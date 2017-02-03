# encoding: utf-8
require "logstash/environment"
require "logstash/errors"
require "logstash/config/cpu_core_strategy"
require "logstash/instrument/collector"
require "logstash/instrument/metric"
require "logstash/instrument/periodic_pollers"
require "logstash/instrument/collector"
require "logstash/instrument/metric"
require "logstash/pipeline"
require "logstash/webserver"
require "logstash/event_dispatcher"
require "logstash/config/source_loader"
require "logstash/pipeline_action"
require "logstash/converge_result"
require "logstash/state_resolver"
require "stud/trap"
require "uri"
require "socket"
require "securerandom"

LogStash::Environment.load_locale!

class LogStash::Agent
  include LogStash::Util::Loggable
  STARTED_AT = Time.now.freeze

  attr_reader :metric, :name, :pipelines, :settings, :webserver, :dispatcher
  attr_accessor :logger

  # initialize method for LogStash::Agent
  # @param params [Hash] potential parameters are:
  #   :name [String] - identifier for the agent
  #   :auto_reload [Boolean] - enable reloading of pipelines
  #   :reload_interval [Integer] - reload pipelines every X seconds
  def initialize(settings = LogStash::SETTINGS, source_loader = LogStash::Config::SOURCE_LOADER.create(LogStash::SETTINGS))
    @logger = self.class.logger
    @settings = settings
    @auto_reload = setting("config.reload.automatic")

    @pipelines = {}
    @name = setting("node.name")
    @http_host = setting("http.host")
    @http_port = setting("http.port")
    @http_environment = setting("http.environment")
    # Generate / load the persistent uuid
    id

    @source_loader = source_loader

    @reload_interval = setting("config.reload.interval")
    @pipelines_mutex = Mutex.new

    @collect_metric = setting("metric.collect")

    # Create the collectors and configured it with the library
    configure_metrics_collectors

    @state_resolver = LogStash::StateResolver.new(metric)

    @pipeline_reload_metric = metric.namespace([:stats, :pipelines])
    @instance_reload_metric = metric.namespace([:stats, :reloads])

    @dispatcher = LogStash::EventDispatcher.new(self)
    LogStash::PLUGIN_REGISTRY.hooks.register_emitter(self.class, dispatcher)
    dispatcher.fire(:after_initialize)
  end

  def execute
    @thread = Thread.current # this var is implicilty used by Stud.stop?
    logger.debug("starting agent")

    # Start what need to be run
    converge_state_and_update
    start_webserver

    if @auto_reload
      # `sleep_then_run` instead of firing the interval right away
      Stud.interval(@reload_interval, :sleep_then_run => true) { converge_state_and_update }
    else
      # If we don't have any pipelines at this point we assume that the current logstash
      # config is bad and all of the pipeline died.
      #
      # We assume that we cannot recover from that scenario and quit logstash
      #
      # TODO(ph): I am not sure if this is the best solution when we are running in a context of multiples
      # pipelines.
      return 1 if clean_state

      while !Stud.stop?
        if clean_state? || running_pipelines?
          sleep 0.5
        else
          break
        end
      end
    end
  end

  # This is a big of a change at how we used to deal with the sequence of event,
  # instead we depends on a series of task derived from the internal state and what
  # need to be run, theses action are applied to the current pipelines to converge to
  # the desired state.
  #
  # The current actions are simple and favor composition, allow us to experiment with different
  # way to making them and also test them in isolation with the current running agent.
  #
  # Currently only action related to pipeline exist, but nothing prevent us to use the same logic
  # for other tasks.
  def converge_state(pipeline_configs)
    logger.info("Converging pipelines")

    converge_result = LogStash::ConvergeResult.new

    # We Lock any access on the pipelines, since the action will modify the
    # content of it.
    @pipelines_mutex.synchronize do
      pipeline_actions = resolve_actions(pipeline_configs)

      logger.info("Needed actions to converge", :actions_count => pipeline_actions.size) unless pipeline_actions.empty?

      pipeline_actions.each do |action|
        begin
          logger.info("Executing action", :action => action)

          if status = action.execute(@pipelines)
            converge_result.add_successful_action(action)
          else
            # The API expect to be able to display a meaningful exception,
            # So we generate one based on the current action.
            #
            # - Syntax issues will be pickup up by the rescue blog
            # - Register problem will fall here:
            #     - In the API we will see the `PipelineActionError`
            #     - In the log we will see both the error generated in the thread by the #run method
            #
            # Until we have a more robust, validation it will make the code harder without any coupling
            exception = LogStash::PipelineActionError.new("Could not successfully execute: #{action}")
            logger.error(exception.message)
            converge_result.add_fail_action(action, exception)
          end
        rescue => e
          logger.error("Failed to execute action", :action => action, :exception => e.class.name, :message => e.message)

          converge_result.add_fail_action(action, e)
        end
      end

      if converge_result.success?
        logger.info("Converge successful")
      else
        logger.error("Could not execute all the required actions",
                     :failed_actions_count => converge_result.fails_count,
                     :total => converge_result.total)

      end
    end

    number_of_running_pipeline = running_pipelines.size
    if number_of_running_pipeline.size > 0
      logger.info("Pipelines running", :count => number_of_running_pipeline, :pipelines => running_pipelines.values.collect(&:pipeline_id) )
    else
      logger.info("No pipeline are currently running")
    end

    converge_result
  end

  def converge_state_and_update
    pipeline_configs = @source_loader.fetch
    converge_result = converge_state(pipeline_configs)
    update_metrics(converge_result)
  end

  # Calculate the Logstash uptime in milliseconds
  #
  # @return [Fixnum] Uptime in milliseconds
  def uptime
    ((Time.now.to_f - STARTED_AT.to_f) * 1000.0).to_i
  end

  def stop_collecting_metrics
    @periodic_pollers.stop
  end

  def shutdown
    stop_collecting_metrics
    stop_webserver
    shutdown_pipelines
  end

  def id
    return @id if @id

    uuid = nil
    if ::File.exists?(id_path)
      begin
        uuid = ::File.open(id_path) {|f| f.each_line.first.chomp }
      rescue => e
        logger.warn("Could not open persistent UUID file!",
                    :path => id_path,
                    :error => e.message,
                    :class => e.class.name)
      end
    end

    if !uuid
      uuid = SecureRandom.uuid
      logger.info("No persistent UUID file found. Generating new UUID",
                  :uuid => uuid,
                  :path => id_path)
      begin
        ::File.open(id_path, 'w') {|f| f.write(uuid) }
      rescue => e
        logger.warn("Could not write persistent UUID file! Will use ephemeral UUID",
                    :uuid => uuid,
                    :path => id_path,
                    :error => e.message,
                    :class => e.class.name)
      end
    end

    @id = uuid
  end

  def id_path
    @id_path ||= ::File.join(settings.get("path.data"), "uuid")
  end

  def running_pipelines
    @pipelines_mutex.synchronize do
      @pipelines.select {|pipeline_id, _| running_pipeline?(pipeline_id) }
    end
  end

  def running_pipelines?
    @pipelines_mutex.synchronize do
      @pipelines.select {|pipeline_id, _| running_pipeline?(pipeline_id) }.any?
    end
  end

  def close_pipeline(id)
    pipeline = @pipelines[id]
    if pipeline
      @logger.warn("closing pipeline", :id => id)
      pipeline.close
    end
  end

  def close_pipelines
    @pipelines.each  do |id, _|
      close_pipeline(id)
    end
  end

  private
  def resolve_actions(pipeline_configs)
    @state_resolver.resolve(@pipelines, pipeline_configs)
  end

  def start_webserver
    options = {:http_host => @http_host, :http_ports => @http_port, :http_environment => @http_environment }
    @webserver = LogStash::WebServer.new(@logger, self, options)
    Thread.new(@webserver) do |webserver|
      LogStash::Util.set_thread_name("Api Webserver")
      webserver.run
    end
  end

  def stop_webserver
    @webserver.stop if @webserver
  end

  def configure_metrics_collectors
    @collector = LogStash::Instrument::Collector.new

    @metric = if collect_metrics?
      @logger.debug("Agent: Configuring metric collection")
      LogStash::Instrument::Metric.new(@collector)
    else
      LogStash::Instrument::NullMetric.new(@collector)
    end

    @periodic_pollers = LogStash::Instrument::PeriodicPollers.new(@metric,
                                                                  settings.get("queue.type"),
                                                                  self)
    # TODO(ph): reenable
    # @periodic_pollers.start
  end

  def collect_metrics?
    @collect_metric
  end

  def shutdown_pipelines
    @pipelines_mutex.synchronize do
      @pipelines.keys.each { |pipeline_id| LogStash::PipelineAction::Stop.new(pipeline_id).execute(@pipelines) }
    end
  end

  def running_pipeline?(pipeline_id)
    thread = @pipelines[pipeline_id].thread
    thread.is_a?(Thread) && thread.alive?
  end

  def clean_state?
    @pipelines.empty?
  end

  def setting(key)
    @settings.get(key)
  end

  # Methods related to the creation of all metrics
  # related to states changes and failures
  def update_metrics(converge_result)
    converge_result.failed_actions.each do |result|
      update_failures_metrics(result.action, result.exception)
    end

    converge_result.successful_actions do |action|
      update_success_metrics(action)
    end
  end

  def update_success_metrics(action)
    if action.is_a?(LogStash::PipelineAction::Reload)
      update_successful_reload_metrics(action)
    elsif action.is_a?(LogStash::PipelineAction::Create)
      initialize_metrics(action)
    end
  end

  def initialize_metrics(action)
    @instance_reload_metric.increment(:successes, 0)
    @instance_reload_metric.increment(:failures, 0)

    @pipeline_reload_metric.namespace([action.pipeline_id, :reloads]).tap do |n|
      n.increment(:successes, 0)
      n.increment(:failures, 0)
      n.gauge(:last_error, nil)
      n.gauge(:last_success_timestamp, nil)
      n.gauge(:last_failure_timestamp, nil)
    end
  end

  def update_successful_reload_metrics(action)
    @instance_reload_metric.increment(:successes)

    @pipeline_reload_metric.namespace([action.pipeline_id, :reloads]).tap do |n|
      n.increment(:successes)
      n.gauge(:last_success_timestamp, LogStash::Timestamp.now)
    end
  end

  def update_failures_metrics(action, exception)
    @instance_reload_metric.increment(:failures)

    @pipeline_reload_metric.namespace([action.pipeline_id, :reloads]).tap do |n|
      n.increment(:failures)
      n.gauge(:last_error, { :message => exception.message, :backtrace => exception.backtrace})
      n.gauge(:last_failure_timestamp, LogStash::Timestamp.now)
    end
  end
end # class LogStash::Agent
