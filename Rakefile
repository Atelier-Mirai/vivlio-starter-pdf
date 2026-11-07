# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"
require "rubocop/rake_task"

RuboCop::RakeTask.new(:rubocop)

SUPPORTED_RUBY_VERSIONS = %w[3.4.12 4.0.9].freeze

# 子プロセスは別の Ruby で動くので、親の bundler の環境変数を渡さない（値が nil の変数は取り除かれる）
UNBUNDLED_ENV = {
  "RUBYOPT" => nil, "RUBYLIB" => nil, "GEM_HOME" => nil, "GEM_PATH" => nil,
  "BUNDLE_GEMFILE" => nil, "BUNDLE_BIN_PATH" => nil, "BUNDLER_VERSION" => nil,
  "BUNDLER_SETUP" => nil
}.freeze

namespace :test do
  Rake::TestTask.new(:current) do |t|
    t.libs << "test"
    t.libs << "lib"
    t.test_files = FileList["test/**/*_test.rb"]
  end

  desc "対応する全 Ruby 版（#{SUPPORTED_RUBY_VERSIONS.join(' / ')}）でテストする"
  task :versions do
    missing = SUPPORTED_RUBY_VERSIONS - `rbenv versions --bare`.split("\n")
    unless missing.empty?
      abort <<~MESSAGE
        次の Ruby が rbenv に入っていません: #{missing.join(', ')}
          #{missing.map { "rbenv install #{it}" }.join("\n  ")}
      MESSAGE
    end

    failed = SUPPORTED_RUBY_VERSIONS.reject do |version|
      puts "\n=== Ruby #{version} ==="
      env = UNBUNDLED_ENV.merge("RBENV_VERSION" => version)

      unless system(env, "rbenv exec bundle check", out: File::NULL, err: File::NULL)
        next false unless system(env, "rbenv exec bundle install --quiet")
      end

      system(env, "rbenv exec bundle exec rake test:current")
    end

    abort "\n失敗した Ruby: #{failed.join(', ')}" unless failed.empty?
    puts "\n全 Ruby 版で通過: #{SUPPORTED_RUBY_VERSIONS.join(' / ')}"
  end
end

# CI は Ruby の版をマトリクスで分担するので、各ジョブは現在の Ruby だけでテストする
task test: (ENV["CI"] ? "test:current" : "test:versions")
task default: %i[rubocop test]

task :reinstall do
  gemspec = Dir['*.gemspec'].first
  raise 'gemspec が見つかりません' unless gemspec

  require_relative 'lib/vivlio_starter/cli/pdf/version'
  version = VivlioStarter::Pdf::VERSION
  gem_name = 'vivlio-starter-pdf'
  gem_file = "#{gem_name}-#{version}.gem"

  sh "gem uninstall #{gem_name} --version #{version} --executables --ignore-dependencies 2>/dev/null || true"
  sh "gem build #{gemspec}"
  sh "gem install #{gem_file}"
end
