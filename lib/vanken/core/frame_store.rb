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
      DIRECTION_IDS = {nil => 0, in: 1, out: 2}.freeze #: Hash[Symbol?, Integer]
      MIN_TIMESTAMP = -(1 << 63) #: Integer
      MAX_TIMESTAMP = (1 << 63) - 1 #: Integer
      attr_reader :directory #: String

      # @rbs! @interfaces: Array[Hash[String, untyped]]

      # @rbs (?parent: String?, ?directory: String?, ?recover: bool) -> void
      def initialize(parent: nil, directory: nil, recover: false)
        @directory = directory || Dir.mktmpdir("vanken-", parent)
        validate_directory
        File.chmod(0o700, @directory)
        @mutex = Mutex.new
        @count = 0
        @interfaces = []
        @durable_count = 0
        @closed = false
        restore if recover
        @data = private_file("frames.bin", recover ? "r+b" : "w+b")
        @records = private_file("frames.idx", recover ? "r+b" : "w+b")
        @data.seek(0, IO::SEEK_END)
        @records.seek(0, IO::SEEK_END)
        @reader = File.open(File.join(@directory, "frames.bin"), "rb")
        @index_reader = File.open(File.join(@directory, "frames.idx"), "rb")
        persist("session.json", {"schema_version" => 1, "created_at" => Time.now.utc.iso8601, "pid" => Process.pid})
      end

      # @rbs (String directory) -> FrameStore
      def self.recover(directory) = new(directory: directory, recover: true)
      # @rbs () -> Integer
      def count = @mutex.synchronize { @count }
      # @rbs () -> Integer
      # Published only after both files flush; reading the immutable count must not wait for writer IO.
      def durable_count = @durable_count

      # @rbs (Frame frame) -> Integer
      def append(frame)
        raise ArgumentError, "invalid frame lengths" unless frame.bytes.is_a?(String) && frame.original_length.is_a?(Integer) && frame.original_length.between?(frame.bytes.bytesize, 0xffff_ffff) && frame.bytes.bytesize <= 16 << 20
        raise ArgumentError, "invalid frame metadata" unless frame.linktype.is_a?(Integer) && frame.linktype.between?(0, 0xffff) && frame.timestamp_ns.is_a?(Integer) && frame.timestamp_ns.between?(MIN_TIMESTAMP, MAX_TIMESTAMP)
        @mutex.synchronize do
          raise IOError, "store closed" if @closed
          interface = frame.interface ? intern_interface(frame.interface) : 0xffff
          direction = DIRECTION_IDS.fetch(frame.direction)
          record = [@data.pos, frame.bytes.bytesize, frame.original_length, frame.timestamp_ns,
                    frame.linktype, interface, direction].pack(RECORD)
          @data.write(frame.bytes)
          @records.write(record)
          @count += 1
        end
      end

      # @rbs () -> self
      def flush
        @mutex.synchronize do
          @data.flush
          @records.flush
          @durable_count = @count
        end
        self
      end

      # @rbs (Integer number) -> frame_metadata
      def metadata(number)
        @mutex.synchronize do
          raise IndexError, "frame is not durable" unless number.is_a?(Integer) && number.between?(1, @durable_count)
          offset = (number - 1) * RECORD_SIZE
          record = if @index_reader.respond_to?(:pread)
            @index_reader.pread(RECORD_SIZE, offset)
          else
            @index_reader.seek(offset)
            @index_reader.read(RECORD_SIZE)
          end
          raise IOError, "truncated frame index" unless record && record.bytesize == RECORD_SIZE
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
            [@data, @records, @reader, @index_reader].compact.each(&:close)
            @closed = true
          end
          FileUtils.remove_entry_secure(@directory) if remove && File.directory?(@directory)
        end
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
        Dir.children(@directory).each do |name|
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
        limit = File.size(File.join(@directory, "frames.bin"))
        @interfaces = JSON.parse(File.read(File.join(@directory, "interfaces.json"))) if File.exist?(File.join(@directory, "interfaces.json"))
        expected_offset = 0
        File.open(path, "rb") do |io|
          while (record = io.read(RECORD_SIZE)) && record.bytesize == RECORD_SIZE
            offset, caplen, original, _time, _link, interface, direction = record.unpack(RECORD)
            break unless offset == expected_offset && caplen <= 16 << 20 && offset + caplen <= limit && original >= caplen && (interface == 0xffff || interface < @interfaces.size) && direction <= 2
            @count += 1
            expected_offset = offset + caplen
          end
        end
        @durable_count = @count
        File.truncate(path, @count * RECORD_SIZE)
        File.truncate(File.join(@directory, "frames.bin"), expected_offset)
      end
    end
  end
end
