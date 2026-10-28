# frozen_string_literal: true

require_relative '../../support/doctest'

RSpec.describe 'README examples' do
  Doctest.blocks(File.expand_path('../README.md', __dir__)).each do |block|
    it "run as documented (README.md:#{block.line})" do
      passed, stderr = Doctest.run(block, requires: ['field_struct/json_schema'])

      expect(passed).to be(true), stderr
    end
  end
end
