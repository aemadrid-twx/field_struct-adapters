# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'open3'
require 'rake'
require 'tmpdir'

# The type signatures of an adapter gem, the way field_struct and actionable
# make theirs: sord generates sig/<gem>.rbs from the YARD comments, `sigs:check`
# fails when the committed file is stale, and `sigs:validate` resolves every
# name with rbs, against the signatures field_struct and actionable ship.
#
# An adapter's YARD types name classes from those gems, which sord can't see:
# it parses only this gem. So write each such name in full
# (+FieldStruct::Field+, not +Field+). A short name sord can't find at all
# fails generation. A short name it can find is worse: it picks any loaded
# class with that name (+Field+ became +Prism::Reflection::Field+), and only
# sigs:validate catches it, because that class isn't among the signatures it
# loads.
#
# Dev only: no gem packages this file.
module AdapterSigs
  extend Rake::DSL

  # Where an unresolved name may come from: the gems adapters build on.
  QUALIFIED = /\A(::|FieldStruct::|Actionable::)/

  module_function

  # Defines sigs:generate, sigs:check and sigs:validate in the calling Rakefile.
  #
  # @param gem_name [String] the gem, and the basename of its sig file
  # @param libraries [Array<String>] stdlib signatures to load (+rbs -r+)
  # @param gems [Array<String>] gems whose own sig/ to load (+rbs -I+)
  # @return [void]
  def define(gem_name, libraries: [], gems: [])
    sig_file = "sig/#{gem_name}.rbs"

    namespace :sigs do
      desc "Regenerate #{sig_file} from the YARD comments via sord"
      task(:generate) { AdapterSigs.generate(sig_file, sig_file) }

      desc "Fail unless #{sig_file} matches a fresh sord run"
      task :check do
        abort "#{sig_file} doesn't exist yet: run `rake sigs:generate` and commit it." unless File.exist?(sig_file)

        Dir.mktmpdir do |dir|
          fresh = File.join(dir, File.basename(sig_file))
          AdapterSigs.generate(sig_file, fresh)
          next if Digest::SHA256.file(sig_file) == Digest::SHA256.file(fresh)

          sh "diff -u #{sig_file} #{fresh} || true"
          abort "#{sig_file} is stale: run `rake sigs:generate` and commit the result."
        end
      end

      desc 'Resolve every name in sig/ with rbs'
      task :validate do
        args = libraries.flat_map { |library| ['-r', library] }
        args += gems.flat_map { |name| ['-I', File.join(Gem.loaded_specs.fetch(name).full_gem_path, 'sig')] }
        sh 'bundle', 'exec', 'rbs', *args, '-I', 'sig', 'validate'
      end
    end
  end

  # Runs sord into +target+, with the committed +sig_file+ moved aside: YARD
  # reads sig/*.rbs as input, and an old signature confuses sord's output.
  #
  # @param sig_file [String]
  # @param target [String]
  # @return [void]
  def generate(sig_file, target)
    FileUtils.mkdir_p(File.dirname(target))
    aside = "#{sig_file}.aside"
    File.rename(sig_file, aside) if File.exist?(sig_file)
    FileUtils.rm_rf('.yardoc')
    # Private methods stay out: Ruby hides them, so the signatures should too.
    output, status = Open3.capture2e('bundle', 'exec', 'sord', target, '--rbs', '--no-sord-comments', '--hide-private')
    abort "sord failed (exit #{status.exitstatus}):\n#{output}" unless status.success?

    guard!(output, File.read(target))
    kept = target == sig_file
  ensure
    # Put the committed file back unless a successful run just replaced it.
    if File.exist?(aside)
      kept ? File.delete(aside) : File.rename(aside, sig_file)
    end
  end

  # @param output [String] sord's log
  # @param rbs [String] what it wrote
  # @return [void]
  def guard!(output, rbs)
    plain = output.gsub(/\e\[[0-9;]*m/, '')
    short = plain.scan(/: (\S+) wasn't able to be resolved/).flatten.uniq.grep_v(QUALIFIED)
    unless short.empty?
      abort 'Write these YARD types in full (FieldStruct::..., Actionable::...), ' \
            "so sord can't guess what they mean: #{short.join(", ")}"
    end
    # Only declarations count: a doc comment may say "untyped" in prose.
    untyped = rbs.lines.grep_v(/\A\s*#/).grep(/SORD_ERROR|\buntyped\b/)
    return if untyped.empty?

    abort "sord couldn't type everything (SORD_ERROR or untyped in the output):\n#{untyped.join}" \
          "Fix the YARD types sord names:\n#{plain.lines.grep(/OMIT|DUCK|SORD_ERROR|untyped/).join}"
  end
end
