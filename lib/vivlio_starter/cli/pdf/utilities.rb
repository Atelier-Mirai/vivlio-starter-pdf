# frozen_string_literal: true

require "fileutils"
require "hexapdf"

module VivlioStarter
  module Pdf
    # HexaPDF を使った PDF 共通ユーティリティ
    module Utilities
      module_function

      # PDF のページ数を取得する
      # @param file [String]
      # @return [Integer, nil]
      def page_count(file)
        return nil unless File.exist?(file)

        if system("which pdfinfo >/dev/null 2>&1")
          info = `pdfinfo "#{file}" 2>/dev/null`
          pages = info[/^Pages:\s+(\d+)/i, 1]
          return pages.to_i if pages
        end

        doc = HexaPDF::Document.open(file)
        doc.pages.count
      rescue StandardError
        nil
      end

      # 空白ページ PDF を生成する
      # @param path [String]
      # @param width_pt [Float]
      # @param height_pt [Float]
      def ensure_blank_page_pdf(path, width_pt, height_pt)
        return path if File.exist?(path)

        doc = HexaPDF::Document.new
        doc.pages.add([0, 0, width_pt, height_pt])
        write_document(doc, path)
        path
      end

      # HexaPDF の文書を path へ書き出す。
      #
      # 一時ファイルに書いてから置き換える。HexaPDF は path を空にしてから書き始めるので、
      # 途中で失敗すると、途中までの壊れた PDF が path に残るため。
      #
      # 書き込みは別のスレッドで行う。Ruby 3.4・4.0 に同梱の zlib 3.2.3 は、主スレッドで
      # Zlib::Deflate を断片ごとに使っている間にシグナルを受けると Zlib::BufError（buffer error）で
      # 失敗する（zlib 3.2.4 で修正）。vs build は EPUB の枝で子プロセスを走らせるので、その終了の
      # SIGCHLD が、主スレッドで走る PDF の枝の書き込みと重なると起きる。シグナルを受けるのは
      # 主スレッドだけなので、別のスレッドで書けば失敗しない。
      # @param document [HexaPDF::Document]
      # @param path [String]
      def write_document(document, path)
        # 置き換え（rename）は書き込めないファイルも置き換えるので、直接書くときと同じく先に断る
        raise Errno::EACCES, path if File.exist?(path) && !File.writable?(path)

        temp = "#{path}.writing-#{Process.pid}"
        writer = Thread.new do
          Thread.current.report_on_exception = false # 例外は join で呼び出し側へ渡す
          document.write(temp, optimize: true)
        end
        writer.join
        File.rename(temp, path)
      ensure
        FileUtils.rm_f(temp)
      end
    end
  end
end
