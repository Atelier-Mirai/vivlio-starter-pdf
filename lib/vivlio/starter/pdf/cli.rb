# frozen_string_literal: true

require "json"

require "samovar"

require_relative "../cli/pdf/enhanced_provider"
require_relative "../cli/pdf/log_helper"

module Vivlio
  module Starter
    module PDF
      # vivlio-starter-pdf のスタンドアロン CLI エントリポイント
      # read / nombre / outline サブコマンドを提供する
      class CLI < Samovar::Command
        self.description = "Advanced PDF processor for vivlio-starter (HexaPDF)"

        class << self
          attr_accessor :provider_factory

          # サブコマンド名とクラスの対応マップ
          def command_map
            @command_map ||= {
              "read" => ReadCommand,
              "nombre" => NombreCommand,
              "outline" => OutlineCommand
            }.freeze
          end
        end
        self.provider_factory = -> { Vivlio::Starter::Pdf::EnhancedProvider.new }

        options do
          option "-v/--verbose", "Enable verbose output"
          option "-h/--help", "Print usage information"
          option "--version", "Print version information", key: :version
        end

        # CLI のメインエントリ: ヘルプ/バージョン表示またはサブコマンド実行
        def call
          if options[:help]
            print_usage
            return 0
          end

          if options[:version]
            puts Vivlio::Starter::PDF::VERSION
            return 0
          end

          if @command
            @command.call
          else
            print_usage
            0
          end
        rescue Samovar::InvalidInputError => e
          print_usage
          abort "Error: #{e.message}"
        end

        private

        # サブコマンドに渡す共通オプション Hash を構築する
        def build_options
          { verbose: options[:verbose] }
        end

        # PDF からテキスト・画像を抽出し、JSON 形式で標準出力に出力するサブコマンド
        class ReadCommand < Samovar::Command
          self.description = "Extract text/images from a PDF and emit JSON"

          one :pdf_path, "Target PDF path"
          many :settings, "Extraction settings as key=value pairs"

          # PDF を解析し、結果を JSON で出力する
          def call
            ensure_file!(pdf_path, "PDF")
            cfg = parsed_settings

            result = Vivlio::Starter::PDF::Reader.new(
              pdf_path,
              page_separator: parse_boolean(cfg.fetch("page_separator", "true")),
              text_area: parse_text_area(cfg["text_area"]),
              line_merge_tolerance: Float(cfg.fetch("line_merge_tolerance", "2.0")),
              images_dir: cfg["images_dir"],
              image_reference_dir: cfg["image_reference_dir"],
              ocr: parse_json_object(cfg["ocr"])
            ).execute

            puts JSON.generate(result)
            0
          rescue ArgumentError, JSON::ParserError => e
            Vivlio::Starter::Pdf::LogHelper.log_error(e.message)
            1
          rescue Samovar::InvalidInputError => e
            Vivlio::Starter::Pdf::LogHelper.log_error(e.message)
            1
          end

          private

          # ファイルの存在を検証し、なければエラーを送出する
          def ensure_file!(path, label)
            return if File.exist?(path)

            raise Samovar::InvalidInputError, "#{label} が見つかりません: #{path}"
          end

          # key=value 形式の引数をパースして Hash に変換する
          def parsed_settings
            Array(settings).each_with_object({}) do |token, hash|
              key, value = token.to_s.split("=", 2)
              raise ArgumentError, "Invalid setting token: #{token.inspect}" if key.to_s.empty? || value.nil?

              hash[key] = value
            end
          end

          # 文字列を真偽値に変換する
          def parse_boolean(value)
            case value.to_s.strip.downcase
            in "true" | "1" | "yes" | "on" then true
            in "false" | "0" | "no" | "off" then false
            else
              raise ArgumentError, "Invalid --page-separator value: #{value.inspect}"
            end
          end

          # text_area の JSON 文字列をパースする
          def parse_text_area(value)
            raw = value.to_s.strip
            return nil if raw.empty?

            JSON.parse(raw)
          end

          # JSON 文字列をパースして Hash を返す
          def parse_json_object(value)
            raw = value.to_s.strip
            return nil if raw.empty?

            JSON.parse(raw)
          end
        end

        # PDF に隠しノンブル（ページ番号）を書き込むサブコマンド
        class NombreCommand < Samovar::Command
          self.description = "Overlay hidden nombre (page numbers) onto a PDF"

          # mm → pt 変換係数
          MM_TO_PT = 72.0 / 25.4
          # 塗り足し幅の既定値（mm）
          DEFAULT_BLEED_MM = 3.0

          one :pdf_path, "Target PDF path"

          # 隠しノンブルを PDF に書き込む
          def call
            ensure_file!(pdf_path, "PDF")

            bleed_mm = resolve_bleed_mm
            bleed_pt = bleed_mm * MM_TO_PT

            Vivlio::Starter::Pdf::LogHelper.log_action(
              "[vs-pdf nombre] 隠しノンブルを書き込みます (bleed=#{format('%.2f', bleed_mm)}mm)"
            )

            if provider.stamp_nombre!(pdf_path, bleed_pt:)
              Vivlio::Starter::Pdf::LogHelper.log_success('[vs-pdf nombre] 隠しノンブル書き込みが完了しました')
              0
            else
              Vivlio::Starter::Pdf::LogHelper.log_error('[vs-pdf nombre] 隠しノンブル書き込みに失敗しました')
              1
            end
          rescue Samovar::InvalidInputError => e
            Vivlio::Starter::Pdf::LogHelper.log_error(e.message)
            1
          end

          private

          # EnhancedProvider のインスタンスを生成する
          def provider = CLI.provider_factory.call

          # ファイルの存在を検証する
          def ensure_file!(path, label)
            return if File.exist?(path)

            raise Samovar::InvalidInputError, "#{label} が見つかりません: #{path}"
          end

          # book.yml の print_pdf.bleed 設定から塗り足し幅（mm）を取得する
          def resolve_bleed_mm
            source = print_pdf_config
            raw = if source.respond_to?(:bleed)
                    source.bleed
                  elsif source.is_a?(Hash)
                    source[:bleed] || source["bleed"]
                  end

            parse_bleed_mm(raw)
          end

          # book.yml の print_pdf セクションを取得する
          def print_pdf_config
            config = vivlio_config
            return config.print_pdf if config.respond_to?(:print_pdf)

            case config
            in Hash => hash
              hash.fetch(:print_pdf) { hash.fetch("print_pdf") }
            else
              raise Samovar::InvalidInputError, "print_pdf 設定が見つかりません"
            end
          rescue KeyError
            raise Samovar::InvalidInputError, "print_pdf 設定が見つかりません"
          end

          # vivlio-starter 本体の設定オブジェクトを取得する
          def vivlio_config
            Vivlio::Starter::CLI::Common::CONFIG
          rescue NameError
            raise Samovar::InvalidInputError, "Vivlio Starter の設定がロードされていません"
          end

          # 塗り足し幅の設定値を mm の Float に変換する
          def parse_bleed_mm(raw)
            case raw
            in Numeric => number then positive_or_default(number.to_f)
            in String => str
              numeric = str.strip.downcase.delete_suffix("mm")
              positive_or_default(Float(numeric))
            else
              DEFAULT_BLEED_MM
            end
          rescue ArgumentError
            DEFAULT_BLEED_MM
          end

          # 正の値ならそのまま、それ以外なら既定値を返す
          def positive_or_default(value)
            value.positive? ? value : DEFAULT_BLEED_MM
          end
        end

        # HTML の見出しを解析して PDF にアウトライン（しおり）を付与するサブコマンド
        class OutlineCommand < Samovar::Command
          self.description = "Rebuild PDF outlines using existing Vivlio headings logic"

          one :pdf_path, "Target PDF path"
          many :html_inputs, "HTML files or glob patterns (default: *.html)"

          options do
            option "-m/--max-level", "Maximum outline depth (1-6)",
                   value: "LEVEL", default: "3", key: :max_level
            option "-s/--start-page", "Start page offset (default: 1)",
                   value: "PAGE", default: "1", key: :start_page
          end

          # HTML を解析し、PDF にアウトラインを付与する
          def call
            ensure_file!(pdf_path, "PDF")

            html_files = resolve_html_inputs
            raise Samovar::InvalidInputError, "対象HTMLが見つかりません" if html_files.empty?

            extractor = load_outline_extractor
            Vivlio::Starter::Pdf::LogHelper.log_action(
              "[vs-pdf outline] HTML #{html_files.size} 件を解析してアウトラインを付与します (max_level=#{max_level}, start_page=#{start_page})"
            )

            result = extractor.add_outline_from_headings!(pdf_path, html_files, max_level:, start_page:)

            if result != false
              Vivlio::Starter::Pdf::LogHelper.log_success('[vs-pdf outline] アウトラインの付与が完了しました')
              0
            else
              Vivlio::Starter::Pdf::LogHelper.log_error('[vs-pdf outline] アウトライン付与に失敗またはスキップされました')
              1
            end
          rescue Samovar::InvalidInputError => e
            Vivlio::Starter::Pdf::LogHelper.log_error(e.message)
            1
          rescue LoadError => e
            Vivlio::Starter::Pdf::LogHelper.log_error(
              "[vs-pdf outline] Vivlio::Starter::CLI::Build::OutlineExtractor を読み込めませんでした: #{e.message}"
            )
            1
          end

          private

          # ファイルの存在を検証する
          def ensure_file!(path, label)
            return if File.exist?(path)

            raise Samovar::InvalidInputError, "#{label} が見つかりません: #{path}"
          end

          # --max-level オプションを整数に変換する（1〜6）
          def max_level
            Integer(options[:max_level]).clamp(1, 6)
          rescue ArgumentError
            raise Samovar::InvalidInputError, "Invalid --max-level value: #{options[:max_level].inspect}"
          end

          # --start-page オプションを整数に変換する
          def start_page
            Integer(options[:start_page]).clamp(1, 10_000)
          rescue ArgumentError
            raise Samovar::InvalidInputError, "Invalid --start-page value: #{options[:start_page].inspect}"
          end

          # HTML 入力パスを解決する（glob 展開対応、既定は *.html）
          def resolve_html_inputs
            paths = if html_inputs&.any?
                      expand_globs(html_inputs)
                    else
                      Dir.glob("*.html").sort
                    end
            paths
              .map { File.expand_path(it) }
              .select { File.file?(it) }
          end

          # glob パターンを展開してファイルパスの配列を返す
          def expand_globs(patterns)
            patterns.flat_map { |pattern| Dir.glob(pattern, File::FNM_EXTGLOB) }.uniq
          end

          # vivlio-starter 本体の OutlineExtractor を動的にロードする
          def load_outline_extractor
            require "vivlio/starter/cli/build/outline_extractor"
            Vivlio::Starter::CLI::Build::OutlineExtractor
          end
        end

        nested :command, command_map
      end
    end
  end
end
