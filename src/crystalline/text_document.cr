require "uri"
require "./position_utils"
require "./project"

class Crystalline::TextDocument
  getter uri : URI
  @inner_contents : Array(String) = [] of String
  getter! version : Int32

  # The client-assigned version, or 0 when the client never sent one.
  def version_number : Int32
    @version || 0
  end

  getter? project : Project?
  getter? dirty = false

  def initialize(@uri, @project, contents : String)
    self.contents = contents
    @dirty = false
  end

  def contents=(contents : String)
    @inner_contents = contents.lines(chomp: false)
  end

  def contents : String
    @inner_contents.join
  end

  def lines_nb : Int32
    @inner_contents.size
  end

  def eof_position : LSP::Position
    if (last_line = @inner_contents.last?)
      if last_line.ends_with?("\n")
        LSP::Position.new(line: @inner_contents.size, character: 0)
      else
        LSP::Position.new(line: @inner_contents.size - 1, character: last_line.size)
      end
    else
      LSP::Position.new(line: 0, character: 0)
    end
  end

  # Applies the changes of one `didChange` notification in the order the
  # client sent them, then adopts the notification's version.
  #
  # The version is a label, not a sequence: the protocol only promises that
  # it increases after each change, not that it is consecutive. Neovim sends
  # its `changedtick` and coalesces every edit made within its debounce
  # window into a single notification, so a burst of keystrokes skips
  # numbers. Gating on consecutive versions (as 0.20.0 did) queued such a
  # change "until the missing version arrived", which never happened: the
  # server's copy of the buffer stayed frozen until the file was reopened,
  # completion replaced ranges computed on stale text, semantic tokens
  # landed on old positions and a format request would have reverted the
  # edits. Notifications arrive in order, so applying them in order is all
  # the synchronisation the protocol asks for.
  def update_contents(content_changes : Array({String, LSP::Range?}), version : Int32? = nil)
    content_changes.each do |(contents, range)|
      if range
        partial_update(contents, range)
      else
        full_update(contents)
      end
    end

    @version = version if version
    @dirty = true
  end

  def mark_saved
    @dirty = false
  end

  private def partial_update(contents : String, range : LSP::Range)
    start_line = @inner_contents[range.start.line]? || ""
    end_line = @inner_contents[range.end.line]? || ""
    # LSP columns are UTF-16 code units, unlike Crystal string indices.
    #
    # The end column is clamped to the line content: slicing out of range would
    # include the line terminator or duplicate the whole line. The start column
    # is deliberately left as is: a column past the line end keeps the whole
    # prefix, which is what an edit spanning the line break expects.
    prefix = start_line[...PositionUtils.utf16_to_char_index(start_line, range.start.character)]
    end_column = PositionUtils.utf16_to_char_index(end_line, range.end.character).clamp(0, end_line.chomp.size)
    suffix = end_line[end_column..]
    replacement_lines = String.build { |str|
      str << prefix << contents << suffix
    }.lines(chomp: false)
    @inner_contents = (@inner_contents[...range.start.line]? || [] of String) + replacement_lines + (@inner_contents[range.end.line + 1...]? || [] of String)
  end

  private def full_update(contents : String)
    self.contents = contents
  end
end
