# frozen_string_literal: true

require 'json_schemer'

RSpec.describe Actionable::Tools do
  subject(:tool) do
    described_class.definition(ToolSpecs::RefundOrder,
      description: 'Refund part or all of an order',
      context: {user_id: ->(source) { source[:user_id] }},
      annotations: {destructive: true})
  end

  let(:output_validator) { JSONSchemer.schema(tool.output_schema) }

  before { ToolSpecs.refunds.clear }

  describe '.definition' do
    it 'names the tool after the action' do
      expect(tool.name).to eq('refund_order')
    end

    it 'takes a name you give it' do
      named = described_class.definition(ToolSpecs::RefundOrder, description: 'x', name: 'shop.refund')

      expect(named.name).to eq('shop.refund')
    end

    it 'leaves the context fields out of the input schema' do
      expect(tool.input_schema['properties'].keys).to eq(%w[order_id amount reason ship_to])
      expect(tool.input_schema['required']).to eq(%w[order_id amount])
    end

    it 'keeps definitions the input refers to' do
      expect(tool.input_schema['$defs'].keys).to eq(['ToolSpecs::Address'])
    end

    it 'is a valid 2020-12 schema, input and output' do
      expect(JSONSchemer.valid_schema?(tool.input_schema)).to be(true)
      expect(JSONSchemer.valid_schema?(tool.output_schema)).to be(true)
    end

    it 'lists the declared codes for the model' do
      expect(tool.output_schema.dig('properties', 'code', 'description'))
        .to include('Declared failures: over_limit.', 'Declared skips: already_refunded.')
    end

    it 'refuses an action without an input schema' do
      expect { described_class.definition(ToolSpecs::FreeForm, description: 'x') }
        .to raise_error(ArgumentError, /no input schema/)
    end

    it 'refuses a discriminated input' do
      expect { described_class.definition(ToolSpecs::Dispatched, description: 'x') }
        .to raise_error(ArgumentError, /discriminated input/)
    end

    it 'refuses a context field the input lacks' do
      expect { described_class.definition(ToolSpecs::RefundOrder, description: 'x', context: {tenant: proc {}}) }
        .to raise_error(ArgumentError, /no input field tenant/)
    end

    it 'refuses a blank description' do
      expect { described_class.definition(ToolSpecs::RefundOrder, description: ' ') }
        .to raise_error(ArgumentError, /needs a description/)
    end

    it 'is frozen' do
      expect(tool).to be_frozen
    end
  end

  describe '#call' do
    it 'runs the action with the context fields filled in' do
      result = tool.call({'order_id' => 'o1', 'amount' => '12.50'}, {user_id: 7})

      expect(result).to eq('status' => 'success', 'code' => 'success', 'message' => nil,
        'output' => {'refund_id' => 'rf_o1', 'amount' => '12.5', 'ship_to' => nil},
        'errors' => {}, 'metadata' => {})
      expect(ToolSpecs.refunds).to eq([{order_id: 'o1', amount: BigDecimal('12.5'), user_id: 7}])
    end

    it 'ignores a context field the model sends' do
      tool.call({'order_id' => 'o1', 'amount' => '1.0', 'user_id' => 999}, {user_id: 7})

      expect(ToolSpecs.refunds.last[:user_id]).to eq(7)
    end

    it 'reports a declared failure, with its metadata' do
      result = tool.call({'order_id' => 'o1', 'amount' => '200.0'}, {user_id: 7})

      expect(result.slice('status', 'code', 'message', 'metadata'))
        .to eq('status' => 'failure', 'code' => 'over_limit',
          'message' => 'refunds over 100 need a person', 'metadata' => {'kind' => 'rejected'})
      expect(tool.error?(result)).to be(true)
    end

    it 'reports rejected arguments field by field, so the model can retry' do
      result = tool.call({'order_id' => 'o1', 'amount' => '0.0'}, {user_id: 7})

      expect(result.slice('code', 'errors')).to eq('code' => 'invalid_input', 'errors' => {'amount' => ['is invalid']})
    end

    it 'reports a skip, which is not an error' do
      result = tool.call({'order_id' => 'dup', 'amount' => '1.0'}, {user_id: 7})

      expect(result.slice('status', 'code')).to eq('status' => 'skipped', 'code' => 'already_refunded')
      expect(tool.error?(result)).to be(false)
    end

    it 'always returns the same keys' do
      results = [%w[o1 1.0], %w[o1 200.0], %w[dup 1.0], %w[o1 0.0]].map do |order, amount|
        tool.call({'order_id' => order, 'amount' => amount}, {user_id: 7})
      end

      expect(results.map(&:keys).uniq).to eq([described_class::RESULT_KEYS])
    end

    it 'returns results the output schema accepts, whatever the outcome' do
      [%w[o1 1.0], %w[o1 200.0], %w[dup 1.0], %w[o1 0.0]].each do |order, amount|
        result = tool.call({'order_id' => order, 'amount' => amount}, {user_id: 7})

        expect(output_validator.validate(result).to_a).to be_empty, "#{order} #{amount}: #{result}"
      end
    end

    it 'holds a successful output to the action output schema' do
      wrong = tool.call({'order_id' => 'o1', 'amount' => '1.0'}, {user_id: 7}).merge('output' => {})

      expect(output_validator.valid?(wrong)).to be(false)
    end

    it 'carries nested structs as JSON' do
      result = tool.call({'order_id' => 'o1', 'amount' => '1.0', 'ship_to' => {'city' => 'Provo'}}, {user_id: 7})

      expect(result.dig('output', 'ship_to')).to eq('city' => 'Provo')
    end

    it 'accepts any output from an action without an output schema' do
      ping = described_class.definition(ToolSpecs::Ping, description: 'Echo')

      expect(ping.call({'echo' => 'hi'})['output']).to eq('echo' => 'hi')
      expect(ping.output_schema.dig('properties', 'output')).to eq({})
    end
  end
end
