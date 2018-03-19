Puppet Profile Parser
=====================

[![Build Status](https://travis-ci.org/Sharpie/puppet-profile-parser.svg?branch=master)](https://travis-ci.org/Sharpie/puppet-profile-parser)

Tools for parsing profile information from Puppet Server logs and transforming
to various output formats.


Installation
------------

The tool in this repository is the `puppet-profile-parser.rb` script. This
script has no dependencies and can be run from any location where a Ruby
interpreter is present on the `PATH`.

The script is tested against Ruby 2.1 and newer.

The most recent stable release of the script can be downloaded here:

  [Stable release: 0.2.0][stable-release]


And the latest development version can be downloaded from:

  [Edge release from master branch][edge-release]

  [stable-release]: https://github.com/Sharpie/puppet-profile-parser/releases/download/0.2.0/puppet-profile-parser.rb
  [edge-release]: https://raw.githubusercontent.com/Sharpie/puppet-profile-parser/master/puppet-profile-parser.rb


Usage
-----

### Generating profiles

The `puppet-profile-parser.rb` script scans Puppet Server logs for information
generated when the Puppet profiler is enabled. The profiler is disabled by
default and can be enabled using the [profile setting][profile-setting]
in `puppet.conf`.

  [profile-setting]: https://puppet.com/docs/puppet/5.4/configuration.html#profile

#### Profiling specific agents

A single profile can be generated for an agent by executing a test run
with the `--profile` flag:

    puppet agent -t --profile

Setting `profile=true` in the `[agent]` section of `puppet.conf` and restarting
the `puppet` service will cause all runs to generate profiling information. The
profile results will be located in the Puppet Server logs.

#### Profiling all agents

Profiling can be enabled globally by setting `profile=true` in the `[master]`
section of `puppet.conf` and restarting the `puppetserver` service.

#### Configure Puppet Server logging

Depending on the version in use, there are certain adjustments you'll want to
make to the Puppet Server logging configuration. These adjustments can be made
in the main logback configuration file:

    /etc/puppetlabs/puppetserver/logback.xml

If `puppet --version` is less than `4.8.0`, the level for the `puppetserver`
logger will need to be raised to DEBUG by adding the following configuration
towards the bottom of the file:

    <logger name="debug" level="debug"/>

Or, upgrade the `puppet-agent` package to provide Puppet 4.8.0, where profiling
data is logged at the default INFO level.

Puppet Server should be configured to include the time zone in log timestamps.
This can be done by adjusting the `pattern` of the `F1` appender:

     <pattern>%d{yyyy-MM-dd'T'HH:mm:ss.SSSXXX} %-5p [%t] [%c{2}] %m%n</pattern>

Adding the time zone improves allows logs to be processed with accurate time
stamps.

### Parsing profiles

The `puppet-profile-parser.rb` script expects list of Puppet Server
log files containing `PROFILE` entries:

    ./puppet-profile-parser.rb .../path/to/puppetserver.log [.../more/logs]

The script is capable of reading both plaintext log files and archived
log files that have been compressed with `gzip`. Compressed log files
must have a name that ends in `.gz` in order to be read.

A full list of options can be displayed using the `--help` flag:

    ./puppet-profile-parser.rb --help

### Output formats

The profile parser extracts a "trace" for each request profiled by the Puppet
Server. Within each trace are a number of nested "spans" representing
instrumented oprations executed to generate a response for the request. The
terminology of traces and spans follows the [OpenTracing specification][opentracing-spec].

The parser is capable of rendering traces to `$stdout` in a variety of
output formats which are selected using the `--format` flag. The currently
supported output formats are:

  - Human-readable (default)
  - CSV
  - FlameGraph stacks
  - Zipkin JSON

**NOTE:** Each trace is currently assigned a randomly-generated UUIDv4 as an
identifier. Re-running the script on the same input will result in the same
traces, but with new randomly generated IDs. These IDs are included in the
CSV and Zipkin output formats.

  [opentracing-spec]: https://github.com/opentracing/specification/blob/master/specification.md

#### Human readable

The `human` output format is the default used by the script if the `--format`
flag is not used to select another option This output format displays each
trace parsed from the logs as an indented list followed by summary tables for
function calls, resource evaluations, and "other" operations measured by the
profiler. The summary tables are sorted in terms of "exclusive" time, which is
the time spent on the operation after excluding any time spent on nested child
operations.

In POSIX environments, the traces are also colorized using ANSI color codes.
This behavior can be toggled using the `--color` and `--no-color` flags.


#### CSV

The CSV output format prints a header row followed by a row for each span in
each trace using a comma-separated format. The columns included in the CSV
output are:

  - `timestamp`: ISO-8601 formatted timestamp with timezone indicating when
     the span was logged.

  - `trace_id`: Randomly assigned UUIDv4 for each trace.

  - `span_id`: Dot-delimited sequence of numbers indicating span number
     and nesting depth.

  - `name`: Name of the profiled operation.

  - `exclusive_time_ms`: Milliseconds spent on the span, excluding time
     spent on nested child spans.

  - `inclusive_time_ms`: Milliseconds spent on the span, including time
     spent on nested child spans.


#### FlameGraph

The `flamegraph` output format prints each span in each trace as a semi-colon
delimited call stack followed by the number of milliseconds measured for
that span. This output format can be piped into the `flamegraph.pl` script
from [brendangregg/FlameGraph][flamegraph] to create interactive SVG
visualizations:

    ./puppet-profile-parser.rb -f flamegraph puppetserver.log | \
      path/to/flamegraph.pl --countname ms > puppet_profile.svg

An example SVG generated by `flamegraph.pl` (click for interactive version):

  [![Example FlameGraph, click for interactive version.][example-flamegraph]][example-flamegraph]

  [flamegraph]: https://github.com/brendangregg/FlameGraph
  [example-flamegraph]: https://sharpie.github.io/puppet-profile-parser/assets/puppet_profile.svg


#### Zipkin JSON

The `zipkin` output format prints a JSON array containing each span in each
trace. The JSON array conforms to the `ListOfSpans` data type defined by the
[Zipkin v2 API specification][zipkin-v2-spec]. This allows the JSON output
to be submitted as a POST request to services which implement the API:

    ./puppet-profile-parser.rb -f zipkin puppetserver.log | \
      curl -X POST -H 'Content-Type: application/json' \
        http://<zipkin hostname>:9411/api/v2/spans --data @-

There are two implementations of the Zipkin API that can be spun up quickly
inside of Docker containers:

  - [Jaeger][jaeger], an implementation by Uber now part of the CNCF:

        docker run -d -e COLLECTOR_ZIPKIN_HTTP_PORT=9411 \
          -p 16686:16686 -p 9411:9411 jaegertracing/all-in-one:latest

    Visit <http://localhost:16686> to view profiling data in the Jaeger UI.
    Double check the date range in the "lookback" setting if no traces show up.

  - [Zipkin][zipkin], the original implementation by Twitter:

        docker run -d -p 9411:9411 openzipkin/zipkin

    Visit <http://localhost:9411> to view profiling data in the Zipkin UI.
    Double check the date range in the "lookback" setting if no traces show up.


  [zipkin-v2-spec]: https://zipkin.io/zipkin-api/
  [jaeger]: http://jaeger.readthedocs.io/en/latest/
  [zipkin]: https://zipkin.io/
