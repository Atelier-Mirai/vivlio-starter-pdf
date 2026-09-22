# frozen_string_literal: true

require_relative "lib/vivlio_starter/cli/pdf/version"

Gem::Specification.new do |spec|
  spec.name = "vivlio-starter-pdf"
  spec.version = VivlioStarter::Pdf::VERSION
  spec.authors = ["Atelier Mirai"]
  spec.email = ["contact@atelier-mirai.net"]

  spec.summary = "Advanced PDF processor for vivlio-starter using HexaPDF"
  spec.description = "Provides PDF outline extraction, precision page numbering, and OCR via HexaPDF. AGPL-3.0 licensed."
  spec.homepage = "https://github.com/Atelier-Mirai/vivlio-starter-pdf"
  spec.license = "AGPL-3.0-only"
  spec.required_ruby_version = ">= 3.4.0"

  # homepage_uri は spec.homepage から自動で作られる。metadata にも同じ URL を書くと
  # rubygems.org はどちらか片方しか表示せず、gem build が警告を出す
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["source_code_uri"] = "https://github.com/Atelier-Mirai/vivlio-starter-pdf"
  spec.metadata["changelog_uri"] = "https://github.com/Atelier-Mirai/vivlio-starter-pdf/blob/master/CHANGELOG.md"
  spec.post_install_message = <<~MESSAGE
    [vivlio-starter-pdf]
    Enhanced Mode の OCR には外部ツール（tesseract / tesseract-lang / poppler / vips）が必要です。
      vs doctor --fix
    で本体側からまとめて導入できます（macOS / Homebrew）。
    手動の場合: brew install tesseract tesseract-lang poppler vips

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
  spec.add_development_dependency "minitest", ">= 5.20"
  # Minitest 6 は minitest/mock を本体から外し、この gem へ分離した
  # （History.rdoc: "Dropped minitest/mock.rb. This has been extracted to the minitest-mock gem."）。
  # 5 では autorun がついでに読んでいたので、書かなくても Object#stub が使えていた
  spec.add_development_dependency "minitest-mock", "~> 5.27"
  spec.add_development_dependency "minitest-reporters", "~> 1.7"
  spec.add_development_dependency "rake", "~> 13.1"
  # fixture の PDF を組み立てるのに使う（HexaPDF で作って HexaPDF で読むと
  # 同じ実装の癖を検証から外せないため、生成側は別のライブラリにする）
  spec.add_development_dependency "prawn", "~> 2.5"
  spec.add_development_dependency "rubocop", "~> 1.81"
end
