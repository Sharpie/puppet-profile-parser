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

The most recent stable release of the script can be downloaded from:

https://github.com/Sharpie/puppet-profile-parser/releases/download/0.1.0/profile-parser.rb

And the latest development version can be downloaded from:

https://raw.githubusercontent.com/Sharpie/puppet-profile-parser/master/puppet-profile-parser.rb


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

### Parsing profiles

The `puppet-profile-parser.rb` script expects list of Puppet Server
log files containing `PROFILE` entries:

    ./profile-parser.rb .../path/to/puppetserver.log [.../more/logs]

The script is capable of reading both plaintext log files and archived
log files that have been compressed with `gzip`. Compressed log files
must have a name that ends in `.gz` in order to be read.

### Output formats

The tool defaults to a human-readable summary. Additional formats can be
selected using the `--format` flag. For example, to generate output for
[brendangregg/FlameGraph](https://github.com/brendangregg/FlameGraph):

    ./profile-parser.rb --format flamegraph puppetserver.log | \
      path/to/flamegraph.pl --countname ms > puppet_profile.svg
