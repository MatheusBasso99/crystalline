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
  end
end
