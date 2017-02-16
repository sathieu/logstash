# encoding: utf-8
require "spec_helper"
require "stud/temporary"
require "logstash/inputs/generator"
require "logstash/config/pipeline_config"
require "logstash/config/config_part"
require "logstash/config/source/local"
require_relative "../support/mocks_classes"
require "fileutils"
require_relative "../support/helpers"

def create_pipeline_config(config_string)
  parts = [LogStash::Config::ConfigPart.new(LogStash::Config::Source::Local::ConfigStringLoader, "config_string", config_string)]
  LogStash::Config::PipelineConfig.new("TestMock", :main, parts, LogStash::SETTINGS)
end

describe LogStash::Agent do
  let(:agent_settings) { LogStash::SETTINGS }
  let(:agent_args) { { "config.string" => "input {} output {}" }  }
  let(:pipeline_settings) { agent_settings.clone }
  let(:pipeline_args) { {} }
  let(:config_file) { Stud::Temporary.pathname }
  let(:config_file_txt) { "input { generator { count => 100000 } } output { }" }

  subject { LogStash::Agent.new(agent_settings) }

  before :each do
    # This MUST run first, before `subject` is invoked to ensure clean state
    clear_data_dir

    File.open(config_file, "w") { |f| f.puts config_file_txt }
    agent_args.each do |key, value|
      agent_settings.set(key, value)
      pipeline_settings.set(key, value)
    end
    pipeline_args.each do |key, value|
      pipeline_settings.set(key, value)
    end
  end

  after :each do
    LogStash::SETTINGS.reset
    File.unlink(config_file)
  end

  it "fallback to hostname when no name is provided" do
    expect(LogStash::Agent.new(agent_settings).name).to eq(Socket.gethostname)
  end

  describe "register_pipeline" do
    let(:config_string) { "input { } filter { } output { }" }
    let(:agent_args) do
      {
        "config.string" => config_string,
        "config.reload.automatic" => true,
        "config.reload.interval" => 0.01,
        "pipeline.workers" => 4,
      }
    end

    after(:each) do
      subject.close_pipelines
    end

    it "should delegate settings to new pipeline" do
      expect(LogStash::Pipeline).to receive(:new) do |arg1, arg2|
        expect(arg1).to eq(config_string)
        expect(arg2.to_hash).to include(agent_args)
      end

      subject.converge_state_and_update
    end
  end

  describe "#id" do
    let(:config_file_txt) { "" }
    let(:id_file_data) { File.open(subject.id_path) {|f| f.read } }

    it "should return a UUID" do
      expect(subject.id).to be_a(String)
      expect(subject.id.size).to be > 0
    end

    it "should write out the persistent UUID" do
      expect(id_file_data).to eql(subject.id)
    end
  end

  describe "#execute" do
    let(:config_file_txt) { "input { generator { count => 100000 } } output { }" }

    before :each do
      allow(subject).to receive(:start_webserver).and_return(false)
      allow(subject).to receive(:stop_webserver).and_return(false)
    end

    context "when auto_reload is false" do
      let(:agent_args) do
        {
          "config.reload.automatic" => false,
          "path.config" => config_file
        }
      end

      context "if state is clean" do
        before :each do
          allow(subject).to receive(:running_pipelines?).and_return(true)
          allow(subject).to receive(:sleep)
          allow(subject).to receive(:clean_state?).and_return(false)
        end

        it "should not converge state" do
          expect(subject).to receive(:converge_state_and_update).once
          t = Thread.new { subject.execute }

          # TODO: refactor this. forcing an arbitrary fixed delay for thread concurrency issues is an indication of
          # a bad test design or missing class functionality.
          sleep(0.1)
          Stud.stop!(t)
          t.join
          subject.shutdown
        end
      end

      xcontext "when calling reload_pipeline!" do
        context "with a config that contains reload incompatible plugins" do
          let(:second_pipeline_config) { "input { stdin {} } filter { } output { }" }

          it "does not upgrade the new config" do
            t = Thread.new { subject.execute }
            sleep(0.1) until subject.running_pipelines? && subject.pipelines.values.first.ready?
            expect(subject).to_not receive(:upgrade_pipeline)
            File.open(config_file, "w") { |f| f.puts second_pipeline_config }
            subject.send(:"reload_pipeline!", "main")

            # TODO: refactor this. forcing an arbitrary fixed delay for thread concurrency issues is an indication of
            # a bad test design or missing class functionality.
            sleep(0.1)
            Stud.stop!(t)
            t.join
            subject.shutdown
          end
        end

        context "with a config that does not contain reload incompatible plugins" do
          let(:second_pipeline_config) { "input { generator { } } filter { } output { }" }

          it "does upgrade the new config" do
            t = Thread.new { subject.execute }
            sleep(0.1) until subject.running_pipelines? && subject.pipelines.values.first.ready?
            expect(subject).to receive(:upgrade_pipeline).once.and_call_original
            File.open(config_file, "w") { |f| f.puts second_pipeline_config }
            subject.send(:"reload_pipeline!", "main")

            # TODO: refactor this. forcing an arbitrary fixed delay for thread concurrency issues is an indication of
            # a bad test design or missing class functionality.
            sleep(0.1)
            Stud.stop!(t)
            t.join
            subject.shutdown
          end
        end

      end
      context "when calling reload_state!" do
        context "with a pipeline with auto reloading turned off" do
          let(:second_pipeline_config) { "input { generator { } } filter { } output { }" }
          let(:agent_args) { super.merge({ "config.reload.automatic" => false }) }

          it "does not try to reload the pipeline" do
            t = Thread.new { subject.execute }
            sleep(0.01) until subject.running_pipelines? && subject.pipelines.values.first.running?
            expect(subject).to_not receive(:reload_pipeline!)
            File.open(config_file, "w") { |f| f.puts second_pipeline_config }
            subject.converge_state_and_update
            sleep 0.1
            Stud.stop!(t)
            t.join
            subject.shutdown
          end
        end

        context "with a pipeline with auto reloading turned on" do
          let(:second_pipeline_config) { "input { generator { } } filter { } output { }" }
          let(:agent_args) { super.merge({ "config.reload.automatic" => true }) }

          it "tries to reload the pipeline" do
            t = Thread.new { subject.execute }
            sleep(0.01) until subject.running_pipelines? && subject.pipelines.values.first.running?
            expect(subject).to receive(:reload_pipeline!).once.and_call_original
            File.open(config_file, "w") { |f| f.puts second_pipeline_config }
            subject.converge_state_and_update
            sleep 0.1
            Stud.stop!(t)
            t.join
            subject.shutdown
          end
        end
      end
    end

    context "when auto_reload is true" do
      let(:agent_args) do
        {
          "config.reload.automatic" => true,
          "config.reload.interval" => 0.01,
          "path.config" => config_file,
        }
      end

      before(:each) do
        subject.converge_state_and_update
      end

      context "if state is clean" do
        it "should periodically reload_state" do
          allow(subject).to receive(:clean_state?).and_return(false)
          t = Thread.new { subject.execute }
          sleep 0.01 until subject.running_pipelines? && subject.pipelines.values.first.running?
          expect(subject).to receive(:converge_state_and_update).at_least(2).times
          sleep 0.1
          Stud.stop!(t)
          t.join
          subject.shutdown
        end
      end

      context "when calling reload_state!" do
        xcontext "with a config that contains reload incompatible plugins" do
          let(:second_pipeline_config) { "input { stdin { id => '123' } } filter { } output { }" }

          it "does not upgrade the new config" do
            t = Thread.new { subject.execute }
            sleep 0.01 until subject.running_pipelines? && subject.pipelines.values.first.running?
            expect(subject.pipelines.values.first.config_str).to eq(config_file_txt)
            expect(subject).to receive(:converge_state_and_update).at_least(1).times

            File.open(config_file, "w") { |f| f.puts second_pipeline_config }
            sleep 0.5

            expect(subject.pipelines.values.first.config_str.trim).to eq(config_file_txt)

            Stud.stop!(t)
            t.join
            subject.shutdown
          end
        end

        context "with a config that does not contain reload incompatible plugins" do
          let(:second_pipeline_config) { "input { generator { } } filter { } output { }" }

          it "does upgrade the new config" do
            t = Thread.new { subject.execute }
            sleep 0.01 until subject.running_pipelines? && subject.pipelines.values.first.running?
            File.open(config_file, "w") { |f| f.puts second_pipeline_config }

            # TODO: refactor this. forcing an arbitrary fixed delay for thread concurrency issues is an indication of
            # a bad test design or missing class functionality.
            sleep(0.1)
            Stud.stop!(t)
            t.join
            expect(subject.get_pipeline(:main).config_str).to eq(second_pipeline_config)
            subject.shutdown
          end
        end
      end
    end
  end

  describe "#reload_state!" do
    let(:mock_source) { double("SourceLoader", :fetch => [mock_pipeline_config(:main, first_pipeline_config)]) }

    let(:first_pipeline_config) { "input { generator { id => '1'} } filter { } output { }" }
    let(:second_pipeline_config) { "input { generator { id => '2' } } filter { } output { }" }

    let(:agent_args) { {
      "config.string" => first_pipeline_config,
      "pipeline.workers" => 4,
      "config.reload.automatic" => true
    } }

    subject { LogStash::Agent.new(agent_settings, mock_source) }

    before(:each) do
      subject.converge_state_and_update
    end

    after(:each) do
      subject.shutdown
    end

    after(:each) do
      subject.close_pipelines
    end

    context "when fetching a new state" do
      it "upgrades the state" do
        expect(subject.pipelines[:main].running?).to be_truthy
        pipeline_config = mock_pipeline_config(:main, second_pipeline_config)
        expect(mock_source).to receive(:fetch).and_return([pipeline_config])
        subject.converge_state_and_update
        expect(subject.pipelines[:main].running?).to be_truthy
        expect(subject.pipelines[:main].config_hash).to match(pipeline_config.config_hash)
      end
    end

    context "when fetching the same state" do
      it "doesn't upgrade the state" do
        expect(subject.pipelines[:main].running?).to be_truthy
        old_pipeline = subject.pipelines[:main]
        subject.converge_state_and_update
        expect(subject.pipelines[:main]).to eq(old_pipeline)
        expect(subject.pipelines[:main].running?).to be_truthy
      end
    end
  end

  describe "Environment Variables In Configs" do
    let(:mock_source) { double("SourceLoader", :fetch => [mock_pipeline_config(:main, pipeline_config)]) }
    let(:pipeline_config) { "input { generator { message => '${FOO}-bar' } } filter { } output { }" }
    let(:agent_args) { {
      "config.reload.automatic" => false,
      "config.reload.interval" => 0.01,
      "config.string" => pipeline_config
    } }

    subject { LogStash::Agent.new(agent_settings, mock_source) }

    after(:each) do
      subject.shutdown
    end

    context "environment variable templating" do
      before :each do
        @foo_content = ENV["FOO"]
        ENV["FOO"] = "foo"
      end

      after :each do
        ENV["FOO"] = @foo_content
        subject.close_pipelines
      end

      it "doesn't upgrade the state" do
        # In this case the config_hash will be the same, since the environment variable are replaced post-process
        subject.converge_state_and_update
        expect(subject.pipelines[:main].running?).to be_truthy
        old_pipeline = subject.pipelines[:main]
        subject.converge_state_and_update
        expect(subject.pipelines[:main]).to eq(old_pipeline)
        expect(subject.pipelines[:main].running?).to be_truthy
      end
    end
  end

  describe "#upgrade_pipeline" do
    let(:pipeline_config) { "input { generator  { id => 'original' } } filter { } output { }" }
    let(:agent_args) { {
      "config.string" => pipeline_config,
      "pipeline.workers" => 4
    } }
    let(:new_pipeline_config) { "input { generator {} } output { }" }

    before(:each) do
      subject.converge_state_and_update
    end

    after(:each) do
      # new pipelines will be created part of the upgrade process so we need
      # to close any initialized pipelines
      subject.close_pipelines
    end

    subject { LogStash::Agent.new(agent_settings, mock_source) }

    # TODO(ph): To make it true without using mock I need colin changes from
    # https://github.com/elastic/logstash/pull/6631
    xcontext "when the upgrade fails" do
      before :each do
        allow(subject).to receive(:fetch_config).and_return(create_pipeline_config(new_pipeline_config))
        allow(subject).to receive(:create_pipeline).and_return(nil)
        allow(subject).to receive(:stop_pipeline) do |id|
          # we register_pipeline but we never execute them so we have to mock #stop_pipeline to
          # not call Pipeline#shutdown but Pipeline#close
          subject.close_pipeline(id)
        end
      end

      it "leaves the state untouched" do
        expect_any_instance_of(LogStash::Pipeline)
        subject.send(:"reload_pipeline!", default_pipeline_id)
        expect(subject.pipelines[default_pipeline_id].config_str).to eq(pipeline_config)
      end

      context "and current state is empty" do
        it "should not start a pipeline" do
          expect(subject).to_not receive(:start_pipeline)
          subject.send(:"reload_pipeline!", default_pipeline_id)
        end
      end
    end

    context "when the upgrade succeeds" do
      let(:mock_source) { double("SourceLoader", :fetch => [mock_pipeline_config(default_pipeline_id, pipeline_config)]) }
      let(:new_config) { "input { generator { id => 'new'  } } output { }" }

      it "updates the state" do
        allow(mock_source).to receive(:fetch).and_return([mock_pipeline_config(default_pipeline_id, new_config)])
        subject.converge_state_and_update
        new_pipeline = subject.pipelines[default_pipeline_id]

        expect(new_pipeline.config_str).to eq(new_config)
        expect(new_pipeline.running?).to be_truthy
      end
    end
  end

  context "#started_at" do
    it "return the start time when the agent is started" do
      expect(described_class::STARTED_AT).to be_kind_of(Time)
    end
  end

  context "#uptime" do
    it "return the number of milliseconds since start time" do
      expect(subject.uptime).to be >= 0
    end
  end

  context "metrics after config reloading" do
    let!(:config) { "input { generator { } } output { dummyoutput { } }" }

    let!(:config_path) do
      f = Stud::Temporary.file
      f.write(config)
      f.fsync
      f.close
      f.path
    end

    let(:agent_args) do
      {
        "config.reload.automatic" => false,
        "pipeline.batch.size" => 1,
        "metric.collect" => true,
        "pipeline.workers" => 2,
        "path.config" => config_path
      }
    end

    # We need to create theses dummy classes to know how many
    # events where actually generated by the pipeline and successfully send to the output.
    # Theses values are compared with what we store in the metric store.
    class DummyOutput2 < LogStash::Outputs::DroppingDummyOutput; end

    let!(:dummy_output) { LogStash::Outputs::DroppingDummyOutput.new }
    let!(:dummy_output2) { DummyOutput2.new }
    let(:initial_generator_threshold) { 1000 }
    let(:pipeline_thread) do
      Thread.new do
        subject.register_pipeline(pipeline_settings)
        subject.execute
      end
    end


    before :each do
      allow(LogStash::Outputs::DroppingDummyOutput).to receive(:new).at_least(:once).with(anything).and_return(dummy_output)
      allow(DummyOutput2).to receive(:new).at_least(:once).with(anything).and_return(dummy_output2)

      allow(LogStash::Plugin).to receive(:lookup).with("input", "generator").and_return(LogStash::Inputs::Generator)
      allow(LogStash::Plugin).to receive(:lookup).with("codec", "plain").and_return(LogStash::Codecs::Plain)
      allow(LogStash::Plugin).to receive(:lookup).with("output", "dummyoutput").and_return(LogStash::Outputs::DroppingDummyOutput)
      allow(LogStash::Plugin).to receive(:lookup).with("output", "dummyoutput2").and_return(DummyOutput2)

      @abort_on_exception = Thread.abort_on_exception
      Thread.abort_on_exception = true

      @t = Thread.new do
        subject.execute
      end

      # wait for some events to reach the dummy_output
      sleep(0.1) until dummy_output.events_received > initial_generator_threshold
    end

    after :each do
      begin
        subject.shutdown
        Stud.stop!(pipeline_thread)
        pipeline_thread.join
      ensure
        Thread.abort_on_exception = @abort_on_exception
      end
    end

    context "when reloading a good config" do
      let(:new_config_generator_counter) { 500 }
      let(:new_config) { "input { generator { count => #{new_config_generator_counter} } } output { dummyoutput2 {} }" }

      before :each do
        File.open(config_path, "w") do |f|
          f.write(new_config)
          f.fsync
        end

        subject.converge_state_and_update

        # wait until pipeline restarts
        sleep(0.01) until dummy_output2.events_received > 0
      end

      it "resets the pipeline metric collector" do
        snapshot = subject.metric.collector.snapshot_metric
        value = snapshot.metric_store.get_with_path("/stats/pipelines")[:stats][:pipelines][:main][:events][:in].value
        expect(value).to be <= new_config_generator_counter
      end

      it "does not reset the global event count" do
        snapshot = subject.metric.collector.snapshot_metric
        value = snapshot.metric_store.get_with_path("/stats/events")[:stats][:events][:in].value
        expect(value).to be > initial_generator_threshold
      end

      it "increases the successful reload count" do
        snapshot = subject.metric.collector.snapshot_metric
        value = snapshot.metric_store.get_with_path("/stats/pipelines")[:stats][:pipelines][:main][:reloads][:successes].value
        instance_value = snapshot.metric_store.get_with_path("/stats")[:stats][:reloads][:successes].value
        expect(value).to eq(1)
        expect(instance_value).to eq(1)
      end

      it "does not set the failure reload timestamp" do
        snapshot = subject.metric.collector.snapshot_metric
        value = snapshot.metric_store.get_with_path("/stats/pipelines")[:stats][:pipelines][:main][:reloads][:last_failure_timestamp].value
        expect(value).to be(nil)
      end

      it "sets the success reload timestamp" do
        snapshot = subject.metric.collector.snapshot_metric
        value = snapshot.metric_store.get_with_path("/stats/pipelines")[:stats][:pipelines][:main][:reloads][:last_success_timestamp].value
        expect(value).to be_a(LogStash::Timestamp)
      end

      it "does not set the last reload error" do
        snapshot = subject.metric.collector.snapshot_metric
        value = snapshot.metric_store.get_with_path("/stats/pipelines")[:stats][:pipelines][:main][:reloads][:last_error].value
        expect(value).to be(nil)
      end
    end

    context "when reloading a bad config" do
      let(:new_config) { "input { generator { count => " }
      before :each do

        File.open(config_path, "w") do |f|
          f.write(new_config)
          f.fsync
        end

        subject.converge_state_and_update
      end

      it "does not increase the successful reload count" do
        snapshot = subject.metric.collector.snapshot_metric
        value = snapshot.metric_store.get_with_path("/stats/pipelines")[:stats][:pipelines][:main][:reloads][:successes].value
        expect(value).to eq(0)
      end

      it "does not set the successful reload timestamp" do
        snapshot = subject.metric.collector.snapshot_metric
        value = snapshot.metric_store.get_with_path("/stats/pipelines")[:stats][:pipelines][:main][:reloads][:last_success_timestamp].value
        expect(value).to be(nil)
      end

      it "sets the failure reload timestamp" do
        snapshot = subject.metric.collector.snapshot_metric
        value = snapshot.metric_store.get_with_path("/stats/pipelines")[:stats][:pipelines][:main][:reloads][:last_failure_timestamp].value
        expect(value).to be_a(LogStash::Timestamp)
      end

      it "sets the last reload error" do
        snapshot = subject.metric.collector.snapshot_metric
        value = snapshot.metric_store.get_with_path("/stats/pipelines")[:stats][:pipelines][:main][:reloads][:last_error].value
        expect(value).to be_a(Hash)
        expect(value).to include(:message, :backtrace)
      end

      it "increases the failed reload count" do
        snapshot = subject.metric.collector.snapshot_metric
        value = snapshot.metric_store.get_with_path("/stats/pipelines")[:stats][:pipelines][:main][:reloads][:failures].value
        expect(value).to be > 0
      end
    end

    context "when reloading a config that raises exception on pipeline.run" do
      let(:new_config) { "input { generator { count => 10000 } } output { stdout {}}" }
      let(:new_config_generator_counter) { 500 }

      class BrokenGenerator < LogStash::Inputs::Generator
        def register
          raise ArgumentError
        end
      end

      before :each do
        allow(LogStash::Plugin).to receive(:lookup).with("input", "generator").and_return(BrokenGenerator)
        allow(LogStash::Plugin).to receive(:lookup).with("output", "stdout").and_return(DummyOutput2)

        File.open(config_path, "w") do |f|
          f.write(new_config)
          f.fsync
        end
      end

      it "does not increase the successful reload count" do
        expect { subject.send(:converge_state_and_update) }.to_not change {
          snapshot = subject.metric.collector.snapshot_metric
          reload_metrics = snapshot.metric_store.get_with_path("/stats/pipelines")[:stats][:pipelines][:main][:reloads]
          reload_metrics[:successes].value
        }
      end

      it "increases the failured reload count" do
        expect { subject.send(:converge_state_and_update) }.to change {
          snapshot = subject.metric.collector.snapshot_metric
          reload_metrics = snapshot.metric_store.get_with_path("/stats/pipelines")[:stats][:pipelines][:main][:reloads]
          reload_metrics[:failures].value
        }.by(1)
      end
    end
  end
end
