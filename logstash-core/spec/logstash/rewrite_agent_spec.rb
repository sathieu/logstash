# encoding: utf-8
# This test are complimentary of `agent_spec` and with invoking the minimum of
# threading or mocks
#
require "logstash/agent"
require_relative "../support/helpers"
require_relative "../support/matchers"
require_relative "../support/mocks_classes"
require "spec_helper"

def start_agent(agent)
  th = Thread.new do
    subject.execute
  end
  th.abort_on_exception = true

  sleep(0.01) unless subject.running?
end

describe LogStash::Agent do
  # by default no tests uses the auto reload logic
  let(:agent_settings) { mock_settings("config.reload.automatic" => false) }

  subject { described_class.new(agent_settings, source_loader) }

  xcontext "add test for a finite pipeline AKA generator count => 5"

  context "Agent execute options" do
    context "when `config.reload.automatic`" do
      let(:pipeline_config) { mock_pipeline_config(:main, "input { generator {} } output { null {} }") }

      let(:source_loader) do
        TestSourceLoader.new(pipeline_config)
      end

      context "is FALSE" do
        let(:agent_settings) { mock_settings("config.reload.automatic" => true) }

        it "converge only once" do
          start_agent(subject)

          expect(subject).to have_running_pipeline?(pipeline_config)
          expect(source_loader.fetch_count).to eq(1)
          subject.shutdown
        end
      end

      context "is TRUE" do
        let(:agent_settings) do
          mock_settings(
            "config.reload.automatic" => true,
            "config.reload.interval" => 0.01
          )
        end

        it "converges periodically the pipelines from the configs source" do
          start_agent(subject)

          expect(subject).to have_running_pipeline?(pipeline_config)

          # Let the thread trigger a few calls
          try { expect(source_loader.fetch_count).to be > 1 }

          subject.shutdown
        end
      end
    end
  end

  context "when shutting down the agent" do
    let(:pipeline_config) { mock_pipeline_config(:main, "input { generator {} } output { null {} }") }
    let(:new_pipeline_config) { mock_pipeline_config(:new, "input { generator {} } output { null {} }") }

    let(:source_loader) do
      TestSourceLoader.new(pipeline_config, new_pipeline_config)
    end

    before do
      expect(subject.converge_state_and_update.success?).to be_truthy
    end

    it "stops the running pipelines" do
      expect { subject.shutdown }.to change { subject.running_pipelines.size }.from(2).to(0)
    end
  end

  context "Configuration converge scenario" do
    let(:pipeline_config) { mock_pipeline_config(:main, "input { generator {} } output { null {} }") }
    let(:new_pipeline_config) { mock_pipeline_config(:new, "input { generator {} } output { null {} }") }

    before do
      expect(subject.converge_state_and_update.success?).to be_truthy
    end

    after do
      subject.shutdown
    end

    context "no pipelines is running" do
      let(:source_loader) do
        TestSequenceSourceLoader.new([], pipeline_config)
      end

      it "creates and starts the new pipeline" do
        expect {
          expect(subject.converge_state_and_update.success?).to be_truthy
        }.to change { subject.running_pipelines.count }.from(0).to(1)
        expect(subject).to have_running_pipeline?(pipeline_config)
      end
    end

    context "when a pipeline is running" do
      context "when the source returns the current pipeline and a new one" do
        let(:source_loader) do
          TestSequenceSourceLoader.new(
            pipeline_config,
            [pipeline_config, new_pipeline_config]
          )
        end

        it "start a new pipeline and keep the original" do
          expect {
            expect(subject.converge_state_and_update.success?).to be_truthy
          }.to change { subject.running_pipelines.count }.from(1).to(2)
          expect(subject).to have_running_pipeline?(pipeline_config)
          expect(subject).to have_running_pipeline?(new_pipeline_config)
        end
      end

      context "when the source returns a new pipeline but not the old one" do
        let(:source_loader) do
          TestSequenceSourceLoader.new(
            pipeline_config,
            new_pipeline_config
          )
        end

        it "stops the missing pipeline and start the new one" do
          expect {
            expect(subject.converge_state_and_update.success?).to be_truthy
          }.not_to change { subject.running_pipelines.count }
          expect(subject).not_to have_pipeline?(pipeline_config)
          expect(subject).to have_running_pipeline?(new_pipeline_config)
        end
      end
    end

    context "when the source return a modified pipeline" do
      let(:modified_pipeline_config) { mock_pipeline_config(:main, "input { generator { id => 'new-and-modified'} } output { null {} }") }

      let(:source_loader) do
        TestSequenceSourceLoader.new(
          pipeline_config,
          modified_pipeline_config
        )
      end

      it "stops the missing pipeline and start the new one" do
        expect {
          expect(subject.converge_state_and_update.success?).to be_truthy
        }.not_to change { subject.running_pipelines.count }
        expect(subject).to have_running_pipeline?(modified_pipeline_config)
        expect(subject).not_to have_pipeline?(pipeline_config)
      end
    end

    context "when the source return no pipelines" do
      let(:source_loader) do
        TestSequenceSourceLoader.new(
          [pipeline_config, new_pipeline_config],
          []
        )
      end


      it "stops all the pipeline" do
        expect {
          expect(subject.converge_state_and_update.success?).to be_truthy
        }.to change { subject.running_pipelines.count }.from(2).to(0)
        expect(subject).not_to have_pipeline?(pipeline_config)
      end
    end
  end

  context "collecting stats"
end

# Extract stats from this test suite
