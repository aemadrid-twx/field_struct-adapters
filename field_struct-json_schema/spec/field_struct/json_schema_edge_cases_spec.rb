# frozen_string_literal: true

# Rules that the rest of the suite left unpinned (a mutation-testing pass found
# each one survived a change to the code).
RSpec.describe FieldStruct::JSONSchema, 'edge cases' do
  def struct(const_name, &body)
    klass = Class.new(FieldStruct::Base)
    klass.class_eval(&body) if body
    stub_const(const_name, klass)
    klass
  end

  it 'refuses FieldStruct::Base itself' do
    expect { described_class.generate(FieldStruct::Base) }
      .to raise_error(ArgumentError, /expects a FieldStruct::Base subclass, got FieldStruct::Base/)
  end

  it 'leaves out a float default that is not a JSON number' do
    klass = struct('Ratios') do
      required :up, :float, default: Float::INFINITY
      required :nan, :float, default: Float::NAN
    end

    expect(described_class.generate(klass)['properties'].values.map { |property| property.key?('default') }).to eq([false, false])
  end

  it "never keeps a schema that asked a type's json_schema, wherever that field sits" do
    calls = 0
    money = Class.new(FieldStruct::Types::Base) do
      define_method(:coerce) { |value, **| value }
      define_method(:ruby_type) { Rational }
      define_method(:json_schema) { {'type' => 'string', 'description' => "call #{calls += 1}"} }
    end
    ledger = struct('Ledger') do
      required :amount, money
      required :note, :string
    end

    expect(described_class.generate(ledger)['properties']['amount']['description']).to eq('call 1')
    expect(described_class.generate(ledger)['properties']['amount']['description']).to eq('call 2')
  end

  it 'lists each distinct member schema once in anyOf' do
    klass = struct('Either') { required :v, :union, of: %i[string immutable_string] }

    expect(described_class.generate(klass)['properties']['v']).to eq('anyOf' => [{'type' => 'string'}])
  end

  it 'describes a nested named struct that refers to itself, with the root outside the cycle' do
    node = struct('Tree::Node') { required :label, :string }
    node.optional :children, :array, of: node
    doc = struct('Doc') { required :tree, node }

    schema = described_class.generate(doc)
    expect(schema['properties']['tree']).to eq('$ref' => '#/$defs/Tree::Node')
    expect(schema['$defs']['Tree::Node']['properties']['children']['items'])
      .to eq('anyOf' => [{'$ref' => '#/$defs/Tree::Node'}, {'type' => 'null'}])
  end

  it 'leaves an optional custom type with no json_schema unconstrained, with no anyOf' do
    plain = Class.new(FieldStruct::Types::Base) do
      def coerce(value, **) = value
      def ruby_type = Rational
    end
    klass = struct('Loose') { optional :other, plain }

    expect(described_class.generate(klass)['properties']['other']).to eq('x-ruby-type' => 'Rational')
  end

  describe '.pattern_for' do
    it 'translates a group holding a variable repeat when the interval repeats it at most once' do
      expect(described_class.pattern_for(/\A(a+){1}\z/)).to eq('^(a+){1}$')
      expect(described_class.pattern_for(/\A(?:a|aa){0,1}\z/)).to eq('^(?:a|aa){0,1}$')
    end

    it 'folds a letter after a leading dash in a class under /i' do
      expect(described_class.pattern_for(/\A[-a]\z/i)).to eq('^[-aA]$')
    end

    it 'gives up on \x80, the first raw byte, and keeps \x7F' do
      expect(described_class.pattern_for(Regexp.new('\A\x80\z', Regexp::NOENCODING))).to be_nil
      expect(described_class.pattern_for(Regexp.new('\A\x7F\z'))).to eq('^\x7F$')
    end
  end
end
