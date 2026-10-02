# frozen_string_literal: true

RSpec.describe "display-filter compiler" do
  before { require "vanken/core/display_filter/compiler" }

  class FilterFixture
    attr_reader :fields, :protocols, :types

    def initialize(fields, protocols, types = {})
      @fields, @protocols, @types = fields, protocols, types
    end

    def values(name) = fields.fetch(name, [])
    def layer?(name) = protocols.include?(name.to_s)
    def field_type(name) = types[name]
  end

  catalog_fields = {
    "http.host" => {type: :string, source: :dissect}, "http.request.method" => {type: :string},
    "dns.answer" => {type: :string}, "tcp.flags" => {type: :uint16},
    "ip.src" => {type: :ipv4}, "ipv6.src" => {type: :ipv6}, "eth.src" => {type: :mac},
    "data.bytes" => {type: :bytes}, "dynamic.boolean" => {type: :boolean}
  }
  catalog = Object.new
  catalog.define_singleton_method(:lookup) { |name| catalog_fields[name] }
  catalog.define_singleton_method(:protocol?) { |name| %w[tcp udp ip ipv6 eth http dns data].include?(name) }

  frames = [
    FilterFixture.new({"frame.number" => [1], "frame.len" => [100], "frame.marked" => [false],
                       "frame.ignored" => [false], "frame.time_relative" => [1.5],
                       "tcp.port" => [80, 443], "tcp.flags" => [0x12], "tcp.flags.syn" => [true],
                       "ip.addr" => ["192.0.2.1", "198.51.100.2"], "ip.src" => ["192.0.2.1"],
                       "eth.addr" => ["AA-BB-CC-DD-EE-FF"], "eth.src" => ["aa:bb:cc:dd:ee:ff"],
                       "http.host" => ["Example.COM"], "http.request.method" => ["GET"],
                       "data.bytes" => ["\xaa\xbb\xcc\x00".b], "tcp.stream" => [2],
                       "expert.severity" => [:warning], "expert.code" => ["checksum"],
                       "tcp.analysis.retransmission" => [true]}, %w[eth ip tcp http data]),
    FilterFixture.new({"frame.number" => [2], "frame.len" => [80], "frame.marked" => [true],
                       "frame.ignored" => [false], "frame.time_relative" => [2.0],
                       "udp.port" => [53, 53000], "ip.addr" => ["203.0.113.2"],
                       "eth.addr" => ["0011.2233.4455"], "dns.answer" => ["a", "b"],
                       "expert.severity" => [:note], "dynamic.boolean" => [false]}, %w[eth ip udp dns]),
    FilterFixture.new({"frame.number" => [3], "frame.len" => [1500], "frame.marked" => [false],
                       "frame.ignored" => [true], "frame.time_relative" => [2.75],
                       "tcp.port" => [22, 55000], "tcp.flags" => [4], "tcp.flags.syn" => [false],
                       "ipv6.addr" => ["2001:db8::1", "::1"], "ipv6.src" => ["2001:db8::1"],
                       "data.bytes" => ["\x00\xaa\xbb".b], "tcp.stream" => [3],
                       "expert.severity" => [:error]}, %w[eth ipv6 tcp data])
  ]

  cases = {
    "" => [1, 2, 3], "tcp" => [1, 3], "udp" => [2], "ip" => [1, 2], "ipv6" => [3],
    "http" => [1], "dns" => [2], "not tcp" => [2], "!udp" => [1, 3],
    "tcp.port" => [1, 3], "frame.marked" => [1, 2, 3], "dynamic.boolean" => [2],
    "frame.marked == true" => [2], "frame.marked == 1" => [2], "frame.marked == false" => [1, 3],
    "frame.marked == 0" => [1, 3], "tcp.flags.syn == false" => [3],
    "tcp.port == 80" => [1], "tcp.port != 80" => [2, 3], "tcp.port ~= 80" => [1, 3],
    "tcp.port != 1" => [1, 2, 3], "unknown.field == 1" => [], "unknown.field != 1" => [1, 2, 3],
    "unknown.field ~= 1" => [], "tcp.port in {22,80,443}" => [1, 3],
    "tcp.port in {1..100}" => [1, 3], "udp.port in {1..1024 8080}" => [2],
    "frame.number in {1..2}" => [1, 2], "tcp.flags & 0x02" => [1], "tcp.flags & 0b100" => [3],
    "ip.addr == 192.0.2.0/24" => [1], "ip.addr == 198.51.100.2" => [1],
    "ip.addr != 192.0.2.1" => [2, 3], "ip.addr ~= 192.0.2.1" => [1, 2],
    "ipv6.addr == 2001:db8::/32" => [3], "ipv6.addr == ::1" => [3],
    "ipv6.src == 192.0.2.1" => [], "ip.src == ::1" => [],
    "eth.addr == aa:bb:cc:dd:ee:ff" => [1], "eth.addr == aa-bb-cc-dd-ee-ff" => [1],
    "eth.addr == aabb.ccdd.eeff" => [1], "eth.addr == 00:11:22:33:44:55" => [2],
    'http.host contains "COM"' => [1], 'http.host contains "com"' => [],
    'http.host matches "(?i)example\\\\.com"' => [1], 'http.host matches "^example"' => [],
    'http.request.method == "GET"' => [1], "http.request.method == GET" => [1],
    "data.bytes contains aa:bb" => [1, 3], "data.bytes == aa:bb:cc:00" => [1],
    "data.bytes contains 0xaabb" => [1, 3], 'data.bytes contains "\\xAA\\xBB"' => [1, 3],
    "data.bytes == 0x00aabb" => [3], "tcp.stream == 2" => [1],
    "tcp.analysis.retransmission" => [1], "expert.severity >= warning" => [1, 3],
    "expert.severity < error" => [1, 2], "expert.severity == error" => [3],
    "frame.time_relative > 2.5" => [3], "frame.time_relative == 1.5" => [1],
    "not tcp and udp or ipv6" => [2, 3], "not (tcp and udp)" => [1, 2, 3],
    "tcp and (frame.len > 100 or frame.marked == true)" => [3],
    "tcp or udp and frame.marked" => [1, 2, 3], "(tcp or udp) and frame.marked == true" => [2]
  }
  operations = {"==" => :==, "eq" => :==, "!=" => :!=, "ne" => :!=, ">" => :>, "gt" => :>,
                "<" => :<, "lt" => :<, ">=" => :>=, "ge" => :>=, "<=" => :<=, "le" => :<=}
  [0, 1, 2, 3, 4, 10, 80, 100].product(operations.keys).each do |number, operator|
    cases["frame.number #{operator} #{number}"] = (1..3).select { |value| value.public_send(operations[operator], number) }
  end
  cases.each do |expression, expected|
    it "matches #{expected.inspect} for #{expression.inspect}" do
      program = Vanken::Core::DisplayFilter.compile(expression, catalog: catalog)
      matched = frames.select { |frame| program.match?(frame) }.map { |frame| frame.values("frame.number").first }
      expect(matched).to eq(expected)
    end
  end

  {
    "frame.len > 10" => [:frame], "frame.marked" => [:frame], "tcp.stream == 2" => [:annotation],
    "tcp.analysis.retransmission" => [:annotation], "expert.severity == warning" => [:annotation],
    "tcp" => [:column], "tcp.port == 443" => [:column], "udp.port == 53" => [:column],
    "ip.addr == 192.0.2.1" => [:dissect], "frame.protocols contains tcp" => [:dissect],
    "tcp and frame.len > 10 and tcp.stream == 2" => %i[column frame annotation]
  }.each do |expression, sources|
    it "tracks sources for #{expression}" do
      program = Vanken::Core::DisplayFilter.compile(expression, catalog: catalog)
      expect(program.sources).to match_array(sources)
      expect(program.fast?).to eq(!sources.include?(:dissect))
      expect(program.expression).to eq(expression)
    end
  end

  it "keeps the distinct fields and only warns for unobserved names" do
    program = Vanken::Core::DisplayFilter.compile("tcp.port == 80 or tcp.port == 443 or unknown.field", catalog: catalog)
    expect(program.fields).to eq(["tcp.port", "unknown.field"])
    expect(program.warnings.join).to include("unknown.field")
    expect(Vanken::Core::DisplayFilter.compile("dns.answer", catalog: catalog).warnings).to be_empty
  end

  ['frame.len == "x"', 'frame.marked == 2', 'frame.len contains 2', 'frame.len matches "x"',
   'http.host & 1', 'ip.src > 192.0.2.1', 'eth.src > aa:bb:cc:dd:ee:ff',
   'frame.number in {3..1}', 'frame.number in {1.."x"}', 'http.host matches "["',
   'expert.severity > invalid', 'frame.len == true'].each do |expression|
    it "rejects incompatible values in #{expression.inspect}" do
      expect { Vanken::Core::DisplayFilter.compile(expression, catalog: catalog) }
        .to raise_error(Vanken::Core::DisplayFilter::SyntaxError) do |error|
          expect(error.position).to be >= 0
          expect(error.length).to be > 0
        end
    end
  end

  it "infers types of dynamically observed values without requiring declarations" do
    view = FilterFixture.new({"custom.address" => [IPAddr.new("192.0.2.7")], "custom.number" => [123],
                              "custom.boolean" => [false], "custom.bytes" => ["\xaa\xbb".b]}, [])
    ["custom.address == 192.0.2.0/24", "custom.number > 100", "custom.boolean == 0",
     "custom.bytes contains aa:bb"].each do |expression|
      expect(Vanken::Core::DisplayFilter.compile(expression).match?(view)).to be(true)
    end
  end

  it "short circuits boolean expressions" do
    view = FilterFixture.new({}, ["tcp"])
    view.define_singleton_method(:values) { |_| raise "Unexpected dissection" }
    expect(Vanken::Core::DisplayFilter.compile("tcp or custom.field").match?(view)).to be(true)
    expect(Vanken::Core::DisplayFilter.compile("udp and custom.field").match?(view)).to be(false)
  end

  it "evaluates known fast fields without asking the packet for its field types" do
    view = FilterFixture.new({"tcp.port" => [443]}, ["tcp"])
    view.define_singleton_method(:field_type) { |_| raise "Unexpected dissection" }
    expect(Vanken::Core::DisplayFilter.compile("tcp.port == 443").match?(view)).to be(true)
  end

  it "keeps not-equal semantics when dynamic fields contain incompatible types" do
    view = FilterFixture.new({"custom.field" => [1, "x"]}, [])
    {"custom.field == 1" => true, "custom.field != 1" => false,
     "custom.field ~= 1" => true, 'custom.field == "y"' => false,
     'custom.field != "y"' => true, 'custom.field ~= "y"' => true}.each do |expression, expected|
      expect(Vanken::Core::DisplayFilter.compile(expression).match?(view)).to eq(expected)
    end
  end

  it "does not retain fields or warnings when a compiler is reused" do
    compiler = Vanken::Core::DisplayFilter::Compiler.new(catalog: catalog)
    previous = compiler.compile("unknown.field")
    current = compiler.compile("tcp")
    expect(previous.fields).to eq(["unknown.field"])
    expect(current.fields).to eq(["tcp"])
    expect(current.sources).to eq([:column])
    expect(current.warnings).to be_empty
  end

  it "uses a dynamically observed field type when the catalog has no declaration" do
    view = FilterFixture.new({"custom.hex" => ["\xaa\xbb".b]}, [], {"custom.hex" => :bytes})
    expect(Vanken::Core::DisplayFilter.compile("custom.hex == 0xaabb").match?(view)).to be(true)
  end

  it "resolves full-width IPv6 and eight-byte colon literals using the declared field type" do
    view = FilterFixture.new({"data.bytes" => ["\xaa\xbb\xcc\xdd\xee\xff\x00\x11".b],
                              "ipv6.addr" => ["aa:bb:cc:dd:ee:ff:00:11"]}, [])
    %w[data.bytes ipv6.addr].each do |field|
      program = Vanken::Core::DisplayFilter.compile("#{field} == aa:bb:cc:dd:ee:ff:00:11", catalog: catalog)
      expect(program.match?(view)).to be(true)
    end
  end

  it "treats unsupported operators on undeclared runtime types as nonmatches" do
    view = FilterFixture.new({"custom.number" => [1], "custom.string" => ["1"],
                              "custom.bool" => [false]}, [])
    ['custom.number contains 1', 'custom.string & 1', 'custom.bool > false'].each do |expression|
      expect(Vanken::Core::DisplayFilter.compile(expression).match?(view)).to be(false)
    end
  end

  it "stores declared types from field metadata objects as well as hashes" do
    entry = Struct.new(:type, :source).new(:uint32, :column)
    custom_catalog = Object.new
    custom_catalog.define_singleton_method(:lookup) { |_| entry }
    custom_catalog.define_singleton_method(:protocol?) { |_| false }
    program = Vanken::Core::DisplayFilter.compile("custom.number > 1", catalog: custom_catalog)
    expect(program.sources).to eq([:column])
    expect(program.fast?).to be(true)
    expect(program.warnings).to be_empty
  end

  it "bounds pathological regular expressions" do
    view = FilterFixture.new({"http.host" => ["a" * 30_000 + "!"]}, [])
    program = Vanken::Core::DisplayFilter.compile('http.host matches "^(a+)+\\\\1$"', catalog: catalog)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect(program.match?(view)).to be(false)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 2
  end
end
