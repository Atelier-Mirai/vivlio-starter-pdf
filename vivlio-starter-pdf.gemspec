# frozen_string_literal: true

require_relative "lib/vivlio_starter/cli/pdf/version"

Gem::Specification.new do |spec|
  spec.name = "vivlio-starter-pdf"
  spec.version = VivlioStarter::Pdf::VERSION
  spec.authors = ["Atelier Mirai"]
  spec.email = ["contact@atelier-mirai.net"]

  spec.summary = "Vivlio Starter の PDF のしおり付与と、PDF から Markdown への変換を行う拡張プラグイン"
  spec.description = "Vivlio Starter の Enhanced Mode を提供する拡張プラグインです。HexaPDF で PDF にしおりを付け、" \
                     "PDF を Markdown へ変換します。スキャンした PDF は Tesseract で OCR し、画像は WebP で抽出します。" \
                     "ライセンスは AGPL-3.0 です。"
  spec.homepage = "https://github.com/Atelier-Mirai/vivlio-starter-pdf"
  spec.license = "AGPL-3.0-only"
  spec.required_ruby_version = ">= 3.4.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["source_code_uri"] = "https://github.com/Atelier-Mirai/vivlio-starter-pdf"
  spec.metadata["changelog_uri"] = "https://github.com/Atelier-Mirai/vivlio-starter-pdf/blob/master/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "false"

  spec.files = Dir.chdir(__dir__) do
    tracked = `git ls-files -z`.split("\x0").reject do |f|
      (File.expand_path(f) == __FILE__) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git .rubocop.yml .ruby-version appveyor Gemfile Rakefile])
    end
    source_files = Dir.glob("lib/**/*.rb")
    executables = Dir.glob("exe/*")
    (tracked + source_files + executables).uniq
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "hexapdf", "~> 1.0"
  spec.add_dependency "ruby-vips", "~> 2.2"

  spec.add_development_dependency "minitest", ">= 5.20"
  spec.add_development_dependency "minitest-mock", "~> 5.27"
  spec.add_development_dependency "minitest-reporters", "~> 1.7"
  spec.add_development_dependency "rake", "~> 13.1"
  spec.add_development_dependency "prawn", "~> 2.5"
  spec.add_development_dependency "rubocop", "~> 1.81"
end
