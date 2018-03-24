#!/usr/bin/env ruby
# -*- coding: utf-8 -*-

# puppet-profile-parser.rb        Parse Puppet Server logs for PROFILE data
#                                 and transform to various output formats.
#
# Copyright 2018 Charlie Sharpsteen
# Copyright 2014 Adrien Thebo
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'zlib'
require 'optparse'
require 'securerandom'
require 'csv'
require 'time'
require 'json'
require 'digest/sha2'

# Tools for parsing and formatting Puppet Server PROFILE logs
#
# This module wraps components that are used to extract data from PROFILE
# lines in Puppet Server logs and then convert the extracted data to
# various output formats.
#
# A CLI is also provided to create an easy to run tool.
#
# @author Charlie Sharpsteen
# @author Adrien Thebo
module PuppetProfileParser
  VERSION = '0.2.0'.freeze

  # Utility functions for terminal interaction
  #
  # A collection of functions for  colorizing output.
  module Tty
    # Pre-defined list of ANSI escape codes
    #
    # @return [Hash{Symbol => Integer}] A hash mapping human-readable color
    #   names to ANSI escape numbers.
    COLOR_CODES = {
      red: 31,
      green: 32,
      yellow: 33,
    }.freeze

    # Detect whether Ruby is running in a Windows environment
    #
    # @return [Boolean] Returns `true` if the alternate path separator is
    #   defined to be a backslash.
    def self.windows?
      @is_windows ||= (::File::ALT_SEPARATOR == "\\")
    end

    # Detect whether Ruby is run interactively
    #
    # @return [Boolean] Returns true if the standard output is a TTY.
    def self.tty?
      @is_tty ||= $stdout.tty?
    end

    # Maybe wrap a string in ANSI escape codes for color
    #
    # @param color [Integer] The color to apply, as a number from the
    #   ANSI color table.
    # @param string [String] The string to which color should be applied.
    # @param enable [Boolean] Override logic for detecting when to apply
    #   color.
    #
    # @return [String] A colorized string, if `enable` is set to true or
    #   if {.windows?} returns false, {.tty?} returns true and `enable`
    #   is unset.
    # @return [String] The original string unmodified if `enable` is set
    #   to false, or {.windows?} returns true, or {.tty?} returns false.
    def self.colorize(color, string, enable = nil)
      if (!windows?) && ((enable.nil? && tty?) || enable)
        "\033[#{COLOR_CODES[color]}m#{string}\033[0m"
      else
        string
      end
    end

    COLOR_CODES.keys.each do |name|
      define_singleton_method(name) do |string, enable = nil|
        colorize(name, string, enable)
      end
    end
  end

  # Organize nested Span objects
  #
  # The Trace class implements logic for organizing related {Span} objects
  # into a hierarchy representing a single profile operation. The Trace class
  # wraps a {Span} instance to provide some core capabilities:
  #
  #   - {#add}: Add a new {Span} object to the trace at a given position in
  #     the hierarchy.
  #
  #   - {#each}: Implements the functionality of the core Ruby Enumerable
  #     module by yielding `self` followed by all child spans nested under
  #     `self`.
  #
  #   - {#finalize!}: Iterates through `self` and all child spans to compute
  #     summary statistics. Should only be called once when no further spans
  #     will be added to the Trace.
  #
  # @see Span Span class.
  # @see https://github.com/opentracing/specification/blob/1.1/specification.md#the-opentracing-data-model
  #   Definitions of "Trace" and "Span" from the OpenTracing project.
  class Trace
    include Enumerable

    # Array of strings giving the nesting depth and order of the span
    #
    # @return [Array[String]]
    attr_reader :namespace
    # Wrapped Span object
    #
    # @return [Span]
    attr_reader :object
    # Unique ID for this Trace and its children
    #
    # @return [String]
    attr_reader :trace_id

    # Milliseconds spent on this operation, excluding child operations
    #
    # Equal to inclusive_time minus the sum of inclusive_time for children.
    #
    # @return [Integer]
    # @return [nil] If {#finalize!} has not been called.
    attr_reader :exclusive_time
    # Milliseconds spent on this operation, including child operations
    #
    # @return [Integer]
    # @return [nil] If {#finalize!} has not been called.
    attr_reader :inclusive_time
    # Array of operation names
    #
    # @return [Array[String]]
    # @return [nil] If {#finalize!} has not been called.
    attr_reader :stack

    # Initialize a new Trace instance
    #
    # @param namespace [String] A single string containing a sequence of
    #   namespace segments. Puppet uses integers separated by `.` characters
    #   to represent nesting depth and order of profiled operations.
    #
    # @param object [Span] A {Span} instance representing the operation
    #   associated with the `namespace`.
    #
    # @param trace_id [String] A string giving a unique id for this trace
    #   instance and its children. Defaults to a UUIDv4 produced by
    #   `SecureRandom.uuid`.
    def initialize(namespace, object, trace_id = nil)
      @namespace = namespace.split('.')
      @object    = object
      @trace_id  = trace_id || SecureRandom.uuid
      @children  = {}
      @exclusive_time = nil
      @inclusive_time = nil
    end

    # Add a new Span object as a child of the current trace
    #
    # @param namespace [String] A single string containing a sequence of
    #   namespace segments. Puppet uses integers separated by `.` characters
    #   to represent nesting depth and order of profiled operations.
    #
    # @param object [Span] A {Span} instance representing the operation
    #   associated with the `namespace`.
    #
    # @return [void]
    def add(namespace, object)
      parts = namespace.split('.')

      child_ns = parts[0..-2]
      child_id = parts.last

      if(parts == @namespace)
        # We are the object
        @object = object
      elsif @namespace == child_ns
        get(child_id).add(namespace, object)
      else
        id = parts.drop(@namespace.size).first
        child = get(id)
        child.add(namespace, object)
      end
    end

    # Yield self followed by all Trace instances that are children of self
    #
    # @yield [Trace]
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
    #
    # @return [void]
    def finalize!
      do_finalize!
    end

    protected

    # Internals of finalize that handle object state
    def do_finalize!(parent_stack = [], parent_object = nil)
      @stack = parent_stack + [object.name]

      @children.each {|_, child| child.do_finalize!(@stack, object) }

      @inclusive_time = Integer(object.time * 1000)

      child_time = @children.inject(0) {|sum, (_, child)| sum + child.inclusive_time }
      @exclusive_time = @inclusive_time - child_time
      @exclusive_time = 0 unless (@exclusive_time >= 0)

      # Copy state to our wrapped span.
      object.context[:trace_id] = @trace_id
      object.references << ['child_of', parent_object.id] unless parent_object.nil?
      object.finish!
    end

    private

    # Get or create a child Trace at the given nesting depth
    def get(id)
      @children[id] ||= Trace.new([@namespace, id].flatten.join('.'),
                                  nil,
                                  @trace_id)
    end
  end

  class Span
    attr_reader :id
    attr_reader :time
    attr_reader :start_time
    attr_reader :finish_time

    attr_reader :context
    attr_reader :tags
    attr_reader :references

    def initialize(name = nil, finish_time = nil, tags = {})
      # Typically spans are initialized with the start time.
      # But, we're parsing from logs writen _after_ the operation
      # completes. So, its finish time.
      @finish_time = finish_time
      @name = name

      @context = {trace_id: nil, span_id: nil}
      @tags = tags.merge({'component' => 'puppetserver',
                          'span.kind' => 'server'})
      @references = []
    end

    def finish!
      unless @finish_time.nil?
        @start_time = @finish_time - @time
      end
    end
  end

  class FunctionSpan < Span
    attr_reader :function
    alias name function

    def parse(line)
      match = line.match(/([\d\.]+) Called (\S+): took ([\d\.]+) seconds/)
      @id       = match[1]
      @function = match[2]
      @time     = match[3].to_f

      @context[:span_id] = @id

      self
    end

    def inspect
      "function #{@function}"
    end
  end

  class ResourceSpan < Span
    attr_reader :type
    attr_reader :title

    def parse(line)
      match = line.match(/([\d\.]+) Evaluated resource ([\w:]+)\[(.*)\]: took ([\d\.]+) seconds$/)

      @id    = match[1]
      @type  = match[2]
      @title = match[3]
      @time  = match[4].to_f

      @context[:span_id] = @id

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

  class OtherSpan < Span
    attr_reader :name

    def parse(line)
      match = line.match(/PROFILE \[\d+\] ([\d\.]+) (.*): took ([\d\.]+) seconds$/)
      @id = match[1]
      @name = match[2]
      @time = match[3].to_f

      @context[:span_id] = @id

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

    def parse(line, metadata)
      span_class = case line
                   when /Called/
                     FunctionSpan
                   when /Evaluated resource/
                     ResourceSpan
                   else
                     OtherSpan
                   end

      span = span_class.new(nil, metadata[:timestamp]).parse(line)

      if span.id == '1'
        # We've hit the root of a profile, which gets logged last.
        trace = Trace.new('1', span)

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

    def parse_file(file)
      io = if file.is_a?(IO)
             file
           else
             case File.extname(file)
             when '.gz'
               Zlib::GzipReader.open(file)
             else
               File.open(file, 'r')
             end
           end

      begin
        io.each_line do |line|
          next unless line.match("PROFILE")

          parse_line(line)
        end
      ensure
        io.close
      end
    end

    def parse_line(log_line)
      match = @log_parser.match(log_line)

      if match.nil?
        $stderr.puts("WARN Could not parse log line: #{log_line})")
        return
      end

      # NOTE: The zip can be replaced with match.named_captures, which
      # was added in Ruby 2.4.
      data = match.names.zip(match.captures).map do |k, v|
               if k == "timestamp"
                 # Ruby only allows a subset of the ISO8601 string formats.
                 # Java defaults to printing a format that Ruby doesn't allow.
                 v = Time.iso8601(v.sub(' ', 'T').sub(',','.'))
               end

               [k.to_sym, v]
             end.to_h

      trace_parser = @trace_parsers[data[:thread_id]]
      result = trace_parser.parse(data[:message], data)

      # The TraceParser returns nil unless the log lines parsed so far
      # add up to a complete profile.
      traces << result unless result.nil?
    end
  end

  class CsvOutput
    def initialize(output)
      @output = CSV.new(output)
      @header_written = false
    end

    def display(traces)
      traces.each do |trace|
        trace.each do |span|
          data = convert_span(span.object, span)

          unless @header_written
            @output << data.keys
            @header_written = true
          end

          @output << data.values
        end
      end
    end

    private

    def convert_span(span, trace)
      # NOTE: The Puppet::Util::Profiler library prints seconds with 4 digits
      # of precision, so preserve that in the output.
      #
      # TODO: This outputs in ISO 8601 format, which is great but may not be
      # the best for programs like Excel. Look into this.
      {timestamp: span.start_time.iso8601(4),
       trace_id: span.context[:trace_id],
       span_id: span.context[:span_id],
       name: span.name,
       exclusive_time_ms: trace.exclusive_time,
       inclusive_time_ms: trace.inclusive_time}
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

    def initialize(output, use_color = nil)
      @output = output
      @use_color = if use_color.nil?
                     output.tty?
                   else
                     use_color
                   end
    end

    def display(traces)
      traces.each do |trace|
        trace.each do |span|
          indent = " " * span.namespace.length
          id = Tty.green(span.object.id, @use_color)
          time = Tty.yellow("(#{span.inclusive_time} ms)", @use_color)

          @output.puts(indent + [id, span.object.inspect, time].join(' '))
        end

        @output.write("\n\n")
      end

      spans = Hash.new {|h,k| h[k] = [] }
      traces.each_with_object(spans) do |trace, span_map|
        trace.each do |span|
          case span.object
          when FunctionSpan
            span_map[:functions] << span
          when ResourceSpan
            span_map[:resources] << span
          when OtherSpan
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

  class ZipkinOutput
    def initialize(output)
      @output = output
    end

    def display(traces)
      first_loop = true
      @output.write('[')

      traces.each do |trace|
        trace.each do |span|
          next unless (span.inclusive_time > 0)

          if first_loop
            first_loop = false
          else
            @output.write(',')
          end

          @output.write(convert_span(span.object).to_json)
        end
      end

      @output.write(']')
    end

    private

    def convert_span(span)
      # Zipkin requires 16 -- 32 hex characters for trace IDs. We can get that
      # by removing the dashes from a UUID.
      trace_id = span.context[:trace_id].gsub('-', '')
      # And exactly 16 hex characters for span and parent IDs.
      span_id = Digest::SHA2.hexdigest(span.context[:span_id])[0..15]

      result = {"traceId" => trace_id,
                "id" => span_id,
                "name" => span.name,
                "kind" => "SERVER",
                "localEndpoint" => {"serviceName" => "puppetserver"}}

      if (parent = span.references.find {|r| r.first == "child_of"})
        result["parentId"] = Digest::SHA2.hexdigest(parent.last)[0..15]
      end

      # Zipkin reports durations in microseconds and timestamps in microseconds
      # since the UNIX epoch.
      #
      # NOTE: Time#to_i truncates to the nearest second. Using to_f is required
      # for sub-second precision.
      unless span.start_time.nil?
        result["timestamp"] = Integer(span.start_time.to_f * 10**6)
      end
      result["duration"] = Integer(span.time * 10**6)

      result["tags"] = span.tags unless span.tags.empty?

      result
    end
  end

  class CLI
    def initialize(argv = [])
      @log_files = []
      @outputter = nil
      @options = {color: $stdout.tty? }

      @optparser = OptionParser.new do |parser|
        parser.banner = "Usage: puppet-profile-parser [options] puppetserver.log [...]"

        parser.on('-f', '--format FORMAT', String,
                  'Output format to use. One of:',
                  '    human (default)',
                  '    csv',
                  '    flamegraph',
                  '    zipkin') do |format|
          @options[:format] = case format
                              when 'csv', 'human', 'flamegraph', 'zipkin'
                                format.intern
                              else
                                raise ArgumentError, "#{format} is not a supported output format. See --help for details."
                              end
        end

        parser.on('--[no-]color', 'Colorize output.',
                  'Defaults to true if run from an interactive POSIX shell.') do |v|
          @options[:color] = v
        end


        parser.on_tail('-h', '--help', 'Show help') do
          $stdout.puts(parser.help)
          exit 0
        end

        parser.on_tail('--version', 'Show version') do
          $stdout.puts(VERSION)
          exit 0
        end
      end

      args = argv.dup
      @optparser.parse!(args)

      # parse! consumes all --flags and their arguments leaving
      # file names behind.
      @log_files += args
      @outputter = case @options[:format]
                   when :csv
                     CsvOutput.new($stdout)
                   when :flamegraph
                     FlameGraphOutput.new($stdout)
                   when :zipkin
                     ZipkinOutput.new($stdout)
                   else
                     HumanOutput.new($stdout, @options[:color])
                   end
    end

    def run
      if @log_files.empty?
        $stderr.puts(@optparser.help)
        exit 1
      end

      parser = LogParser.new

      @log_files.each {|f| parser.parse_file(f)}

      @outputter.display(parser.traces)
    end
  end
end

if File.expand_path(__FILE__) == File.expand_path($PROGRAM_NAME)
  begin
    PuppetProfileParser::CLI.new(ARGV).run
  rescue => e
    $stderr.puts("ERROR #{e.class}: #{e.message}")
    exit 1
  end
end
