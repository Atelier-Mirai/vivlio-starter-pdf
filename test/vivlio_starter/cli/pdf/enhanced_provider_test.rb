# frozen_string_literal: true

require "test_helper"
require "vivlio_starter/cli/pdf/enhanced_provider"
require "hexapdf"
require "tmpdir"
require "fileutils"

module VivlioStarter
  module Pdf
    # EnhancedProvider のテストスイート（隠しノンブルのフォント埋め込み = FT-02）
    class EnhancedProviderTest < Minitest::Test
      # 隠しノンブル用の同梱 TTF。書籍プロジェクト（sibling の vivlio-starter）から借用する。
      FONT_SOURCE = File.expand_path(
        "../../../../../vivlio-starter/stylesheets/fonts/hackgen35/HackGen35ConsoleNF-Regular.ttf",
        __dir__
      )

      # FT-02: プロジェクトに同梱 TTF があれば、ノンブルは TrueType としてサブセット
      # 埋め込みされ、非埋め込みの Helvetica が PDF に残らない（入稿事故防止）。
      def test_should_embed_nombre_font_when_bundled_ttf_is_available
        skip "同梱フォントが見つかりません: #{FONT_SOURCE}" unless File.exist?(FONT_SOURCE)

        Dir.mktmpdir do |dir|
          Dir.chdir(dir) do
            FileUtils.mkdir_p(File.join("stylesheets", "fonts", "hackgen35"))
            FileUtils.cp(FONT_SOURCE, EnhancedProvider::NOMBRE_FONT_RELATIVE)
            pdf_path = create_pdf("t.pdf", 2)

            assert EnhancedProvider.new.stamp_nombre!(pdf_path, bleed_pt: 8.5)

            summary = font_summary(pdf_path)
            assert summary[:embedded_truetype],
                   "ノンブルが TrueType としてサブセット埋め込みされていること（FontFile2）"
            assert(summary[:base_fonts].any? { it.include?("HackGen") },
                   "ノンブルが HackGen35ConsoleNF で描画されていること: #{summary[:base_fonts]}")
            refute(summary[:base_fonts].any? { it.include?("Helvetica") },
                   "非埋め込み Helvetica が残っていないこと（FT-02 回帰）: #{summary[:base_fonts]}")
          end
        end
      end

      # 同梱 TTF が無い環境でも、ノンブル書き込み自体は Helvetica で継続する（後方互換）。
      def test_should_fall_back_to_helvetica_when_font_is_missing
        Dir.mktmpdir do |dir|
          Dir.chdir(dir) do
            pdf_path = create_pdf("t.pdf", 1)

            assert EnhancedProvider.new.stamp_nombre!(pdf_path, bleed_pt: 8.5),
                   "フォント未配置でもノンブル書き込みは成功すること"
          end
        end
      end

      private

      # 指定ページ数の空白 PDF を生成して返す
      def create_pdf(name, page_count)
        document = HexaPDF::Document.new
        page_count.times { document.pages.add([0, 0, 533, 745]) }
        document.write(name, optimize: true)
        name
      end

      # PDF 内の全オブジェクトを走査し、BaseFont 名一覧と FontFile2 の有無を集計する。
      def font_summary(pdf_path)
        document = HexaPDF::Document.open(pdf_path)
        base_fonts = []
        embedded_truetype = false

        document.each do |obj|
          value = obj.value
          next unless value.is_a?(Hash)

          base_fonts << value[:BaseFont].to_s if value[:BaseFont]
          embedded_truetype = true if value.key?(:FontFile2)
        end

        { base_fonts: base_fonts.uniq, embedded_truetype: }
      end
    end
  end
end
