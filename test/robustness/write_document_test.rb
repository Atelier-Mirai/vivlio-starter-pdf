# frozen_string_literal: true

# ================================================================
# 検証内容:
#   Utilities.write_document が、書き込みの途中で失敗しても書き出し先を壊さないこと、
#   子プロセスの終了（SIGCHLD）が続く中でも書き出せること。
#
#   HexaPDF は書き出し先を空にしてから書き始めるので、そのまま書くと、途中で失敗したとき
#   途中までの PDF が残る。vs build では、EPUB の枝の子プロセスが終わるたびに主スレッドへ
#   シグナルが届き、zlib 3.2.3 の圧縮が Zlib::BufError で失敗して、閲覧用 PDF が壊れていた。
# ================================================================

require_relative "../test_helper"
require_relative "robustness_helper"
require "zlib"

class WriteDocumentTest < Minitest::Test
  include RobustnessHelper

  # 途中まで書いてから失敗する文書（HexaPDF の書き込みの失敗を再現する）
  class FailingDocument
    def write(path, **)
      File.write(path, "%PDF-1.7\npartial")
      raise Zlib::BufError, "buffer error"
    end
  end

  def test_should_keep_the_destination_when_writing_fails
    in_workdir do
      make_pdf("out.pdf")
      before = File.binread("out.pdf")

      assert_raises(Zlib::BufError) { VivlioStarter::Pdf::Utilities.write_document(FailingDocument.new, "out.pdf") }

      assert_equal before, File.binread("out.pdf"), "失敗しても書き出し先は元のままのはずです"
      assert_equal ["out.pdf"], Dir.children("."), "一時ファイルが残らないはずです"
    end
  end

  # オブジェクトが多いと、オブジェクトストリームを断片ごとに圧縮する（この経路で失敗していた）
  def test_should_write_while_child_processes_keep_exiting
    in_workdir do
      stop = false
      spawner = Thread.new { system("true") until stop }

      3.times do
        VivlioStarter::Pdf::Utilities.write_document(document_with_many_objects, "out.pdf")

        assert_equal 1, HexaPDF::Document.open("out.pdf").pages.count
      end
    ensure
      stop = true
      spawner&.join
    end
  end

  private

  def document_with_many_objects
    doc = HexaPDF::Document.new
    doc.pages.add(a4_box)
    doc.pages.root[:Refs] = Array.new(20_000) { doc.add({ Type: :Test, Name: "object #{it}" * 3 }) }
    doc
  end
end
