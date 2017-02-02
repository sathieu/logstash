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
      pipeline.thread.join
    end
  end
end end
