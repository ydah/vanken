# frozen_string_literal: true

RSpec.describe "display-filter lexer" do
  before { require "vanken/core/display_filter/compiler" }

  cases = {
    "tcp.port" => [:identifier, "tcp.port"], "frame.number" => [:identifier, "frame.number"],
    "dns.a" => [:identifier, "dns.a"], "_custom.field_1" => [:identifier, "_custom.field_1"],
    "tcp" => [:identifier, "tcp"], "ip" => [:identifier, "ip"],
    "0" => [:integer, 0], "10" => [:integer, 10], "-10" => [:integer, -10],
    "0x1f" => [:integer, 31], "0XFF" => [:integer, 255], "0o17" => [:integer, 15],
    "0b101" => [:integer, 5], "1.5" => [:float, 1.5], "-1.5" => [:float, -1.5],
    "1e3" => [:float, 1000.0], "true" => [:boolean, true], "false" => [:boolean, false],
    '"hello"' => [:string, "hello"], '""' => [:string, ""],
    '"a\"b"' => [:string, 'a"b'], '"a\\\\b"' => [:string, 'a\\b'],
    '"\\x41"' => [:string, "A"],
    '"é"' => [:string, "é"], '"\\xC3\\xA9"' => [:string, "é"],
    '"é\\xAA"' => [:string, "é\xaa".b],
    "192.0.2.1" => [:address, "192.0.2.1"], "192.0.2.0/24" => [:address, "192.0.2.0/24"],
    "10.0.0.1/8" => [:address, "10.0.0.1/8"], "::1" => [:address, "::1"],
    "fe80::1/64" => [:address, "fe80::1/64"], "2001:db8::1" => [:address, "2001:db8::1"],
    "2001:db8::/32" => [:address, "2001:db8::/32"],
    "aa:bb:cc:dd:ee:ff:00:11" => [:address, "aa:bb:cc:dd:ee:ff:00:11"],
    "aa:bb:cc:dd:ee:ff" => [:mac, "aa:bb:cc:dd:ee:ff"],
    "aa-bb-cc-dd-ee-ff" => [:mac, "aa-bb-cc-dd-ee-ff"],
    "aabb.ccdd.eeff" => [:mac, "aabb.ccdd.eeff"], "AA:BB:CC" => [:bytes, "AA:BB:CC"],
    "aa:bb:cc" => [:bytes, "aa:bb:cc"], "aa:bb" => [:bytes, "aa:bb"],
    "==" => [:operator, :eq], "eq" => [:operator, :eq], "!=" => [:operator, :ne],
    "ne" => [:operator, :ne], "~=" => [:operator, :any_ne], "any_ne" => [:operator, :any_ne],
    ">" => [:operator, :gt], "gt" => [:operator, :gt], "<" => [:operator, :lt],
    "lt" => [:operator, :lt], ">=" => [:operator, :ge], "ge" => [:operator, :ge],
    "<=" => [:operator, :le], "le" => [:operator, :le], "contains" => [:operator, :contains],
    "matches" => [:operator, :matches], "in" => [:operator, :in], "&" => [:operator, :bitmask],
    "and" => [:operator, :and], "&&" => [:operator, :and], "or" => [:operator, :or],
    "||" => [:operator, :or], "not" => [:operator, :not], "!" => [:operator, :not],
    "(" => [:lparen, "("], ")" => [:rparen, ")"], "{" => [:lbrace, "{"],
    "}" => [:rbrace, "}"], "," => [:comma, ","], ".." => [:range, ".."]
  }

  cases.each do |input, (type, value)|
    it "lexes #{input.inspect}" do
      token = Vanken::Core::DisplayFilter::Lexer.new("  #{input}").tokens.first
      expect([token.type, token.value, token.position, token.length]).to eq([type, value, 2, input.bytesize])
    end
  end

  it "separates adjacent range bounds" do
    tokens = Vanken::Core::DisplayFilter::Lexer.new("1..4").tokens
    expect(tokens.map(&:type)).to eq(%i[integer range integer eof])
  end

  ['"unterminated', '"\\q"', '"\\xGG"', "192.0.2.999", "2001:db8::/129", "@", "'str'", "0b102"].each do |input|
    it "rejects #{input.inspect} with its location" do
      expect { Vanken::Core::DisplayFilter::Lexer.new(input).tokens }
        .to raise_error(Vanken::Core::DisplayFilter::SyntaxError) { |error| expect(error.position).to eq(0) }
    end
  end
end
