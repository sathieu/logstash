# encoding: utf-8
require "logstash/outputs/base"
require "logstash/inputs/base"
require "thread"

module LogStash
  module Inputs
    class DummyInput < LogStash::Inputs::Base
      config_name "dummyinput"

      def run(queue)
        # noop
      end
    end
  end
  module Outputs
    class DummyOutput < LogStash::Outputs::Base
      config_name "dummyoutput"
      milestone 2

      attr_reader :num_closes, :events

      def initialize(params={})
        super
        @num_closes = 0
        @events = []
      end

      def register
      end

      def receive(event)
        @events << event
      end

      def close
        @num_closes += 1
      end
    end

    class DummyOutputWithEventsArray < LogStash::Outputs::Base
      config_name "dummyoutput2"
      milestone 2

      attr_reader :events

      def initialize(params={})
        super
        @events = []
      end

      def register
      end

      def receive(event)
        @events << event
      end

      def close
      end
    end

    class DroppingDummyOutput < LogStash::Outputs::Base
      config_name "droppingdummyoutput"
      milestone 2

      attr_reader :num_closes

      def initialize(params={})
        super
        @num_closes = 0
        @events_received = Concurrent::AtomicFixnum.new(0)
      end

      def register
      end

      def receive(event)
        @events_received.increment
      end

      def events_received
        @events_received.value
      end

      def close
        @num_closes = 1
      end
    end
end end


# A Test Source loader will return the same configuration on every fetch call
class TestSourceLoader
  def initialize(*responses)
    @count = Concurrent::AtomicFixnum.new(0)
    @responses_mutex = Mutex.new
    @responses = responses.size == 1 ? Array(responses.first) : responses
  end

  def fetch
    @count.increment
    @responses
end

  def fetch_count
    @count.value
  end
end

# This source loader will return a new configuration on very call until we ran out.
class TestSequenceSourceLoader
  attr_reader :original_responses

  def initialize(*responses)
    @count = Concurrent::AtomicFixnum.new(0)
    @responses_mutex = Mutex.new
    @responses = responses.collect { |response| Array(response) }

    @original_responses = @responses.dup
  end

  def fetch
    @count.increment
    response  = @responses_mutex.synchronize { @responses.shift }
    raise "TestSequenceSourceLoader runs out of response" if response.nil?
    response
  end

  def fetch_count
    @count.value
  end
end
