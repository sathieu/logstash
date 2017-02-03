# encoding: utf-8
require "logstash/pipeline_action/base"
require "logstash/pipeline"
require "logstash/util/loggable"

module LogStash module PipelineAction
  class Create < Base
    include LogStash::Util::Loggable

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
      logger.debug("Starting pipeline", :pipeline_id => pipeline_id)
      pipeline = create_pipeline
      thread = spawn(pipeline)
      status = wait_until_started(pipeline, thread)

      if status
        logger.debug("Pipeline started succesfully", :pipeline_id => pipeline_id)
        pipelines[pipeline_id] = pipeline # The pipeline is successfully started we can add it to the hash
      end
      status
    end

    def create_pipeline
      LogStash::Pipeline.new(pipeline_config.config_string,
                             pipeline_config.settings,
                             metric)
    end

    def spawn(pipeline)
      Thread.new do
        begin
          LogStash::Util.set_thread_name("pipeline.#{pipeline_id}")
          pipeline.run
        rescue
          logger.error("Pipeline aborted due to error", :exception => e, :backtrace => e.backtrace)
        end
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
