require 'spec_helper'

require "#{PROJECT_ROOT}/profile-parser.rb"

describe PuppetProfiler::CLI do
  # Caputure output from tests.
  # TODO: Add better output control to the CLI.
  original_stdout = $stdout
  let(:output) { StringIO.new }
  before(:each) { $stdout = output }
  after(:each) { $stdout = original_stdout }

  it 'uses file extensions to determine which IO class to use' do
    cli = described_class.new(['foo.log', 'bar.log.gz', 'baz'])

    expect(File).to receive(:open).with('foo.log', any_args).and_return(StringIO.new)
    expect(File).to receive(:open).with('baz', any_args).and_return(StringIO.new)
    expect(Zlib::GzipReader).to receive(:open).with('bar.log.gz').and_return(StringIO.new)

    cli.run
  end
end
