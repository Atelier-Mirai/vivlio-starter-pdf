# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "test_helper"

# exe/vivlio-starter-pdf を子プロセスとして起動して確かめる。
# 本体 vivlio-starter は AGPL のこの gem を require せず、この実行ファイルを呼ぶ。
# 窓口の `read` は 1.1.2 まで存在せず、`vs pdf:read` の Enhanced Mode は
# 「Unknown option 'read'」で一度も動いていなかった（本体のテストは呼び出しをスタブしていた）
class ExeTest < Minitest::Test
  EXE = File.expand_path("../exe/vivlio-starter-pdf", __dir__)
  LIB = File.expand_path("../lib", __dir__)
  SAMPLE_PDF = File.expand_path("fixtures/sample.pdf", __dir__)

  def test_should_print_reader_result_as_json_for_read
    stdout, stderr, status = run_exe("read", SAMPLE_PDF, "page_separator=false", 'ocr={"mode":"disable"}')

    assert(status.success?, stderr)
    result = JSON.parse(stdout)
    assert_equal(2, result["pages"])
    assert_includes(result["markdown"], "プログラミング")
    assert_equal(result["page_texts"].length, result["page_chunks"].length)
  end

  # 本体が渡す設定はすべて解釈できる（PdfReadCommand#enhanced_command と同じ並び）
  def test_should_accept_every_setting_that_vs_passes
    Dir.mktmpdir do |dir|
      stdout, stderr, status = run_exe(
        "read", SAMPLE_PDF,
        "page_separator=true",
        'text_area={"top":0.0,"bottom":0.0,"inner":0.0,"outer":0.0}',
        "line_merge_tolerance=2.0",
        "images_dir=#{dir}",
        "image_reference_dir=",
        'ocr={"mode":"disable","languages":["jpn"]}'
      )

      assert(status.success?, stderr)
      assert_equal(2, JSON.parse(stdout)["pages"])
    end
  end

  # 知らない設定は黙って捨てずに止める。本体と版がずれたことに気づけるように
  def test_should_fail_without_json_on_unknown_setting
    stdout, stderr, status = run_exe("read", SAMPLE_PDF, "colour=red")

    refute(status.success?)
    assert_empty(stdout)
    assert_includes(stderr, "知らない設定です: colour")
  end

  def test_should_fail_when_pdf_is_missing
    stdout, stderr, status = run_exe("read", "/nonexistent/book.pdf")

    refute(status.success?)
    assert_empty(stdout)
    assert_includes(stderr, "PDF が見つかりません")
  end

  def test_should_print_version
    stdout, _stderr, status = run_exe("--version")

    assert(status.success?)
    assert_equal("vivlio-starter-pdf #{VivlioStarter::Pdf::VERSION}\n", stdout)
  end

  private

  def run_exe(*args)
    Open3.capture3(RbConfig.ruby, "-I", LIB, EXE, *args)
  end
end
