# frozen_string_literal: true

require 'open3'
require 'rbconfig'

# Runs the README examples of an adapter gem, so they can't drift from the
# code. Like field_struct's own doctests: a ```ruby block preceded by a
# `<!-- doctest -->` line runs, and each `expr # => expected` line in it is an
# assertion (both sides are evaluated and compared with ==), and so is an
# expression followed by `# =>` comment lines holding a value that wraps. An
# expected value that isn't valid Ruby (`#<Invoice ...>`) is shown, not checked.
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

  module_function

  # @param path [String] a README
  # @return [Array<Block>] its doctest blocks, in order
  def blocks(path)
    lines = File.readlines(path)
    lines.each_index.filter_map do |index|
      next unless lines[index].strip == '<!-- doctest -->'

      fence = index + 1
      fence += 1 while fence < lines.length && lines[fence].strip.empty?
      next unless lines[fence]&.strip&.start_with?('```ruby')

      close = fence + 1
      close += 1 until close >= lines.length || lines[close].strip == '```'
      Block.new(path, fence + 2, lines[(fence + 1)...close].join)
    end
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
  # @return [String] the block, with each assertable `# =>` rewritten: on the
  #   expression's own line, or on comment lines right after it (a value that
  #   wraps, each continuation line starting with `#`)
  def assertions(block)
    lines = block.source.lines
    out = []
    index = 0
    while index < lines.length
      line = lines[index]
      label = "#{File.basename(block.path)}:#{block.line + index}"
      if (match = line.chomp.match(/\A(\s*)(\S.*?)\s+# => (.+)\z/)) && assertable?(match[3])
        out << assertion(match[1], match[2], match[3], label)
      elsif !line.strip.start_with?('#') && lines[index + 1]&.match?(/\A\s*# => /)
        expected, taken = wrapped_value(lines, index + 1)
        if assertable?(expected)
          out << assertion(line[/\A\s*/], line.strip, expected, label)
          out.concat(["\n"] * taken) # keep line numbers stable
          index += taken
        else
          out << line
        end
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

  # @param lines [Array<String>]
  # @param start [Integer] the `# =>` line
  # @return [Array(String, Integer)] the value, and how many lines it took
  def wrapped_value(lines, start)
    taken = 1
    value = lines[start].sub(/\A\s*# => /, '').chomp
    while lines[start + taken]&.match?(/\A\s*#\s/) && !lines[start + taken].match?(/\A\s*# => /)
      value << ' ' << lines[start + taken].sub(/\A\s*#\s*/, '').chomp
      taken += 1
    end
    [value, taken]
  end

  # @param expected [String]
  # @return [Boolean] whether the documented value is Ruby that can be compared
  def assertable?(expected)
    return false if expected.start_with?('#<')

    RubyVM::InstructionSequence.compile("(#{expected}\n)")
    true
  rescue SyntaxError
    false
  end
end
