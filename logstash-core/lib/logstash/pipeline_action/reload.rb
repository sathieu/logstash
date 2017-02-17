# encoding: utf-8
require "logstash/pipeline_action/base"
require "logstash/pipeline_action/create"
require "logstash/pipeline_action/stop"
require "logstash/errors"
require "logstash/util/loggable"

module LogStash module PipelineAction
  class Reload < Base
    include LogStash::Util::Loggable

    def initialize(pipeline_config, metric)
      @pipeline_config = pipeline_config
      @metric = metric
    end

    def pipeline_id
      @pipeline_config.pipeline_id
    end

    def execute(pipelines)
      old_pipeline = pipelines[pipeline_id]

      return false if !old_pipeline.reloadable?

      begin
        pipeline_validator = LogStash::BasePipeline.new(@pipeline_config.config_string, @pipeline_config.settings)
      rescue => e
        return false
      end

      if !pipeline_validator.reloadable?
        return false
      end

      status = Stop.new(pipeline_id).execute(pipelines)

      if status
        return Create.new(@pipeline_config, @metric).execute(pipelines)
      else
        return status
      end
    end
  end
end end
