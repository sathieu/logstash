# encoding: utf-8
def silence_warnings
  warn_level = $VERBOSE
  $VERBOSE = nil
  yield
ensure
  $VERBOSE = warn_level
end

def clear_data_dir
    data_path = agent_settings.get("path.data")
    Dir.foreach(data_path) do |f|
    next if f == "." || f == ".." || f == ".gitkeep"
    FileUtils.rm_rf(File.join(data_path, f))
  end
end

def mock_settings(settings_values)
  settings = LogStash::SETTINGS.clone

  settings_values.each do |key, value|
    settings.set(key, value)
  end

  settings
end

def mock_pipeline(pipeline_id, reloadable = true, config_hash = nil)
  config_string = "input { stdin { id => '#{pipeline_id}' }}"
  settings = mock_settings("pipeline.id" => pipeline_id.to_s, "config.string" => config_string)
  pipeline = LogStash::Pipeline.new(config_string, settings)
  allow(pipeline).to receive(:reloadable?).and_return(true) if !reloadable
  pipeline
end

def mock_pipeline_config(pipeline_id, config_string = nil)
  config_string = "input { stdin { id => '#{pipeline_id}' }}" if config_string.nil?
  config_part = LogStash::Config::ConfigPart.new(:config_string, "config_string", config_string)
  LogStash::Config::PipelineConfig.new(LogStash::Config::Source::Local, pipeline_id, config_part, mock_settings({}))
end

def simulate_auto_reload(agent, number_of_reload = 1, sleep_time_between = 0)
  number_of_reload.times do
    agent.converge_state_and_update
    sleep(sleep_time_between)
  end
end

