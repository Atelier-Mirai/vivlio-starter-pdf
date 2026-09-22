# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"
require "rubocop/rake_task"

# 見るのは Lint と Security だけ（.rubocop.yml）。様式ではなくバグの芽を拾う
RuboCop::RakeTask.new(:rubocop)

# gemspec が Ruby 3.4 以上を謳う以上、それが本当かは実際に走らせないと分からない。
# `it`（暗黙ブロック引数）は 3.3 以下でも構文エラーにならず「it というメソッドの
# 呼び出し」として通り、実行時に NameError になる——静的解析では捕まらない。
SUPPORTED_RUBY_VERSIONS = %w[3.4.10 4.0.7].freeze

# 別の Ruby を子プロセスで起動する以上、親の bundler 環境は必ず捨てる。
# `bundle exec rake test` から呼ばれると、親（現在の Ruby）の bundler を
# 子（別の Ruby）が読みに行き、テストが始まる前に LoadError で落ちる。
# nil を渡すと、その環境変数は子から取り除かれる。
UNBUNDLED_ENV = {
  "RUBYOPT" => nil, "RUBYLIB" => nil, "GEM_HOME" => nil, "GEM_PATH" => nil,
  "BUNDLE_GEMFILE" => nil, "BUNDLE_BIN_PATH" => nil, "BUNDLER_VERSION" => nil,
  "BUNDLER_SETUP" => nil
}.freeze

namespace :test do
  # テストの実体。現在の Ruby で 1 回だけ走る（test:versions が各版でこれを呼ぶ）
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

    # 版ごとに bundle が要る。未導入なら黙って入れる（その版の初回だけ時間がかかる）
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

# 手元では常に対応全版を回す（1 版あたり 10 秒弱で終わるため、分けるほどの負担にならない）。
# CI（GitHub Actions）は版をマトリクスで分担するので、各ジョブは 1 回でよい。
task test: (ENV["CI"] ? "test:current" : "test:versions")
task default: %i[rubocop test]

# gem のアンインストール → ビルド → インストールを一括実行
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
