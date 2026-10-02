# frozen_string_literal: true
# rbs_inline: enabled

require "tmpdir"
require "json"
require "fileutils"
require_relative "frame"

module Vanken
  module Core
    class FrameStore
      RECORD = "Q<L<L<q<S<S<Cx3"
      RECORD_SIZE = 32
      attr_reader :directory #: String

      # @rbs! @interfaces: Array[Hash[String, untyped]]

      # @rbs (?parent: String?, ?directory: String?, ?recover: bool) -> void
      def initialize(parent: nil, directory: nil, recover: false)
        @directory = directory || Dir.mktmpdir("vanken-", parent)
        validate_directory
        File.chmod(0o700, @directory)
        @mutex = Mutex.new
        @index = +"".b
        @interfaces = []
        @durable_count = 0
        @closed = false
        restore if recover
        @data = private_file("frames.bin", recover ? "r+b" : "w+b")
        @records = private_file("frames.idx", recover ? "r+b" : "w+b")
        @data.seek(0, IO::SEEK_END)
        @records.seek(0, IO::SEEK_END)
        @reader = File.open(File.join(@directory, "frames.bin"), "rb")
        persist("session.json", {"schema_version" => 1, "created_at" => Time.now.utc.iso8601, "pid" => Process.pid})
      end

      # @rbs (String directory) -> FrameStore
      def self.recover(directory) = new(directory: directory, recover: true)
      # @rbs () -> Integer
      def count = @mutex.synchronize { @index.bytesize / RECORD_SIZE }
      # @rbs () -> Integer
      def durable_count = @mutex.synchronize { @durable_count }

      # @rbs (Frame frame) -> Integer
      def append(frame)
        raise ArgumentError, "invalid frame lengths" unless frame.bytes.is_a?(String) && frame.original_length.is_a?(Integer) && frame.original_length.between?(frame.bytes.bytesize, 0xffff_ffff) && frame.bytes.bytesize <= 16 << 20
        raise ArgumentError, "invalid frame metadata" unless frame.linktype.is_a?(Integer) && frame.linktype.between?(0, 0xffff) && frame.timestamp_ns.is_a?(Integer) && frame.timestamp_ns.between?(-(1 << 63), (1 << 63) - 1)
        @mutex.synchronize do
          raise IOError, "store closed" if @closed
          interface = frame.interface ? intern_interface(frame.interface) : 0xffff
          direction = {nil => 0, in: 1, out: 2}.fetch(frame.direction)
          record = [@data.pos, frame.bytes.bytesize, frame.original_length, frame.timestamp_ns,
                    frame.linktype, interface, direction].pack(RECORD)
          @data.write(frame.bytes)
          @records.write(record)
          @index << record
          @index.bytesize / RECORD_SIZE
        end
      end

      # @rbs () -> self
      def flush
        @mutex.synchronize do
          @data.flush
          @records.flush
          @durable_count = @index.bytesize / RECORD_SIZE
        end
        self
      end

      # @rbs (Integer number) -> frame_metadata
      def metadata(number)
        @mutex.synchronize do
          raise IndexError, "frame is not durable" unless number.is_a?(Integer) && number.between?(1, @durable_count)
          record = @index.byteslice((number - 1) * RECORD_SIZE, RECORD_SIZE) || raise(IOError, "truncated frame index")
          values = record.unpack(RECORD)
          {offset: values[0], caplen: values[1], original_length: values[2], timestamp_ns: values[3],
           linktype: values[4], interface: values[5] == 0xffff ? nil : @interfaces.fetch(values[5]),
           direction: [nil, :in, :out].fetch(values[6]), number: number}
        end
      end

      # @rbs (Integer number) -> Frame
      def read(number)
        meta = metadata(number)
        bytes = if @reader.respond_to?(:pread)
          meta[:caplen].zero? ? "".b : @reader.pread(meta[:caplen], meta[:offset])
        else
          @mutex.synchronize { @reader.seek(meta[:offset]); @reader.read(meta[:caplen]) }
        end
        raise IOError, "truncated frame spool" unless bytes && bytes.bytesize == meta[:caplen]
        Frame.new(bytes: bytes, timestamp_ns: meta[:timestamp_ns], original_length: meta[:original_length],
                  linktype: meta[:linktype], interface: meta[:interface], direction: meta[:direction], number: number)
      end

      # @rbs () -> Array[Hash[String, untyped]]
      def interfaces = @mutex.synchronize { @interfaces.dup }

      # @rbs (?remove: bool) -> void
      def close(remove: true)
        @mutex.synchronize do
          unless @closed
            [@data, @records, @reader].compact.each(&:close)
            @closed = true
          end
        end
        FileUtils.remove_entry_secure(@directory) if remove && File.directory?(@directory)
      end

      private

      # @rbs (String name, String mode) -> File
      def private_file(name, mode)
        path = File.join(@directory, name)
        io = File.open(path, mode, 0o600)
        io.chmod(0o600)
        io
      end

      def validate_directory
        raise Vanken::FileError, "unsafe session directory" unless File.directory?(@directory) && !File.symlink?(@directory) && File.stat(@directory).uid == Process.uid
        %w[frames.idx frames.bin interfaces.json session.json].each do |name|
          path = File.join(@directory, name)
          next unless File.exist?(path) || File.symlink?(path)
          stat = File.lstat(path)
          raise Vanken::FileError, "unsafe session file" unless stat.file? && stat.uid == Process.uid && stat.nlink == 1
        end
      end

      def persist(name, value)
        File.open(File.join(@directory, name), "w", 0o600) { |io| io.write(JSON.generate(value)) }
        File.chmod(0o600, File.join(@directory, name))
      end

      def intern_interface(value)
        value = value.transform_keys(&:to_s)
        found = @interfaces.index(value)
        return found if found
        raise ArgumentError, "too many interfaces" if @interfaces.length >= 0xffff
        @interfaces << value.freeze
        persist("interfaces.json", @interfaces)
        @interfaces.length - 1
      end

      def restore
        raise Vanken::FileError, "unsafe session directory" unless File.directory?(@directory) && !File.symlink?(@directory) && File.stat(@directory).uid == Process.uid
        %w[frames.idx frames.bin interfaces.json].each do |name|
          raise Vanken::FileError, "unsafe session file" if File.symlink?(File.join(@directory, name))
        end
        path = File.join(@directory, "frames.idx")
        bytes = File.binread(path)
        limit = File.size(File.join(@directory, "frames.bin"))
        @interfaces = JSON.parse(File.read(File.join(@directory, "interfaces.json"))) if File.exist?(File.join(@directory, "interfaces.json"))
        complete = bytes.bytesize / RECORD_SIZE
        expected_offset = 0
        complete.times do |index|
          record = bytes.byteslice(index * RECORD_SIZE, RECORD_SIZE) || raise(IOError, "truncated frame index")
          offset, caplen, original, _time, _link, interface, direction = record.unpack(RECORD)
          break unless offset == expected_offset && caplen <= 16 << 20 && offset + caplen <= limit && original >= caplen && (interface == 0xffff || interface < @interfaces.size) && direction <= 2
          @index << bytes.byteslice(index * RECORD_SIZE, RECORD_SIZE)
          expected_offset = offset + caplen
        end
        @durable_count = @index.bytesize / RECORD_SIZE
        File.truncate(path, @index.bytesize)
        last = @index.empty? ? 0 : @index.byteslice(-RECORD_SIZE, RECORD_SIZE).unpack(RECORD).then { |row| row[0] + row[1] }
        File.truncate(File.join(@directory, "frames.bin"), last)
      end
    end
  end
end
