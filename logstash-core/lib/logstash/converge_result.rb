# encoding:
module LogStash
  # I've opted for a result class here to give us more flexibility
  # when we want to implement logstash's health
  class ConvergeResult
    class FailedAction < Struct.new(:action, :exception); end

    attr_reader :successful_actions, :failed_actions

    def initialize
      @successful_actions = []
      @failed_actions = []
    end

    def add_fail_action(action, exception)
      @failed_actions << FailedAction.new(action, exception)
    end

    def add_successful_action(action)
      @successful_actions << action
    end

    def success?
      @failed_actions.empty?
    end

    def fails_count
      @failed_actions.size
    end

    def success_count
      @successful_actions.size
    end

    def total
      @successful_actions.size + @failed_actions.size
    end
  end
end
