# encoding: utf-8
require "spec_helper"
require_relative "../../support/helpers"
require "logstash/pipeline_action/create"
require "logstash/instrument/null_metric"

describe LogStash::PipelineAction::Create do
  let(:metric) { LogStash::Instrument::NullMetric.new }
  let(:pipeline_config) { mock_pipeline_config(:main) }

  subject { described_class.new(pipeline_config, metric) }

  it "returns the pipeline_id" do
    expect(subject.pipeline_id).to eq(:main)
  end
end
