#!/usr/bin/env ruby

require 'zlib'

module PuppetProfiler
  # Utility functions for terminal interaction
  module Tty
    COLOR_CODES = {
      red: 31,
      green: 32,
      yellow: 33,
    }.freeze

    def self.windows?
      @is_windows ||= (::File::ALT_SEPARATOR == "\\")
    end

    def self.tty?
      @is_tty ||= (!windows? && $stdout.isatty)
    end

    def self.colorize(color, string)
      if tty?
        "\033[#{COLOR_CODES[color]}m#{string}\033[0m"
      else
        string
      end
    end

    COLOR_CODES.keys.each do |name|
      define_singleton_method(name) do |string|
        colorize(name, string)
      end
    end
  end

  class Namespace
    include Enumerable

    attr_reader :namespace
    attr_reader :object

    # Milliseconds spent on this operation, excluding child operations
    #
    # Equal to inclusive_time minus the sum of inclusive_time for children.
    attr_reader :exclusive_time
    # Milliseconds spent on this operation, including child operations
    attr_reader :inclusive_time

    def initialize(namespace, object)
      @namespace = namespace.split('.')
      @object    = object
      @children  = {}
      @exclusive_time = nil
      @inclusive_time = nil
    end

    def add(ns, object)
      parts = ns.split('.')

      child_ns = parts[0..-2]
      child_id = parts.last

      if(parts == @namespace)
        # We are the object
        @object = object
      elsif @namespace == child_ns
        get(child_id).add(ns, object)
      else
        id = parts.drop(@namespace.size).first
        child = get(id)
        child.add(ns, object)
      end
    end

    def get(id)
      @children[id] ||= Namespace.new([@namespace, id].flatten.join('.'), nil)
    end

    def each
      yield self

      @children.each do |_, child|
        child.each {|grandchild| yield grandchild }
      end
    end

    # Compute summary statistics
    #
    # This method should be called once all child spans have been added
    # in order to compute summary statistics for the entire trace.
    def finalize!
      @children.each {|_, child| child.finalize! }

      @inclusive_time = Integer(object.time * 1000)

      child_time = @children.inject(0) {|sum, (_, child)| sum + child.inclusive_time }
      @exclusive_time = @inclusive_time - child_time
      @exclusive_time = 0 unless @exclusive_time.positive?
    end
  end

  class Slice
    attr_reader :id
    attr_reader :time
  end

  class FunctionSlice < Slice
    attr_reader :function
    alias name function

    def parse(line)
      match = line.match(/([\d\.]+) Called (\S+): took ([\d\.]+) seconds/)
      @id       = match[1]
      @function = match[2]
      @time     = match[3].to_f
      self
    end

    def inspect
      time = Tty.yellow("(#{@time} seconds)")
      "function #{@function} #{time}"
    end
  end

  class ResourceSlice < Slice
    attr_reader :type
    alias name type
    attr_reader :title

    def parse(line)
      match = line.match(/([\d\.]+) Evaluated resource ([\w:]+)\[(.*)\]: took ([\d\.]+) seconds$/)

      @id    = match[1]
      @type  = match[2]
      @title = match[3]
      @time  = match[4].to_f

      self
    end

    def inspect
      time = Tty.yellow("(#{@time} seconds)")
      "resource #{@type}[#{@title}] #{time}"
    end
  end

  class OtherSlice < Slice
    attr_reader :name

    def parse(line)
      match = line.match(/PROFILE \[\d+\] ([\d\.]+) (.*): took ([\d\.]+) seconds$/)
      @id = match[1]
      @name = match[2]
      @time = match[3].to_f
      self
    end

    def inspect
      time = Tty.yellow("(#{@time} seconds)")
      "#{@name} #{time}"
    end
  end

  class TraceParser
    def initialize
      @spans = []
    end

    def parse(line)
      # Finch originally called these "slices", but we'll rename to "span"
      # eventually in order to match OpenTracing terminology.
      span = case line
             when /Called/
               FunctionSlice.new.parse(line)
             when /Evaluated resource/
               ResourceSlice.new.parse(line)
             else
               OtherSlice.new.parse(line)
             end

      if span.id == '1'
        # We've hit the root of a profile, which gets logged last.
        trace = Namespace.new('1', span)

        @spans.each do |child|
          trace.add(child.id, child)
        end

        # Re-set for parsing a new profile and return the completed trace.
        @spans = []

        trace.finalize!
        return trace
      else
        @spans << span

        # Return nil to signal we haven't parsed a complete profile yet.
        return nil
      end
    end
  end

  # Top-level parser for extracting profile data from logs
  class LogParser
    # Regex for parsing ISO 8601 datestamps
    #
    # Basically the regex used by {Time.iso8601} with some extensions.
    #
    # @see https://ruby-doc.org/stdlib-2.4.3/libdoc/time/rdoc/Time.html#method-i-xmlschema
    ISO_8601 = /(?:\d+)-(?:\d\d)-(?:\d\d)
                [T\s]
                (?:\d\d):(?:\d\d):(?:\d\d)
                (?:[\.,]\d+)?
                (?:Z|[+-]\d\d:\d\d)?/ix

    # Regex for parsing Puppet Server logs
    #
    # Matches log lines that use the default logback pattern for Puppet Server:
    #
    #     %d %-5p [%t] [%c{2}] %m%n
    DEFAULT_PARSER = /^\s*
                      (?<timestamp>#{ISO_8601})\s+
                      (?<log_level>[A-Z]+)\s+
                      \[(?<thread_id>\S+)\]\s+
                      \[(?<java_class>\S+)\]\s+
                      (?<message>.*)$/x

    attr_reader :traces

    def initialize
      @traces = []
      @trace_parsers = Hash.new {|h,k| h[k] = TraceParser.new }

      # TODO: Could be configurable. Would be a lot of work to implement
      # a reasonable intersection of Java and Passenger formats.
      #
      # The "PROFILE [<trace_id>] ..." messages also include an id which
      # is set to the Ruby object id created to handle each HTTP request.
      # Could switch to using that instead of the Java thread id.
      @log_parser = DEFAULT_PARSER
    end

    def parse_line(log_line)
      data = @log_parser.match(log_line)

      if data.nil?
        $stderr.puts("WARN Could not parse log line: #{log_line})")
        return
      end

      trace_parser = @trace_parsers[data[:thread_id]]
      result = trace_parser.parse(data[:message])

      # The TraceParser returns nil unless the log lines parsed so far
      # add up to a complete profile.
      traces << result unless result.nil?
    end
  end

  class HumanOutput
    ELLIPSIS = "\u2026".freeze

    def initialize(output)
      @output = output
    end

    def display(traces)
      traces.each do |trace|
        trace.each do |span|
          indent = " " * span.namespace.length

          @output.write(indent)
          @output.write("#{Tty.green(span.namespace.join('.'))} ")
          @output.write(span.object.inspect)
          @output.write("\n")
        end

        @output.write("\n\n")
      end

      # FIXME: Eliminate double iteration.
      funcalls = traces.flat_map do |trace|
        trace.select {|span| span.object.is_a?(FunctionSlice) }.map(&:object)
      end
      resevals = traces.flat_map do |trace|
        trace.select {|span| span.object.is_a?(ResourceSlice) }.map(&:object)
      end

      process_group("Function calls", funcalls)
      process_group("Resource evaluations", resevals)
    end

    private

    def truncate(str, width)
      if (str.length <= width)
        str
      else
        str[0..(width-2)] + ELLIPSIS
      end
    end

    def process_group(title, slices)
      total = 0
      itemized_totals = Hash.new { |h, k| h[k] = 0 }

      slices.each do |slice|
        total += Integer(slice.time * 1000)
        itemized_totals[slice.name] += Integer(slice.time * 1000)
      end

      rows = itemized_totals.to_a.sort { |a, b| b[1] <=> a[1] }

      @output.puts "\n--- #{title} ---"
      @output.puts "Total time: #{total} ms"
      @output.puts "Itemized:"

      # NOTE: Table formatting fixed to 72 columns. Adjusting this based on
      # screen size is possible, but not worth the complexity at this time.
      @output.printf("%-50s | %-19s\n", 'Source', 'Time')
      @output.puts(('-' * 50) + '-+-' + ('-' * 19))
      rows.each do |k, v|
        @output.printf("%-50s | %i ms\n", truncate(k, 50), v)
      end
    end
  end

  class CLI
    def initialize(argv)
      @log_files = argv
      @outputter = HumanOutput.new($stdout)
    end

    def run
      parser = LogParser.new

      @log_files.each do |file|
        io = case File.extname(file)
             when '.gz'
               Zlib::GzipReader.open(file)
             else
               File.open(file, 'r')
             end

        begin
          io.each_line do |line|
            next unless line.match(/PROFILE/)

            parser.parse_line(line)
          end
        ensure
          io.close
        end
      end

      @outputter.display(parser.traces)
    end
  end
end

if File.expand_path(__FILE__) == File.expand_path($PROGRAM_NAME)
  begin
    PuppetProfiler::CLI.new(ARGV).run
  rescue => e
    $stderr.puts("ERROR #{e.class}: #{e.message}")
  end
end
