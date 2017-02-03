# encoding: utf-8
require "logstash/pipeline_action/base"

module LogStash module PipelineAction
  class Stop < Base
    attr_reader :pipeline_id

    def initialize(pipeline_id)
      @pipeline_id = pipeline_id
    end

    def execute(pipelines)
      pipeline = pipelines[pipeline_id]
      pipeline.shutdown { LogStash::ShutdownWatcher.start(pipeline) }
      pipelines.delete(pipeline_id)
      # If we reach this part of the code we have succeeded because
      # the shutdown call will block.
      return true
    end
  end
end end
