# frozen_string_literal: true

# ================================================================
# Test: robustness/outline_entry_test.rb
# ================================================================
# 検証内容:
#   壊れたアウトライン項目が混ざったとき、**その 1 件だけを飛ばして残りを書く**こと。
#
#   これは「落ちないこと」より強い要求である。アウトラインは本のしおりなので、
#   見出しが 1 つ壊れているだけで全滅すると、読者は目次から本文へ飛べなくなる。
#   しかも add_outline! は false を返すだけで PDF 自体は出来上がるため、
#   **成果物を開くまで気付けない**種類の失敗になる。
#
#   飛ばした項目は必ず on_skip で理由つきに報告する（著者が原稿を直せるように）。
# ================================================================

require_relative "../test_helper"
require_relative "robustness_helper"

class OutlineEntryTest < Minitest::Test
  include RobustnessHelper

  GOOD = { level: 1, text: "正しい見出し", page: 1 }.freeze
  BROKEN_TITLE = "壊れた\xFF".dup.force_encoding(Encoding::UTF_8)

  # 不正な UTF-8 のタイトルは String#strip が Encoding::CompatibilityError を投げる。
  # 素通しにすると add_outline! の rescue まで飛び、しおりが丸ごと消える
  def test_should_skip_invalid_utf8_title_and_keep_the_rest
    inserted, skips = write_outline([GOOD, { level: 1, text: BROKEN_TITLE, page: 1 }])

    assert_equal 1, inserted, "壊れた 1 件のために全滅させてはならない"
    assert(skips.any? { it.include?("not valid UTF-8") }, "飛ばした理由を報告すること")
  end

  def test_should_skip_out_of_range_page_and_keep_the_rest
    inserted, skips = write_outline([GOOD, { level: 1, text: "範囲外", page: 999 }])

    assert_equal 1, inserted
    assert(skips.any? { it.include?("outside") })
  end

  def test_should_skip_empty_title_and_keep_the_rest
    inserted, skips = write_outline([GOOD, { level: 1, text: "", page: 1 }])

    assert_equal 1, inserted
    assert(skips.any? { it.include?("missing title") })
  end

  def test_should_skip_invalid_page_and_keep_the_rest
    inserted, = write_outline([GOOD, { level: 1, text: "ゼロ", page: 0 },
                               { level: 1, text: "負", page: -1 }])

    assert_equal 1, inserted
  end

  # nil や想定外の型が混ざっても、走査自体は止まらない
  def test_should_survive_nil_and_unexpected_entry_types
    inserted, = write_outline([nil, GOOD, "文字列", 42])

    assert_equal 1, inserted
  end

  # max_level を超える深さは切り上げて採用する（捨てない）
  def test_should_clamp_level_deeper_than_max
    inserted, = write_outline([GOOD, { level: 9, text: "深い見出し", page: 2 }], max_level: 2)

    assert_equal 2, inserted, "深すぎる項目は切り上げて残すこと"
  end

  # 有効な項目が 1 つも無ければ 0。空のしおりツリーを残さない
  def test_should_return_zero_and_leave_no_outline_when_all_entries_are_invalid
    in_workdir do
      make_pdf("book.pdf")
      doc = HexaPDF::Document.open("book.pdf")
      writer = VivlioStarter::Pdf::OutlineWriter.new(doc, max_level: 3, on_skip: ->(_m) {})

      assert_equal 0, writer.write([{ level: 1, text: "", page: 1 }])
      refute doc.catalog.key?(:Outlines), "空のアウトラインツリーを残してはならない"
    end
  end

  private

  # 項目を書き込み、[挿入件数, スキップ理由の配列] を返す
  def write_outline(items, max_level: 3)
    in_workdir do
      make_pdf("book.pdf")
      doc = HexaPDF::Document.open("book.pdf")
      skips = []
      writer = VivlioStarter::Pdf::OutlineWriter.new(doc, max_level:, on_skip: ->(m) { skips << m })
      return [writer.write(items), skips]
    end
  end
end
