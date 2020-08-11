#!/bin/bash

LOGS=${PT_logs:-/var/log/puppetlabs/puppetserver/puppetserver.log}
RUBY=$(which ruby||echo "/opt/puppetlabs/puppet/bin/ruby")
# allow expansion to empty string
shopt -s nullglob
log_list=($LOGS)
# prevent globbing to grab the parameter itself
set -o noglob
echo Supplied logs parameter: ${LOGS}
if [ ${#log_list[@]} == 0 ] ; then
  echo "Could not find matching log files"
  exit 1
fi
echo "Analyzing logs: "
echo "${log_list[@]}"
# we allow $LOGS to contain globbing characters
# FIXME: potential security issue with allowing any logfile to be specified
# Probably need to restrict to files inside /var/log/puppetlabs/puppetserver
$RUBY ${PT__installdir}/puppet_profile_parser/files/puppet-profile-parser.rb ${log_list[@]}
