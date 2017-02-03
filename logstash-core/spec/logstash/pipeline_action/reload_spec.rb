# encoding: utf-8
require "spec_helper"
require_relative "../support/helpers"
require "logstash/pipeline_action/reload"
require "logstash/instrument/null_metric"


describe LogStash::PipelineAction::Reload do
  let(:metric) { LogStash::Instrument::NullMetric.new }
  let(:pipeline_config) { mock_pipeline_config(:main) }
end
