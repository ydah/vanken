# frozen_string_literal: true

RSpec.describe "display-filter parser" do
  before { require "vanken/core/display_filter/compiler" }

  it "rejects excessive size, token count, and nesting without exhausting a worker stack" do
    [("!" * 1000) + "tcp", ("(" * 1000) + "tcp" + (")" * 1000), ["tcp"] * 600 * " or ", " " * 9000].each do |expression|
      expect { Vanken::Core::DisplayFilter.compile(expression) }.to raise_error(Vanken::Core::DisplayFilter::SyntaxError)
    end
    expect(Vanken::Core::DisplayFilter.compile(("(" * 32) + "tcp" + (")" * 32)).fast?).to be(true)
  end

  valid = ["", "tcp", "not tcp", "!tcp", "(tcp)", "tcp and udp", "tcp or udp",
           "tcp && !udp", "not (tcp or udp)", "tcp.port in {80 443}", "tcp.port in {80,443}",
           "tcp.port in {1..1024 8080}", "tcp.flags & 0x12", 'http.host contains "example"',
           'http.host matches "(?i)example"', "frame.marked == false", "ip.addr == 192.0.2.0/24",
           "ipv6.addr == 2001:db8::/32", "eth.addr == aabb.ccdd.eeff", "data.bytes contains aa:bb"]
  %w[== eq != ne ~= any_ne > gt < lt >= ge <= le].each { |op| valid << "tcp.port #{op} 443" }
  %w[tcp udp ip ipv6 eth dns].product(%w[and or && ||]).each do |field, operator|
    valid << "#{field} #{operator} (frame.len > 10)"
    valid << "not (#{field} #{operator} frame.marked)"
  end

  valid.each do |expression|
    it "parses #{expression.inspect}" do
      expect { Vanken::Core::DisplayFilter::Parser.new(expression).parse }.not_to raise_error
    end
  end

  invalid = [
    ["(", nil], [")", ")"], ["tcp and", nil], ["tcp or", nil], ["not", nil], ["!", nil],
    ["or tcp", "or"], ["and tcp", "and"], ["tcp or or udp", "or"], ["tcp and and udp", "and"],
    ["tcp tcp", "tcp"], ["tcp ==", nil], ["tcp.port == )", ")"], ["tcp.port == }", "}"],
    ["tcp.port === 1", "="], ["tcp.port = 1", "="], ["tcp.port == true false", "false"],
    ["tcp.port in", nil], ["tcp.port in 80", "80"], ["tcp.port in {}", "}"],
    ["tcp.port in {80,}", "}"], ["tcp.port in {,80}", ","], ["tcp.port in {80", nil],
    ["tcp.port in {1..}", "}"], ["tcp.port in {..4}", ".."], ["tcp.port in {1...4}", ".4"],
    ["tcp.port in {1,,4}", ","], ["tcp.port in {{1}}", "{"], ["tcp.port in {1} 2", "2"],
    ["tcp.port &", nil], ["tcp.port & 1.5", "1.5"], ['tcp.port & "x"', '"x"'],
    ["http.host matches 10", "10"], ["http.host matches true", "true"],
    ["tcp contains", nil], ["(tcp", nil], ["tcp)", ")"], ["(tcp))", ")"],
    ["tcp or ()", ")"], ["tcp[0:2]", "tcp[0:2]"]
  ]
  invalid.each do |expression, marker|
    it "locates the error in #{expression.inspect}" do
      position = marker ? expression.rindex(marker) : expression.bytesize
      expect { Vanken::Core::DisplayFilter::Parser.new(expression).parse }
        .to raise_error(Vanken::Core::DisplayFilter::SyntaxError) do |error|
          expect(error.position).to eq(position)
          expect(error.length).to be >= 0
        end
    end
  end

  it "uses not, and, or precedence and warns about mixed boolean operators" do
    parser = Vanken::Core::DisplayFilter::Parser.new("not tcp and udp or ip")
    ast = parser.parse
    expect(ast.kind).to eq(:or)
    expect(ast.left.kind).to eq(:and)
    expect(ast.left.left.kind).to eq(:not)
    expect(parser.warnings.join).to include("parentheses")
  end

  ["(tcp and udp) or ip", "tcp and (udp or ip)", "(tcp and udp) or (ip or eth)"].each do |expression|
    it "does not warn about grouped operators in #{expression}" do
      parser = Vanken::Core::DisplayFilter::Parser.new(expression)
      parser.parse
      expect(parser.warnings).to be_empty
    end
  end
end
