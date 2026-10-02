# frozen_string_literal: true

require "optparse"

module Vanken
  module CLI
    def self.start(argv, out: $stdout, err: $stderr)
      options = {}
      parser = OptionParser.new do |flags|
        flags.banner = "Usage: vanken [options] [capture.pcapng]"
        flags.on("--version", "Show version") { out.puts(VERSION); return 0 }
        flags.on("-h", "--help", "Show help") { out.puts(flags); return 0 }
        flags.on("-r PATH", "--read PATH", "Open a pcap or pcapng capture") { |value| options[:path] = value }
        flags.on("--headless", "Run without a native window") { options[:headless] = true }
        flags.on("--print-columns", "Print tab-separated packet columns") { options[:print_columns] = true }
        flags.on("--filter EXPR", "Apply a Vanken display filter") { |value| options[:filter] = value }
        flags.on("--tui", "Run in a terminal") { options[:tui] = true }
        flags.on("--smoke", "Draw three frames and exit") { options[:smoke] = true }
        flags.on("--allow-root", "Allow privileged UI with a warning") { options[:allow_root] = true }
        flags.on("--no-yjit", "Do not enable YJIT") { options[:no_yjit] = true }
        flags.on("--debug", "Enable debug logging") { options[:debug] = true }
      end
      remaining = parser.parse(argv.dup)
      raise OptionParser::InvalidArgument, "only one capture path is accepted" if remaining.size > 1 || (options[:path] && !remaining.empty?)
      options[:path] ||= remaining.first
      raise OptionParser::InvalidArgument, "--tui and --headless cannot be combined" if options[:tui] && options[:headless]
      RubyVM::YJIT.enable if defined?(RubyVM::YJIT.enable) && !options[:no_yjit]
      if options[:print_columns]
        raise OptionParser::InvalidArgument, "--print-columns needs --read or a capture path" unless options[:path]
        return print_columns(options, out)
      end
      if Process.euid.zero? && !options[:allow_root]
        err.puts("Vanken refuses to run its UI as root. Run the capture helper with capture privileges instead.")
        return 3
      end
      err.puts("Warning: running the packet analysis UI as root.") if Process.euid.zero?
      require_relative "ui/application"
      application = UI::Application.new(backend: options[:headless] ? :headless : options[:tui] ? :tui : nil, debug: options[:debug])
      application.open_file(options[:path]) if options[:path]
      application.initial_filter(options[:filter]) if options[:filter]
      options[:smoke] ? application.smoke : application.run
      0
    rescue OptionParser::ParseError => error
      err.puts(error.message)
      2
    rescue Vanken::Error, Core::DisplayFilter::SyntaxError, IOError, SystemCallError => error
      err.puts(error.message)
      1
    ensure
      application&.close
    end

    def self.print_columns(options, out)
      document = App::Document.new.open(options[:path]).wait
      raise document.error if document.error
      document.apply_filter(options[:filter]).wait if options[:filter]
      raise document.error if document.error
      out.puts("No.\tTime\tSource\tDestination\tProtocol\tLength\tInfo")
      document.display_numbers.each do |number|
        row = document.row(number)
        out.puts([number, format("%.6f", document.time_value(number)), row[:source], row[:destination], row[:protocol], row[:length], row[:info]].join("\t"))
      end
      0
    ensure
      document&.close
    end
  end
end
