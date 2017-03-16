# encoding: utf-8
require "logstash/config/source/local"

module LogStash module Config module Source

  class MultiLocal < Local

    def pipeline_configs
      pipelines.map do |pipeline_settings|
				@settings = @settings.clone.merge(pipeline_settings)
        super
      end
    end

    def match?
      multi_pipeline_enabled?
    end

    private
    def multi_pipeline_enabled?
      @settings.get("config.multi_pipeline")
    end

    def pipelines
      @settings.get("pipelines")
    end
  end
end end end

