# encoding: utf-8
require "logstash/pipeline_action/base"
require "logstash/pipeline_action/create"
require "logstash/pipeline_action/stop"
require "logstash/errors"
require "logstash/util/loggable"

module LogStash module PipelineAction
  class Reload < Create
    class NonReloadablePipelineError < StandardError; end

    include LogStash::Util::Loggable

    def initialize(pipeline_config, metric)
      super
    end

    def pipeline_id
      @pipeline_config.pipeline_id
    end

    # We could detect in the resolve states that we are trying to reload
    # a non reloadable pipeline, but I think we should fail here and raise an exception.
    # If we need to reload a non reloadable pipeline the health status of logstash should be yellow
    # since its not consistent.
    def execute(pipelines)
      old_pipeline = pipelines[pipeline_id]
      raise NonReloadablePipelineError, "Cannot reload pipeline: #{pipeline_id}" unless old_pipeline.reloadable?

      Stop.new(pipeline_id).execute(pipelines)

      pipeline = create_pipeline
      t = spawn(pipeline)
      wait_until_started(pipeline, t)
      pipelines[pipeline_id] = pipeline # The pipeline is successfully started we can add it to the hash
    end
  end
end end
