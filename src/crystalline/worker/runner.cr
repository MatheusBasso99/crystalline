require "./protocol"
require "../semantic"
require "../lightweight/snapshot"

# The worker side: compiles one job, then answers semantic queries until its
# stdin closes. The typed program never leaves this process, so the operating
# system takes all of it back when the server lets the worker go.
module Crystalline::Worker
  # The snapshot is written when the heap is at its fullest, and all of it is
  # garbage as soon as it is written. The collector grows the heap by what is
  # allocated between two collections, garbage or not: collecting more often
  # during that phase keeps its peak 150 MB lower on a large project, at no
  # measurable cost.
  SNAPSHOT_GC_DIVISOR = 64

  # Entry point of `crystalline --worker`.
  def self.start : Nil
    # Stdout carries the protocol. Logs default to it: send them to stderr,
    # which the worker shares with the server, and keep them rare since
    # editors surface a server's stderr as errors.
    ::Log.setup(:warn, ::Log::IOBackend.new(STDERR))
    run(STDIN, STDOUT)
  end

  def self.run(input : IO, output : IO) : Nil
    return unless line = input.gets

    job = Job.from_json(line)
    result, diagnostics = Analysis.compile_with_diagnostics(
      Analysis.sources_for(job.entry),
      lib_path: job.lib_path,
      wants_doc: job.wants_doc,
      top_level: job.top_level,
      compiler_flags: job.flags,
    )
    send(output, DiagnosticsMessage.new(diagnostics.to_h))

    unless result
      send(output, Compiled.new(success: false))
      return
    end

    File.open(job.snapshot_path, "w") do |file|
      GC.with_free_space_divisor(SNAPSHOT_GC_DIVISOR) { Lightweight::Snapshot.write(result, file) }
    end
    send(output, Compiled.new(success: true, requires: result.program.requires.to_a))
    return if job.top_level

    # Nothing allocates while the worker waits for queries, so the collector
    # would never run again: the snapshot, garbage by now, and the slack of
    # the compile would stay in the heap for as long as the worker lives.
    GC.collect_and_unmap

    provider = Semantic::Local.new(result)
    while line = input.gets
      # A line that does not parse is skipped rather than fatal.
      next unless query = (Query.from_json(line) rescue nil)
      send(output, Response.new(query.id, answer(provider, query)))
    end
  end

  private def self.answer(provider : Semantic::Provider, query : Query) : String?
    uri = URI.parse(query.uri)
    position = LSP::Position.new(line: query.line, character: query.character)
    case query.kind
    in .hover?       then provider.hover(uri, position).try(&.to_json)
    in .definitions? then provider.definitions(uri, position).try(&.to_json)
    in .completion?
      provider.completion(uri, position, query.line_text || "", query.trigger_character).try(&.to_json)
    end
  end

  private def self.send(output : IO, message : Message) : Nil
    message.to_json(output)
    output << '\n'
    output.flush
  end
end
