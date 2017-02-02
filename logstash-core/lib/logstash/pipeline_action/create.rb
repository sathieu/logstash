# encoding: utf-8
require "logstash/pipeline_action/base"

module LogStash module PipelineAction
  class Create < Base
    # Not a big fan of passing the metric around, we will have
    # to come up with a better usage or metric in our classes
    attr_reader :pipeline_config, :metric

    def initialize(pipeline_config, metric)
      @pipeline_config = pipeline_config
      @metric = metric
    end

    def pipeline_id
      @pipeline_config.pipeline_id
    end

    def execute(pipelines)
      pipeline = create_pipeline
      thread = spawn(pipeline)
      wait_until_started(pipeline, thread)
      pipelines[pipeline_id] = pipeline # The pipeline is successfully started we can add it to the hash
    end

    def create_pipeline
      LogStash::Pipeline.new(pipeline_config.config_string,
                             pipeline_config.settings,
                             metric)
    end

    def spawn(pipeline)
      Thread.new do
        LogStash::Util.set_thread_name("pipeline.#{pipeline_id}")
        pipeline.run
      end
    end

    def wait_until_started(pipeline, thread)
      while true do
        if !thread.alive?
          return false
        elsif pipeline.running?
          return true
        else
          sleep 0.01
        end
      end
    end
  end
end end
