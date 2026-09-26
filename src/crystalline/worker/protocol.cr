require "json"
require "lsp/base/diagnostic"

# The server and its compile workers talk JSON Lines over the worker's
# stdin/stdout: a `Job` first, then any number of `Query`s one way, `Message`s
# the other way. Bulky data (the lightweight snapshot) travels through a file.
module Crystalline::Worker
  record Job,
    entry : String,
    snapshot_path : String,
    lib_path : String? = nil,
    flags : Array(String) = [] of String,
    wants_doc : Bool = false,
    top_level : Bool = false do
    include JSON::Serializable
  end

  enum QueryKind
    Hover
    Definitions
    Completion
  end

  record Query,
    id : Int64,
    kind : QueryKind,
    uri : String,
    line : Int32,
    character : Int32,
    # Completion only: the text of the cursor line and what triggered it.
    line_text : String? = nil,
    trigger_character : String? = nil do
    include JSON::Serializable
  end

  abstract struct Message
    include JSON::Serializable

    use_json_discriminator "type", {
      diagnostics: DiagnosticsMessage,
      compiled:    Compiled,
      response:    Response,
    }
  end

  # Sent as soon as the semantic pass ends, ahead of the snapshot.
  struct DiagnosticsMessage < Message
    getter type = "diagnostics"
    getter diagnostics : Hash(String, Array(LSP::Diagnostic))

    def initialize(@diagnostics)
    end
  end

  # The compile is over and, on success, the snapshot is on disk. *requires*
  # lists the files the compiler reached: all of them on success, those
  # expanded before the error otherwise.
  struct Compiled < Message
    getter type = "compiled"
    getter? success : Bool
    getter requires : Array(String)

    def initialize(@success, @requires = [] of String)
    end
  end

  # *result* is the JSON of the LSP answer, nil when there is none.
  struct Response < Message
    getter type = "response"
    getter id : Int64
    getter result : String?

    def initialize(@id, @result)
    end
  end
end
