# encoding: utf-8
require "spec_helper"
require_relative "../../support/helpers"
require "logstash/pipeline_action/stop"
require "logstash/pipeline"
require "logstash/instrument/null_metric"

describe LogStash::PipelineAction::Stop do
  let(:metric) { LogStash::Instrument::NullMetric.new(LogStash::Instrument::Collector.new) }
  let(:pipeline_config) { "input { generator {} } output { }" }
  let(:pipeline_id) { :main }
  let(:pipeline) { LogStash::Pipeline.new(pipeline_config) }
  let(:pipelines) { { :main => pipeline } }

  subject { described_class.new(pipeline_id) }

  before do
    pipeline.start
  end

  it "returns the pipeline_id" do
    expect(subject.pipeline_id).to eq(:main)
  end

  it "shutdown the running pipeline" do
    expect(pipeline.running?).to be_truthy
    subject.execute(pipelines)
    expect(pipeline.running?).to be_falsey
  end

  it "removes the pipeline from the running pipelines" do
    expect(pipelines.include?(pipeline_id)).to be_truthy
    subject.execute(pipelines)
    expect(pipelines.include?(pipeline_id)).to be_falsey
  end
end
