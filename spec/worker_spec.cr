require "spec"
require "file_utils"
require "../src/crystalline/requires"
require "../src/crystalline/main"

# The spec executable cannot be started as a compile worker.
Crystalline::Worker::Client.isolated = false
# Whatever the machine running the specs is going through.
Crystalline::Worker::Client.memory_pressure = -> { false }

private def with_worker_project(source : String, &)
  root = File.join(Dir.tempdir, "crystalline-worker-#{Random::Secure.hex(8)}")
  path = File.join(root, "src", "main.cr")
  Dir.mkdir_p(File.dirname(path))
  File.write(File.join(root, "shard.yml"), <<-YAML)
    name: worker_spec
    targets:
      worker_spec:
        main: src/main.cr
  YAML
  File.write(path, source)

  begin
    Crystalline::EnvironmentConfig.run
    yield root, path
  ensure
    FileUtils.rm_rf(root)
  end
end

private def job_for(path : String, **options) : Crystalline::Worker::Job
  Crystalline::Worker::Job.new(**options, entry: path, snapshot_path: File.tempname("crystalline-worker-spec", ".json"), wants_doc: true)
end

private def position_of(source : String, needle : String, offset : Int32 = 1) : LSP::Position
  lines = source.lines
  line_number = lines.index!(&.includes?(needle))
  LSP::Position.new(line: line_number, character: lines[line_number].index!(needle) + offset)
end

private SOURCE = <<-CRYSTAL
  class Greeter
    # Shouts.
    def shout(text : String) : String
      text.upcase
    end
  end

  greeting = Greeter.new.shout("hi")
  greeting.size
  CRYSTAL

describe Crystalline::Worker do
  it "compiles a job and ships the requires and the lightweight snapshot" do
    with_worker_project(SOURCE) do |_root, path|
      job = job_for(path)
      worker = Crystalline::Worker::Client.spawn
      published = [] of Hash(String, Array(LSP::Diagnostic))

      compiled = worker.compile(job) { |diagnostics| published << diagnostics }.should_not be_nil
      compiled.success?.should be_true
      compiled.requires.should contain(path)
      published.size.should eq(1)
      published.first["file://#{path}"].should be_empty

      snapshot = Crystalline::Worker::Client.take_snapshot(job).should_not be_nil
      snapshot.index.types["Greeter"].methods.map(&.name).should contain("shout")
      snapshot.summary.type("Greeter").should_not be_nil
      File.exists?(job.snapshot_path).should be_false
    ensure
      worker.try(&.close)
    end
  end

  it "reports the diagnostics of a program that does not type" do
    with_worker_project(%(1 + "a"\n)) do |_root, path|
      worker = Crystalline::Worker::Client.spawn
      published = [] of Hash(String, Array(LSP::Diagnostic))
      job = job_for(path)

      worker.compile(job) { |diagnostics| published << diagnostics }
      published.first["file://#{path}"].map(&.message).join.should contain("Int32#+")
    ensure
      worker.try(&.close)
      job.try { |j| File.delete?(j.snapshot_path) }
    end
  end

  it "ships the files a compile that failed had reached" do
    with_worker_project(%(require "./broken"\n)) do |root, path|
      broken = File.join(root, "src", "broken.cr")
      File.write(broken, "class Broken < Missing\nend\n")
      job = job_for(path)
      worker = Crystalline::Worker::Client.spawn
      published = [] of Hash(String, Array(LSP::Diagnostic))

      compiled = worker.compile(job) { |diagnostics| published << diagnostics }.should_not be_nil
      compiled.success?.should be_false
      compiled.requires.should contain(path)
      compiled.requires.should contain(broken)
      published.first["file://#{broken}"].map(&.message).join.should contain("undefined constant Missing")
    ensure
      worker.try(&.close)
    end
  end

  it "answers the semantic queries like the program it holds" do
    with_worker_project(SOURCE) do |_root, path|
      uri = URI.parse("file://#{path}")
      result = Crystalline::Analysis.compile(LSP::Server.new(IO::Memory.new, IO::Memory.new), uri, ignore_diagnostics: true, wants_doc: true).not_nil!
      local = Crystalline::Semantic::Local.new(result)
      job = job_for(path)
      worker = Crystalline::Worker::Client.spawn
      worker.compile(job) { }
      File.delete?(job.snapshot_path)

      position = position_of(SOURCE, "shout(\"hi\")")
      hover = worker.hover(uri, position).should_not be_nil
      hover.to_json.should eq(local.hover(uri, position).to_json)
      hover.to_json.should contain("Shouts.")

      definitions = worker.definitions(uri, position).should_not be_nil
      definitions.to_json.should eq(local.definitions(uri, position).to_json)

      dot = position_of(SOURCE, "greeting.size", "greeting.".size)
      items = worker.completion(uri, dot, "greeting.size", ".").should_not be_nil
      items.map(&.insert_text).should contain("upcase")

      worker.close
      worker.hover(uri, position).should be_nil
    ensure
      worker.try(&.close)
    end
  end

  it "stops after a top-level job" do
    with_worker_project(SOURCE) do |_root, path|
      job = job_for(path, top_level: true)
      worker = Crystalline::Worker::Client.spawn
      worker.compile(job) { }.try(&.success?).should be_true
      Crystalline::Worker::Client.take_snapshot(job).should_not be_nil

      worker.hover(URI.parse("file://#{path}"), position_of(SOURCE, "shout(\"hi\")")).should be_nil
      worker.closed?.should be_true
    end
  end

  it "skips the lines of the worker that are not messages" do
    output = IO::Memory.new(<<-LINES)
      warning: something printed by a macro
      {"type":"compiled","success":tr
      {"type":"unknown"}
      {"type":"compiled","success":true,"requires":["a.cr"]}

      LINES
    worker = Crystalline::Worker::Client.new(IO::Memory.new, output)

    compiled = worker.compile(job_for("a.cr")) { }.should_not be_nil
    compiled.requires.should eq(["a.cr"])
  end

  it "reports a worker that went away as a failed compile" do
    worker = Crystalline::Worker::Client.new(IO::Memory.new, IO::Memory.new)
    worker.compile(job_for("a.cr")) { }.should be_nil
  end

  it "lets go of a worker that has been idle for too long" do
    previous = Crystalline::Worker::Client.idle_timeout
    Crystalline::Worker::Client.idle_timeout = 20.milliseconds
    worker = Crystalline::Worker::Client.new(IO::Memory.new, IO::Memory.new)
    worker.close_when_idle

    worker.closed?.should be_false
    sleep 100.milliseconds
    worker.closed?.should be_true
  ensure
    Crystalline::Worker::Client.idle_timeout = previous if previous
  end

  it "lets go of an idle worker when the system runs short of memory" do
    Crystalline::Worker::Client.memory_pressure = -> { true }
    worker = Crystalline::Worker::Client.new(IO::Memory.new, IO::Memory.new)
    worker.close_when_idle

    worker.closed?.should be_false
    sleep 50.milliseconds
    worker.closed?.should be_true
  ensure
    Crystalline::Worker::Client.memory_pressure = -> { false }
  end
end

describe Crystalline::MemoryPressure do
  it "reads the pressure stall information of Linux" do
    calm = "some avg10=0.31 avg60=0.12 avg300=0.02 total=1234\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n"
    short = "some avg10=23.40 avg60=9.12 avg300=2.02 total=99999\nfull avg10=11.00 avg60=3.00 avg300=1.00 total=555\n"

    Crystalline::MemoryPressure.stalled?(calm).should be_false
    Crystalline::MemoryPressure.stalled?(short).should be_true
    Crystalline::MemoryPressure.stalled?("").should be_false
  end

  it "tells, or says false where it cannot" do
    Crystalline::MemoryPressure.high?.should be_a(Bool)
  end
end

class Crystalline::Workspace
  def semantic_provider_for_test(key : String) : Crystalline::Semantic::Provider?
    @semantic_cache[key]?
  end
end

# Plays the client accepting the progress token, which is what starts a compile.
private def accept_progress(server : LSP::Server)
  spawn do
    until request = server.requests_sent.delete(0)
      sleep 1.millisecond
    end
    request.as(LSP::RequestMessage).on_response(nil, nil)
  end
end

describe Crystalline::Workspace do
  it "keeps the worker of the last compile as the semantic fallback, one at a time" do
    with_worker_project(SOURCE) do |root, path|
      server = LSP::Server.new(IO::Memory.new, IO::Memory.new)
      workspace = Crystalline::Workspace.new(server, "file://#{root}")
      uri = URI.parse("file://#{path}")
      workspace.opened_documents[uri.to_s] = Crystalline::TextDocument.new(uri, workspace.projects.first?, SOURCE)

      accept_progress(server)
      first = workspace.compile(server, uri, ignore_diagnostics: true, wants_doc: true).should_not be_nil
      workspace.semantic_provider_for_test(uri.to_s).should be(first)
      workspace.projects.first.lightweight_index.not_nil!.types.has_key?("Greeter").should be_true
      first.hover(uri, position_of(SOURCE, "shout(\"hi\")")).should_not be_nil

      accept_progress(server)
      second = workspace.compile(server, uri, ignore_diagnostics: true, wants_doc: true, ignore_cached_result: true).should_not be_nil
      second.should_not be(first)
      first.as(Crystalline::Worker::Client).closed?.should be_true
      second.as(Crystalline::Worker::Client).closed?.should be_false
    ensure
      second.try(&.close)
    end
  end

  it "compiles a file created after the dependency calculation through the entry point" do
    source = <<-CRYSTAL
      class Job
        macro inherited
          {% raise "jobs are final" %}
        end
      end

      require "./jobs/*"
      CRYSTAL

    with_worker_project(source) do |root, path|
      jobs = File.join(root, "src", "jobs")
      Dir.mkdir_p(jobs)
      File.write(File.join(jobs, "existing.cr"), "")
      server = LSP::Server.new(IO::Memory.new, IO::Memory.new)
      workspace = Crystalline::Workspace.new(server, "file://#{root}")
      project = workspace.projects.first
      workspace.recalculate_dependencies(server, project)
      project.dependencies.should contain(path)

      # Created after that calculation, and wrong in a way its own compile
      # reports as `undefined constant Job`, which is not the error.
      created = File.join(jobs, "created.cr")
      File.write(created, "class Created < Job\nend\n")
      created_uri = URI.parse("file://#{created}")
      workspace.opened_documents[created_uri.to_s] = Crystalline::TextDocument.new(created_uri, nil, File.read(created))

      accept_progress(server)
      workspace.compile(server, created_uri, ignore_diagnostics: false, discard_nil_cached_result: true).should be_nil

      project.dependencies.should contain(created)
      project.outsiders.should be_empty
      server.output.to_s.should contain("jobs are final")
      server.output.to_s.should_not contain("undefined constant Job")

      # A file the entry point does not require compiles on its own, and is
      # not looked for again.
      scratch = File.join(root, "scratch.cr")
      File.write(scratch, "")
      accept_progress(server)
      workspace.compile(server, URI.parse("file://#{scratch}"), ignore_diagnostics: true)
      project.outsiders.should eq(Set{scratch})
      project.dependencies.should_not contain(scratch)
    end
  end
end

describe Crystalline::Lightweight::Snapshot do
  it "writes the snapshot it would build" do
    with_worker_project(SOURCE) do |_root, path|
      result = Crystalline::Analysis.compile(LSP::Server.new(IO::Memory.new, IO::Memory.new), URI.parse("file://#{path}"), ignore_diagnostics: true, wants_doc: true).not_nil!
      built = JSON.parse(Crystalline::Lightweight::Snapshot.from_result(result).to_json)
      written = JSON.parse(String.build { |io| Crystalline::Lightweight::Snapshot.write(result, io) })

      written.should eq(built)
      written["summary"]["types"].as_h.has_key?("Greeter").should be_true
    end
  end

  it "reads equal strings as one object" do
    source = <<-CRYSTAL
      class Greeter
        def shout(text : String) : String
          text.upcase
        end

        def whisper(text : String) : String
          text.downcase
        end
      end

      Greeter.new.shout(Greeter.new.whisper("hi"))
      CRYSTAL

    with_worker_project(source) do |_root, path|
      result = Crystalline::Analysis.compile(LSP::Server.new(IO::Memory.new, IO::Memory.new), URI.parse("file://#{path}"), ignore_diagnostics: true, wants_doc: true).not_nil!
      json = String.build { |io| Crystalline::Lightweight::Snapshot.write(result, io) }
      snapshot = Crystalline::Lightweight::Snapshot.read(IO::Memory.new(json))

      snapshot.to_json.should eq(Crystalline::Lightweight::Snapshot.from_json(json).to_json)
      methods = snapshot.index.types["Greeter"].methods
      methods.size.should be > 1
      filenames = methods.compact_map(&.location.try(&.filename.as?(String)))
      filenames.size.should be > 1
      filenames.each(&.should(be(filenames.first)))
      methods.each(&.owner.should(be(methods.first.owner)))
    end
  end

  it "flattens macro-generated locations to their expansion site" do
    source = <<-CRYSTAL
      macro define_greet
        def greet : String
          "hi"
        end
      end

      class Greeter
        define_greet
      end

      Greeter.new.greet
      CRYSTAL

    with_worker_project(source) do |_root, path|
      result = Crystalline::Analysis.compile(LSP::Server.new(IO::Memory.new, IO::Memory.new), URI.parse("file://#{path}"), ignore_diagnostics: true).not_nil!
      greeter = Crystalline::Lightweight::Snapshot.from_result(result).index.types["Greeter"]
      greeter.methods.find!(&.name.==("greet")).location.not_nil!.filename.should be_a(Crystal::VirtualFile)

      shipped = Crystalline::Lightweight::TypeInfo.from_json(greeter.to_json)
      location = shipped.methods.find!(&.name.==("greet")).location.not_nil!
      location.filename.should eq(path)
      location.line_number.should eq(source.lines.index!(&.includes?("  define_greet")) + 1)
    end
  end
end
