# frozen_string_literal: true

require "hexapdf"
require_relative "utilities"
require_relative "log_helper"
require_relative "outline_writer"

module VivlioStarter
  module Pdf
    # vivlio-starter 本体から呼び出される HexaPDF ベースのプロバイダ。
    #
    # 本体が委ねるのは 3 つだけである（`Pdf.provider` 経由）。
    #
    #   page_count             ページ数
    #   ensure_blank_page_pdf  空白ページ PDF の生成
    #   add_outline!           しおり（PDF アウトライン）の付与
    #
    # **隠しノンブルはここには無い。** かつては本体が委譲していたが、CombinePDF が
    # 保存時に named destinations を再構築しない問題があり、本体は Prawn ＋
    # `qpdf --overlay`（構造保存・等倍）の MIT 共通実装へ移した。プラグインの
    # 有無で成果物が変わらないほうがよい種類の処理なので、戻す予定は無い。
    #
    # このクラスの約束は 2 つ。**例外を外へ出さない**（本体のビルドパイプラインの
    # 途中から呼ばれるため、失敗は戻り値で伝える）。**失敗しても入力を壊さない**
    # （読み込んだのと同じパスへ書き戻すため、途中失敗は最も気付きにくい事故になる）。
    class EnhancedProvider
      # PDF のページ数を取得する
      def page_count(pdf_path)
        Utilities.page_count(pdf_path)
      end

      # 空白ページ PDF が存在しなければ生成する
      def ensure_blank_page_pdf(path, width_pt, height_pt)
        Utilities.ensure_blank_page_pdf(path, width_pt, height_pt)
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

      # OutlineWriter のスキップ通知をログに出力するコールバック
      def log_outline_skip(message)
        LogHelper.log_warn("[OutlineWriter] #{message}")
      end
    end
  end
end
