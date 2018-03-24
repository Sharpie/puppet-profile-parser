# Change Log

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](http://keepachangelog.com/)
and this project adheres to [Semantic Versioning](http://semver.org/).

## [Unreleased]

### Fixed

  - The script now exits with code 1 if an error is raised.

### Changed

  - The `get` method of the Trace class is now private.

  - The FunctionSpan, ResourceSpan, and OtherSpan classes have been nested
    under the Span class as Span::Function, Span::Resource, and Span::Other.


## [0.2.0] - 2018-03-18

### Added

  - Colorization of output can be toggled via the `--color` and `--no-color`
    flags.

  - The LogParser class now has a `parse_file` method.

  - Each Trace is assigned a random UUID.

  - CSV output format.

  - JSON output for [v2 of the Zipkin API][zipkin-v2].

  [zipkin-v2]: https://github.com/openzipkin/zipkin-api

### Changed

  - The Namespace class has been re-named to Trace and the Slice classes
    have been renamed to Span. This matches the implementation up with
    [OpenTracing terminology][opentracing-spec].

  - The `profile-parser.rb` script has been re-named to `puppet-profile-parser.rb`
    for clarity.

  - The PuppetProfiler module has been re-named to PuppetProfileParser for
    consistency with the script name.

  - The script prints usage to stderr and exits 1 if no log files are passed.

  [opentracing-spec]: https://github.com/opentracing/specification/blob/master/specification.md


## [0.1.0] - 2018-03-02

### Added

  - RSpec tests.

  - Apache 2 license.

  - Support for reading gzipped log files.

  - Support for FlameGraph output.

### Changed

  - Profiled events are now separated by request and Java thread id. Incomplete
    profiles are dropped.

  - Inclusive and exclusive times are computed for each profile span. Output
    uses exclisive time so that hot spots aren't hidden by spans double
    counting the time taken by their children.

### Removed

  - Dependency on the `colored` and `terminal-table` gems.

  - The `catalog-analyzer.rb` script has been removed. It may return in the
    future, but for now the project will focus on parsing profile data.


## [0.0.1] - 2014-05-19

Initial version by [Adrien Thebo](https://github.com/adrienthebo)


[Unreleased]: https://github.com/Sharpie/puppet-profile-parser/compare/0.2.0...HEAD
[0.2.0]: https://github.com/Sharpie/puppet-profile-parser/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/Sharpie/puppet-profile-parser/compare/0.0.1...0.1.0
[0.0.1]: https://github.com/Sharpie/puppet-profile-parser/compare/53a9d9f...0.0.1
