require "./analysis/*"
require "./completion_context"

# The requests the lightweight engine misses are answered from a typed
# program. The program is heavy (gigabytes on a large project) and the
# conservative GC never quite lets go of one, so it lives behind this
# interface: in a worker process in production, in-process in the worker
# itself and in the specs.
module Crystalline::Semantic
  alias Definitions = Array(LSP::LocationLink | LSP::Location)

  abstract class Provider
    abstract def hover(file_uri : URI, position : LSP::Position) : LSP::Hover?
    abstract def definitions(file_uri : URI, position : LSP::Position) : Definitions?
    # *line* is the text of the line under the cursor.
    abstract def completion(file_uri : URI, position : LSP::Position, line : String, trigger_character : String?) : Array(LSP::CompletionItem)?

    # Releases whatever backs the provider.
    def close : Nil
    end
  end

  # Answers from a compilation result held in this very process.
  class Local < Provider
    def initialize(@result : Crystal::Compiler::Result)
    end

    def hover(file_uri : URI, position : LSP::Position) : LSP::Hover?
      result = @result
      location = Crystal::Location.new(
        file_uri.decoded_path,
        line_number: position.line + 1,
        column_number: position.character + 1
      )
      result.try { |r|
        Analysis.nodes_at_cursor(r, location)
      }.try do |nodes, _context|
        n = nodes.last?
        contents = [] of String

        # LSP::Log.info { "Node at cursor: #{n}" }
        # LSP::Log.info { "Node class: #{n.class}" }
        # LSP::Log.info { "Node expansion: #{n.expanded if n.responds_to? :expanded}" }
        # LSP::Log.info { "Node type: #{n.try &.type?}" }
        # LSP::Log.info { "Node type class: #{n.try &.type?.try &.class}" }
        # LSP::Log.info { "Nodes classes: #{nodes.map &.class}" }
        # LSP::Log.info { "Context: #{_context}" }

        if n.is_a? Crystal::Def || n.is_a? Crystal::Macro
          contents << code_markdown(Utils.format_def(n), language: "crystal")
          append_markdown_doc contents, n.doc
        elsif (n.is_a? Crystal::MacroExpression || n.is_a? Crystal::MacroIf) && n.expanded
          contents << code_markdown(n.expanded.to_s, language: "crystal")
        elsif n.responds_to? :resolved_type
          str = ""
          if n.responds_to? :name
            str += "#{n.name}: #{n.resolved_type}"
          else
            str += n.resolved_type.to_s
            str = n.to_s if str.empty?
          end
          contents << code_markdown(str, language: "crystal")
          append_markdown_doc contents, n.resolved_type.doc
        elsif n.is_a? Crystal::Call
          if (definition = n.target_defs.try &.first?)
            contents << code_markdown(Utils.format_def(definition), language: "crystal")
          elsif n.expanded && n.expanded_macro
            contents << code_markdown(n.expanded.to_s, language: "crystal")
          end
          append_markdown_doc contents, (definition || n.expanded_macro).try &.doc
        elsif n.is_a? Crystal::Path
          node_type = n.type? || Utils.resolve_path(n, nodes)
          if node_type
            contents << code_markdown(node_type.to_s, language: "crystal")
            append_markdown_doc contents, node_type.doc
          end
        elsif n
          str = ""
          if n.responds_to? :name
            str += "#{n.name}: #{n.type? || "?"}"
          else
            str += n.type?.to_s
            str = n.to_s if str.empty?
          end
          contents << code_markdown(str, language: "crystal")
          append_markdown_doc contents, n.doc
        end

        LSP::Hover.new(
          contents: LSP::MarkupContent.new(
            kind: LSP::MarkupKind::MarkDown,
            value: contents.join "\n",
          ),
        )
      end
    rescue
      nil
    end

    def definitions(file_uri : URI, position : LSP::Position) : Definitions?
      result = @result
      location = Crystal::Location.new(
        file_uri.decoded_path,
        line_number: position.line + 1,
        column_number: position.character + 1
      )
      result.try { |r|
        Analysis.definitions_at_cursor(r, location)
      }.try do |definitions|
        node = definitions.node
        definitions.locations.try &.map { |start_loc, end_loc|
          if node.is_a? Crystal::Path || node.is_a? Crystal::Require
            target_uri = "file://#{start_loc.original_filename}"
            origin_location = node.location.not_nil!
            origin_end_location = definitions.node.end_location || Crystal::Location.new(
              file_uri.decoded_path,
              line_number: origin_location.line_number + 1,
              column_number: 0
            )

            origin_selection_range = LSP::Range.new(
              start: LSP::Position.new(line: origin_location.line_number - 1, character: origin_location.column_number - 1),
              end: LSP::Position.new(line: origin_end_location.line_number - 1, character: origin_end_location.column_number),
            )
            target_range = LSP::Range.new(
              start: LSP::Position.new(line: start_loc.line_number - 1, character: start_loc.column_number - 1),
              end: LSP::Position.new(line: end_loc.line_number - 1, character: end_loc.column_number),
            )

            LSP::LocationLink.new(
              target_uri: target_uri,
              origin_selection_range: origin_selection_range,
              target_range: target_range,
              target_selection_range: target_range,
            )
          else
            LSP::Location.new(
              uri: "file://#{start_loc.original_filename}",
              range: LSP::Range.new(
                start: LSP::Position.new(line: start_loc.line_number - 1, character: start_loc.column_number - 1),
                end: LSP::Position.new(line: end_loc.line_number - 1, character: end_loc.column_number),
              ),
            )
          end
        }
      end
    rescue
      nil
    end

    def completion(file_uri : URI, position : LSP::Position, line : String, trigger_character : String?) : Array(LSP::CompletionItem)?
      return unless completion_context = CompletionContext.detect(line, position.character, trigger_character)

      result = @result
      trigger_character = completion_context.trigger_character
      location = Crystal::Location.new(
        file_uri.decoded_path,
        line_number: position.line + 1,
        column_number: completion_context.analysis_column,
      )

      nodes, _ = Analysis.nodes_at_cursor(result, location)
      nodes.last?.try do |n|
        completion_items = [] of LSP::CompletionItem

        # LSP::Log.info { "Node at cursor: #{n}" }
        # LSP::Log.info { "Node class: #{n.class}" }
        # LSP::Log.info { "Node type: #{n.type?}" }
        # LSP::Log.info { "Node type class: #{n.type?.try &.class}" }
        # LSP::Log.info { "Node type defs: #{n.type?.try &.defs}" }

        range = completion_context.completion_range(position.line)

        case trigger_character
        when "."
          node_type = n.type?
          node_type = node_type.base_type if node_type.responds_to? :base_type

          # We are looking for methods…
          if node_type.responds_to? :defs
            Analysis.all_defs(node_type.not_nil!).each { |def_name, definition, owner_type, nesting|
              owner_prefix = "*Inherited from: #{owner_type.name}*\n\n" if owner_type.responds_to? :name && owner_type != n.type
              owner_prefix ||= ""
              documentation = (owner_prefix + (definition.doc || ""))

              text_edit = LSP::TextEdit.new(
                range: range,
                new_text: def_name,
              )

              completion_items << LSP::CompletionItem.new(
                label: Utils.format_def(definition, short: true),
                insert_text: def_name,
                kind: LSP::CompletionItemKind::Function,
                filter_text: def_name,
                detail: Utils.format_def(definition),
                text_edit: text_edit,
                sort_text: (nesting + 1).chr.to_s + def_name,
                documentation: documentation.try { |doc|
                  LSP::MarkupContent.new(
                    kind: LSP::MarkupKind::MarkDown,
                    value: doc,
                  )
                },
              )
            }

            Analysis.all_macros(n.type).each { |macro_name, macro_def, owner_type, nesting|
              owner_prefix = "*Inherited from: #{owner_type.name}*\n\n" if owner_type.responds_to? :name && owner_type != n.type
              owner_prefix ||= ""
              documentation = (owner_prefix + (macro_def.doc || ""))

              text_edit = LSP::TextEdit.new(
                range: range,
                new_text: macro_name,
              )

              completion_items << LSP::CompletionItem.new(
                label: Utils.format_def(macro_def, short: true),
                insert_text: macro_name,
                kind: LSP::CompletionItemKind::Method,
                filter_text: macro_name,
                detail: Utils.format_def(macro_def),
                text_edit: text_edit,
                sort_text: (nesting + 1).chr.to_s + macro_name,
                documentation: documentation.try { |doc|
                  LSP::MarkupContent.new(
                    kind: LSP::MarkupKind::MarkDown,
                    value: doc,
                  )
                },
              )
            }
          end
        when ":"
          # We are looking for module types…
          node_type = n.type?

          if n.is_a? Crystal::Path
            node_type ||= Utils.resolve_path(n, nodes)
          end

          if node_type.is_a? Crystal::MetaclassType
            node_type = node_type.instance_type

            Analysis.all_submodules(result, node_type).uniq(&.to_s).each { |type|
              type_string = type.to_s

              text_edit = LSP::TextEdit.new(
                range: range,
                new_text: type_string.lchop(node_type.to_s).lchop(trigger_character || ':'),
              )

              completion_items << LSP::CompletionItem.new(
                label: type_string,
                text_edit: text_edit,
                kind: Crystalline::Utils.map_completion_kind(type, default: LSP::CompletionItemKind::Module),
                documentation: type.doc.try { |doc|
                  LSP::MarkupContent.new(
                    kind: LSP::MarkupKind::MarkDown,
                    value: doc,
                  )
                },
              )
            }
          end
        else
          # Context autocompletion.
          context = Analysis.context_at(result, location)
          if trigger_character == "@"
            context.try &.select!(&.starts_with?("@"))
          end
          context.try &.each { |name, type|
            label = "#{name} : #{type}"
            text_edit = LSP::TextEdit.new(
              range: range,
              new_text: name.lchop(trigger_character || ""),
            )
            completion_items << LSP::CompletionItem.new(
              label: label,
              text_edit: text_edit,
              kind: LSP::CompletionItemKind::Variable,
              documentation: type.doc.try { |doc|
                LSP::MarkupContent.new(
                  kind: LSP::MarkupKind::MarkDown,
                  value: doc,
                )
              },
            )
          }
        end

        completion_items
      end
    rescue
      nil
    end

    private def append_markdown_doc(contents : Array(String), doc : String?)
      if doc
        contents << "----------"
        contents << <<-MARKDOWN
        #{doc}
        MARKDOWN
      end
    end

    private def code_markdown(str : String?, *, language = "") : String
      if str
        <<-MARKDOWN
        ```#{language}
        #{str}
        ```
        MARKDOWN
      else
        ""
      end
    end
  end
end
