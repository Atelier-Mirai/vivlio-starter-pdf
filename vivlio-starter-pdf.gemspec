# frozen_string_literal: true

require_relative "lib/vivlio_starter/cli/pdf/version"

Gem::Specification.new do |spec|
  spec.name = "vivlio-starter-pdf"
  spec.version = VivlioStarter::Pdf::VERSION
  spec.authors = ["Mirai"]
  spec.email = ["mirai@example.com"]

  spec.summary = "Advanced PDF processor for vivlio-starter using HexaPDF"
  spec.description = "Provides PDF outline extraction, precision page numbering, and OCR via HexaPDF. AGPL-3.0 licensed."
  spec.homepage = "https://github.com/Atelier-Mirai/vivlio-starter-pdf"
  spec.license = "AGPL-3.0-only"
  spec.required_ruby_version = ">= 4.0.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/Atelier-Mirai/vivlio-starter-pdf"
  spec.post_install_message = <<~MESSAGE
    [vivlio-starter-pdf]
    Enhanced Mode の OCR を利用するには以下の外部ツールを Homebrew でインストールしてください:
      brew install tesseract tesseract-lang poppler vips

    すでに導入済みの場合はこのメッセージを無視して構いません。
  MESSAGE

  # Specify which files should be added to the gem when it is released.
  spec.files = Dir.chdir(__dir__) do
    tracked = `git ls-files -z`.split("\x0").reject do |f|
      (File.expand_path(f) == __FILE__) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git appveyor Gemfile])
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

  # Development dependencies
  spec.add_development_dependency "minitest", "~> 5.20"
  spec.add_development_dependency "minitest-reporters", "~> 1.7"
  spec.add_development_dependency "rake", "~> 13.1"
end
