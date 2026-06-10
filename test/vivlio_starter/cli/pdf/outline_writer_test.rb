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
