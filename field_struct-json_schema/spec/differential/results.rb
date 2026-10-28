# frozen_string_literal: true

# The Ruby half of the differential check (see check.mjs and `rake
# differential`): for every Regexp in corpus.json, the pattern pattern_for
# emits and whether Ruby matches each sample. Prints JSON for check.mjs.
#
# Ruby's answers are computed here, on the Ruby running the check, rather than
# stored: Onigmo's behaviour can differ between Ruby versions, and the
# translation has to match the Ruby the gem runs on.
require 'json'
require 'field_struct/json_schema'

# Onigmo warns about some corpus entries on purpose (an unescaped ']' or
# '-'), when it compiles them and when it first matches them.
$VERBOSE = nil

dir = __dir__
pool = JSON.parse(File.read(File.join(dir, 'pool.json')))
corpus = JSON.parse(File.read(File.join(dir, 'corpus.json')))

FLAGS = {'i' => Regexp::IGNORECASE, 'm' => Regexp::MULTILINE, 'x' => Regexp::EXTENDED}.freeze

def build(src, flags)
  options = flags.chars.sum { |flag| FLAGS.fetch(flag, 0) }
  Regexp.new(src, options)
rescue RegexpError
  nil
end

cases = corpus.filter_map do |src, flags, extra|
  regexp = build(src, flags)
  next {src: src, flags: flags, status: 'ruby-rejects'} unless regexp

  pattern = FieldStruct::JSONSchema.pattern_for(regexp)
  next {src: src, flags: flags, status: 'untranslated'} if pattern.nil?

  samples = (extra + pool).uniq.map { |sample| [sample, regexp.match?(sample)] }
  {src: src, flags: flags, status: 'translated', pattern: pattern, samples: samples}
end

puts JSON.generate(ruby: RUBY_VERSION, cases: cases)
