#!/bin/bash

LOGS=${PT_logs:-/var/log/puppetlabs/puppetserver/puppetserver.log}
RUBY=$(which ruby||echo "/opt/puppetlabs/puppet/bin/ruby")

echo "Analyzing logs: "
eval echo $LOGS
# we allow $LOGS to contain globbing characters
# FIXME: potential security issue with allowing any logfile to be specified
# Probably need to restrict to files inside /var/log/puppetlabs/puppetserver
$RUBY ${PT__installdir}/puppet_profile_parser/files/puppet-profile-parser.rb ${LOGS}
