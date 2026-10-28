# frozen_string_literal: true

# Each adapter is a gem of its own, with its own Gemfile; `rake` runs every
# gem's default task (specs and lint) from its directory, and stops at the
# first one that fails.
GEMS = Dir['*/*.gemspec'].map { |path| File.dirname(path) }.sort

GEMS.each do |gem_dir|
  desc "Specs and lint for #{gem_dir}"
  task gem_dir do
    Dir.chdir(gem_dir) do
      Bundler.with_unbundled_env do
        env = {'BUNDLE_GEMFILE' => File.expand_path('Gemfile')}
        sh(env, 'bundle check > /dev/null || bundle install --quiet')
        sh(env, 'bundle exec rake')
      end
    end
  end
end

desc 'Lint the files outside the gems (this Rakefile, support/)'
task :lint do
  sh 'bundle exec rubocop Rakefile Gemfile support'
end

desc 'Specs and lint for every adapter, and the shared files'
task default: [:lint, *GEMS]
