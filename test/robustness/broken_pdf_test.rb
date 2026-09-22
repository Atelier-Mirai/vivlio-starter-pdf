# frozen_string_literal: true

# ================================================================
# Test: robustness/broken_pdf_test.rb
# ================================================================
# 検証内容:
#   壊れた PDF・空ファイル・存在しないパス・暗号化 PDF を渡したとき、
#   例外を投げずに「できなかった」を戻り値で返すこと。
#
#   ここは本体（vivlio-starter）のビルドパイプラインから呼ばれる。1 つの PDF 操作が
#   例外で飛ぶとビルド全体が落ちるため、**このプロバイダの公開 API は例外を外へ出さない**
#   のが約束である（page_count は nil、add_outline! は false）。
#
#   あわせて **入力ファイルを壊さないこと** を見る。add_outline! は
#   読み込んだのと同じパスへ書き戻すため、失敗時に元 PDF が切り詰められると
#   「ビルドは続いたが成果物が壊れた」という最悪の失敗になる。
# ================================================================

require_relative "../test_helper"
require_relative "robustness_helper"

class BrokenPdfTest < Minitest::Test
  include RobustnessHelper

  def test_page_count_returns_nil_for_broken_pdf
    in_workdir do
      make_broken_pdf("broken.pdf")

      assert_nil provider.page_count("broken.pdf")
    end
  end

  def test_page_count_returns_nil_for_empty_and_missing_files
    in_workdir do
      File.write("empty.pdf", "")

      assert_nil provider.page_count("empty.pdf")
      assert_nil provider.page_count("nosuch.pdf")
    end
  end

  def test_add_outline_returns_false_instead_of_raising
    in_workdir do
      make_broken_pdf("broken.pdf")
      items = [{ level: 1, text: "章", page: 1 }]

      silently do
        refute provider.add_outline!("broken.pdf", items, max_level: 3)
        refute provider.add_outline!("nosuch.pdf", items, max_level: 3)
      end
    end
  end

  # 失敗しても入力を書き換えない。ここが崩れると「壊れた成果物が静かに残る」
  def test_should_not_damage_the_input_when_it_fails
    in_workdir do
      make_broken_pdf("broken.pdf")
      before = File.binread("broken.pdf")

      silently do
        provider.add_outline!("broken.pdf", [{ level: 1, text: "章", page: 1 }], max_level: 3)
      end

      assert_equal before, File.binread("broken.pdf"), "失敗時に入力を書き換えてはならない"
    end
  end

  # 暗号化 PDF は開けない。ここも例外ではなく戻り値で伝える
  def test_encrypted_pdf_is_reported_as_failure
    in_workdir do
      make_encrypted_pdf("enc.pdf")
      before = File.binread("enc.pdf")

      silently do
        assert_nil provider.page_count("enc.pdf")
        refute provider.add_outline!("enc.pdf", [{ level: 1, text: "章", page: 1 }], max_level: 3)
      end

      assert_equal before, File.binread("enc.pdf"), "開けなかった PDF を書き換えてはならない"
    end
  end

  # 書き込めない PDF でも、元ファイルは無傷のまま false を返す
  def test_readonly_pdf_is_left_untouched
    in_workdir do
      make_pdf("ro.pdf")
      before = File.binread("ro.pdf")
      skip_unless_permission_enforced("ro.pdf")

      silently { refute provider.add_outline!("ro.pdf", [{ level: 1, text: "章", page: 1 }], max_level: 3) }

      assert_equal before, File.binread("ro.pdf")
    ensure
      File.chmod(0o644, "ro.pdf") if File.exist?("ro.pdf")
    end
  end
end
