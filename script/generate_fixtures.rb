#!/usr/bin/env ruby
# frozen_string_literal: true

# Run: bundle exec ruby script/generate_fixtures.rb [--output DIR] [--performance [COUNT]]
# --performance defaults to 200,000 frames; omit it to generate only the small fixtures.
require "optparse"
require "fileutils"
require "ipaddr"
require_relative "../lib/vanken"

module VankenFixtures
  module_function

  CLIENT_MAC = ["020000000001"].pack("H*").freeze
  SERVER_MAC = ["020000000002"].pack("H*").freeze
  CLIENT_IP = IPAddr.new("192.0.2.10").hton.freeze
  SERVER_IP = IPAddr.new("198.51.100.5").hton.freeze
  CLIENT_IP6 = IPAddr.new("2001:db8::10").hton.freeze
  SERVER_IP6 = IPAddr.new("2001:db8::5").hton.freeze
  TIMESTAMP_NS = 1_700_000_000_000_000_000

  def checksum(bytes)
    padded = bytes.bytesize.odd? ? bytes + "\0" : bytes
    sum = padded.unpack("n*").sum
    sum = (sum & 0xffff) + (sum >> 16) while sum > 0xffff
    ~sum & 0xffff
  end

  def addresses(reverse = false, ipv6: false)
    values = ipv6 ? [CLIENT_IP6, SERVER_IP6] : [CLIENT_IP, SERVER_IP]
    reverse ? values.reverse : values
  end

  def ethernet(payload, type: 0x0800, reverse: false, vlan: nil)
    src, dst = reverse ? [SERVER_MAC, CLIENT_MAC] : [CLIENT_MAC, SERVER_MAC]
    header = vlan ? [0x8100, vlan, type].pack("n3") : [type].pack("n")
    dst + src + header + payload.b
  end

  def ipv4(payload, protocol:, reverse: false)
    src, dst = addresses(reverse)
    header = [0x45, 0, 20 + payload.bytesize, 1, 0, 64, protocol, 0].pack("CCnnnCCn") + src + dst
    header[10, 2] = [checksum(header)].pack("n")
    header + payload
  end

  def tcp(seq:, ack: 0, flags: 2, payload: "", reverse: false, port: 80, window: 65_535)
    src, dst = addresses(reverse)
    ports = reverse ? [port, 51_514] : [51_514, port]
    segment = [*ports, seq, ack, 0x5000 | flags, window, 0, 0].pack("nnNNnnnn") + payload.b
    pseudo = src + dst + [0, 6, segment.bytesize].pack("CCn")
    segment[16, 2] = [checksum(pseudo + segment)].pack("n")
    ethernet(ipv4(segment, protocol: 6, reverse: reverse), reverse: reverse)
  end

  def udp(payload, source: 53_000, destination: 53, reverse: false, vlan: nil)
    src, dst = addresses(reverse)
    ports = reverse ? [destination, source] : [source, destination]
    datagram = [*ports, 8 + payload.bytesize, 0].pack("n4") + payload.b
    pseudo = src + dst + [0, 17, datagram.bytesize].pack("CCn")
    value = checksum(pseudo + datagram)
    datagram[6, 2] = [value.zero? ? 0xffff : value].pack("n")
    ethernet(ipv4(datagram, protocol: 17, reverse: reverse), reverse: reverse, vlan: vlan)
  end

  def icmp(reverse: false, ipv6: false)
    type = ipv6 ? (reverse ? 129 : 128) : (reverse ? 0 : 8)
    message = [type, 0, 0, 7, 1].pack("CCnnn") + "deterministic echo".b
    if ipv6
      src, dst = addresses(reverse, ipv6: true)
      pseudo = src + dst + [message.bytesize, 58].pack("NN")
      message[2, 2] = [checksum(pseudo + message)].pack("n")
      header = [0x60000000, message.bytesize, 58, 64].pack("NnCC") + src + dst
      ethernet(header + message, type: 0x86dd, reverse: reverse)
    else
      message[2, 2] = [checksum(message)].pack("n")
      ethernet(ipv4(message, protocol: 1, reverse: reverse), reverse: reverse)
    end
  end

  def arp(reverse: false)
    src, dst = addresses(reverse)
    src_mac, dst_mac = reverse ? [SERVER_MAC, CLIENT_MAC] : [CLIENT_MAC, "\0".b * 6]
    payload = [1, 0x0800, 6, 4, reverse ? 2 : 1].pack("nnCCn") + src_mac + src + dst_mac + dst
    packet = ethernet(payload, type: 0x0806, reverse: reverse)
    packet[0, 6] = "\xff".b * 6 unless reverse
    packet
  end

  def handshake(port: 80)
    [tcp(seq: 100, port: port), tcp(seq: 500, ack: 101, flags: 0x12, reverse: true, port: port),
     tcp(seq: 101, ack: 501, flags: 0x10, port: port)]
  end

  def tcp_analysis
    data = tcp(seq: 101, ack: 501, flags: 0x18, payload: "payload", port: 9000)
    ack = tcp(seq: 501, ack: 108, flags: 0x10, reverse: true, port: 9000)
    handshake(port: 9000) + [data, data, ack, ack, ack, ack,
      tcp(seq: 501, ack: 108, flags: 0x10, reverse: true, window: 0, port: 9000),
      tcp(seq: 108, ack: 501, flags: 0x14, port: 9000)]
  end

  def http_split
    first = "GET /fixture HTTP/1.1\r\nHost: example.test\r\n".b
    last = "User-Agent: Vanken\r\nConnection: close\r\n\r\n".b
    handshake + [tcp(seq: 101, ack: 501, flags: 0x18, payload: first),
      tcp(seq: 101 + first.bytesize, ack: 501, flags: 0x18, payload: last),
      tcp(seq: 501, ack: 101 + first.bytesize + last.bytesize, flags: 0x10, reverse: true)]
  end

  def dns
    name = "\x07example\x04test\0".b
    question = name + [1, 1].pack("n2")
    query = [0x1234, 0x0100, 1, 0, 0, 0].pack("n6") + question
    answer = [0x1234, 0x8180, 1, 1, 0, 0].pack("n6") + question +
      [0xc00c, 1, 1, 300, 4].pack("nnnNn") + SERVER_IP
    [udp(query), udp(answer, reverse: true)]
  end

  def tls_client_hello
    hostname = "example.test".b
    server_name = [0, hostname.bytesize].pack("Cn") + hostname
    extension = [0, server_name.bytesize + 2, server_name.bytesize].pack("n3") + server_name
    body = [0x0303].pack("n") + (0...32).to_a.pack("C*") + "\0".b +
      [4, 0xc02f, 0x002f, 1, 0, extension.bytesize].pack("nnnCCn") + extension
    handshake_bytes = [1, 0, body.bytesize].pack("CCn") + body
    record = [22, 0x0303, handshake_bytes.bytesize].pack("Cnn") + handshake_bytes
    handshake(port: 443) + [tcp(seq: 101, ack: 501, flags: 0x18, payload: record, port: 443)]
  end

  def malformed
    bad_ip = tcp(seq: 100).dup
    bad_ip[16, 2] = [4096].pack("n")
    bad_tcp = tcp(seq: 100).dup
    bad_tcp.setbyte(46, 0xf0) # TCP header claims 60 bytes, but only 20 exist.
    bad_udp = udp("short", destination: 55_000)
    bad_udp[38, 2] = [2].pack("n")
    [tcp(seq: 100).byteslice(0, 10), tcp(seq: 100).byteslice(0, 30), bad_ip, bad_tcp, bad_udp]
  end

  def write(path, bytes, count: bytes.size)
    format = File.extname(path) == ".pcap" ? :pcap : :pcapng
    Vanken::Gateway::FileWriter.open(path, format: format) do |writer|
      count.times do |index|
        packet = bytes[index % bytes.size]
        writer << Vanken::Core::Frame.new(bytes: packet, timestamp_ns: TIMESTAMP_NS + (index * 1_000_000),
          original_length: packet.bytesize, linktype: 1, interface: nil, direction: nil, number: index + 1)
      end
    end
  end

  def generate(directory, performance: nil)
    FileUtils.mkdir_p(directory)
    network = [ethernet("fixture", type: 0x88b5), arp, arp(reverse: true), icmp, icmp(reverse: true),
      icmp(ipv6: true), icmp(reverse: true, ipv6: true), *handshake, *dns]
    fixtures = {"network.pcap" => network, "network.pcapng" => network,
      "tcp-analysis.pcapng" => tcp_analysis, "http-split.pcapng" => http_split, "dns.pcapng" => dns,
      "tls-client-hello.pcapng" => tls_client_hello, "vlan.pcapng" => [udp("tagged datagram", destination: 55_000, vlan: 42)],
      "malformed.pcapng" => malformed}
    fixtures.each { |name, packets| write(File.join(directory, name), packets) }
    if performance
      write(File.join(directory, "performance.pcapng"), [udp("Vanken benchmark", destination: 55_000)], count: performance)
    end
    fixtures.keys + (performance ? ["performance.pcapng"] : [])
  end

  def run(argv)
    output = File.expand_path("../spec/fixtures/pcap", __dir__)
    performance = nil
    parser = OptionParser.new do |options|
      options.banner = "Usage: ruby script/generate_fixtures.rb [--output DIR] [--performance [COUNT]]"
      options.on("--output DIR", "Destination (default: spec/fixtures/pcap)") { |value| output = value }
      options.on("--performance [COUNT]", Integer, "Also generate a performance capture (default: 200000)") do |value|
        performance = value || 200_000
        raise OptionParser::InvalidArgument, "performance count must be positive" unless performance.positive?
      end
      options.on("-h", "--help", "Show help") { puts options; return 0 }
    end
    parser.parse!(argv)
    raise OptionParser::InvalidArgument, "unexpected arguments: #{argv.join(' ')}" unless argv.empty?
    generate(output, performance: performance).each { |name| puts File.join(output, name) }
    0
  rescue OptionParser::ParseError, Vanken::FileError, SystemCallError => error
    warn error.message
    1
  end
end

exit VankenFixtures.run(ARGV) if $PROGRAM_NAME == __FILE__
