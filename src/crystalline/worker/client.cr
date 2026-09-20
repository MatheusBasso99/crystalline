require "./protocol"
require "./runner"
require "../semantic"
require "../lightweight/snapshot"

# The server side of a compile worker: spawns the process, runs one job on it
# and then keeps it around as the semantic provider of that compilation,
# until it is replaced, cancelled or has been idle for too long.
class Crystalline::Worker::Client < Crystalline::Semantic::Provider
  # How long an unused worker (and its typed program) is kept. Zero lets the
  # worker go as soon as its compile ends.
  class_property idle_timeout : Time::Span = (ENV["CRYSTALLINE_WORKER_IDLE_TIMEOUT"]?.try(&.to_i?) || 300).seconds

  QUERY_TIMEOUT = 15.seconds

  # The GC never hands memory back on its defaults, and grows the heap
  # eagerly: on a large project that is a gigabyte of difference at the peak.
  GC_ENV = {"GC_FREE_SPACE_DIVISOR" => "12", "GC_UNMAP_THRESHOLD" => "1"}

  getter? closed = false
  @lock = Mutex.new
  @last_query_id = 0_i64
  @last_used : Time::Instant = Time.instant

  # Workers run inside this process when false. That gives up the memory
  # isolation, so it is only meant for the specs: their executable is not
  # crystalline and cannot be started as a worker.
  class_property? isolated = true

  def self.spawn : self
    return in_process unless isolated?

    env = GC_ENV.reject { |name, _| ENV.has_key?(name) }
    process = Process.new(Process.executable_path.not_nil!, ["--worker"], env: env, input: :pipe, output: :pipe, error: :inherit)
    new(process.input, process.output, process)
  end

  private def self.in_process : self
    worker_input, input = IO.pipe
    output, worker_output = IO.pipe
    ::spawn do
      Worker.run(worker_input, worker_output)
    rescue IO::Error
      # The client hung up first.
    ensure
      worker_output.close
    end
    new(input, output)
  end

  # *input* and *output* are the worker's.
  def initialize(@input : IO, @output : IO, @process : Process? = nil)
  end

  # Runs *job*, yielding its diagnostics as soon as they are known. Returns
  # nil when the worker went away first: it crashed, or `#close` cancelled it.
  def compile(job : Job, & : Hash(String, Array(LSP::Diagnostic)) ->) : Compiled?
    @lock.synchronize do
      send(job)
      while message = receive
        case message
        when DiagnosticsMessage then yield message.diagnostics
        when Compiled           then return message
        end
      end
    end
    nil
  end

  # The snapshot of a successful *job*. The file it travelled in is removed.
  def self.take_snapshot(job : Job) : Lightweight::Snapshot?
    File.open(job.snapshot_path) { |file| Lightweight::Snapshot.read(file) }
  rescue ex : File::Error | JSON::ParseException
    LSP::Log.warn(exception: ex) { "[worker] unreadable snapshot: #{ex.message}" }
    nil
  ensure
    File.delete?(job.snapshot_path)
  end

  # Closes the worker once it has gone `idle_timeout` without a query.
  def close_when_idle : Nil
    @output.as?(IO::FileDescriptor).try(&.read_timeout = QUERY_TIMEOUT)
    @last_used = Time.instant
    ::spawn do
      until closed?
        remaining = self.class.idle_timeout - (Time.instant - @last_used)
        if remaining > Time::Span.zero
          sleep remaining
        else
          LSP::Log.info { "[worker] idle for #{self.class.idle_timeout.total_seconds.to_i}s: releasing the typed program" }
          close
        end
      end
    end
  end

  def hover(file_uri : URI, position : LSP::Position) : LSP::Hover?
    query(LSP::Hover, QueryKind::Hover, file_uri, position)
  end

  def definitions(file_uri : URI, position : LSP::Position) : Semantic::Definitions?
    query(Semantic::Definitions, QueryKind::Definitions, file_uri, position)
  end

  def completion(file_uri : URI, position : LSP::Position, line : String, trigger_character : String?) : Array(LSP::CompletionItem)?
    query(Array(LSP::CompletionItem), QueryKind::Completion, file_uri, position, line, trigger_character)
  end

  def close : Nil
    return if closed?
    @closed = true
    @input.close rescue nil
    @process.try do |process|
      process.terminate(graceful: false) rescue nil
      process.wait
    end
    @output.close rescue nil
  end

  private def query(type : T.class, kind : QueryKind, file_uri : URI, position : LSP::Position, line_text : String? = nil, trigger_character : String? = nil) : T? forall T
    return if closed?

    @lock.synchronize do
      id = (@last_query_id += 1)
      send(Query.new(id, kind, file_uri.to_s, position.line, position.character, line_text, trigger_character))
      while message = receive
        next unless message.is_a?(Response) && message.id == id
        @last_used = Time.instant
        return message.result.try { |result| T.from_json(result) }
      end
    end
    # No answer: the worker is gone, or stuck past the timeout.
    close
    nil
  end

  private def send(message) : Nil
    message.to_json(@input)
    @input << '\n'
    @input.flush
  rescue IO::Error
  end

  # The next message of the worker, nil once its output is over. Anything
  # that is not a message (a stray print, a truncated line) is skipped.
  private def receive : Message?
    while line = @output.gets
      begin
        return Message.from_json(line)
      rescue JSON::ParseException
        LSP::Log.debug { "[worker] skipped output: #{line[0, 200]}" }
      end
    end
    nil
  rescue IO::Error
    nil
  end
end
