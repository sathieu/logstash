# encoding: utf-8
require "logstash/config/source/local"
require "logstash/errors"
require "thread"
require "set"

module LogStash module Config
  class SourceLoader
    class AggregateSource
      def initialize(sources)
        @sources = sources
      end

      def fetch
        @sources.collect(&:pipeline_configs).flatten
      end
    end

    include LogStash::Util::Loggable

    def initialize
      @sources_lock = Mutex.new
      @sources = Set.new([LogStash::Config::Source::Local])
    end

    # This return a ConfigLoader object that will
    # abstract the call to the different sources and will return multiples pipeline
    def create(settings)
      source_loaders = []

      sources do |source|
        if source.match?(settings)
          source_loaders << source.new(settings)
        end
      end

      if sources.empty?
        # This shouldn't happen with the settings object or with any external plugins.
        # but lets add a guard so we fail fast.
        raise LogStash::InvalidSourceLoaderSettingError, "Can't find an appropriate config loader with current settings"
      else
        Source.new(sources)
      end
    end

    def sources
      @sources_lock.synchronize do
        @sources.each do |source|
          yield source
        end
      end
    end

    def configure_sources(new_sources)
      new_sources = Array(new_sources).to_set
      logger.debug("Configure sources", :sources => new_sources.collect(&:to_s))
      @sources_lock.synchronize { @sources = new_sources }
    end

    def add_source(new_source)
      logger.debug("Adding source", :source => new_source.to_s)
      @sources_lock.synchronize { @sources << new_source}
    end
  end

  SOURCE_LOADER = SourceLoader.new
end end
