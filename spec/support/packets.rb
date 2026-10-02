# frozen_string_literal: true

module PacketFixtures
  def tcp_bytes(seq: 100, ack: 0, flags: 2, payload: "", port: 80)
    ethernet = ["0200000000020200000000010800"].pack("H*")
    tcp = [51514, port, seq, ack, 0x5000 | flags, 65_535, 0, 0].pack("nnNNnnnn") + payload.b
    ip = [0x45, 0, 20 + tcp.bytesize, 1, 0, 64, 6, 0, 0xc000020a, 0xc6336405].pack("CCnnnCCnNN")
    ethernet + ip + tcp
  end

  def frame(bytes = tcp_bytes, number: 1, timestamp_ns: 1_700_000_000_123_456_789, linktype: 1, interface: nil)
    Vanken::Core::Frame.new(bytes: bytes, timestamp_ns: timestamp_ns, original_length: bytes.bytesize,
      linktype: linktype, interface: interface, direction: nil, number: number)
  end

  def write_capture(path, frames = [frame])
    Vanken::Gateway::FileWriter.open(path, format: File.extname(path) == ".pcap" ? :pcap : :pcapng) do |writer|
      frames.each { |item| writer << item }
    end
    path
  end
end

RSpec.configure { |config| config.include PacketFixtures }
