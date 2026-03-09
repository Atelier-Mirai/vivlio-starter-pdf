# frozen_string_literal: true

require "hexapdf"

module Vivlio
  module Starter
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
          doc.write(path, optimize: true)
          path
        end
      end
    end
  end
end
