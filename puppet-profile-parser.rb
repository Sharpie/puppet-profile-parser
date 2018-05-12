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
require 'rubygems/requirement'

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
  REQUIRED_RUBY_VERSION = Gem::Requirement.new('>= 2.0')

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
    # in order to compute summary statistics for the entire trace. The
    # {Span#finish!} method is also called on wrapped span objects in
    # order to finalize their state.
    #
    # @see Span#finish!
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

  # Profile data from a discrete operation
  #
  # Instances of the Span class encapsulate details of a single operation
  # measured by the Puppet profiler. The data managed by a Span object is
  # a subset of of items defined by the OpenTracing specification:
  #
  #   - {context}: Provides ID values that identify the span and the trace
  #     it is associated with.
  #
  #   - {name}: A name that identifies the operation measured by the
  #     Span instance.
  #
  #   - {references}: A list of references to related Span instances, such
  #     as parent Spans.
  #
  #   - {tags}: A key/value map of data extracted from the Puppet Server
  #     PROFILE log line used to generate the Span instance.
  #
  # If the logs used to generate the Span included timestamps, then the
  # following standard peices of data will also be available:
  #
  #   - {start_time}
  #   - {finish_time}
  #
  # Spans also include a non-standard {time} which is present even if the
  # logs lacked Timestamp information.
  #
  # Most of these fields will be `nil` or otherwise incomplete unless the
  # Span instance is associated with a {Trace} instance via {Trace#add}
  # which is then finanlized via {Trace#finalize!}. The finalize method
  # of the Trace class fills in many details of the Span class, such as
  # the trace ID.
  #
  #
  # @see Trace Trace class.
  # @see https://github.com/opentracing/specification/blob/1.1/specification.md#the-opentracing-data-model
  #   Definitions of "Trace" and "Span" from the OpenTracing project.
  class Span
    # Operation name
    #
    # @return [String]
    attr_reader :name

    # Duration of operation measured by the span in seconds
    #
    # @return [Float]
    attr_accessor :time
    # Time at which the operation measured by the span started
    #
    # @return [Time]
    # @return [nil] Until {#finish!} is called and {finish_time} is non-nil.
    attr_reader :start_time
    # Time at which the operation measured by the span finished
    #
    # @return [Time, nil]
    attr_reader :finish_time

    # Values identifying the span and associated {Trace}
    #
    # @return [Hash{:trace_id, :span_id => String}]
    # @return [Hash{:trace_id, :span_id => nil}] Until a span is associated
    #   with {Trace#add} and {Trace#finalize!} is called on the trace instance.
    attr_reader :context
    # Data items parsed from PROFILE logs
    #
    # @see https://github.com/opentracing/specification/blob/1.1/semantic_conventions.md#standard-span-tags-and-log-fields
    #   List of tags standardized by OpenTracing.
    #
    # @return [Hash{String => Object}]
    attr_reader :tags
    # Links to related Span instances
    #
    # @return [Array<List(String, String)>] An array of tuples of the form
    #   `[<relationship type>, <span id>]` that relates this Span instance
    #   to other Span instances in the same Trace.
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

    # Identifier for the span. Unique within a given Trace
    #
    # @!attribute [r] id
    #   @return [String]
    def id
      @context[:span_id]
    end

    def inspect
      @name
    end

    # Finalize Span state
    #
    # @return [void]
    def finish!
      unless @finish_time.nil?
        @start_time = @finish_time - @time
      end
    end
  end

  # Parser for extracting spans from PROFILE log lines
  #
  # Instances of the TraceParser class process the messages of log lines
  # that include the `PROFILE` keyword and create {Span} instances which
  # are eventually grouped into finalized {Trace} instances.
  #
  # @see LogParser
  # @see Trace
  # @see Span
  class TraceParser
    # Regex for extracting span id and duration
    COMMON_DATA = /(?<span_id>[\d\.]+)\s+
                   (?<message>.*)
                   :\stook\s(?<duration>[\d\.]+)\sseconds$/x

    FUNCTION_CALL = /Called (?<name>\S+)/
    RESOURCE_EVAL = /Evaluated resource (?<name>(?<puppet.resource_type>[\w:]+)\[(?<puppet.resource_title>.*)\])/
    PUPPETDB_OP   = /PuppetDB: (?<name>[^\(]*)(?:\s\([\w\s]*: \d+\))?\Z/
    # For most versions of PuppetDB, the query function forgot to use a
    # helper that added "PuppetDB: " to the beginning of the message.
    PUPPETDB_QUERY = /(?<name>Submitted query .*)/

    HOSTNAME = /\b(?:[0-9A-Za-z][0-9A-Za-z-]{0,62})(?:\.(?:[0-9A-Za-z][0-9A-Za-z-]{0,62}))*(\.?|\b)/
    CERTNAME_REQUEST = /Processed\srequest\s
                        (?<http.method>[A-Z]+)\s
                        (?<name>.*\/)(?<peer.hostname>#{HOSTNAME})?\Z/x
    HTTP_REQUEST = /Processed request (?<http.method>[A-Z]+) (?<name>.*\/)/

    def initialize
      @spans = []
    end

    # Parse a log line possibly returning a completed trace
    #
    # @param line [String]
    # @param metadata [Hash]
    #
    # @return [Trace] A finalized {Trace} instance is returned when a {Span}
    #   with id `1` is parsed. All span instances parsed thus far are added
    #   to the trace and the TraceParser re-sets by emptying its list of
    #   parsed spans.
    #
    # @return [nil] A `nil` value is returned when the lines parsed thus
    #   far have not ended in a complete trace.
    def parse(line, metadata)
      match = COMMON_DATA.match(line)
      if match.nil?
        $stderr.puts("WARN Could not parse PROFILE message: #{line})")
        return nil
      end
      common_data = LogParser.convert_match(match) {|k, v| v.to_f if k == 'duration' }

      span_data = case common_data['message']
                  when FUNCTION_CALL
                    LogParser.convert_match(Regexp.last_match).merge({
                      'puppet.op_type' => 'function_call'})
                  when RESOURCE_EVAL
                    LogParser.convert_match(Regexp.last_match).merge({
                      'puppet.op_type' => 'resource_eval'})
                  when PUPPETDB_OP, PUPPETDB_QUERY
                    LogParser.convert_match(Regexp.last_match).merge({
                      'puppet.op_type' => 'puppetdb_call'})
                  when CERTNAME_REQUEST, HTTP_REQUEST
                    data = LogParser.convert_match(Regexp.last_match).merge({
                             'puppet.op_type' => 'http_request'})

                    # TODO: Would be nice if there was a reliable way of
                    # getting the server's hostname so we could use it
                    # instead of a RFC 2606 example domain.
                    data['http.url'] = 'https://puppetserver.example:8140' +
                      data['name']

                    unless data['peer.hostname'].nil?
                      data['http.url'] += data['peer.hostname']
                    end

                    data
                  else
                    {'name' => common_data['message'],
                     'puppet.op_type' => 'other'}
                  end

      span = Span.new(span_data.delete('name'),metadata['timestamp'], span_data)
      span.context[:span_id] = common_data['span_id']
      span.time = common_data['duration']

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
  #
  # Intances of the LogParser class consume content from log files one line
  # at a time looking for lines that contain the keyword `PROFILE`. These
  # lines are parsed to determine basic data such as the timestamp and
  # thread id. Internally the LogParser maintains a hash of {TraceParser}
  # instances keyed by thread id that parse log lines into {Trace} instances.
  # Completed Trace instances are exposed via the {#traces} method.
  #
  # @see TraceParser
  # @see Trace
  class LogParser
    # String which identifies log lines containing profiling data
    PROFILE_TAG = 'PROFILE'.freeze

    # Regex for parsing ISO 8601 datestamps
    #
    # A copy of the regex used by Ruby's Time.iso8601 with extensions to
    # allow for a space as a separator beteeen date and time segments and a
    # comma as a separator between seconds and sub-seconds.
    #
    # @see https://ruby-doc.org/stdlib-2.4.3/libdoc/time/rdoc/Time.html#method-i-xmlschema
    #
    # @return [Regex]
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
    #
    # The parser also consumes a leading "Puppet PROFILE [XXXX]" or
    # "PROFILE [XXXX]" string where "XXXX" is an id assigned to each
    # profiling operation. HTTP requests are assigned a unique per-request id.
    #
    # @return [Regex]
    DEFAULT_PARSER = /^\s*
                      (?<timestamp>#{ISO_8601})\s+
                      (?<log_level>[A-Z]+)\s+
                      \[(?<thread_id>\S+)\]\s+
                      \[(?<java_class>\S+)\]\s+
                      (?:Puppet\s+)?PROFILE\s+\[(?<request_id>[^\]]+)\]\s+
                      (?<message>.*)$/x

    # List of completed Trace instances
    #
    # @return [Array<Trace>]
    attr_reader :traces

    # Convert Regex MatchData to a hash of captures
    #
    # This function converts MatchData from a Regex to a hash of named
    # captures and yeilds each pair to an option block for transformation.
    # The function assumes that every capture in the Regex is named.
    #
    # @yieldparam k [String] Name of the regex capture group.
    # @yieldparam v [String] Value of the regex capture group.
    # @yieldreturn [nil, Object] An object representing the match data
    #   transformed to some value. A return value of `nil` will cause the
    #   original value to be used unmodified.
    #
    # @return [Hash{String => Object}] a hash mapping the capture names to
    #   transformed values.
    def self.convert_match(match_data)
      # NOTE: The zip can be replaced with match.named_captures, which
      # was added in Ruby 2.4.
      match_pairs = match_data.names.zip(match_data.captures).map do |k, v|
                      new_v = yield(k, v) if block_given?
                      v = new_v.nil? ? v : new_v

                      [k, v]
                    end

      Hash[match_pairs]
    end

    def initialize
      @traces = []
      @trace_parsers = Hash.new {|h,k| h[k] = TraceParser.new }

      # TODO: Could be configurable. Would be a lot of work to implement
      # a reasonable intersection of Java and Passenger formats.
      @log_parser = DEFAULT_PARSER
    end

    # Parse traces from a logfile
    #
    # @param file [String] Path to the logfile. Paths ending in `.gz` will
    #   be read using a `Zlib::GzipReader`.
    # @param file [IO] `IO` object that returns Puppet Server log lines.
    #   The `close` method will be called on the `IO` instance as a result
    #   of parsing.
    #
    # @return [void]
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
          next unless line.match(PROFILE_TAG)

          parse_line(line)
        end
      ensure
        io.close
      end
    end

    # Parse a single log line
    #
    # @param log_line [String]
    #
    # @return [void]
    def parse_line(log_line)
      match = @log_parser.match(log_line)

      if match.nil?
        $stderr.puts("WARN Could not parse log line: #{log_line})")
        return
      end

      data = LogParser.convert_match(match) do |k, v|
        if k == "timestamp"
          # Ruby only allows the ISO 8601 profile defined by RFC 3339.
          # The Java %d format prints something that Ruby won't accept.
          Time.iso8601(v.sub(' ', 'T').sub(',','.'))
        end
      end
      message = data.delete('message')

      trace_parser = @trace_parsers[data['thread_id']]
      result = trace_parser.parse(message, data)

      # The TraceParser returns nil unless the log lines parsed so far
      # add up to a complete profile.
      traces << result unless result.nil?
    end
  end

  # Base class for output formats
  #
  # Subclasses of Formatter render lists of {Trace} instances to particular
  # output format and then write them to an IO instance.
  #
  # @see Trace
  #
  # @abstract
  class Formatter
    # Create a new formatter instance
    #
    # @param output [IO] An IO instance to which formatted data will be written
    #   during a call to {#write}.
    def initialize(output)
    end

    # Format a list of traces and write to the wrapped output
    #
    # @param traces [Trace]
    #
    # @return [void]
    def write(traces)
      raise NotImplementedError, "#{self.class.name} is an abstract class."
    end

    # Format traces as CSV rows
    #
    # This Formatter loops over each trace and writes a row of data in CSV
    # format for each span.
    #
    # @see file:README.md#label-CSV
    #   More details in README
    class Csv < Formatter
      # (see Formatter#initialize)
      def initialize(output)
        @output = CSV.new(output)
        @header_written = false
      end

      # (see Formatter#write)
      def write(traces)
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

    # Format traces as input for flamegraph.pl
    #
    # This Formatter loops over each trace and writes its spans out as a
    # semicolon-delimited list of operations followed by the
    # {Trace#exclusive_time}. This output format is suitable as input for
    # the FlameGraph tool which generates an interactive SVG visualization.
    #
    # @see https://github.com/brendangregg/FlameGraph
    #   brendangregg/FlameGraph on GitHub
    # @see file:README.md#label-FlameGraph
    #   More details in README
    class FlameGraph < Formatter
      # (see Formatter#initialize)
      def initialize(output)
        @output = output
      end

      # (see Formatter#write)
      def write(traces)
        traces.each do |trace|
          trace.each do |span|
            span_time = span.exclusive_time

            next if span_time.zero?

            case span.object.tags['puppet.resource_type']
            when nil, 'Class'
            else
              # Aggregate resources that aren't classes.
              span.stack[-1] = span.object.tags['puppet.resource_type']
            end

            # The FlameGraph script uses ; as a separator for namespace segments.
            span_label = span.stack.map {|l| l.gsub(';', '') }.join(';')

            @output.puts("#{span_label} #{span_time}")
          end
        end
      end
    end

    # Format traces as human-readable output
    #
    # This Formatter loops over each trace and writes its spans out as an
    # indented list. The traces are followed by summary tables that display
    # the most expensive operations, sorted by {Trace#exclusive_time}.
    #
    # @see file:README.md#label-Human+readable
    #   More details in README
    class Human < Formatter
      ELLIPSIS = "\u2026".freeze

      # (see Formatter#initialize)
      #
      # @param use_color [nil, Boolean] Whether or not to colorize output
      #   using ANSI escape codes. If set to `nil`, the default value
      #   of {Tty.tty?} will be used.
      def initialize(output, use_color = nil)
        @output = output
        @use_color = if use_color.nil?
                       output.tty?
                     else
                       use_color
                     end
      end

      # (see Formatter#write)
      def write(traces)
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
            case span.object.tags['puppet.op_type']
            when 'function_call'
              span_map[:functions] << span
            when 'resource_eval'
              span_map[:resources] << span
            when 'puppetdb_call'
              span_map[:puppetdb] << span
            when 'http_request'
              span_map[:http_req] << span
            else
              span_map[:other] << span
            end
          end
        end

        process_group("Function calls", spans[:functions])
        process_group("Resource evaluations", spans[:resources])
        process_group("PuppetDB operations", spans[:puppetdb])
        process_group("HTTP Requests", spans[:http_req])
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
          span_key = case span.object.tags['puppet.resource_type']
                     when nil, 'Class'
                       span.object.name
                     else
                       # Aggregate resources that aren't classes.
                       span.object.tags['puppet.resource_type']
                     end

          itemized_totals[span_key] += span.exclusive_time
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

    # Format traces as Zipkin JSON
    #
    # This Formatter loops over each trace and writes its spans out as JSON
    # data formatted according to the `ListOfSpans` datatype accepted by the
    # Zipkin v2 API.
    #
    # @see https://zipkin.io/zipkin-api/
    #   Zipkin v2 API specification
    # @see file:README.md#label-Zipkin+JSON
    #   More details in README
    class Zipkin < Formatter
      # (see Formatter#initialize)
      def initialize(output)
        @output = output
      end

      # (see Formatter#write)
      def write(traces)
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

        unless span.tags.empty?
          result["tags"] = span.tags.dup
          result["tags"].delete("span.kind") # Set to SERVER above.
        end

        result
      end
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

        parser.on_tail('--debug', 'Enable backtraces from errors.') do
          @options[:debug] = true
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
      @formatter = case @options[:format]
                   when :csv
                     Formatter::Csv.new($stdout)
                   when :flamegraph
                     Formatter::FlameGraph.new($stdout)
                   when :zipkin
                     Formatter::Zipkin.new($stdout)
                   else
                     Formatter::Human.new($stdout, @options[:color])
                   end
    end

    def run
      if not REQUIRED_RUBY_VERSION.satisfied_by?(Gem::Version.new(RUBY_VERSION))
        $stderr.puts("puppet-profile-parser requires Ruby #{REQUIRED_RUBY_VERSION}")
        exit 1
      elsif @log_files.empty?
        $stderr.puts(@optparser.help)
        exit 1
      end

      parser = LogParser.new

      @log_files.each {|f| parser.parse_file(f)}

      @formatter.write(parser.traces)
    rescue => e
      message = if @options[:debug]
                  ["ERROR #{e.class}: #{e.message}",
                   e.backtrace].join("\n\t")
                else
                  "ERROR #{e.class}: #{e.message}"
                end

      $stderr.puts(message)
      exit 1
    end
  end
end


if File.expand_path(__FILE__) == File.expand_path($PROGRAM_NAME)
  PuppetProfileParser::CLI.new(ARGV).run
end
