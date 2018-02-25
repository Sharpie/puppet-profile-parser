require 'spec_helper'

require "#{PROJECT_ROOT}/profile-parser.rb"

describe PuppetProfiler do
  it { is_expected.to be_a(Module) }
end
