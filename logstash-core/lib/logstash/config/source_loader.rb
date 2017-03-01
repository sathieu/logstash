# encoding: utf-8
require "logstash/config/source/local"
require "logstash/errors"
require "thread"
require "set"

module LogStash module Config
  class SourceLoader
    class AggregateSource
      class SuccessfulFetch
        attr_reader :response

        def initialize(response)
          @response = response
        end

        def success?
          true
        end
      end

      class FailedFetch
        attr_reader :error

        def initialize(error)
          @error = error
        end

        def success?
          false
        end
      end

      include LogStash::Util::Loggable

      def initialize(sources)
        @sources = sources
      end

      def fetch
        SuccessfulFetch.new(@sources.collect(&:pipeline_configs).compact.flatten)
      rescue => e
        logger.error("Could not fetch all the sources", :exception => e.class, :message => e.message)
        FailedFetch.new(e.message)
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
      sources_loaders = []

      sources do |source|
        if source.match?(settings)
          sources_loaders << source.new(settings)
        end
      end

      if sources_loaders.empty?
        # This shouldn't happen with the settings object or with any external plugins.
        # but lets add a guard so we fail fast.
        raise LogStash::InvalidSourceLoaderSettingError, "Can't find an appropriate config loader with current settings"
      else
        AggregateSource.new(sources_loaders)
      end
    end

    def sources()
      @sources_lock.synchronize do
        if block_given?
          @sources.each do |source|
            yield source
          end
        else
          @sources
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
