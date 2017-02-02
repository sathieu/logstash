# encoding: utf-8
require "rspec"
require "rspec/expectations"

RSpec::Matchers.define :be_a_metric_event do |namespace, type, *args|
  match do
    namespace == Array(actual[0]).concat(Array(actual[1])) &&
      type == actual[2] &&
      args == actual[3..-1]
  end
end

# Match to test `NullObject` pattern
RSpec::Matchers.define :implement_interface_of do |type, key, value|
  match do |actual|
    all_instance_methods_implemented?
  end

  def missing_methods
    expected.instance_methods.select { |method| !actual.instance_methods.include?(method) }
  end

  def all_instance_methods_implemented?
    expected.instance_methods.all? { |method| actual.instance_methods.include?(method) }
  end

  failure_message do
    "Expecting `#{expected}` to implements instance methods of `#{actual}`, missing methods: #{missing_methods.join(",")}"
  end
end

RSpec::Matchers.define :have_actions do |*expected|
  match do |actual|
    expect(actual.size).to eq(expected.size)

    expected_values = expected.each_with_object([]) do |i, obj|
      klass_name = "LogStash::PipelineAction::#{i.first.capitalize}"
      obj << [klass_name, i.last]
    end

    actual_values = actual.each_with_object([]) do |i, obj|
      klass_name = i.class.name
      obj << [klass_name, i.pipeline_id]
    end

    values_match? expected_values, actual_values
  end
end
