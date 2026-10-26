# frozen_string_literal: true

require 'bigdecimal'
require 'json_schemer'

RSpec.describe FieldStruct::JSONSchema do
  # Build a named FieldStruct subclass without leaking a top-level constant.
  def struct(const_name, &body)
    klass = Class.new(FieldStruct::Base)
    klass.class_eval(&body) if body
    stub_const(const_name, klass)
    klass
  end

  # Validate a JSON document against a generated schema with an independent
  # validator: the oracle for "the schema describes what to_json emits".
  def errors_for(schema, json)
    JSONSchemer.schema(schema).validate(Oj.load(json)).map { |error| error['error'] }
  end

  def property(klass, name)
    described_class.generate(klass)['properties'][name.to_s]
  end

  describe 'FieldStruct::Base.to_json_schema' do
    it 'returns the generated schema' do
      klass = struct('Thing') { required :name, :string }

      expect(klass.to_json_schema).to eq(described_class.generate(klass))
    end
  end

  describe '.generate' do
    it 'rejects non-FieldStruct classes' do
      expect { described_class.generate(String) }
        .to raise_error(ArgumentError, /expects a FieldStruct::Base subclass, got String/)
    end

    it 'emits a draft 2020-12 object schema titled with the class name' do
      klass = struct('Acme::User') { required :name, :string }

      expect(described_class.generate(klass)).to eq(
        '$schema' => 'https://json-schema.org/draft/2020-12/schema',
        'title' => 'Acme::User',
        'type' => 'object',
        'properties' => {'name' => {'type' => 'string'}},
        'required' => ['name']
      )
    end

    it 'leaves the title out for an anonymous class' do
      schema = described_class.generate(Class.new(FieldStruct::Base) { required :name, :string })

      expect(schema).not_to have_key('title')
      expect(schema['properties']).to eq('name' => {'type' => 'string'})
    end

    it 'includes inherited fields' do
      parent = struct('Parent') { required :id, :integer }
      child = Class.new(parent) { required :name, :string }
      stub_const('Child', child)

      expect(described_class.generate(child)['properties'].keys).to eq(%w[id name])
    end

    describe 'required and nullable' do
      it 'lists required fields without a default, and lets optional fields be null' do
        klass = struct('Account') do
          required :name, :string
          required :plan, :string, default: 'free'
          optional :nickname, :string
        end
        schema = described_class.generate(klass)

        expect(schema['required']).to eq(['name'])
        expect(schema['properties']['nickname']).to eq('type' => %w[string null])
      end

      it 'adds null to an optional enum' do
        klass = struct('Light') { optional :color, :string, enum: %w[red green] }

        expect(property(klass, :color)).to eq('type' => %w[string null], 'enum' => ['red', 'green', nil])
      end

      it 'wraps a nullable $ref in anyOf' do
        struct('Addr') { required :city, :string }
        klass = struct('Person') { optional :home, Addr }

        expect(property(klass, :home)).to eq('anyOf' => [{'$ref' => '#/$defs/Addr'}, {'type' => 'null'}])
      end
    end

    describe 'scalar types' do
      let(:klass) do
        struct('Scalars') do
          required :s, :string
          required :is, :immutable_string
          required :i, :integer
          required :f, :float
          required :d, :big_decimal
          required :b, :boolean
          required :dt, :date
          required :t, :time
          required :dtt, :datetime
          required :v, :value
          required :sym, :symbol
          required :u, :uuid
          required :url, :url
          required :em, :email
        end
      end

      it 'maps each built-in type' do
        properties = described_class.generate(klass)['properties']

        expect(properties).to eq(
          's' => {'type' => 'string'},
          'is' => {'type' => 'string'},
          'i' => {'type' => 'integer'},
          'f' => {'type' => 'number'},
          'd' => {'type' => 'string', 'pattern' => '^-?[0-9]+\.[0-9]+$'},
          'b' => {'type' => 'boolean'},
          'dt' => {'type' => 'string', 'format' => 'date'},
          't' => {'type' => 'string', 'format' => 'date-time'},
          'dtt' => {'type' => 'string', 'format' => 'date-time'},
          'v' => {},
          'sym' => {'type' => 'string'},
          'u' => {'type' => 'string', 'format' => 'uuid'},
          'url' => {'type' => 'string', 'format' => 'uri'},
          'em' => {'type' => 'string', 'format' => 'email'}
        )
      end

      it 'describes what to_json emits for a valid instance' do
        instance = klass.new(
          s: 'x', is: 'y', i: 1, f: 1.5, d: BigDecimal('-12345678901234567890.125'), b: false,
          dt: Date.new(2026, 1, 2), t: Time.utc(2026, 1, 2, 3, 4, 5), dtt: DateTime.new(2026, 1, 2, 3, 4, 5, '+05:00'),
          v: {'any' => [1]}, sym: :ok, u: '123e4567-e89b-12d3-a456-426614174000', url: 'https://example.com/a',
          em: 'a@example.com'
        )

        expect(instance).to be_valid
        expect(errors_for(described_class.generate(klass), instance.to_json)).to eq([])
      end

      it 'emits no format for a time written with a non-RFC 3339 format' do
        klass = struct('Stamp') do
          required :at, :time, format: :db
          required :on, :date, format: '%m/%d/%Y'
          required :iso, :time, format: :iso8601
        end
        properties = described_class.generate(klass)['properties']

        expect(properties['at']).to eq('type' => 'string')
        expect(properties['on']).to eq('type' => 'string')
        expect(properties['iso']).to eq('type' => 'string', 'format' => 'date-time')
      end
    end

    describe 'constraints' do
      let(:klass) do
        struct('Order') do
          required :status, :string, enum: %w[open paid]
          required :kind, :symbol, enum: %i[retail wholesale]
          required :qty, :integer, in: 1..10
          required :tier, :integer, in: [1, 2, 3]
          required :ratio, :float, in: 0.0...1.0
          required :code, :string, format: /\A[A-Z]{3}-\d+\z/
        end
      end

      it 'maps enum and in: ranges' do
        properties = described_class.generate(klass)['properties']

        expect(properties['status']).to eq('type' => 'string', 'enum' => %w[open paid])
        expect(properties['kind']).to eq('type' => 'string', 'enum' => %w[retail wholesale])
        expect(properties['qty']).to eq('type' => 'integer', 'minimum' => 1, 'maximum' => 10)
        expect(properties['tier']).to eq('type' => 'integer', 'enum' => [1, 2, 3])
        expect(properties['ratio']).to eq('type' => 'number', 'minimum' => 0.0, 'exclusiveMaximum' => 1.0)
      end

      it 'translates a Regexp format to an ECMA-262 pattern' do
        expect(property(klass, :code)).to eq('type' => 'string', 'pattern' => '^[A-Z]{3}-\d+$')
      end

      it 'rejects values the struct rejects' do
        schema = described_class.generate(klass)
        valid = klass.new(status: 'open', kind: :retail, qty: 3, tier: 2, ratio: 0.5, code: 'ABC-12')

        expect(errors_for(schema, valid.to_json)).to eq([])
        expect(errors_for(schema, valid.to_json.sub('"open"', '"closed"'))).not_to be_empty
        expect(errors_for(schema, valid.to_json.sub('"qty":3', '"qty":11'))).not_to be_empty
        expect(errors_for(schema, valid.to_json.sub('ABC-12', 'abc-12'))).not_to be_empty
      end

      it 'keeps a pattern JSON Schema cannot express as x-ruby-pattern' do
        klass = struct('Loose') do
          required :caseless, :string, format: /\Aabc\z/i
          required :possessive, :string, format: /\Aa++\z/
        end
        properties = described_class.generate(klass)['properties']

        expect(properties['caseless']).to eq('type' => 'string', 'x-ruby-pattern' => '\Aabc\z')
        expect(properties['possessive']).to eq('type' => 'string', 'x-ruby-pattern' => '\Aa++\z')
      end
    end

    describe 'arrays, unions and nested structs' do
      it 'maps array elements, letting scalar elements be null' do
        struct('Line') { required :sku, :string }
        klass = struct('Cart') do
          required :counts, :array, of: :integer, element: {in: 1..5}
          required :lines, :array, of: Line
        end
        properties = described_class.generate(klass)['properties']

        expect(properties['counts']).to eq(
          'type' => 'array', 'items' => {'type' => %w[integer null], 'minimum' => 1, 'maximum' => 5}
        )
        expect(properties['lines']).to eq('type' => 'array', 'items' => {'$ref' => '#/$defs/Line'})
      end

      it 'maps a union to anyOf, and a union with :value to anything' do
        klass = struct('Mixed') do
          required :id, :union, of: %i[integer string]
          required :blob, :union, of: %i[integer value]
        end
        properties = described_class.generate(klass)['properties']

        expect(properties['id']).to eq('anyOf' => [{'type' => 'integer'}, {'type' => 'string'}])
        expect(properties['blob']).to eq({})
      end

      it 'puts each named nested struct in $defs once, and refers to the root as #' do
        struct('Acme::Addr') { required :city, :string }
        klass = struct('Acme::Person') do
          required :home, Acme::Addr
          optional :work, Acme::Addr
          optional :friends, :array, of: self
        end
        schema = described_class.generate(klass)

        expect(schema['$defs']).to eq(
          'Acme::Addr' => {'title' => 'Acme::Addr', 'type' => 'object',
                           'properties' => {'city' => {'type' => 'string'}}, 'required' => ['city']}
        )
        expect(schema['properties']['home']).to eq('$ref' => '#/$defs/Acme::Addr')
        doc = klass.new(home: {city: 'A'}, friends: [{home: {city: 'B'}}]).to_json
        expect(errors_for(schema, doc)).to eq([])
        expect(errors_for(schema, doc.sub('"city":"B"', '"city":2'))).not_to be_empty
        expect(schema['properties']['friends']).to eq('type' => %w[array null], 'items' => {'$ref' => '#'})
      end

      it 'inlines an anonymous nested struct' do
        inner = Class.new(FieldStruct::Base) { required :n, :integer }
        klass = struct('Outer') { required :inner, inner }

        expect(property(klass, :inner)).to eq(
          'type' => 'object', 'properties' => {'n' => {'type' => 'integer'}}, 'required' => ['n']
        )
      end

      it 'validates a nested to_json document' do
        struct('Pet') { required :name, :string }
        klass = struct('Owner') do
          required :pets, :array, of: Pet
          optional :best, Pet
        end
        instance = klass.new(pets: [{name: 'Rex'}], best: {name: 'Fido'})

        expect(errors_for(described_class.generate(klass), instance.to_json)).to eq([])
        expect(errors_for(described_class.generate(klass), '{"pets":[{"name":1}],"best":null}')).not_to be_empty
      end
    end

    describe 'serialized names and unknown attributes' do
      it 'uses the serialize :json external names' do
        klass = struct('Contact') do
          required :first_name, :string
          optional :last_name, :string
          serialize :json, first_name: 'firstName'
        end
        schema = described_class.generate(klass)

        expect(schema['properties'].keys).to eq(%w[firstName last_name])
        expect(schema['required']).to eq(['firstName'])
        expect(errors_for(schema, klass.new(first_name: 'Ada').to_json)).to eq([])
      end

      it 'forbids additional properties when unknown attributes raise' do
        klass = struct('Strict') do
          unknown_attributes :raise
          required :a, :string
        end

        expect(described_class.generate(klass)['additionalProperties']).to be(false)
      end
    end

    describe 'annotations and overrides' do
      it 'carries description, literal defaults and sensitivity' do
        klass = struct('Profile') do
          optional :plan, :string, default: 'free', description: 'Billing plan'
          optional :token, :string, sensitive: true, default: -> { 'generated' }
        end
        properties = described_class.generate(klass)['properties']

        expect(properties['plan']).to eq('description' => 'Billing plan', 'default' => 'free', 'type' => %w[string null])
        expect(properties['token']).to eq('x-sensitive' => true, 'type' => %w[string null])
      end

      it "uses a field's json_schema: option verbatim" do
        klass = struct('Override') { required :tags, :value, json_schema: {'type' => 'array'} }

        expect(property(klass, :tags)).to eq('type' => 'array')
      end

      it "uses a custom type's #json_schema, else names its Ruby type" do
        money = Class.new(FieldStruct::Types::Base) do
          def coerce(value, **) = value
          def ruby_type = Rational
          def json_schema = {'type' => 'string', 'pattern' => '^[0-9]+/[0-9]+$'}
        end
        plain = Class.new(FieldStruct::Types::Base) do
          def coerce(value, **) = value
          def ruby_type = Rational
        end
        klass = struct('Ledger') do
          required :amount, money
          required :other, plain
        end
        properties = described_class.generate(klass)['properties']

        expect(properties['amount']).to eq('type' => 'string', 'pattern' => '^[0-9]+/[0-9]+$')
        expect(properties['other']).to eq('x-ruby-type' => 'Rational')
      end
    end
  end
end
