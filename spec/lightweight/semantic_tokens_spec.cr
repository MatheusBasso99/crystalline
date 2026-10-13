require "spec"
require "lsp/server"
require "../../src/crystalline/lightweight/semantic_tokens"

private def decode_tokens(source : String) : Array({Int32, Int32, Int32, Int32})
  tokens = Crystalline::Lightweight::SemanticTokens.tokens(source)
  return [] of {Int32, Int32, Int32, Int32} unless tokens

  data = tokens.data
  decoded = [] of {Int32, Int32, Int32, Int32}
  line = 0
  character = 0
  index = 0
  while index < data.size
    delta_line = data[index]
    delta_character = data[index + 1]
    line += delta_line
    character = delta_line == 0 ? character + delta_character : delta_character
    decoded << {line, character, data[index + 2], data[index + 3]}
    index += 5
  end
  decoded
end

private def token_type(source : String, line : Int32, character : Int32) : Int32?
  decode_tokens(source).find { |token| token[0] == line && token[1] == character }.try &.[3]
end

describe Crystalline::Lightweight::SemanticTokens do
  it "announces a legend matching the emitted types" do
    legend = Crystalline::Lightweight::SemanticTokens.legend

    legend.token_types.size.should eq(Crystalline::Lightweight::SemanticTokens::TOKEN_TYPES.size)
    legend.token_types.includes?("method").should be_true
    legend.token_types.includes?("variable").should be_true
    legend.token_modifiers.should be_empty
  end

  it "tokenizes declarations" do
    source = "def compute(total : Int32)\n  count = total\nend\nclass Worker\nend\n"

    decode_tokens(source).should eq([
      {0, 0, 3, 12}, # def
      {0, 4, 7, 9},  # compute (function)
      {0, 12, 5, 6}, # total (parameter)
      {0, 20, 5, 1}, # Int32 (type)
      {1, 2, 5, 7},  # count (variable)
      {1, 10, 5, 7}, # total (variable)
      {2, 0, 3, 12}, # end
      {3, 0, 5, 12}, # class
      {3, 6, 6, 2},  # Worker (class)
      {4, 0, 3, 12}, # end
    ])
  end

  it "tokenizes namespaced types and methods" do
    source = "Foo::Bar.new.call\n"

    decode_tokens(source).should eq([
      {0, 0, 3, 0},   # Foo (namespace)
      {0, 5, 3, 1},   # Bar (type)
      {0, 9, 3, 10},  # new (method)
      {0, 13, 4, 10}, # call (method)
    ])
  end

  it "tokenizes qualified declarations, enum members and aliases" do
    source = "class Foo::Bar\nend\n\nenum Color\n  Red\n  Green = 2\nend\n\nalias Aliasy = String\n"

    decode_tokens(source).should eq([
      {0, 0, 5, 12},  # class
      {0, 6, 3, 0},   # Foo (namespace)
      {0, 11, 3, 2},  # Bar (class)
      {1, 0, 3, 12},  # end
      {3, 0, 4, 12},  # enum
      {3, 5, 5, 4},   # Color (enum)
      {4, 2, 3, 17},  # Red (enum member)
      {5, 2, 5, 17},  # Green (enum member)
      {5, 10, 1, 15}, # 2
      {6, 0, 3, 12},  # end
      {8, 0, 5, 12},  # alias
      {8, 6, 6, 1},   # Aliasy (type)
      {8, 15, 6, 1},  # String (type)
    ])
  end

  it "tokenizes properties and parameters" do
    source = "class Builder\n  def initialize(@name : String)\n    @@count = 1\n    @name\n  end\nend\n"

    decode_tokens(source).should eq([
      {0, 0, 5, 12},
      {0, 6, 7, 2},
      {1, 2, 3, 12},
      {1, 6, 10, 10},
      {1, 17, 5, 8},
      {1, 25, 6, 1},
      {2, 4, 7, 8},
      {2, 14, 1, 15},
      {3, 4, 5, 8},
      {4, 2, 3, 12},
      {5, 0, 3, 12},
    ])
  end

  it "tokenizes literals with their source length, not their value" do
    source = "a = 0xFF\nb = \"#fff\"\nc = /x#y/\nd = <<-TEXT\n  body\n  TEXT\n"

    decoded = decode_tokens(source)

    decoded.should contain({0, 4, 4, 15})                                                    # 0xFF, not the decimal value
    decoded.should contain({1, 4, 6, 14})                                                    # "#fff"
    decoded.should contain({2, 4, 5, 16})                                                    # /x#y/
    decoded.any? { |token| token[0] == 3 && token[1] == 4 && token[3] == 14 }.should be_true # heredoc opener
  end

  it "does not report comments inside literals" do
    source = "a = \"#fff\" # real comment\nb = /x#y/\n"

    comments = decode_tokens(source).select { |token| token[3] == 13 }

    comments.should eq([{0, 11, 14, 13}])
  end

  it "counts columns as UTF-16 code units" do
    source = "x = \"😀\"\ncount = 1\ncount\n"

    decoded = decode_tokens(source)

    decoded.should contain({0, 4, 4, 14}) # the emoji is one character, two UTF-16 units
    decoded.should contain({1, 0, 5, 7})
    decoded.should contain({2, 0, 5, 7})
  end

  it "tokenizes multi-line literals line by line" do
    source = "text = <<-TEXT\n  # not a comment\n  body\n  TEXT\n"

    decoded = decode_tokens(source)
    comments = decoded.select { |token| token[3] == 13 }

    comments.should be_empty
    # The literal spans lines 0 to 3 and colors each of them.
    decoded.select { |token| token[3] == 14 }.map { |token| token[0] }.should eq([0, 1, 2, 3])
  end

  it "leaves the interpolations out of a string and tokenizes their code" do
    source = "channel = 1\nkey = \"\#{channel.id}:\#{ channel.fee }\"\n"

    decode_tokens(source).should eq([
      {0, 0, 7, 7},   # channel (variable)
      {0, 10, 1, 15}, # 1
      {1, 0, 3, 7},   # key (variable)
      {1, 6, 1, 14},  # "
      {1, 9, 7, 7},   # channel (variable)
      {1, 17, 2, 10}, # id (method)
      {1, 20, 1, 14}, # :
      {1, 24, 7, 7},  # channel (variable)
      {1, 32, 3, 10}, # fee (method)
      {1, 37, 1, 14}, # "
    ])
  end

  it "tokenizes a string nested in an interpolation" do
    source = "x = \"a\#{\"b\#{y}c\"}d\"\n"

    decode_tokens(source).select { |token| token[3] == 14 }.should eq([
      {0, 4, 2, 14},  # "a
      {0, 8, 2, 14},  # "b
      {0, 14, 2, 14}, # c"
      {0, 17, 2, 14}, # d"
    ])
  end

  it "leaves the interpolations out of multi-line literals" do
    source = "sql = <<-SQL\n  SELECT \#{column}\n  FROM t\n  SQL\nx = \"a\#{\n  1\n}b\"\n"

    decoded = decode_tokens(source)

    decoded.should contain({1, 0, 9, 14})  # "  SELECT "
    decoded.should contain({1, 11, 6, 10}) # column (method)
    decoded.should contain({2, 0, 8, 14})  # "  FROM t"
    decoded.should contain({4, 4, 2, 14})  # "a
    decoded.should contain({5, 2, 1, 15})  # 1
    decoded.should contain({6, 1, 2, 14})  # b"
    decoded.select { |token| token[0] == 5 && token[3] == 14 }.should be_empty
  end

  it "keeps the regexp type around the interpolations of a regexp" do
    source = "r = /a\#{b}c/\n"

    decode_tokens(source).should eq([
      {0, 0, 1, 7},   # r (variable)
      {0, 4, 2, 16},  # /a
      {0, 8, 1, 10},  # b (method)
      {0, 10, 2, 16}, # c/
    ])
  end

  it "does not take the interpolation of a percent literal for a comment" do
    source = "s = %(a\#{b})\n"

    decode_tokens(source).should eq([
      {0, 0, 1, 7},   # s (variable)
      {0, 4, 3, 14},  # %(a
      {0, 9, 1, 10},  # b (method)
      {0, 11, 1, 14}, # )
    ])
  end

  it "keeps the comments of a buffer that does not parse" do
    source = "def broken( # unterminated\n"

    decode_tokens(source).should eq([{0, 12, 14, 13}])
  end

  it "returns nothing for a buffer without tokens" do
    Crystalline::Lightweight::SemanticTokens.tokens("").should be_nil
    Crystalline::Lightweight::SemanticTokens.tokens("  \n").should be_nil
  end
end
