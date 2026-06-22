# frozen_string_literal: true

require "hexapdf"
require_relative "utilities"
require_relative "log_helper"
require_relative "outline_writer"

module VivlioStarter
  module Pdf
    # vivlio-starter 本体から呼び出される HexaPDF ベースのプロバイダ
    #
    # 隠しノンブル書き込み・PDF アウトライン付与など、
    # Enhanced Mode 固有の PDF 操作を提供する。
    class EnhancedProvider
      # 隠しノンブルに使う埋め込み可能フォント（書籍プロジェクト同梱の TTF）。
      # HexaPDF 組込の "Helvetica" は標準 14 フォントで PDF に埋め込まれず、印刷所入稿で
      # 「非埋め込みフォント」事故になる（FT-02）。プロジェクト直下に同梱の
      # HackGen35ConsoleNF があれば登録してサブセット埋め込みする（数字のみで極小）。
      NOMBRE_FONT_RELATIVE = File.join("stylesheets", "fonts", "hackgen35", "HackGen35ConsoleNF-Regular.ttf")
      # document.config の font.map へ登録する内部フォント名
      NOMBRE_FONT_NAME = "VivlioNombre"
      # 同梱フォントが見つからない場合のフォールバック（非埋め込み標準フォント）
      FALLBACK_FONT_NAME = "Helvetica"
      # 隠しノンブルのフォントサイズ（pt）
      FONT_SIZE_PT = 6

      # PDF のページ数を取得する
      def page_count(pdf_path)
        Utilities.page_count(pdf_path)
      end

      # 空白ページ PDF が存在しなければ生成する
      def ensure_blank_page_pdf(path, width_pt, height_pt)
        Utilities.ensure_blank_page_pdf(path, width_pt, height_pt)
      end

      # PDF の各ページに隠しノンブル（ページ番号）を書き込む
      # 奇数ページは左端、偶数ページは右端に 90° 回転して配置する
      # @param pdf_path [String] 対象 PDF のパス
      # @param bleed_pt [Float] 塗り足し幅（pt）
      # @return [Boolean] 成功なら true
      def stamp_nombre!(pdf_path, bleed_pt:)
        return false unless File.exist?(pdf_path)

        document = HexaPDF::Document.open(pdf_path)
        total = document.pages.count
        return false if total.zero?

        LogHelper.log_action("[NombreStamper] 隠しノンブルを書き込みます（#{total} ページ）[Enhanced Mode]…")

        font = register_nombre_font(document)

        document.pages.each_with_index do |page, idx|
          stamp_page(page, idx + 1, bleed_pt: bleed_pt.to_f, font:)
        end

        document.write(pdf_path, optimize: true)
        LogHelper.log_success("[NombreStamper] 隠しノンブル書き込み完了（#{total} ページ）")
        true
      rescue StandardError => e
        LogHelper.log_error("[NombreStamper] 隠しノンブル書き込みに失敗: #{e.message}")
        false
      end

      # PDF にアウトライン（しおり）を付与する
      # OutlineWriter を使い、階層構造を HexaPDF のアウトラインツリーに変換する
      # @param pdf_path [String] 対象 PDF のパス
      # @param items [Array<Hash>] アウトライン項目（:level, :text, :page）
      # @param max_level [Integer] アウトラインの最大階層深度
      # @return [Boolean] 成功なら true
      def add_outline!(pdf_path, items, max_level:)
        return false unless File.exist?(pdf_path)

        document = HexaPDF::Document.open(pdf_path)
        writer = OutlineWriter.new(document, max_level:, on_skip: method(:log_outline_skip))
        inserted = writer.write(items)
        if inserted.zero?
          LogHelper.log_warn("[OutlineWriter] 有効なアウトライン項目が存在しないためスキップしました")
          return false
        end

        document.write(pdf_path, optimize: true)
        LogHelper.log_success("[OutlineWriter] PDF にアウトラインを #{inserted} 件追加しました")
        true
      rescue StandardError => e
        LogHelper.log_error("[OutlineWriter] PDF アウトライン付与に失敗: #{e.message}")
        false
      end

      private

      # 隠しノンブル用フォントを document へ登録し、canvas に渡すフォント名を返す。
      # 同梱 TTF（NOMBRE_FONT_RELATIVE）があればサブセット埋め込みされる名前を、
      # 見つからなければ非埋め込みの Helvetica（FALLBACK_FONT_NAME）を返す。
      # @param document [HexaPDF::Document]
      # @return [String] canvas.font に渡すフォント名
      def register_nombre_font(document)
        return FALLBACK_FONT_NAME unless File.exist?(NOMBRE_FONT_RELATIVE)

        (document.config["font.map"] ||= {})[NOMBRE_FONT_NAME] = { none: NOMBRE_FONT_RELATIVE }
        NOMBRE_FONT_NAME
      end

      # 1 ページに隠しノンブルを描画する
      # 奇数ページは左端 90°、偶数ページは右端 -90° に回転配置する
      def stamp_page(page, page_number, bleed_pt:, font:)
        canvas = page.canvas(type: :overlay)
        box = page.box(:media)

        canvas.font(font, size: FONT_SIZE_PT)
        canvas.fill_color(0)

        x_offset = bleed_pt / 2.0
        y_center = box.height / 2.0

        if page_number.odd?
          draw_rotated_text(canvas, page_number.to_s, x: x_offset, y: y_center, angle: 90)
        else
          draw_rotated_text(canvas, page_number.to_s, x: box.width - x_offset, y: y_center, angle: -90)
        end
      end

      # キャンバス上の指定座標にテキストを回転描画する
      def draw_rotated_text(canvas, text, x:, y:, angle:)
        canvas
          .save_graphics_state
          .translate(x, y)
          .rotate(angle)
          .text(text, at: [0, 0])
          .restore_graphics_state
      end

      # OutlineWriter のスキップ通知をログに出力するコールバック
      def log_outline_skip(message)
        LogHelper.log_warn("[OutlineWriter] #{message}")
      end
    end
  end
end
