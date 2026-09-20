require "string_pool"
require "./index"
require "./summary"

module Crystalline::Lightweight
  # What the interactive features keep from a compile. It is built next to
  # the typed program, in the worker process, and shipped to the server as
  # JSON: nothing in it refers back to the program.
  record Snapshot, summary : Summary, index : Index do
    include JSON::Serializable

    def self.from_result(result : Crystal::Compiler::Result) : self
      new(Summary.from_result(result), Index.from_program(result.program))
    end

    # Writes the snapshot of *result* as JSON, without building it first: it
    # is large, and it would come on top of the typed program at the very
    # peak of the worker's memory.
    def self.write(result : Crystal::Compiler::Result, io : IO) : Nil
      JSON.build(io) do |json|
        json.object do
          json.field("summary") { Summary.write(result, json) }
          json.field("index") { Index.from_program(result.program).to_json(json) }
        end
      end
    end

    # Reads a snapshot written by `.write`.
    def self.read(io : IO) : self
      new(InterningPullParser.new(io))
    end

    # A snapshot says the same few things over and over: on a large project
    # 2 million strings (file names, type names, docs…) of which 5% are
    # distinct. Reading the equal ones as a single object takes a third off
    # what the snapshot weighs in the server.
    private class InterningPullParser < JSON::PullParser
      @pool = StringPool.new

      def read_string : String
        @pool.get(super)
      end
    end
  end
end
