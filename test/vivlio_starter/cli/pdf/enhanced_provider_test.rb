# frozen_string_literal: true

require "test_helper"
require "vivlio_starter/cli/pdf/enhanced_provider"
require "hexapdf"
require "tmpdir"

module VivlioStarter
  module Pdf
    # EnhancedProvider が本体へ約束している 3 つの入口を固定する。
    #
    # 本体が `Pdf.provider` に委ねるのはこの 3 つだけで、それ以外の PDF 操作は
    # プラグインの有無で結果が変わらないよう本体側（MIT）に置かれている。
    # ここが変わるとプラグインを入れた機械と入れていない機械で成果物が食い違う。
    class EnhancedProviderTest < Minitest::Test
      def setup
        @provider = EnhancedProvider.new
      end

      def test_page_count_returns_the_number_of_pages
        Dir.mktmpdir do |dir|
          path = create_pdf(File.join(dir, "three.pdf"), 3)

          assert_equal 3, @provider.page_count(path)
        end
      end

      def test_ensure_blank_page_pdf_creates_a_pdf_of_the_given_size
        Dir.mktmpdir do |dir|
          path = File.join(dir, "blank.pdf")

          @provider.ensure_blank_page_pdf(path, 533, 745)

          assert_path_exists path
          box = HexaPDF::Document.open(path).pages.first.box(:media)
          assert_equal 533, box.width.round
          assert_equal 745, box.height.round
        end
      end

      # 既にあるファイルは作り直さない。空白ページはビルド中に何度も要求されるため、
      # 毎回書き直すとページの内容が入れ替わる余地が生まれる。
      def test_ensure_blank_page_pdf_keeps_an_existing_file
        Dir.mktmpdir do |dir|
          path = create_pdf(File.join(dir, "blank.pdf"), 2)
          before = File.read(path, mode: "rb")

          @provider.ensure_blank_page_pdf(path, 533, 745)

          assert_equal before, File.read(path, mode: "rb")
        end
      end

      def test_add_outline_writes_a_bookmark_tree
        Dir.mktmpdir do |dir|
          path = create_pdf(File.join(dir, "book.pdf"), 3)
          items = [
            { level: 1, text: "第 1 章", page: 1 },
            { level: 2, text: "1.1 節", page: 2 },
            { level: 1, text: "第 2 章", page: 3 }
          ]

          assert @provider.add_outline!(path, items, max_level: 3)

          assert_equal ["第 1 章", "1.1 節", "第 2 章"], outline_titles(path)
        end
      end

      # 有効な項目が 1 つも無いなら false を返し、空のしおりツリーを残さない。
      # 空のツリーがあると PDF ビューアが「しおり有り」と表示して中身が空になる。
      def test_add_outline_returns_false_when_no_item_is_valid
        Dir.mktmpdir do |dir|
          path = create_pdf(File.join(dir, "book.pdf"), 1)

          refute @provider.add_outline!(path, [{ level: 1, text: "", page: 1 }], max_level: 3)
        end
      end

      private

      # 指定ページ数の空白 PDF を生成して返す
      def create_pdf(path, page_count)
        document = HexaPDF::Document.new
        page_count.times { document.pages.add([0, 0, 533, 745]) }
        document.write(path, optimize: true)
        path
      end

      # しおりの見出しを並べる。each_item はツリーを深さ優先で最後までたどるので、
      # ここで再帰を重ねると子が二度数えられる
      def outline_titles(path)
        document = HexaPDF::Document.open(path)
        document.catalog[:Outlines].each_item.map { it[:Title].to_s }
      end
    end
  end
end
