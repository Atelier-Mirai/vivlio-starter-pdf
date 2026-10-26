# frozen_string_literal: true

require "test_helper"
require "vivlio_starter/cli/pdf/outline_writer"
require "hexapdf"

module VivlioStarter
  module Pdf
    # OutlineWriter のテストスイート
    class OutlineWriterTest < Minitest::Test
      # テスト用の HexaPDF ドキュメントを初期化する
      def setup
        @document = HexaPDF::Document.new
        4.times { @document.pages.add }
      end

      # write がネストしたアウトラインツリーを構築することを検証する
      def test_write_builds_nested_outline_tree
        items = [
          { level: 1, text: "Chapter 1", page: 1 },
          { level: 2, text: "Section 1.1", page: 2 },
          { level: 1, text: "Chapter 2", page: 3 }
        ]

        writer = OutlineWriter.new(@document, max_level: 3)
        count = writer.write(items)

        assert_equal 3, count

        outline = @document.catalog[:Outlines]
        refute_nil outline

        first = outline[:First]
        assert_equal "Chapter 1", first[:Title]
        assert_equal @document.pages[0], first.destination_page

        child = first[:First]
        assert_equal "Section 1.1", child[:Title]
        assert_equal @document.pages[1], child.destination_page

        second = first[:Next]
        assert_equal "Chapter 2", second[:Title]
        assert_equal @document.pages[2], second.destination_page
      end

      # write が無効なエントリをスキップし、理由を報告することを検証する
      def test_write_skips_invalid_entries_and_reports_reason
        messages = []
        writer = OutlineWriter.new(@document, max_level: 2, on_skip: ->(msg) { messages << msg })

        count = writer.write([{ level: 1, text: "Broken", page: 99 }])

        assert_equal 0, count
        assert_nil @document.catalog[:Outlines]
        assert(messages.any? { it.include?("page 99") })
      end

      # :top のある項目は見出しの位置へ飛ぶ。左端と倍率は nil で、読者の横の位置と倍率を保つ
      def test_write_jumps_to_the_heading_when_top_is_given
        writer = OutlineWriter.new(@document, max_level: 3)
        writer.write([{ level: 1, text: "Chapter", page: 1 }, { level: 2, text: "Section", page: 2, top: 512.25 }])

        chapter = @document.catalog[:Outlines][:First]
        section = chapter[:First]
        assert_equal :Fit, chapter[:Dest][1], ":top の無い項目は今までどおりページ全体"
        assert_equal [@document.pages[1], :XYZ, nil, 512.25, nil], section[:Dest].to_a
        assert_equal @document.pages[1], section.destination_page
      end

      # ページの外を指す :top や数でない :top は使わず、ページへの飛び先に戻す（項目は落とさない）
      def test_write_falls_back_to_the_page_for_unusable_top
        writer = OutlineWriter.new(@document, max_level: 3)
        count = writer.write([
                               { level: 1, text: "Above", page: 1, top: 5000 },
                               { level: 1, text: "Text", page: 2, top: "12" },
                               { level: 1, text: "NaN", page: 3, top: Float::NAN }
                             ])

        assert_equal 3, count
        item = @document.catalog[:Outlines][:First]
        3.times do |i|
          assert_equal :Fit, item[:Dest][1], "#{item[:Title]} はページ全体"
          assert_equal @document.pages[i], item.destination_page
          item = item[:Next]
        end
      end

      # write が既存のアウトラインルートを置き換えることを検証する
      def test_write_replaces_existing_outline_root
        writer = OutlineWriter.new(@document, max_level: 3)
        writer.write([{ level: 1, text: "Old", page: 1 }])

        writer.write([{ level: 1, text: "New Root", page: 2 }])

        outline = @document.catalog[:Outlines]
        refute_nil outline

        first = outline[:First]
        assert_equal "New Root", first[:Title]
        assert_nil first[:Next]
        assert_equal @document.pages[1], first.destination_page
      end
    end
  end
end
