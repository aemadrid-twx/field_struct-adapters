# frozen_string_literal: true

require 'open3'
require 'rbconfig'

# Runs the README examples of an adapter gem, so they can't drift from the
# code. Like field_struct's own doctests: a ```ruby block preceded by a
# `<!-- doctest -->` line runs, and each `expr # => expected` line in it is an
# assertion (both sides are evaluated and compared with ==), and so is a
# one-line expression followed by `# =>` comment lines holding a value that
# wraps. An expected value written as an inspect string (`#<Invoice ...>`) is
# shown, not checked. Anything else that would check nothing raises instead of
# passing quietly: a marker with no ```ruby block after it, a README with no
# doctest blocks, a `# =>` with no value or no expression before it, and a
# value that isn't Ruby. A `# =>` inside a string or heredoc in the example
# is read as an arrow too, so keep those out of doctest blocks.
#
# Each block runs in its own Ruby process, at the top level: adapters need
# classes with real names (an Avro record is named after its class), which a
# block evaluated inside a throwaway module wouldn't have. Dev only: no gem
# packages this file.
module Doctest
  Block = Struct.new(:path, :line, :source)

  # Defined in each block's process; the rewritten `# =>` lines call it.
  PRELUDE = <<~'RUBY'
    def __doctest_eq(actual, expected, label)
      return if actual == expected

      abort "#{label}: documented #{expected.inspect}, got #{actual.inspect}"
    end
  RUBY

  # The arrow, spelled as field_struct's doctests accept it (`# =>`, `#=>`).
  ARROW = /#\s*=>\s*/

  module_function

  # @param path [String] a README
  # @return [Array<Block>] its doctest blocks, in order
  # @raise [ArgumentError] when a marker has no ```ruby block right after it,
  #   or the file has no doctest blocks at all
  def blocks(path)
    lines = File.readlines(path)
    found = lines.each_index.filter_map do |index|
      next unless lines[index].match?(/\A\s*<!--\s*doctest\s*-->\s*\z/)

      fence = index + 1
      fence += 1 while fence < lines.length && lines[fence].strip.empty?
      unless lines[fence]&.strip&.match?(/\A```ruby\b/)
        raise ArgumentError, "#{path}:#{index + 1}: a doctest marker needs a ```ruby block right after it"
      end

      close = fence + 1
      close += 1 until close >= lines.length || lines[close].strip == '```'
      Block.new(path, fence + 2, lines[(fence + 1)...close].join)
    end
    raise ArgumentError, "#{path}: no doctest blocks (mark a ```ruby block with <!-- doctest -->)" if found.empty?

    found
  end

  # @param block [Block]
  # @param requires [Array<String>] features to require first
  # @return [Array(Boolean, String)] whether it passed, and its stderr
  def run(block, requires:)
    script = +PRELUDE
    requires.each { |feature| script << "require #{feature.inspect}\n" }
    script << assertions(block)
    _out, err, status = Open3.capture3(RbConfig.ruby, '-', stdin_data: script)
    [status.success?, err]
  end

  # @param block [Block]
  # @return [String] the block, with each `# =>` rewritten: on the
  #   expression's own line, or on comment lines right after it (a value that
  #   wraps, each continuation line starting with `#`)
  # @raise [ArgumentError] on a `# =>` value that is neither Ruby nor `#<...>`
  def assertions(block)
    lines = block.source.lines
    out = []
    index = 0
    while index < lines.length
      line = lines[index]
      label = "#{File.basename(block.path)}:#{block.line + index}"
      if line.match?(/\A\s*#{ARROW}/)
        raise ArgumentError, "#{label}: a # => needs the expression on the line right before it"
      end

      if line.strip.start_with?('#')
        out << line
      elsif (match = line.chomp.match(/\A(\s*)(\S.*?)\s*#{ARROW}(.*)\z/))
        expected, taken = wrapped_value(match[3], lines, index + 1, label)
        out << (expected ? assertion(match[1], match[2], expected, label) : line)
        out.concat(["\n"] * taken) # keep line numbers stable
        index += taken
      elsif (start = lines[index + 1]&.match(/\A\s*#{ARROW}/))
        expected, taken = wrapped_value(start.post_match.chomp, lines, index + 2, label)
        out << (expected ? assertion(line[/\A\s*/], line.strip, expected, label) : line)
        out.concat(["\n"] * (taken + 1))
        index += taken + 1
      else
        out << line
      end
      index += 1
    end
    out.join
  end

  # @return [String]
  def assertion(indent, expr, expected, label)
    "#{indent}__doctest_eq((#{expr}), (#{expected}), #{label.inspect})\n"
  end

  # A documented value, joined with the `#` comment lines after it only until
  # it is complete Ruby, so a plain comment after a value stays a comment.
  #
  # @param value [String] the text after the arrow
  # @param lines [Array<String>]
  # @param next_line [Integer] the first line that may continue the value
  # @param label [String]
  # @return [Array(String, Integer), Array(nil, Integer)] the value (nil for
  #   an inspect string, which is shown, not checked), and how many
  #   continuation lines it took
  # @raise [ArgumentError] when the value never becomes Ruby
  def wrapped_value(value, lines, next_line, label)
    value = value.strip
    raise ArgumentError, "#{label}: a # => with no value after it" if value.empty?
    return [nil, 0] if value.start_with?('#<')

    taken = 0
    until ruby?(value)
      continuation = lines[next_line + taken]
      unless continuation&.match?(/\A\s*#/) && !continuation.match?(/\A\s*#{ARROW}/)
        raise ArgumentError, "#{label}: the documented value isn't Ruby, so it can't be checked: #{value}"
      end

      value << ' ' << continuation.sub(/\A\s*#\s?/, '').chomp
      taken += 1
    end
    [value, taken]
  end

  # @param source [String]
  # @return [Boolean]
  def ruby?(source)
    RubyVM::InstructionSequence.compile("(#{source}\n)")
    true
  rescue SyntaxError
    false
  end
end
