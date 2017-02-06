# encoding: utf-8
require "spec_helper"
require_relative "../../support/helpers"
require "logstash/pipeline_action/reload"
require "logstash/instrument/null_metric"

describe LogStash::PipelineAction::Reload do
  let(:metric) { LogStash::Instrument::NullMetric.new(LogStash::Instrument::Collector.new) }
  let(:pipeline_id) { :main }
  let(:new_pipeline_config) { mock_pipeline_config(pipeline_id, "input { generator { id => 'new' } } output { null {} }") }
  let(:pipeline_config) { "input { generator {} } output { null {} }" }
  let(:pipeline) { LogStash::Pipeline.new(pipeline_config) }
  let(:pipelines) { { pipeline_id => pipeline } }

  subject { described_class.new(new_pipeline_config, metric) }

  before do
    pipeline.start
  end

  after do
    pipelines.each { |_, pipeline| pipeline.shutdown }
  end

  it "returns the pipeline_id" do
    expect(subject.pipeline_id).to eq(pipeline_id)
  end

  context "reloadable pipeline" do
    it "stop the previous pipeline" do
      expect { subject.execute(pipelines) }.to change(pipeline, :running?).from(true).to(false)
    end

    it "start the new pipeline" do
      subject.execute(pipelines)
      expect(pipelines[pipeline_id].running?).to be_truthy
    end

    it "run the new pipeline code" do
      subject.execute(pipelines)
      expect(pipelines[pipeline_id].config_hash).to eq(new_pipeline_config.config_hash)
    end
  end

  context "non reloadable pipeline" do
    before do
      allow(pipeline).to receive(:reloadable?).and_return(false)
    end

    it "raises an exception" do
      expect { subject.execute(pipelines) }.to raise_error LogStash::NonReloadablePipelineError, /#{pipeline_id}/
    end
  end
end
