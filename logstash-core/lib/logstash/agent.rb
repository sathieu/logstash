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

    @pipeline_reload_metric = metric.namespace([:stats, :pipelines])
    @instance_reload_metric = metric.namespace([:stats, :reloads])

    @dispatcher = LogStash::EventDispatcher.new(self)
    LogStash::PLUGIN_REGISTRY.hooks.register_emitter(self.class, dispatcher)
    dispatcher.fire(:after_initialize)
  end

  def execute
    @thread = Thread.current # this var is implicilty used by Stud.stop?
    @logger.debug("starting agent")

    # Start what need to be run
    converge_state
    start_webserver

    return 1 if clean_state?

    Stud.stoppable_sleep(@reload_interval) # sleep before looping

    if @auto_reload
      # `sleep_then_run` instead of firing the interval right away
      Stud.interval(@reload_interval, :sleep_then_run => true) { converge_state }
    else
      while !Stud.stop?
        if clean_state? || running_pipelines?
          sleep 0.5
        else
          break
        end
      end
    end
  end

  # register_pipeline - adds a pipeline to the agent's state
  # @param pipeline_id [String] pipeline string identifier
  # @param settings [Hash] settings that will be passed when creating the pipeline.
  #   keys should be symbols such as :pipeline_workers and :pipeline_batch_delay
  def register_pipeline(settings)
    pipeline_settings = settings.clone
    pipeline_id = pipeline_settings.get("pipeline.id")

    pipeline = create_pipeline(pipeline_settings)
    return unless pipeline.is_a?(LogStash::Pipeline)
    if @auto_reload && !pipeline.reloadable?
      @logger.error(I18n.t("logstash.agent.non_reloadable_config_register"),
                    :pipeline_id => pipeline_id,
                    :plugins => pipeline.non_reloadable_plugins.map(&:class))
      return
    end
    @pipelines[pipeline_id] = pipeline
  end

  def resolve_actions(pipeline_configs)
    actions = []

    pipeline_configs.each do |pipeline_config|
      pipeline = @pipelines[pipeline_config.pipeline_id]

      if pipeline.nil?
        actions << LogStash::PipelineAction::Create.new(pipeline_config, metric)
      else
        # TODO(ph): The pipeline should keep a reference to the original PipelineConfig
        # and we could use straight comparison.
        if pipeline_config.config_hash != pipeline.config_hash
          actions << LogStash::PipelineAction::Reload.new(pipeline_config, metric)
        end
      end
    end

    running_pipelines = pipeline_configs.collect(&:pipeline_id)

    # If one of the running pipeline is not in the pipeline_configs, we assume that we need to
    # stop it.
    pipelines.keys
      .select { |pipeline_id| !running_pipelines.include?(pipeline_id) }
      .each { |pipeline_id| actions << LogStash::PipelineAction::Stop.new(pipeline_id) }

    actions.sort # See logstash/pipeline_action.rb
  end

  # def record_success_metrics(action)
  #   # TODO(ph): meta programming dispatch on the metric.
  #   # on the observer based on the name on the successfully command

  #   # Successfully reload
  #   @instance_reload_metric.increment(:successes)
  #   @pipeline_reload_metric.namespace([pipeline_id.to_sym, :reloads]).tap do |n|
  #     n.increment(:successes)
  #     n.gauge(:last_success_timestamp, LogStash::Timestamp.now)
  #   end
  # end

  # def record_failures_metrics(action, exception)
  #   # TODO(ph): meta programming dispatch on the metric.
  #   # on the observer based on the name on the failed command
  #   @instance_reload_metric.increment(:failures)
  #   @pipeline_reload_metric.namespace([action.pipeline_id.to_sym, :reloads]).tap do |n|
  #     n.increment(:failures)
  #     n.gauge(:last_error, { :message => exception.message, :backtrace => exception.backtrace})
  #     n.gauge(:last_failure_timestamp, LogStash::Timestamp.now)
  #   end
  # end

  def converge_state
    logger.info("Converging pipelines")

    # TODO(ph): Response status
    pipeline_configs = @source_loader.fetch

    failed_actions = []

    # We Lock any access on the pipelines, since the action will modify the
    # content of it.
    @pipelines_mutex.synchronize do
      pipeline_actions = resolve_actions(pipeline_configs)

      logger.info("Needed actions to converge", :actions_count => pipeline_actions.size) unless pipeline_actions.empty?

      pipeline_actions.each do |action|
        begin
          logger.info("Executing action", :action => action)
          action.execute(@pipelines)
        rescue => e
          logger.error("Failed to execute action",
                       :action => action,
                       :exception => e.class.name,
                       :message => e.message)

          failed_actions << [action, e]
        end
      end

      if failed_actions.empty?
        logger.info("Pipeline successfully synced")
      else
        logger.error("Could not execute all the required actions",
                      :failed_actions_count => failed_actions.size,
                      :total => pipeline_actions.size)

      end
    end

    # States is what I am expected to run, what I am currently running
    # update_health(failed_actions)
  end
  alias_method :reload_state!, :converge_state

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
    # TODO: reenable
    # @periodic_pollers.start
  end

  def reset_pipeline_metrics(id)
    # selectively reset metrics we don't wish to keep after reloading
    # these include metrics about the plugins and number of processed events
    # we want to keep other metrics like reload counts and error messages
    @collector.clear("stats/pipelines/#{id}/plugins")
    @collector.clear("stats/pipelines/#{id}/events")
  end

  def collect_metrics?
    @collect_metric
  end

  def start_pipelines
    @instance_reload_metric.increment(:successes, 0)
    @instance_reload_metric.increment(:failures, 0)
    @pipelines.each do |id, pipeline|
      start_pipeline(id)
      pipeline.collect_stats
      # no reloads yet, initalize all the reload metrics
      init_pipeline_reload_metrics(id)
    end
  end

  def shutdown_pipelines
    @upgrade_mutex.synchronize do
      @pipelines.keys.each { |pipeline_id| LogStash::PipelineAction::Stop.new(pipeline_id).execute(@pipelines) }
    end
  end

  def running_pipeline?(pipeline_id)
    thread = @pipelines[pipeline_id].thread
    thread.is_a?(Thread) && thread.alive?
  end

  def upgrade_pipeline(pipeline_id, new_pipeline)
    stop_pipeline(pipeline_id)
    reset_pipeline_metrics(pipeline_id)
    @pipelines[pipeline_id] = new_pipeline
    if start_pipeline(pipeline_id) # pipeline started successfuly
      @instance_reload_metric.increment(:successes)
      @pipeline_reload_metric.namespace([pipeline_id.to_sym, :reloads]).tap do |n|
        n.increment(:successes)
        n.gauge(:last_success_timestamp, LogStash::Timestamp.now)
      end
    end
  end

  def clean_state?
    @pipelines.empty?
  end

  def setting(key)
    @settings.get(key)
  end

  def init_pipeline_reload_metrics(id)
    @pipeline_reload_metric.namespace([id.to_sym, :reloads]).tap do |n|
      n.increment(:successes, 0)
      n.increment(:failures, 0)
      n.gauge(:last_error, nil)
      n.gauge(:last_success_timestamp, nil)
      n.gauge(:last_failure_timestamp, nil)
    end
  end
end # class LogStash::Agent
