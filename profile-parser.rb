#!/usr/bin/env ruby

require 'zlib'
require 'optparse'

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
    # Array of operation names
    attr_reader :stack

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
    def finalize!(parent_stack = [])
      @stack = parent_stack + [object.name]

      @children.each {|_, child| child.finalize!(@stack) }

      @inclusive_time = Integer(object.time * 1000)

      child_time = @children.inject(0) {|sum, (_, child)| sum + child.inclusive_time }
      @exclusive_time = @inclusive_time - child_time
      @exclusive_time = 0 unless (@exclusive_time >= 0)
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
      "function #{@function}"
    end
  end

  class ResourceSlice < Slice
    attr_reader :type
    attr_reader :title

    def parse(line)
      match = line.match(/([\d\.]+) Evaluated resource ([\w:]+)\[(.*)\]: took ([\d\.]+) seconds$/)

      @id    = match[1]
      @type  = match[2]
      @title = match[3]
      @time  = match[4].to_f

      self
    end

    def name
      @name ||= if (@type == 'Class')
                  "#{@type}[#{@title}]"
                else
                  @type
                end
    end

    def inspect
      "resource #{@type}[#{@title}]"
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
      @name
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

  class FlameGraphOutput
    def initialize(output)
      @output = output
    end

    def display(traces)
      traces.each do |trace|
        trace.each do |span|
          span_time = span.exclusive_time

          next if span_time.zero?

          # The FlameGraph script uses ; as a separator for namespace segments.
          span_label = span.stack.map {|l| l.gsub(';', '') }.join(';')

          @output.puts("#{span_label} #{span_time}")
        end
      end
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
          id = Tty.green(span.object.id)
          time = Tty.yellow("(#{span.inclusive_time} ms)")

          @output.puts(indent + [id, span.object.inspect, time].join(' '))
        end

        @output.write("\n\n")
      end

      spans = Hash.new {|h,k| h[k] = [] }
      traces.each_with_object(spans) do |trace, span_map|
        trace.each do |span|
          case span.object
          when FunctionSlice
            span_map[:functions] << span
          when ResourceSlice
            span_map[:resources] << span
          when OtherSlice
            span_map[:other] << span
          end
        end
      end

      process_group("Function calls", spans[:functions])
      process_group("Resource evaluations", spans[:resources])
      process_group("Other evaluations", spans[:other])
    end

    private

    def truncate(str, width)
      if (str.length <= width)
        str
      else
        str[0..(width-2)] + ELLIPSIS
      end
    end

    def process_group(title, spans)
      total = 0
      itemized_totals = Hash.new { |h, k| h[k] = 0 }

      spans.each do |span|
        total += span.exclusive_time
        itemized_totals[span.stack.last] += span.exclusive_time
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
        next if v.zero?

        @output.printf("%-50s | %i ms\n", truncate(k, 50), v)
      end
    end
  end

  class CLI
    def initialize(argv = [])
      @log_files = []
      @outputter = nil

      @optparser = OptionParser.new do |parser|
        parser.banner = "Usage: puppet-profile-parser [options] puppetserver.log [...]"

        parser.on('-f', '--format FORMAT', String,
                  'Output format to use. One of:',
                  '    human (default)',
                  '    flamegraph') do |format|
          case format
          when 'human'
            @outputter = HumanOutput.new($stdout)
          when 'flamegraph'
            @outputter = FlameGraphOutput.new($stdout)
          else
            raise ArgumentError, "#{format} is not a supported output format. See --help for details."
          end
        end

        parser.on_tail('-h', '--help', 'Show help') do
          $stdout.puts(parser.help)
          exit 0
        end
      end

      args = argv.dup
      @optparser.parse!(args)

      # parse! consumes all --flags and their arguments leaving
      # file names behind.
      @log_files += args
      @outputter ||= HumanOutput.new($stdout)
    end

    def run
      if @log_files.empty?
        $stdout.puts(@optparser.help)
        exit 0
      end

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
