require "spec"
require "file_utils"
require "../src/crystalline/requires"
require "../src/crystalline/main"

# The spec executable cannot be started as a compile worker.
Crystalline::Worker::Client.isolated = false

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
end

describe Crystalline::Lightweight::Snapshot do
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
