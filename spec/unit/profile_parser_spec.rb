require 'spec_helper'

require "#{PROJECT_ROOT}/profile-parser.rb"

describe PuppetProfiler do
  it { is_expected.to be_a(Module) }
end

describe PuppetProfiler::LogParser do
  describe 'ISO 8601 timestamp parser' do
    subject { PuppetProfiler::LogParser::ISO_8601 }

    it 'matches timestamps produced by the logback %date pattern' do
      expect(subject.match('2017-09-18 12:01:43,344')).to be_a(MatchData)
    end
  end

  describe 'Puppet Server default logback layout parser' do
    subject { PuppetProfiler::LogParser::DEFAULT_PARSER }

    it 'matches PROFILE output formatted with the layout' do
      result = subject.match("2018-02-18 18:43:53,501 INFO  [qtp1732817189-1224] [puppetserver] Puppet PROFILE [39776666] 1 Processed request GET /puppet/v3/node/pe-201734-master.puppetdebug.vlan: took 0.1640 seconds\n")

      expect(result).to be_a(MatchData)
      expect(result[:timestamp]).to eq('2018-02-18 18:43:53,501')
      expect(result[:log_level]).to eq('INFO')
      expect(result[:thread_id]).to eq('qtp1732817189-1224')
      expect(result[:java_class]).to eq('puppetserver')
      expect(result[:message]).to eq('Puppet PROFILE [39776666] 1 Processed request GET /puppet/v3/node/pe-201734-master.puppetdebug.vlan: took 0.1640 seconds')
    end
  end

  describe 'when parsing a logfile' do
    subject { described_class.new }
    let(:log_file) { fixture('puppetserver.log') }

    it 'creates a trace for each complete PROFILE' do
      subject.parse_file(log_file)

      expect(subject.traces.length).to eq(2)
      expect(subject.traces.first.inclusive_time).to eq(1500)
      expect(subject.traces.first.exclusive_time).to eq(1250)
    end
  end
end
