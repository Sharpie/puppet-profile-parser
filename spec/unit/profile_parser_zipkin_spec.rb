require 'spec_helper'
require 'stringio'

require "#{PROJECT_ROOT}/profile-parser.rb"

describe PuppetProfiler::ZipkinOutput do
  subject { described_class.new(output) }

  let(:output) { StringIO.new }
  let(:parser) { PuppetProfiler::LogParser.new }
  let(:log_file) { fixture('puppetserver.log') }

  before(:each) do
    parser.parse_file(log_file)
    subject.display(parser.traces)
  end

  it 'creates valid JSON' do
    expect{ JSON.parse(output.string) }.to_not raise_error
  end

  it 'creates JSON that conforms to a Zipkin APIv2 ListOfSpans' do
    result = JSON.parse(output.string)
    schema = JSON.parse(File.read(fixture('zipkin/listofspans.json')))

    validation_result = JSON::Validator.fully_validate(schema, result)

    expect(validation_result).to eq([])
  end
end
