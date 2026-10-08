# frozen_string_literal: true

require "hexapdf"
require "fileutils"
require "open3"
require "tmpdir"
require "yaml"

module VivlioStarter
  module Pdf
    # HexaPDF ベースの高精度 PDF リーダー
    #
    # テキスト座標解析・画像抽出・OCR 連携・イラスト領域自動検出を統合し、
    # PDF → Markdown 変換パイプラインを提供する。
    class Reader

      # --- Data 構造体 ---
      # テキスト断片（座標付き）
      Fragment = Data.define(:x, :right, :y, :text)
      # 行（Y 座標 + テキスト）
      Line = Data.define(:y, :text)
      # PDF 内画像の出現位置（座標・サイズ・XObject 参照）
      ImageOccurrence = Data.define(:x, :top, :bottom, :center_y, :left, :right, :width, :height, :object)
      # ページのテキスト・行・画像出現をまとめたコンテンツ。words は OCR で読んだ語（OCR したページだけ）
      PageContent = Data.define(:text, :lines, :image_occurrences, :words) do
        def initialize(text:, lines:, image_occurrences:, words: []) = super
      end
      # OCR で読んだ 1 語。座標は PDF のページ（左下が原点・pt）。y はベースライン、size は行の高さ。
      # 本体（vivlio-starter）は語を 1 字ずつに割り、紙面の推定（経路 B）で見出しや段落を戻す
      OcrWord = Data.define(:text, :x, :y, :width, :size, :conf)
      # 抽出済み画像アセット（ページ番号・ファイル名・座標情報を保持）
      ImageAsset = Data.define(:page, :index, :filename, :output_path, :reference_path, :x, :top, :bottom, :center_y, :left, :right, :width, :height)
      # OCR で検出したイラスト領域（ピクセル座標）
      IllustrationRegion = Data.define(:left, :top, :width, :height)
      # OCR 実行パラメータ
      OcrSettings = Data.define(:mode, :languages, :dpi, :psm, :inline_image_text)
      # OCR ページ画像からの切り出し領域
      RenderedPageCrop = Data.define(:source_image_path, :left, :top, :width, :height)
      # ページ解析の最終結果（コンテンツ + OCR 適用有無 + 一時ディレクトリ）
      ResolvedPage = Data.define(:content, :ocr_applied, :ocr_temp_dir)
      # OCR 実行結果（テキスト・行・ブロック・画像情報を保持）
      OcrResult = Data.define(:text, :lines, :blocks, :source_image_path, :image_width, :image_height, :temp_dir, :words) do
        def initialize(text:, lines:, blocks:, source_image_path:, image_width:, image_height:, temp_dir:, words: []) = super
      end
      # Tesseract の TSV の 1 行。fields は書き戻すための元の列で、index は列名から列の位置を引く
      TsvRow = Data.define(:fields, :index) do
        def [](name) = fields[index.fetch(name)]
        def level = self["level"]
        def text = self["text"].to_s.strip
        def left = self["left"].to_f
        def top = self["top"].to_f
        def width = self["width"].to_f
        def height = self["height"].to_f
        def right = left + width
        def bottom = top + height
        def center_x = left + (width / 2)
        def center_y = top + (height / 2)
        def conf = self["conf"].to_f
        def line_key = LINE_KEY.map { self[it] }
        # 英字の語か。空の語は、前後の英字の語の連なりを切らないよう英字の側に入れる
        def latin? = text.empty? || text.match?(LATIN_WORD)

        def with_fields(changes)
          changed = fields.dup
          changes.each { |name, value| changed[index.fetch(name)] = value.to_s }
          with(fields: changed)
        end
      end

      # --- 二度読み（§2.2） ---
      # 囲みの地の割合がこれ以上のページだけ二度読みする。97 章のスキャンでは 23 ページ中 4 ページが
      # 当たり、全ページ二度読みしたときの効果の約 6 割が得られる
      TWO_PASS_TINT = 0.08
      # 読みを選ぶ基準にする確信度
      CONFIDENT_WORD = 80

      # --- 読み飛ばした範囲の読み直し（pdf-read-ocr-improvement-notes.md §4.11） ---
      # 読み直す範囲の大きさの下限（ページの幅を 595 とした単位。A4 なら pt）
      REREAD_MIN_WIDTH = 60
      REREAD_MIN_HEIGHT = 18
      # すでに読めた語がこれを超えて覆う範囲は読み直さない。地の色の付いた囲みの中の文やコードは、別の
      # ブロックで読めていて 15〜30% を覆う。読み直して置き換えると、良くなる行と悪くなる行が混じった
      # （最高・600dpi で F 値 91.4% → 90.7%）。表や色の帯の見出しは 0〜9%
      REREAD_MAX_COVERAGE = 0.1
      # 切り出すときの余白（画像の幅に対する割合。300dpi の A4 で 24px）。読み直しは切り出し方に敏感で、
      # 97 章では 20〜30px の間でも F 値が 0.2 ポイント上下した
      REREAD_PADDING = 24 / 2480.0

      # --- 傾きの補正（pdf-read-ocr-improvement-notes.md §4.14） ---
      # 測る傾きの範囲と刻み（度）。スキャナに置いた紙は少し傾く（97 章のスキャンで、表と裏が交互に ±0.5〜1.1°）
      DESKEW_RANGE = 3.0
      DESKEW_STEP = 0.05
      # これより小さい傾きは直さない
      DESKEW_MIN_ANGLE = 0.1
      # 傾きを測る画像の幅（px）。縮めて測っても 0.05° の刻みで決まる
      DESKEW_WORK_WIDTH = 620

      # --- 斜体の行の読み直し（pdf-read-ocr-improvement-notes.md §4.15） ---
      # 読み直す行の確信度の平均の上限。斜体の行は 0〜40 の意味の無い英字になるか、60〜70 の崩れた和文になる
      SLANT_MAX_CONFIDENCE = 75
      # 読み直す行の字数の下限（図の中の短い札を除く）
      SLANT_MIN_CHARACTERS = 8
      # 戻す傾き（度）。Chrome は斜体の無い和文の書体を傾けて描く。97 章では 10〜14° のどれでも読め、12° が最もよかった
      SLANT_ANGLE = 12

      # --- 英語での読み直し（pdf-read-ocr-improvement-notes.md §4.6） ---
      # 英字の語がこれ以上あるページだけ、英語の学習データでも読む。97 章のスキャンでは 24 ページ中
      # 6〜8 ページ（コードのあるページ）が当たり、10〜30 のどこに置いても成績は変わらなかった
      ENGLISH_PAGE_WORDS = 20
      # 英語の読みを採るのに要る確信度。日本語＋英語の読みと食い違う語の平均で見る。
      # 「11月」の「11」を英語の読みは「lL」（確信度 35）と読む
      ENGLISH_MIN_CONFIDENCE = 60
      # TSV で 1 行を表す列（ブロック・段落・行の番号）
      LINE_KEY = %w[page_num block_num par_num line_num].freeze
      # 英字の語（ASCII とラテン文字、英文の引用符とダッシュ）
      LATIN_WORD = /\A(?:\p{ASCII}|\p{Latin}|[‘’“”–—])+\z/

      # --- 図版の検出（pdf-read-ocr-improvement-notes.md §4.2・§4.4） ---
      # ページを縮めて調べるときの幅（px）。A4 で約 37dpi、1 画素が約 2pt になる
      FIGURE_WORK_WIDTH = 310
      # 紙の明るさよりこれだけ暗い画素と、彩度（LCh の C）がこれを超える画素を、図の候補にする。
      # 彩度は 10〜30 のどこでも 97 章の成績は同じで、淡い黄色の本の表紙が入るよう低めにした
      FIGURE_DARKNESS = 50
      FIGURE_CHROMA = 15
      # 確信度がこれ以上の語と、語の確信度の平均がこれ以上の行は、文字として図の候補から消す
      FIGURE_TEXT_CONFIDENCE = 60
      # 図とみなす大きさの下限。辺はページの幅に、面積はページの面積に対する割合（A4 で 40pt・6,000pt²）。
      # 見出しの帯の色の札（A-2）や、MEMO の札、会話文の話者のアイコン（32pt 角）は外れる
      FIGURE_MIN_SIDE = 40 / 595.0
      FIGURE_MIN_AREA = 6000 / (595.0 * 842.0)
      # 図の枠を削るときに残す、図の画素の埋まった列・行の割合
      FIGURE_DENSE = 0.3

      # --- OCR に回す画像 ---
      # 埋め込みのスキャン画像がこの幅（px）に届かなければ、vips で拡大してから読む。
      # A5 の本を約 230dpi、A4 を約 165dpi で取り込んだ幅にあたる。実測では幅 875px で拡大が効き
      # （確信度 88.8 → 92.2）、幅 1,720px では効かなかった（92.2 → 91.9）
      MIN_OCR_IMAGE_WIDTH = 1600
      # これを超える解像度のスキャンは、TARGET_OCR_DPI へ縮めてから読む
      MAX_OCR_DPI = 400
      TARGET_OCR_DPI = 300.0

      # HexaPDF のコンテンツストリームを走査し、版面内のテキスト断片と画像出現を収集する
      class PageTextCollector < HexaPDF::Content::Processor
        attr_reader :fragments, :image_occurrences

        # @param resources [HexaPDF::Type::Resources] ページリソース
        # @param bounds [Hash, nil] テキスト抽出領域の座標境界
        # @param line_merge_tolerance [Float] 同一行とみなす Y 座標差の閾値（pt）
        def initialize(resources, bounds:, line_merge_tolerance:)
          super(resources)
          @bounds = bounds
          @line_merge_tolerance = line_merge_tolerance.to_f
          @fragments = []
          @image_occurrences = []
        end

        # PDF オペレータ Tj: テキスト表示
        def show_text(data)
          collect_text_box(decode_text_with_positioning(data))
        end

        # PDF オペレータ TJ: 位置調整付きテキスト表示
        def show_text_with_positioning(data)
          collect_text_box(decode_text_with_positioning(data))
        end

        # 収集した断片を Y 座標でグループ化し、Line 配列を返す
        def lines
          build_lines
        end

        # 全行を改行で結合したテキストを返す
        def text
          lines.map(&:text).join("\n")
        end

        # PDF オペレータ Do: XObject 描画。画像なら出現位置を記録する
        def paint_xobject(name)
          xobject = resources.xobject(name)
          collect_image_occurrence(xobject) if image_object?(xobject)
          super
        rescue StandardError
          nil
        end

        private

        # 断片を Y 降順・X 昇順でソートし、同一 Y の断片を結合して Line 配列を構築する
        def build_lines
          sorted = fragments.sort_by { [-it.y, it.x] }
          current_y = nil
          buffer = +""
          lines = []
          previous_fragment = nil

          sorted.each do |fragment|
            if current_y && (current_y - fragment.y).abs <= @line_merge_tolerance
              buffer << separator_between(previous_fragment, fragment)
              buffer << fragment.text
              previous_fragment = fragment
              next
            end

            lines << Line.new(y: current_y, text: normalize_line(buffer)) unless buffer.empty?
            # 複製して受ける。`+fragment.text` は凍結されていない文字列をそのまま返すので、
            # 下の `<<` が断片の文字列自体を書き換え、2 回目の呼び出し（text と lines）で
            # 各行が「全文＋先頭の断片を欠いた全文」に膨らんでいた
            buffer = fragment.text.dup
            current_y = fragment.y
            previous_fragment = fragment
          end

          lines << Line.new(y: current_y, text: normalize_line(buffer)) unless buffer.empty?
          lines.reject { it.text.empty? }
        end

        # テキストボックスが版面内なら Fragment として記録する
        def collect_text_box(box)
          return unless within_bounds?(box)

          text = normalize_fragment_text(box.string)
          return if text.empty?

          x, y = box.lower_left
          right, = box.lower_right
          @fragments << Fragment.new(x:, right:, y:, text:)
        end

        # XObject の CTM からページ座標を算出し、ImageOccurrence として記録する
        def collect_image_occurrence(xobject)
          llx, lly = graphics_state.ctm.evaluate(0, 0)
          lrx, lry = graphics_state.ctm.evaluate(1, 0)
          ulx, uly = graphics_state.ctm.evaluate(0, 1)
          urx, ury = graphics_state.ctm.evaluate(1, 1)

          xs = [llx, lrx, ulx, urx]
          ys = [lly, lry, uly, ury]
          return unless within_points?(xs, ys)

          top = ys.max
          bottom = ys.min
          left = xs.min
          right = xs.max
          @image_occurrences << ImageOccurrence.new(
            x: xs.sum / xs.length,
            top:,
            bottom:,
            center_y: (top + bottom) / 2.0,
            left:,
            right:,
            width: right - left,
            height: top - bottom,
            object: xobject
          )
        end

        # テキスト断片の空白を正規化する
        def normalize_fragment_text(text)
          text.to_s.gsub(/[ \t\u00A0]+/, " ").strip
        end

        # 隣接する断片間の区切り文字を決定する（空白 / 改行 / なし）
        # 断片間の X 座標ギャップから判定する
        def separator_between(previous_fragment, fragment)
          return "" unless previous_fragment

          gap = fragment.x - previous_fragment.right
          return "" if gap <= 6
          return "\n" if gap >= 24 && strong_break_boundary?(previous_fragment.text, fragment.text)

          " "
        end

        # 前後のテキストが強い改行境界（文末句読点・章見出し等）を持つか判定する
        def strong_break_boundary?(previous_text, current_text)
          previous_text.match?(/[。．.!！?？：:]\z/) || current_text.match?(/\A(?:[♣◆■●]+\s*)?(?:第[一二三四五六七八九十百千0-9]+章|\d+(?:[.\-]\d+)*|[0-9]+[.)])/) || current_text.match?(/\A(?:主題|文法|道具)[:：]/)
        end

        # 行テキストの正規化: 空白圧縮・CJK 文字間の不要スペース除去
        def normalize_line(line)
          line
            .to_s
            .gsub(/[ \t\u00A0]+/, " ")
            # ヵヶ は ァ-ヶ の範囲に含まれるので並べない（重複範囲の警告が出る）
            .gsub(/(?<=[一-龯ぁ-ゖァ-ヶー々〆]) (?=[一-龯ぁ-ゖァ-ヶー々〆])/, "")
            .gsub(/(?<=[一-龯ぁ-ゖァ-ヶー々〆]) (?=[、。，．：；！？）】』」])/, "")
            .gsub(/(?<=[（【『「]) (?=[一-龯ぁ-ゖァ-ヶー々〆A-Za-z0-9])/, "")
            .strip
        end

        # テキストボックスが版面境界内に収まっているか
        def within_bounds?(box)
          return true unless @bounds

          llx, lly = box.lower_left
          urx, ury = box.upper_right

          !(urx < @bounds[:left] || llx > @bounds[:right] || ury < @bounds[:bottom] || lly > @bounds[:top])
        end

        # 座標群が版面境界内に収まっているか
        def within_points?(xs, ys)
          return true unless @bounds

          !(xs.max < @bounds[:left] || xs.min > @bounds[:right] || ys.max < @bounds[:bottom] || ys.min > @bounds[:top])
        end

        # XObject が画像オブジェクトかどうかを判定する
        def image_object?(object)
          object.is_a?(HexaPDF::Type::Image) || object[:Subtype] == :Image
        rescue StandardError
          false
        end
      end

      # @param pdf_path [String] 入力 PDF のパス
      # @param page_separator [Boolean] ページ間に "---" を挿入するか
      # @param text_area [Hash, nil] テキスト抽出領域のマージン（pt 単位）
      # @param line_merge_tolerance [Float] 同一行とみなす Y 座標差の閾値（pt）
      # @param images_dir [String, nil] 画像の保存先ディレクトリ
      # @param image_reference_dir [String, nil] Markdown 内の画像参照パスの基底
      # @param ocr [Hash, nil] OCR 設定
      # @param progress [#call, nil] OCR するページごとに (ページ番号, ページ数) で呼ぶ。OCR は 1 ページ数秒かかる
      def initialize(pdf_path, page_separator: true, text_area: nil, line_merge_tolerance: 2.0, images_dir: nil, image_reference_dir: nil, ocr: nil,
                     progress: nil)
        @pdf_path = pdf_path
        @page_separator = page_separator != false
        @text_area = normalize_text_area(text_area)
        @line_merge_tolerance = line_merge_tolerance.to_f
        @images_dir = images_dir&.to_s&.strip
        @image_reference_dir = image_reference_dir&.to_s&.strip
        @ocr = normalize_ocr(ocr)
        @progress = progress
      end

      # PDF を解析し、Markdown テキスト・画像アセット・メタデータを含む Hash を返す
      # @return [Hash] :markdown, :page_texts, :page_chunks, :pages, :images, :page_words, :page_sizes
      #   page_words は、OCR したページなら語の一覧（OcrWord#to_h）、しなかったページなら nil
      def execute
        document = HexaPDF::Document.open(pdf_path)
        page_texts = []
        page_chunks = []
        images = []
        page_words = []
        page_sizes = []

        @page_count = document.pages.count
        document.pages.each_with_index do |page, index|
          resolution = nil

          begin
            content = extract_page_content(page, index)
            resolution = resolve_page_content(page, index, content)
            page_images = extract_page_images(page, resolution.content.image_occurrences, index,
                                              suppress_full_page_scans: resolution.ocr_applied)
            page_lines, image_captions = apply_inline_image_text_policy(resolution.content.lines, page_images)
            page_text = build_page_text(page_lines, resolution.content.text, image_captions)
            page_texts << page_text
            page_chunks << build_page_chunk(page_lines, page_images, page_text, image_captions:)
            images.concat(page_images)
            page_words << (resolution.ocr_applied ? resolution.content.words.map(&:to_h) : nil)
            page_sizes << page_size(page)
          ensure
            cleanup_ocr_temp_dir(resolution&.ocr_temp_dir)
          end
        end

        {
          markdown: build_markdown(page_chunks),
          page_texts:,
          page_chunks:,
          pages: document.pages.count,
          images: images.map(&:to_h),
          page_words:,
          page_sizes:
        }
      end

      private

      attr_reader :pdf_path

      # OCR 用の一時ディレクトリを安全に削除する
      def cleanup_ocr_temp_dir(path)
        return if path.to_s.empty?

        FileUtils.rm_rf(path)
      end

      # HexaPDF のコンテンツストリームを走査し、ページのテキスト・行・画像出現を抽出する
      def extract_page_content(page, index)
        collector = PageTextCollector.new(
          page.resources,
          bounds: text_area_bounds(page, index),
          line_merge_tolerance:
        )
        page.process_contents(collector)
        PageContent.new(
          text: sanitize(collector.text),
          lines: collector.lines,
          image_occurrences: collector.image_occurrences
        )
      rescue StandardError
        PageContent.new(text: "", lines: [], image_occurrences: [])
      end

      # ページ内容を確定する。OCR が必要なら実行し、不要ならそのまま返す
      def resolve_page_content(page, index, content)
        return ResolvedPage.new(content:, ocr_applied: false, ocr_temp_dir: nil) unless ocr_required_for_page?(page, content)

        @progress&.call(index + 1, @page_count)
        resolved_content, ocr_temp_dir = extract_page_ocr_content(page, index, content.image_occurrences)
        ResolvedPage.new(content: resolved_content, ocr_applied: true, ocr_temp_dir:)
      rescue StandardError
        raise if ocr_mode == :always

        ResolvedPage.new(content:, ocr_applied: false, ocr_temp_dir: nil)
      end

      # OCR を実行してページコンテンツを再構築する
      # テキスト後処理（空白圧縮・括弧正規化・誤認識の補正）を適用する
      def extract_page_ocr_content(page, index, image_occurrences)
        result = ocr_page_result(page, index, image_occurrences)
        lines = normalize_ocr_lines(result.lines)
        text = if lines.empty?
                 postprocess_ocr_text(result.text)
               else
                 sanitize(lines.map(&:text).join("\n"))
               end

        resolved_image_occurrences = ocr_image_occurrences(page, image_occurrences, result)
        page_content = if text.empty?
                         PageContent.new(text: "", lines: [], image_occurrences: resolved_image_occurrences, words: result.words)
                       else
                         PageContent.new(text:, lines:, image_occurrences: resolved_image_occurrences, words: result.words)
                       end

        [page_content, result.temp_dir]
      rescue StandardError
        cleanup_ocr_temp_dir(result&.temp_dir)
        raise
      end

      # このページで OCR が必要かどうかを判定する
      # mode が auto の場合はテキスト品質やスキャン画像の有無で判断する
      def ocr_required_for_page?(page, content)
        return false if ocr_mode == :never
        return ocr_dependencies_ready? if ocr_mode == :always

        return false unless ocr_dependencies_ready?
        return true if content.text.to_s.strip.empty?
        return true if poor_text_extraction?(content.text)

        scanned_page_image?(page, content.image_occurrences)
      end

      # ページ内の画像を WebP 形式で抽出し、ImageAsset の配列として返す
      def extract_page_images(page, image_occurrences, index, suppress_full_page_scans: false)
        return [] if @images_dir.to_s.empty?

        occurrences = filtered_image_occurrences(page, image_occurrences, suppress_full_page_scans:)
        return [] if occurrences.empty?

        image_converter
        FileUtils.mkdir_p(@images_dir)
        assets = []

        occurrences.each_with_index do |occurrence, image_index|
          filename = format("page-%03d-image-%02d.webp", index + 1, image_index + 1)
          output_path = File.join(@images_dir, filename)
          write_image_as_webp(occurrence.object, output_path)
          assets << build_image_asset(index, image_index + 1, filename, output_path, occurrence)
        rescue StandardError
          next
        end

        assets
      end

      # テキスト行と画像参照を Y 座標順に統合し、ページチャンク文字列を構築する
      def build_page_chunk(lines, images, fallback_text, image_captions: {})
        fallback = fallback_text.to_s.strip
        return fallback if images.empty?

        ordered_lines = Array(lines).reject { it.text.to_s.strip.empty? }
        if ordered_lines.empty?
          image_block = image_blocks(Array(images), image_captions, "")
          return [image_block, fallback].reject(&:empty?).join("\n\n")
        end

        references_by_index = Array(images)
                              .sort_by { [-it.center_y.to_f, it.x.to_f] }
                              .group_by { image_insertion_index(ordered_lines, it) }

        blocks = []

        (0..ordered_lines.length).each do |index|
          Array(references_by_index[index]).each do |image|
            blocks << "![](#{image.reference_path})"
            caption = image_captions[image.reference_path].to_s.strip
            blocks << "> #{caption}" unless caption.empty?
          end
          next if index == ordered_lines.length

          blocks << ordered_lines[index].text
        end

        body = blocks.reject(&:empty?).join("\n")
        body.empty? ? fallback : body
      end

      # 画像の center_y が挿入されるべき行位置のインデックスを返す
      def image_insertion_index(lines, image)
        ordered_lines = Array(lines)
        return 0 if ordered_lines.empty?

        ordered_lines.take_while { it.y.to_f > image.center_y.to_f }.length
      end

      # ImageOccurrence から ImageAsset を構築する
      def build_image_asset(page_index, image_index, filename, output_path, occurrence)
        ImageAsset.new(
          page: page_index + 1,
          index: image_index,
          filename:,
          output_path:,
          reference_path: image_reference_path(filename),
          x: occurrence.x,
          top: occurrence.top,
          bottom: occurrence.bottom,
          center_y: occurrence.center_y,
          left: occurrence.left,
          right: occurrence.right,
          width: occurrence.width,
          height: occurrence.height
        )
      end

      # PDF 内画像オブジェクトを WebP 形式でファイルに書き出す
      # RenderedPageCrop の場合は vips で切り出し、それ以外は ImageMagick で変換
      def write_image_as_webp(object, output_path)
        if object in RenderedPageCrop
          write_cropped_image_as_webp(object, output_path)
          return
        end

        source_path = output_path.sub(/\.webp\z/, source_image_extension(object))
        object.write(source_path)

        stdout, status = Open3.capture2e(*image_convert_command(source_path, output_path))
        raise Error, stdout.strip unless status.success?
      ensure
        FileUtils.rm_f(source_path) if source_path
      end

      # PDF 画像オブジェクトの圧縮フィルタから元画像の拡張子を推定する
      def source_image_extension(object)
        filter = Array(object[:Filter]).compact.last

        case filter
        in :DCTDecode then ".jpg"
        in :JPXDecode then ".jp2"
        in :JBIG2Decode then ".jb2"
        in :CCITTFaxDecode then ".tif"
        else ".png"
        end
      end

      # ImageMagick による画像変換コマンドを組み立てる（最大 1600px・品質 85）
      def image_convert_command(source_path, output_path)
        [
          image_converter,
          source_path,
          "-resize", "1600x1600>",
          "-strip",
          "-quality", "85",
          "-define", "webp:method=6",
          output_path
        ]
      end

      # vips で OCR ページ画像の指定領域を切り出し、WebP で保存する
      def write_cropped_image_as_webp(crop, output_path)
        vips = require_vips!
        image = vips::Image.new_from_file(crop.source_image_path)
        image.crop(crop.left, crop.top, crop.width, crop.height).write_to_file(output_path, Q: 85, strip: true)
      rescue StandardError => e
        raise Error, e.message
      end

      # ImageMagick の実行コマンド名を検出する（magick または convert）
      def image_converter
        @image_converter ||= if command_in_path?("magick")
                              "magick"
                            elsif command_in_path?("convert")
                              "convert"
                            else
                              raise Error, "画像を WebP に変換するには ImageMagick (magick または convert) が必要です"
                            end
      end

      # 1 ページ分の OCR を実行し、OcrResult を返す
      # ページ画像を用意し（§ ocr_source_image）、Tesseract でテキストと座標を一度に読む。
      # 囲みの多いページは二値化した画像でも読み、英字の多いページは英語の学習データでも読み直す
      def ocr_page_result(page, index, image_occurrences = [])
        temp_dir = Dir.mktmpdir("vivlio-pdf-ocr")
        source_image_path, image_width, image_height = ocr_source_image(page, index, image_occurrences, temp_dir)
        text, tsv = run_tesseract(source_image_path, File.join(temp_dir, "ocr"))
        text, tsv, read_image_path = second_reading(source_image_path, temp_dir, text, tsv)
        tsv = reread_skipped_regions(read_image_path, temp_dir, tsv, page)
        tsv = reread_slanted_lines(read_image_path, temp_dir, tsv)
        tsv = english_reading(read_image_path, temp_dir, tsv)
        source_image_path, tsv = straighten(source_image_path, tsv, temp_dir)

        OcrResult.new(
          text:,
          lines: extract_ocr_lines(tsv, page),
          blocks: [],
          source_image_path:,
          image_width:,
          image_height:,
          temp_dir:,
          words: extract_ocr_words(tsv, page)
        )
      rescue StandardError
        cleanup_ocr_temp_dir(temp_dir)
        raise
      end

      # OCR にかけるページ画像を用意し、[パス, 幅, 高さ] を返す。
      #
      # スキャンしたページは、埋め込みの画像をそのまま書き出す。pdftoppm でページを描き直すと、
      # 300dpi・A4 の JPEG 1 枚で 23 秒かかっていた（書き出しは 0.05 秒）。24 ページで 9.5 分の
      # 読み取りのほぼすべてがこの描き直しだった。埋め込みの画像を使えないページは描き直す
      def ocr_source_image(page, index, image_occurrences, temp_dir)
        embedded = embedded_scan_image(page, image_occurrences)
        if embedded && (embedded.info.width >= MIN_OCR_IMAGE_WIDTH || vips_available?)
          path = File.join(temp_dir, "page.#{embedded.info.extension}")
          embedded.write(path)
          dpi = scan_dpi(page, embedded.info.width)
          return downscale_for_ocr(path, dpi, temp_dir) if dpi && dpi > MAX_OCR_DPI && vips_available?
          return [path, embedded.info.width, embedded.info.height] if embedded.info.width >= MIN_OCR_IMAGE_WIDTH

          return upscale_for_ocr(path, embedded.info.width, temp_dir)
        end

        prefix = File.join(temp_dir, "page")
        stdout, status = Open3.capture2e(*ocr_render_command(prefix, index + 1))
        raise Error, stdout.strip unless status.success?

        path = Dir.glob("#{prefix}-*.png").sort.first
        raise Error, "OCR 用のページ画像を生成できませんでした" unless path

        [path, *png_dimensions(path)]
      end

      # ページの大きさから見たスキャンの解像度（dpi）。ページを実物より大きく作った PDF では低く出るが、
      # 縮める判定（MAX_OCR_DPI を超えるか）にしか使わないので、そういう PDF は縮めない側に倒れる
      def scan_dpi(page, image_width)
        box = media_box(page)
        return nil unless box && (box[2] - box[0]).positive?

        image_width / ((box[2] - box[0]) / 72.0)
      end

      # 解像度の高すぎるスキャンを 300dpi へ縮める。Tesseract は字が大きすぎても読み違える。
      # 97 章を 600dpi で読むと F 値 89.3%・5 分 14 秒、300dpi に縮めると 90.3%・3 分 1 秒だった
      def downscale_for_ocr(path, dpi, temp_dir)
        image = require_vips!::Image.new_from_file(path).resize(TARGET_OCR_DPI / dpi, kernel: :lanczos3)
        downscaled = File.join(temp_dir, "page-downscaled.jpg")
        # PNG で書くと、書き出しと読み込みで 1 ページ 1 秒ほど余計にかかる
        image.write_to_file(downscaled, Q: 92)
        [downscaled, image.width, image.height]
      end

      # 画素の足りない画像を vips で拡大し、[パス, 幅, 高さ] を返す。
      # 幅 875px（150dpi 相当）のスキャンで、2 倍にすると Tesseract の確信度が 88.8 → 92.2 に上がり、
      # 読めなかった見出しが読めた。pdftoppm で 300dpi に描き直したとき（92.9）とほぼ同じで、0.5 秒で済む
      def upscale_for_ocr(path, width, temp_dir)
        scale = (MIN_OCR_IMAGE_WIDTH.to_f / width).clamp(1.0, 3.0)
        image = require_vips!::Image.new_from_file(path).resize(scale, kernel: :lanczos3)
        upscaled = File.join(temp_dir, "page-upscaled.png")
        image.write_to_file(upscaled)
        [upscaled, image.width, image.height]
      end

      # スキャンの傾きを直す（pdf-read-ocr-improvement-notes.md §4.14）。傾いたままだと、切り出した図の縁に
      # 三角の余白が付き、コードの行番号の欄や柱の高さがページの上と下で数 pt ずれる。
      # 読み取りは傾いたままの画像で済ませ、ここでは語の位置だけを回す。回した画像を Tesseract に読ませると、
      # 補間で字がにじんで読みが落ちる（97 章の 1 ページで確信度の高い字が 612 → 525、全体で英字の語が
      # 212 → 184）。Tesseract は傾いた行もそのまま読める。回した画像は図を見つけて切り出すのに使う。
      # 大きさは変えない（OCR の座標を、画像がページを覆う前提でページの座標へ換算するため）。
      # 回して空いた隅は紙の明るさで埋める
      # @return [Array(String, String)] [図を切り出す画像のパス, 語の位置を回した TSV]
      def straighten(path, tsv, temp_dir)
        return [path, tsv] unless vips_available?

        image = require_vips!::Image.new_from_file(path)
        gray = image.colourspace(:b_w).extract_band(0)
        angle = skew_angle(gray)
        return [path, tsv] if angle.abs < DESKEW_MIN_ANGLE

        rotated = image.similarity(angle:, background: Array.new(image.bands, gray.percent(50)))
        deskewed = File.join(temp_dir, "page-deskewed.jpg")
        rotated.crop((rotated.width - image.width) / 2, (rotated.height - image.height) / 2, image.width, image.height)
               .write_to_file(deskewed, Q: 95)
        [deskewed, rotate_tsv(tsv, angle, image.width, image.height)]
      rescue StandardError
        [path, tsv]
      end

      # TSV の枠を、画像を angle（度・時計回り）回したときの位置へ移す。枠の中心を画像の中心のまわりに回し、
      # 大きさは保つ。ただし行・段落・ブロックの枠は、傾いた行を囲んだぶん（幅 × sin）だけ高く出ているので縮める
      # （行の高さは字の大きさの見積もりになる）
      def rotate_tsv(tsv, angle, width, height)
        radians = angle * Math::PI / 180
        cos = Math.cos(radians)
        sin = Math.sin(radians)
        rows = parse_tsv_rows(tsv).map do |row|
          next row if row.level == "1"

          dx = row.center_x - (width / 2.0)
          dy = row.center_y - (height / 2.0)
          box_height = row.level == "5" ? row.height : [row.height - (row.width * sin.abs), row.height / 4].max
          x = (width / 2.0) + (dx * cos) - (dy * sin)
          y = (height / 2.0) + (dx * sin) + (dy * cos)
          row.with_fields("left" => (x - (row.width / 2)).round, "top" => (y - (box_height / 2)).round, "height" => box_height.round)
        end
        "#{[tsv.lines.first.chomp, *rows.map { it.fields.join("\t") }].join("\n")}\n"
      end

      # 傾き（度・時計回りに直す向きが正）。縮めた画像の濃い画素を角度ごとに回して行ごとに足し、行の並びが
      # いちばん鋭く出る（行ごとの和の二乗和が最大の）角度を採る。範囲の端に当たったら、行の並びが
      # 見つからない（絵だけのページなど）とみなして 0 を返す。97 章の 1 ページで 0.2 秒
      def skew_angle(gray)
        factor = [gray.width / DESKEW_WORK_WIDTH, 1].max
        small = gray.shrink(factor, factor)
        ink = (small < small.percent(50) - FIGURE_DARKNESS).ifthenelse(1.0, 0.0).copy_memory
        best = (-DESKEW_RANGE..DESKEW_RANGE).step(DESKEW_STEP).max_by do |angle|
          ink.similarity(angle:).project[1].to_a.flatten.sum { it * it }
        end
        best.abs >= DESKEW_RANGE - (DESKEW_STEP / 2) ? 0.0 : best
      end

      # そのまま OCR に回せる埋め込みの画像を返す（無ければ nil）。
      #
      # OCR の座標は「画像がページ全体に、縦横比を保って広がっている」前提で
      # ページの座標へ換算する（extract_ocr_lines・build_ocr_image_occurrence）。
      # それを満たし、Tesseract が読める形式の画像だけを選ぶ。
      #
      # 解像度はページの寸法から計らない。ページを実物より大きく作ったスキャン PDF がある
      # （1542×2048pt のページに幅 2,057px の画像。ページから計ると 96dpi だが、本の大きさでは
      # 約 270dpi）。そういう PDF を設定の dpi で描き直すと、情報の増えない 3 倍の引き伸ばしに
      # なり、時間だけかかる（幅 5,160px で確信度は 92.2 → 91.9）。画素の多寡は画像の幅で見る
      # （MIN_OCR_IMAGE_WIDTH・upscale_for_ocr）。
      #
      # 回転の指定があるページは描き直しに任せる。画像を上下逆に置いた PDF は見分けられないが、
      # スキャナが作る PDF では起きない
      def embedded_scan_image(page, image_occurrences)
        return nil unless page[:Rotate].to_i.zero?

        box = media_box(page)
        return nil unless box

        page_width = box[2] - box[0]
        page_height = box[3] - box[1]

        Array(image_occurrences).find do |occurrence|
          object = occurrence.object
          next false unless object.is_a?(HexaPDF::Type::Image)

          info = object.info
          next false unless info.writable && %i[jpeg png].include?(info.type) && [1, 3].include?(info.components)
          next false unless occurrence.width >= page_width * 0.98 && occurrence.height >= page_height * 0.98

          # to_f を忘れない。配置を整数で書いた PDF では座標も Integer で来て、割り算が 0 になる
          ((info.width.to_f / info.height) - (occurrence.width.to_f / occurrence.height)).abs <= 0.02
        end&.object
      rescue StandardError
        nil
      end

      # 囲みや絵の多いページだけ、大津の二値化をかけた画像でも読み、確信度の高い字の多いほうを選ぶ
      # （pdf-read-ocr-postprocess-spec.md §2.2）。ページ全体にいつも二値化をかけると悪くなる
      # （F 値 89.7% → 85.8%）が、地の色の付いた囲みのページでは大きく効く（85.9% → 97.3%）。
      # 文字だけのページは 1 回で済ませる。選ぶ基準は確信度の平均ではなく、確信度の高い語の字数にする。
      # 平均で選ぶと、字を落とした読み（433 字 → 325 字）を選ぶことがある。
      # 選んだ読みの画像も返す。英語での読み直し（english_reading）は同じ画像を読む
      # @return [Array(String, String, String)] [テキスト, TSV, 読んだ画像のパス]
      def second_reading(image_path, temp_dir, text, tsv)
        return [text, tsv, image_path] unless vips_available?

        image = require_vips!::Image.new_from_file(image_path).colourspace(:b_w).extract_band(0)
        histogram = image.hist_find.to_a.flatten
        return [text, tsv, image_path] if tint_ratio(histogram) < TWO_PASS_TINT

        binarized = File.join(temp_dir, "page-otsu.png")
        (image > otsu_threshold(histogram)).write_to_file(binarized)
        other_text, other_tsv = run_tesseract(binarized, File.join(temp_dir, "ocr-otsu"))
        confident_characters(other_tsv) > confident_characters(tsv) ? [other_text, other_tsv, binarized] : [text, tsv, image_path]
      rescue StandardError
        [text, tsv, image_path]
      end

      # 囲みの地の割合。紙の明るさ（中央値）より 10〜60 暗い面で、囲みや網掛けの背景がここに入る。
      # スキャンした紙は真っ白ではない（中央値 226〜230）ので、紙を基準にする
      def tint_ratio(histogram)
        total = histogram.sum
        return 0.0 unless total.positive?

        cumulative = 0
        median = histogram.index { (cumulative += it) * 2 >= total }.to_i
        range = ([median - 60, 0].max..[median - 10, 0].max)
        histogram[range].sum.fdiv(total)
      end

      # 大津の方法で、明るさの分布を 2 つに分けるしきい値を求める
      def otsu_threshold(histogram)
        total = histogram.sum.to_f
        sum_all = histogram.each_with_index.sum { |count, level| count * level }
        background = 0.0
        sum_background = 0.0
        histogram.each_with_index.max_by do |count, level|
          background += count
          sum_background += count * level
          foreground = total - background
          next 0.0 if background.zero? || foreground.zero?

          mean_background = sum_background / background
          mean_foreground = (sum_all - sum_background) / foreground
          background * foreground * ((mean_background - mean_foreground)**2)
        end.last
      end

      # 確信度が CONFIDENT_WORD 以上の語に含まれる字の数
      def confident_characters(tsv)
        rows = tsv.to_s.lines.map { it.chomp.split("\t", -1) }
        header = rows.shift
        return 0 unless header

        index = header.each_with_index.to_h
        rows.sum do |row|
          next 0 unless row[index["level"]] == "5" && row[index["conf"]].to_f >= CONFIDENT_WORD

          row[index["text"]].to_s.strip.length
        end
      end

      # Tesseract が文字の無い範囲とみなして読み飛ばした所を、切り出して読み直す
      # （pdf-read-ocr-improvement-notes.md §4.11）。ページ全体を読むと、Tesseract は先に紙面の割り付けを
      # 推定し、罫線で囲んだ表や色の帯の中の見出しを「文字の無いブロック」として読み飛ばす。切り出して
      # 渡すとその推定に邪魔されずに読める（97 章の表 H-1 は「金属」「カリウム 2.2」が抜け落ちていた）。
      # 読み直しの確信度の高い字が十分にあり、もとの読みより多いときだけ、その範囲の語を置き換える。
      # 写真を読み直しても確信度の低い読み違いしか出ないので、置き換わらない。図の範囲（extract_illustration_regions_vips）と
      # 重なる所は読み直さない。絵に描き込まれた英語の題がきれいに読めて本文に入り、その字を消して図を探すので
      # 図も見つからなくなった（97 章のキログラムの絵）
      def reread_skipped_regions(image_path, temp_dir, tsv, page)
        rows = parse_tsv_rows(tsv)
        words = rows.select { it.level == "5" && !it.text.empty? }
        image = require_vips!::Image.new_from_file(image_path)
        replaced = []
        added = []
        figures = extract_illustration_regions_vips(image_path, extract_ocr_words(tsv, page), page).map { [it.left, it.top, it.left + it.width, it.top + it.height] }
        regions = skipped_regions(rows, words, image.width, image.height).reject do |box|
          figures.any? { |figure| [[box[2], figure[2]].min - [box[0], figure[0]].max, 0].max * [[box[3], figure[3]].min - [box[1], figure[1]].max, 0].max > (box[2] - box[0]) * (box[3] - box[1]) * 0.3 }
        end
        regions.each_with_index do |box, number|
          inside = words.select { it.center_x.between?(box[0], box[2]) && it.center_y.between?(box[1], box[3]) }
          left, top, crop = crop_for_reread(image, box, temp_dir, number)
          _text, region_tsv = run_tesseract(crop, File.join(temp_dir, "reread-#{number}"))
          region_rows = parse_tsv_rows(region_tsv).reject { it.level == "1" }
          next unless better_reading?(region_rows, inside)

          replaced.concat(inside)
          added.concat(region_rows.map do |row|
            row.with_fields("left" => row.left.round + left, "top" => row.top.round + top, "block_num" => row["block_num"].to_i + (1000 * (number + 1)))
          end)
        end
        return tsv if added.empty?

        "#{[tsv.lines.first.chomp, *(rows - replaced).map { it.fields.join("\t") }, *added.map { it.fields.join("\t") }].join("\n")}\n"
      rescue StandardError
        tsv
      end

      # 読み直す範囲 [左, 上, 右, 下]（画素）。語の無いブロックのうち、接し合うものを 1 つにまとめる（表は
      # 罫線で区切られた幾つものブロックになり、別々に読むと切り口の字を読み違える）。小さいもの、ページの
      # 半分を超えるもの、すでに読めた語が REREAD_MAX_COVERAGE を超えて覆うもの（地の色の付いた囲みの
      # 中の文は別のブロックで読めている）は除く
      def skipped_regions(rows, words, width, height)
        word_blocks = words.map { it["block_num"] }.uniq
        unit = width / 595.0
        boxes = rows.select { it.level == "2" && !word_blocks.include?(it["block_num"]) }.map { [it.left, it.top, it.right, it.bottom] }
        clusters = []
        boxes.each do |box|
          joined = clusters.select { |group| group.any? { touching?(it, box, unit * 2) } }
          clusters = clusters - joined + [joined.flatten(1) + [box]]
        end
        clusters.map { |group| [group.map { it[0] }.min, group.map { it[1] }.min, group.map { it[2] }.max, group.map { it[3] }.max] }.select do |left, top, right, bottom|
          area = (right - left) * (bottom - top)
          covered = words.sum { [[it.right, right].min - [it.left, left].max, 0].max * [[it.bottom, bottom].min - [it.top, top].max, 0].max }
          right - left >= REREAD_MIN_WIDTH * unit && bottom - top >= REREAD_MIN_HEIGHT * unit && area <= width * height * 0.5 && covered <= area * REREAD_MAX_COVERAGE
        end
      end

      def touching?(a, b, gap) = a[0] - gap <= b[2] && b[0] - gap <= a[2] && a[1] - gap <= b[3] && b[1] - gap <= a[3]

      # 範囲を余白つきで切り出して書き、[左, 上, パス] を返す。余白が狭いと字を読み違え（8px で「カリウム 2.2」が
      # 「Ze」）、広いと周りの本文が入る（48px）
      def crop_for_reread(image, box, temp_dir, number)
        padding = (image.width * REREAD_PADDING).round
        left = [box[0].floor - padding, 0].max
        top = [box[1].floor - padding, 0].max
        right = [box[2].ceil + padding, image.width].min
        bottom = [box[3].ceil + padding, image.height].min
        path = File.join(temp_dir, "reread-#{number}.png")
        image.crop(left, top, right - left, bottom - top).write_to_file(path)
        [left, top, path]
      end

      # 読み直しを採るか。確信度 CONFIDENT_WORD 以上の字が 4 字以上で、読んだ字の半分以上を占め、
      # もとの読みのその範囲の確信度の高い字より多いこと
      def better_reading?(region_rows, inside)
        region_words = region_rows.select { it.level == "5" && !it.text.empty? }
        confident = ->(words) { words.select { it.conf >= CONFIDENT_WORD }.sum { it.text.length } }
        confident.(region_words) >= 4 && confident.(region_words) * 2 >= region_words.sum { it.text.length } &&
          confident.(region_words) > confident.(inside)
      end

      # 斜体の行を、傾きを戻して読み直す（pdf-read-ocr-improvement-notes.md §4.15）。和文に斜体の書体は無く、
      # Chrome は字を傾けて描く。Tesseract は傾いた和文を読めず、引用文が「BROKE DIED, PREVI…」になる
      # （97 章の引用 9 か所・381 字）。確信度の低い行だけを切り出し、SLANT_ANGLE だけ逆に傾けて読む。
      # 97 章では候補 57 行のうち、引用の 11 行が置き換わった
      def reread_slanted_lines(image_path, temp_dir, tsv)
        return tsv unless @ocr.languages.include?("jpn")

        rows = parse_tsv_rows(tsv)
        heights = rows.select { it.level == "4" }.map(&:height).sort
        return tsv if heights.empty?

        line_height = heights[heights.size / 2]
        candidates = rows.select { it.level == "5" && !it.text.empty? }.group_by(&:line_key).values.select do |words|
          words.size >= 2 && words.sum { it.text.length } >= SLANT_MIN_CHARACTERS && mean_confidence(words) < SLANT_MAX_CONFIDENCE &&
            words.map(&:bottom).max - words.map(&:top).min <= line_height * 2.5
        end
        return tsv if candidates.empty?

        image = require_vips!::Image.new_from_file(image_path)
        replaced = []
        added = []
        candidates.each_with_index do |words, number|
          reading = read_unslanted(image, words, temp_dir, number.to_s, SLANT_ANGLE, 100_000 * (number + 1))
          next unless better_unslanted?(reading, words)
          next unless better_unslanted?(reading, read_unslanted(image, words, temp_dir, "#{number}-upright", 0, 0))

          replaced.concat(words)
          added.concat(reading)
        end
        return tsv if added.empty?

        "#{[tsv.lines.first.chomp, *(rows - replaced).map { it.fields.join("\t") }, *added.map { it.fields.join("\t") }].join("\n")}\n"
      rescue StandardError
        tsv
      end

      # 行を余白つきで切り出し、angle（度）だけ傾きを戻して読む。返す行（TSV の行と語）の位置はページの画素へ戻す。
      # 傾きを戻すと字は行の高さに応じて右へずれるので、行の中ほどのずれを引く。ブロックの番号は block_offset だけ
      # ずらす（読み飛ばした範囲の読み直しの 1000 単位と重ならないよう、100000 単位にする）
      def read_unslanted(image, words, temp_dir, name, angle, block_offset)
        top = words.map(&:top).min
        height = words.map(&:bottom).max - top
        left = [words.map(&:left).min.floor - height.ceil, 0].max
        crop_top = [top.floor - (height / 3).ceil, 0].max
        right = [words.map(&:right).max.ceil + height.ceil, image.width].min
        bottom = [(top + height).ceil + (height / 3).ceil, image.height].min
        shear = Math.tan(angle * Math::PI / 180)
        crop = image.crop(left, crop_top, right - left, bottom - crop_top)
        paper = crop.colourspace(:b_w).extract_band(0).percent(50)
        path = File.join(temp_dir, "slant-#{name}.png")
        crop.affine([1, shear, 0, 1], background: Array.new(crop.bands, paper)).write_to_file(path)

        _text, line_tsv = run_tesseract(path, File.join(temp_dir, "slant-#{name}"))
        parse_tsv_rows(line_tsv).select { %w[4 5].include?(it.level) }.map do |row|
          row.with_fields("left" => (row.left - (shear * row.center_y) + left).round, "top" => row.top.round + crop_top,
                          "block_num" => row["block_num"].to_i + block_offset)
        end
      end

      # 傾きを戻した読みを採るか。確信度の高い字が 4 字以上、半分以上が和文で、比べる読み（もとの読みと、同じ所を
      # 傾けずに切り出した読み）より確信度の高い字が十分に多いこと。読めた字の半分以上が確信度の高い字であるか、
      # 20 字以上あること（引用の行の後ろに崩れた字が続くことがある）。傾けずに切り出した読みとも比べるのは、
      # 切り出すだけでよく読める行（和文の文字列を含むコードの行）を、崩れた読みで置き換えないため
      def better_unslanted?(reading, words)
        read = reading.select { it.level == "5" && !it.text.empty? }
        confident = ->(list) { list.select { it.level == "5" && it.conf >= CONFIDENT_WORD }.sum { it.text.length } }
        total = read.sum { it.text.length }
        gained = confident.(read)
        original = confident.(words)
        japanese = read.sum { |word| word.text.each_char.count { !it.ascii_only? } }
        gained >= 4 && japanese * 2 >= total && gained > original + [4, original * 0.3].max &&
          (gained * 2 >= total || gained >= 20)
      end

      # 英字の多いページだけ、英語の学習データでも読み、英字の語を語の位置で突き合わせて採る
      # （pdf-read-ocr-improvement-notes.md §4.6）。日本語＋英語で読むと、コードの `@param` を `Gparam`、
      # `velocity` を `vetoctty` と読み違える。英語だけで読むとコードはよく読めるが、和文はすべて崩れる。
      # そこで和文の語は日本語＋英語の読みのまま残し、英字の語の連なりだけを差し替える。
      # 97 章のスキャンで、英字の語は 205 → 212（最高・600dpi）、195 → 205（普通・300dpi）になった
      def english_reading(image_path, temp_dir, tsv)
        return tsv unless @ocr.languages.include?("eng") && @ocr.languages.size > 1

        rows = parse_tsv_rows(tsv)
        return tsv if rows.count { it.level == "5" && it.latin? && it.text.match?(/[A-Za-z]/) } < ENGLISH_PAGE_WORDS

        _text, english_tsv = run_tesseract(image_path, File.join(temp_dir, "ocr-eng"), languages: ["eng"])
        merge_english_words(tsv, english_tsv)
      rescue StandardError
        tsv
      end

      # 日本語＋英語の読みの各行で、英字の語の連なり（和文の語にはさまれた範囲）ごとに、英語の読みの語を
      # 当てはめる（english_replacement）。差し替えた語には元の行の番号を付けるので、本体に渡す語の
      # ベースラインと大きさは、日本語＋英語の読みの行の枠から取られる（extract_ocr_words）
      def merge_english_words(tsv, english_tsv)
        rows = parse_tsv_rows(tsv)
        english_words = parse_tsv_rows(english_tsv).select { it.level == "5" && !it.text.empty? && it.latin? }
        lines = rows.select { it.level == "4" }.to_h { [it.line_key, it] }

        merged = rows.slice_when { |a, b| a.level != "5" || b.level != "5" || a.line_key != b.line_key }.flat_map do |group|
          line = lines[group.first.line_key]
          next group unless group.first.level == "5" && line

          group.chunk_while { |a, b| a.latin? && b.latin? }.flat_map do |run|
            replacement = english_replacement(run, group, line, english_words)
            next run unless replacement

            english_words -= replacement
            replacement.map { relocate_english_word(it, run) }
          end
        end
        "#{[tsv.lines.first.chomp, *merged.map { it.fields.join("\t") }].join("\n")}\n"
      end

      # 英字の語の連なり run に当てはめる英語の読みの語を返す（当てはめないなら nil）。
      # 中心が run の範囲（横は語の両端、縦は行の枠）に入る語を集め、次をすべて満たすときに採る。
      # - 2 つの読みで食い違う語について、英語の読みの確信度の平均が ENGLISH_MIN_CONFIDENCE 以上で、
      #   日本語＋英語の読みより高い。run 全体の平均で比べると、確信度の高い共通の語（`showcase}`）に
      #   引っ張られて、「::」を「3:」と読んだ側を採ってしまう
      # - 英語の読みの語が run の幅の 8 割以上を覆い、字数が 0.6〜1.6 倍に収まる。端の「"」や「:」を
      #   落とした読みを採らない
      def english_replacement(run, line_words, line, english_words)
        return nil unless run.all?(&:latin?) && run.any? { it.text.match?(/[A-Za-z0-9]/) }

        left = run.map(&:left).min
        right = run.map(&:right).max
        japanese = line_words.reject(&:latin?)
        candidates = english_words.select do |word|
          word.center_x.between?(left, right) && word.center_y.between?(line.top, line.bottom) &&
            japanese.none? { [word.right, it.right].min - [word.left, it.left].max > word.width / 2 }
        end
        return nil if candidates.empty?

        differing = candidates.reject { |word| run.any? { it.text == word.text } }
        replaced = run.reject { |word| candidates.any? { it.text == word.text } }
        return nil if differing.empty?
        return nil unless mean_confidence(differing) >= ENGLISH_MIN_CONFIDENCE && mean_confidence(differing) > mean_confidence(replaced)

        characters = run.sum { it.text.length }
        covered = [candidates.map(&:right).max, right].min - [candidates.map(&:left).min, left].max
        return nil unless candidates.sum { it.text.length }.between?(characters * 0.6, characters * 1.6)
        return nil if covered < (right - left) * 0.8

        candidates
      end

      # 英語の読みの語を、日本語＋英語の読みの行へ移す。行の番号を合わせ、枠は run の範囲に収める。
      # 枠がはみ出すと、隣の和文の語との空白が消える（「方向に delta」→「方向にdelta」）
      def relocate_english_word(word, run)
        left = [word.left, run.map(&:left).min].max
        right = [word.right, run.map(&:right).max].min
        word.with_fields(LINE_KEY.to_h { [it, run.first[it]] }.merge("left" => left.round, "width" => [right - left, 1].max.round))
      end

      # 字数で重みを付けた確信度の平均。語が無ければ 0
      def mean_confidence(words)
        characters = words.sum { it.text.length }
        characters.zero? ? 0.0 : words.sum { it.conf * it.text.length } / characters
      end

      # Tesseract の TSV を TsvRow の並びにする（見出しの行は除く）
      def parse_tsv_rows(tsv)
        header, *rows = tsv.to_s.lines.map { it.chomp.split("\t", -1) }
        return [] unless header

        index = header.each_with_index.to_h
        rows.map { TsvRow.new(fields: it.fill("", it.length...header.length), index:) }
      end

      # Tesseract を 1 回だけ起動し、プレーンテキストと TSV（座標）を同時に書き出す。
      # 以前は TSV 用とテキスト用に 2 回起動していた。テキストは TSV から行を組めなかったときの予備
      # @return [Array(String, String)] [テキスト, TSV]
      def run_tesseract(image_path, output_base, languages: @ocr.languages)
        command = ["tesseract", image_path, output_base, "-l", languages.join("+"), "--psm", @ocr.psm.to_s, "txt", "tsv"]
        stdout, stderr, status = Open3.capture3(*command)
        raise Error, [stderr, stdout].find { !it.to_s.strip.empty? }.to_s.strip unless status.success?

        %w[txt tsv].map { File.read("#{output_base}.#{it}", encoding: "UTF-8") }
      end

      # pdftoppm によるページ画像レンダリングコマンドを組み立てる
      def ocr_render_command(prefix, page_number)
        [
          "pdftoppm",
          "-f", page_number.to_s,
          "-l", page_number.to_s,
          "-r", @ocr.dpi.to_s,
          "-png",
          pdf_path,
          prefix
        ]
      end

      # Tesseract TSV 出力を解析し、行単位の Line 配列を構築する
      # TSV のワード座標を PDF ページ座標に変換して Y 位置を算出する
      def extract_ocr_lines(tsv, page)
        rows = tsv.to_s.lines.map { it.rstrip }
        return [] if rows.empty?

        header = rows.shift.to_s.split("\t")
        index = header.each_with_index.to_h
        box = media_box(page)
        return [] unless box

        page_top = box[3]
        page_height = page_top - box[1]
        return [] unless page_height.positive?

        image_height = 0.0
        grouped = {}

        rows.each do |row|
          columns = row.split("\t", -1)
          next if columns.empty?

          columns.fill("", columns.length...header.length) if columns.length < header.length

          level = columns[index.fetch("level")].to_i
          image_height = columns[index.fetch("height")].to_f if level == 1
          next unless level == 5

          text = columns[index.fetch("text")].to_s.strip
          next if text.empty?

          left = columns[index.fetch("left")].to_f
          top = columns[index.fetch("top")].to_f
          height = columns[index.fetch("height")].to_f
          key = %w[page_num block_num par_num line_num].map { columns[index.fetch(it)] }
          entry = grouped[key] ||= { left:, top:, bottom: top + height, texts: [] }
          entry[:left] = [entry[:left], left].min
          entry[:top] = [entry[:top], top].min
          entry[:bottom] = [entry[:bottom], top + height].max
          entry[:texts] << text
        end

        return [] unless image_height.positive?

        grouped.values.map do |entry|
          center_y = (entry[:top] + entry[:bottom]) / 2.0
          y = page_top - ((center_y / image_height) * page_height)
          Line.new(y:, text: entry[:texts].join(" "))
        end.sort_by { [-it.y.to_f, it.text] }
      rescue KeyError
        []
      end

      # Tesseract TSV の語（level 5）を、PDF のページ座標の OcrWord にする。
      # ベースラインと大きさは、語ではなく行（level 4）の枠から取る。語ごとの枠は字の形
      # （句読点・小書き）で上下するので、同じ行の語がそろわなくなる
      def extract_ocr_words(tsv, page)
        rows = tsv.to_s.lines.map { it.chomp.split("\t", -1) }
        header = rows.shift
        box = media_box(page)
        return [] unless header && box

        index = header.each_with_index.to_h
        value = ->(row, name) { row[index.fetch(name)] }
        image = rows.find { value.(it, "level") == "1" }
        return [] unless image

        scale_x = (box[2] - box[0]) / value.(image, "width").to_f
        scale_y = (box[3] - box[1]) / value.(image, "height").to_f
        line_key = ->(row) { %w[page_num block_num par_num line_num].map { value.(row, it) } }
        lines = rows.select { value.(it, "level") == "4" }.to_h { [line_key.(it), it] }

        rows.filter_map do |row|
          text = value.(row, "text").to_s.strip
          line = lines[line_key.(row)]
          next if value.(row, "level") != "5" || text.empty? || line.nil?

          line_top = value.(line, "top").to_f
          line_height = value.(line, "height").to_f
          OcrWord.new(
            text:,
            x: box[0] + (value.(row, "left").to_f * scale_x),
            y: box[3] - ((line_top + line_height) * scale_y),
            width: value.(row, "width").to_f * scale_x,
            size: line_height * scale_y,
            conf: value.(row, "conf").to_f
          )
        end
      rescue KeyError, ZeroDivisionError
        []
      end

      # ページの幅と高さ（pt）
      def page_size(page)
        box = media_box(page)
        box ? [box[2] - box[0], box[3] - box[1]] : nil
      end

      # PNG ファイルの幅と高さをヘッダから読み取る
      def png_dimensions(path)
        header = File.binread(path, 24)
        raise Error, "OCR 用ページ画像のサイズを取得できませんでした" unless header.bytesize >= 24
        raise Error, "OCR 用ページ画像が PNG ではありません" unless header.start_with?("\x89PNG\r\n\x1A\n".b)

        header.byteslice(16, 8).unpack("N2")
      end

      # OCR 結果からイラスト領域を検出し、既存の画像出現と統合する
      # スキャンページ画像は除外し、vips ベースのイラスト検出結果を追加する
      def ocr_image_occurrences(page, image_occurrences, result)
        inline_occurrences = Array(image_occurrences).reject { scanned_page_image_occurrence?(page, it) }
        return inline_occurrences unless scanned_page_image?(page, image_occurrences) || inline_occurrences.empty?

        inline_occurrences + extract_illustration_regions_vips(result.source_image_path, result.words, page).map { build_ocr_image_occurrence(page, it, result) }
      rescue StandardError
        inline_occurrences
      end

      # OCR したページの画像から図の範囲を見つける（pdf-read-ocr-improvement-notes.md §4.2・§4.4）。
      # ページを縮め、紙より濃い画素と色の付いた画素を拾い、OCR で読めた文字（確信度の高い語と行）を
      # 消してから、残ったまとまりを図とみなす。97 章のスキャンでは、図 15 枚のうち 14 枚が見つかり、
      # 誤りは無かった（行ごとの濃さで探していた以前の方法は 1 枚で、1 ページ約 3 秒かかっていた）。
      # 白地の線だけの図は、文字を消すと線しか残らず、見つからない
      # @param words [Array<OcrWord>] このページの OCR の語（PDF のページの座標）
      # @return [Array<IllustrationRegion>] 元の画像の画素での範囲
      def extract_illustration_regions_vips(source_image_path, words, page)
        image = require_vips!::Image.new_from_file(source_image_path)
        factor = [(image.width / FIGURE_WORK_WIDTH.to_f).round, 1].max
        small = image.shrink(factor, factor)
        ink = figure_ink(small)
        erase_text(ink, small.width, small.height, words, page)
        figure_boxes(ink, small.width, small.height).map do |left, top, right, bottom|
          IllustrationRegion.new(left: left * factor, top: top * factor, width: (right - left) * factor, height: (bottom - top) * factor)
        end
      end

      # 図の候補の画素（左上から行ごとに並べた真偽）。紙の明るさ（中央値）より FIGURE_DARKNESS 以上
      # 暗いか、彩度が FIGURE_CHROMA を超える画素。地の色の付いた囲み（紙より 10〜40 暗い）は入らない
      def figure_ink(small)
        small = small.extract_band(0, n: 3) if small.bands > 3
        gray = small.colourspace(:b_w).extract_band(0)
        histogram = gray.hist_find.to_a.flatten
        total = histogram.sum
        cumulative = 0
        paper = histogram.index { (cumulative += it) * 2 >= total }
        mask = gray < (paper - FIGURE_DARKNESS)
        mask |= small.colourspace(:lch).extract_band(1) > FIGURE_CHROMA if small.bands >= 3
        mask.cast(:uchar).write_to_memory.unpack("C*").map(&:positive?)
      end

      # 確信度の高い語と、語の確信度の平均が高い行の範囲を、図の候補から消す。行ごと消すのは、語の
      # あいだの隙間に残る字の切れ端で、本文の行が図の候補につながらないようにするため
      def erase_text(ink, width, height, words, page)
        box = media_box(page)
        scale_x = width / (box[2] - box[0])
        scale_y = height / (box[3] - box[1])
        lines = words.group_by { [it.y, it.size] }.values.select { |line| line.sum(&:conf) / line.size >= FIGURE_TEXT_CONFIDENCE }
        spans = lines.map { |line| [line.map(&:x).min, line.first.y, line.map { it.x + it.width }.max, line.first.y + line.first.size] } +
                words.select { it.conf >= FIGURE_TEXT_CONFIDENCE }.map { [it.x, it.y, it.x + it.width, it.y + it.size] }
        spans.each do |left, bottom, right, top|
          columns = ((left - box[0]) * scale_x).floor.clamp(0, width)...((right - box[0]) * scale_x).ceil.clamp(0, width)
          rows = ((box[3] - top) * scale_y).floor.clamp(0, height)...((box[3] - bottom) * scale_y).ceil.clamp(0, height)
          rows.each { |y| columns.each { |x| ink[(y * width) + x] = false } }
        end
      end

      # 図の候補の画素のまとまりを、図の枠 [左, 上, 右, 下]（縮めた画像の画素）にする。
      # 隣り合う画素を 1 画素膨らませてつなぎ、枠は膨らませる前の画素で取る。枠は、埋まった列・行の
      # 最も長い連なりへ削る（trim_to_dense）。ページの端に接するもの（ページ上端の飾りの帯・色を
      # 敷いた章扉）は図にしない。図にすると、その上の文字を本体が本文から除いてしまう
      def figure_boxes(ink, width, height)
        grown = ink.each_index.map { |cell| ink[cell] || neighbor_cells(cell, width, ink.size).any? { ink[it] } }
        seen = Array.new(ink.size, false)
        grown.each_index.filter_map do |start|
          next unless grown[start] && !seen[start]

          # つながった画素を幅優先でたどる（each は、たどる途中で足した画素も回る）
          seen[start] = true
          cells = [start]
          cells.each do |cell|
            neighbor_cells(cell, width, ink.size).each do |neighbor|
              next if seen[neighbor] || !grown[neighbor]

              seen[neighbor] = true
              cells << neighbor
            end
          end
          inked = cells.select { ink[it] }
          next if inked.empty?

          box = trim_to_dense(ink, width, [inked.map { it % width }.min, inked.map { it / width }.min, inked.map { it % width }.max + 1, inked.map { it / width }.max + 1])
          box if box && figure_box?(box, cells.size, width, height)
        end
      end

      # 上下左右の画素の番号（左右の端では折り返さない）
      def neighbor_cells(cell, width, size)
        column = cell % width
        [cell - width, cell + width, (cell - 1 if column.positive?), (cell + 1 if column < width - 1)].compact.select { it.between?(0, size - 1) }
      end

      # 枠を、図の画素が FIGURE_DENSE 以上埋まった列の最も長い連なりへ、続いて同じく行の連なりへ削る。
      # 写真は埋まり、写真の横の消し残した字（小さなルビ・確信度の低い語）はまばらなので、写真に
      # つながった本文の字の列が枠から外れる
      def trim_to_dense(ink, width, box)
        left, top, right, bottom = box
        longest = lambda do |flags|
          run = flags.each_with_index.chunk_while { |(a, i), (b, j)| a == b && j == i + 1 }.select { it.first.first }.max_by(&:size)
          run && [run.first.last, run.last.last + 1]
        end
        dense_columns = (left...right).map { |x| (top...bottom).count { |y| ink[(y * width) + x] } >= (bottom - top) * FIGURE_DENSE }
        columns = longest.(dense_columns) or return nil
        left, right = left + columns[0], left + columns[1]
        dense_rows = (top...bottom).map { |y| (left...right).count { |x| ink[(y * width) + x] } >= (right - left) * FIGURE_DENSE }
        rows = longest.(dense_rows) or return nil
        [left, top + rows[0], right, top + rows[1]]
      end

      # 図とみなす枠か。ページの端に接せず、辺と面積が下限を超え、まとまりの画素が枠の半分以上を埋める
      def figure_box?(box, cells, width, height)
        left, top, right, bottom = box
        return false if left <= 1 || top <= 1 || right >= width - 1 || bottom >= height - 1

        side = FIGURE_MIN_SIDE * width
        area = (right - left) * (bottom - top)
        right - left >= side && bottom - top >= side && area >= FIGURE_MIN_AREA * width * height && cells >= area * 0.5
      end

      # イラスト領域のピクセル座標を PDF ページ座標に変換し、ImageOccurrence を構築する
      def build_ocr_image_occurrence(page, region, result)
        box = media_box(page)
        page_width = box[2] - box[0]
        page_height = box[3] - box[1]
        right_edge = region.left + region.width
        bottom_edge = region.top + region.height
        left = box[0] + ((region.left.to_f / result.image_width) * page_width)
        right = box[0] + ((right_edge.to_f / result.image_width) * page_width)
        top = box[3] - ((region.top.to_f / result.image_height) * page_height)
        bottom = box[3] - ((bottom_edge.to_f / result.image_height) * page_height)

        ImageOccurrence.new(
          x: (left + right) / 2.0,
          top:,
          bottom:,
          center_y: (top + bottom) / 2.0,
          left:,
          right:,
          width: right - left,
          height: top - bottom,
          object: RenderedPageCrop.new(
            source_image_path: result.source_image_path,
            left: region.left.round,
            top: region.top.round,
            width: region.width.round,
            height: region.height.round
          )
        )
      end

      # ruby-vips と libvips が使えるか。使えなければ、画素の足りない画像は拡大せずに描き直しへ回す
      def vips_available?
        require_vips!
        true
      rescue Error
        false
      end

      # ruby-vips を安全にロードし、Vips モジュールを返す
      def require_vips!
        require "vips"
        Vips
      rescue LoadError => e
        raise Error, "画像抽出には ruby-vips と libvips が必要です: #{e.message}"
      rescue StandardError => e
        raise Error, "libvips の初期化に失敗しました: #{e.message}"
      end

      # OCR に必要な外部コマンド（pdftoppm, tesseract）と言語データが揃っているか
      def ocr_dependencies_ready?
        return false unless command_in_path?("pdftoppm") && command_in_path?("tesseract")

        missing_languages = @ocr.languages.reject { available_ocr_languages.include?(it) }
        if missing_languages.empty?
          true
        elsif ocr_mode == :always
          raise Error, "OCR 用の Tesseract 言語データが不足しています: #{missing_languages.join(', ')}"
        else
          false
        end
      end

      # Tesseract にインストール済みの言語一覧を取得する（メモ化）
      def available_ocr_languages
        @available_ocr_languages ||= begin
          stdout, status = Open3.capture2e("tesseract", "--list-langs")
          if status.success?
            stdout.lines.map(&:strip).reject { it.empty? || it.start_with?("List of available languages") }
          else
            []
          end
        rescue StandardError
          []
        end
      end

      # テキスト抽出品質が低い（空白過多・断片化）かどうかを判定する
      def poor_text_extraction?(text)
        body = text.to_s.gsub(/\s+/, " ").strip
        return false if body.length < 24

        whitespace_ratio = body.count(" ").to_f / body.length
        fragmented_words = body.scan(/(?:\p{Han}|\p{Hiragana}|\p{Katakana}|[A-Za-z])(?:\s+(?:\p{Han}|\p{Hiragana}|\p{Katakana}|[A-Za-z])){3,}/).length

        whitespace_ratio >= 0.18 || fragmented_words.positive?
      end

      # ページ全体を覆うスキャン画像が存在するかどうか
      def scanned_page_image?(page, image_occurrences)
        Array(image_occurrences).any? { scanned_page_image_occurrence?(page, it) }
      end

      # 画像出現がページ全体を覆うスキャン画像かどうかを面積比で判定する
      def scanned_page_image_occurrence?(page, occurrence)
        box = media_box(page)
        return false unless box

        page_width = box[2] - box[0]
        page_height = box[3] - box[1]
        return false unless page_width.positive? && page_height.positive?

        height_ratio = occurrence.height.to_f / page_height
        width_ratio = occurrence.width.to_f / page_width
        area_ratio = (occurrence.width.to_f * occurrence.height.to_f) / (page_width * page_height)

        (height_ratio >= 0.72 && width_ratio >= 0.72) || area_ratio >= 0.55
      end

      # 指定コマンドが PATH 上に存在し実行可能かを確認する
      def command_in_path?(command)
        return false if command.to_s.empty?

        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
          path = File.join(dir, command)
          File.executable?(path) && !File.directory?(path)
        end
      end

      # Markdown 内で使用する画像参照パスを組み立てる
      def image_reference_path(filename)
        base = @image_reference_dir.to_s.strip
        return filename if base.empty?

        File.join(base, filename)
      end

      # ページチャンクを結合して最終 Markdown を組み立てる
      def build_markdown(chunks)
        body = if @page_separator
                 chunks.join("\n\n---\n\n")
               else
                 chunks.reject(&:empty?).join("\n")
               end
        body = body.strip
        body.empty? ? body : "#{body}\n"
      end

      # テキストの汎用サニタイズ: NBSP 除去・改行正規化・末尾空白除去・連続空行の圧縮
      def sanitize(text)
        text
          .to_s
          .gsub("\u00A0", " ")
          .gsub(/\r\n?/, "\n")
          .gsub(/[ \t]+$/, "")
          .gsub(/\n{3,}/, "\n\n")
          .strip
      end

      # スキャンページ画像をフィルタリングした画像出現リストを返す
      def filtered_image_occurrences(page, image_occurrences, suppress_full_page_scans: false)
        occurrences = Array(image_occurrences)
        return occurrences unless suppress_full_page_scans

        occurrences.reject { scanned_page_image_occurrence?(page, it) }
      end

      # 画像配列を Markdown 画像参照ブロック（+ キャプション）に変換する
      def image_blocks(images, image_captions, fallback)
        blocks = Array(images).sort_by { [-it.center_y.to_f, it.x.to_f] }.flat_map do |image|
          caption = image_captions[image.reference_path].to_s.strip
          next ["![](#{image.reference_path})"] if caption.empty?

          ["![](#{image.reference_path})", "> #{caption}"]
        end

        body = blocks.reject(&:empty?).join("\n")
        body.empty? ? fallback : body
      end

      # 行テキストとキャプションを結合してページテキストを構築する
      def build_page_text(lines, fallback_text, image_captions)
        body = Array(lines).map(&:text).reject { it.to_s.strip.empty? }.join("\n")
        body = fallback_text.to_s.strip if body.empty?
        captions = image_captions.values.map(&:to_s).reject { it.strip.empty? }
        text = [body, *captions].reject(&:empty?).join("\n")
        sanitize(text)
      end

      # inline_image_text ポリシーに従い、画像領域内のテキスト行を処理する
      # :include ならそのまま、:exclude なら除外、:captionize ならキャプション化
      def apply_inline_image_text_policy(lines, images)
        ordered_lines = Array(lines).reject { it.text.to_s.strip.empty? }
        return [ordered_lines, {}] if inline_image_text == :include || ordered_lines.empty? || images.empty?

        captions = Hash.new { |hash, key| hash[key] = [] }
        kept_lines = []

        ordered_lines.each do |line|
          image = overlapping_image(images, line)
          if image
            captions[image.reference_path] << line.text if inline_image_text == :captionize
          else
            kept_lines << line
          end
        end

        normalized_captions = captions.transform_values do |texts|
          sanitize(texts.reject(&:empty?).join(" "))
        end.reject { _2.empty? }

        [kept_lines, normalized_captions]
      end

      # 行の Y 座標と重なる画像を検索する（許容誤差 12pt）
      def overlapping_image(images, line)
        tolerance = 12.0

        Array(images)
          .select { line.y.to_f.between?(it.bottom.to_f - tolerance, it.top.to_f + tolerance) }
          .min_by { (it.center_y.to_f - line.y.to_f).abs }
      end

      # OCR 行テキストに後処理を適用し、空行を除外した Line 配列を返す
      def normalize_ocr_lines(lines)
        Array(lines).filter_map do |line|
          text = postprocess_ocr_text(line.text)
          next if text.empty?

          Line.new(y: line.y, text:)
        end
      end

      # OCR テキストの後処理パイプライン
      # 日本語スペース除去 → 断片結合 → 括弧正規化 → 誤認識の補正
      def postprocess_ocr_text(text)
        sanitized = sanitize(text)
        return "" if sanitized.empty?

        sanitized = collapse_ocr_japanese_spaces(sanitized)
        sanitized = collapse_fragmented_words(sanitized)
        sanitized = normalize_ocr_brackets(sanitized)
        sanitized = apply_ocr_corrections(sanitized)
        sanitize(sanitized)
      end

      # --- OCR テキスト補正用の文字クラス正規表現 ---
      # 足すのは `\p{...}` に入らない 2 文字だけ。々 は \p{Han}、ヵヶ は \p{Katakana} に
      # 含まれるため、並べると「character class has duplicated range」が毎回 5 行出る。
      CJK_CHAR = /[\p{Han}\p{Hiragana}\p{Katakana}ー〆]/.freeze
      JP_PUNCT = /[、。，．：；！？!?…]/.freeze
      JP_OPEN  = /[「『（【《〈]/.freeze
      JP_CLOSE = /[」』）】》〉]/.freeze

      # CJK 文字間・句読点前後の不要スペースを除去する
      def collapse_ocr_japanese_spaces(text)
        result = text.to_s
        result = result.gsub(/(?<=#{CJK_CHAR}) +(?=#{CJK_CHAR})/, "")
        result = result.gsub(/(?<=#{CJK_CHAR}) +(?=#{JP_PUNCT})/, "")
        result = result.gsub(/(?<=#{JP_PUNCT}) +(?=#{CJK_CHAR})/, "")
        result = result.gsub(/(?<=#{JP_OPEN}) +/, "")
        result = result.gsub(/ +(?=#{JP_CLOSE})/, "")
        result = result.gsub(/(?<=#{JP_CLOSE}) +(?=#{CJK_CHAR})/, "")
        result = result.gsub(/(?<=#{CJK_CHAR}) +(?=#{JP_OPEN})/, "")
        result = result.gsub(/\( +/, "(")
        result = result.gsub(/ +\)/, ")")
        result
      end

      # CJK 文字を含む半角括弧を全角括弧に変換する
      def normalize_ocr_brackets(text)
        text.to_s.gsub(/\(([^)]*#{CJK_CHAR}[^)]*)\)/) { "（#{$1.strip}）" }
      end

      # OCR で断片化した単語（1文字ずつ空白区切り）を結合する
      def collapse_fragmented_words(text)
        text.to_s.gsub(/(?:\p{Han}|\p{Hiragana}|\p{Katakana}|[A-Za-z])(?:\s+(?:\p{Han}|\p{Hiragana}|\p{Katakana}|[A-Za-z])){2,}/) do
          it.gsub(/\s+/, "")
        end
      end

      # OCR の誤認識を補正する表を当てる。
      #
      # **当てるのは OCR したページのテキストだけ**で、著者が自分で書いた原稿には触れない。
      # 以前はこれをプロジェクトの prh 辞書（校正辞書）から読んでいたが、校正辞書は
      # 全原稿に当たるため、アルミニウムの元素記号 `Al` が `AI` へ、「言語芸術」が
      # 「言語彙術」へ書き換えられていた。走査の誤りと表記の方針は別物なので表を分けた。
      def apply_ocr_corrections(text)
        ocr_corrections.reduce(text.to_s) do |memo, (matcher, expected)|
          memo.gsub(matcher, expected)
        end
      end

      # 補正表の既定の置き場。プロジェクトごとに育てるものなので gem には持たせない
      OCR_CORRECTIONS_FILE = File.join("config", "ocr_corrections.yml")

      # config/ocr_corrections.yml から補正ルールを読み込む（メモ化）。
      # 各ルールの patterns を Regexp にコンパイルし、[matcher, expected] の配列を返す。
      # ファイルが無いプロジェクト（1.0 より前の雛形）では補正せずに素通りさせる
      def ocr_corrections
        @ocr_corrections ||= begin
          path = File.join(Dir.pwd, OCR_CORRECTIONS_FILE)
          unless File.file?(path)
            []
          else
            data = YAML.safe_load(File.read(path, encoding: "UTF-8"), aliases: true) || {}
            Array(data["rules"]).flat_map do |rule|
              expected = rule["expected"].to_s
              next [] if expected.empty?

              Array(rule["patterns"]).filter_map do |pattern|
                matcher = compile_correction_pattern(pattern)
                matcher ? [matcher, expected] : nil
              end
            end
          end
        rescue StandardError
          []
        end
      end

      # 補正パターンを Regexp にコンパイルする
      # "/pattern/" 形式は正規表現、それ以外はリテラルマッチ
      def compile_correction_pattern(pattern)
        case pattern
        in Regexp then pattern
        else
          value = pattern.to_s.strip
          return nil if value.empty?

          if value.start_with?("/") && value.end_with?("/") && value.length > 2
            Regexp.new(value[1...-1])
          else
            Regexp.new(Regexp.escape(value))
          end
        end
      rescue StandardError
        nil
      end

      # ページの MediaBox とマージン設定からテキスト抽出領域の座標境界を算出する
      # 奇数/偶数ページで綴じ側と小口側を反転する
      def text_area_bounds(page, index)
        return unless @text_area

        box = media_box(page)
        return unless box

        x_min, y_min, x_max, y_max = box
        parity = (index + 1).odd?
        inner = @text_area[:inner]
        outer = @text_area[:outer]

        {
          top: y_max - @text_area[:top],
          bottom: y_min + @text_area[:bottom],
          left: x_min + (parity ? inner : outer),
          right: x_max - (parity ? outer : inner)
        }
      end

      # ページの MediaBox（用紙サイズ座標）を安全に取得する
      def media_box(page)
        box = page[:MediaBox]
        values = Array(box).map { Float(it) }
        return values if values.length >= 4

        nil
      rescue StandardError
        nil
      end

      # text_area パラメータを {:top, :bottom, :inner, :outer} の Hash に正規化する
      def normalize_text_area(text_area)
        return unless text_area

        {
          top: fetch_value(text_area, :top),
          bottom: fetch_value(text_area, :bottom),
          inner: fetch_value(text_area, :inner),
          outer: fetch_value(text_area, :outer)
        }
      end

      # OCR パラメータを OcrSettings 構造体に正規化する
      def normalize_ocr(ocr)
        OcrSettings.new(
          mode: normalize_ocr_mode(setting_value(ocr, :mode)),
          languages: normalize_ocr_languages(setting_value(ocr, :languages)),
          dpi: normalize_positive_integer(setting_value(ocr, :dpi), 300),
          psm: normalize_positive_integer(setting_value(ocr, :psm), 3),
          inline_image_text: normalize_inline_image_text(setting_value(ocr, :inline_image_text))
        )
      end

      # OCR モードを :auto / :always / :never に正規化する
      def normalize_ocr_mode(value)
        case value.to_s.strip.downcase
        in "" | "auto" then :auto
        in "always" | "force" | "true" then :always
        in "never" | "false" | "off" then :never
        else
          :auto
        end
      end

      # OCR 言語指定を正規化する（配列化 + エイリアス解決 + 重複排除、既定は jpn）
      def normalize_ocr_languages(value)
        raw = case value
              in Array then value
              else value.to_s.split(/[+,]/)
              end
        languages = raw.map { normalize_ocr_language_alias(it) }.reject(&:empty?)
        # 既定は日本語と英語。技術書はコードや英字の語を含み、英語を足すと識別子が
        # 18 語中 7 → 16 語戻った。和文は悪くならない（pdf-read-ocr-postprocess-spec.md §2.1）
        languages = %w[jpn eng] if languages.empty?
        languages.uniq
      end

      # "japanese" → "jpn" など、エイリアスを Tesseract 言語コードに変換する
      def normalize_ocr_language_alias(value)
        case value.to_s.strip.downcase.tr("-", "_")
        in "" then ""
        in "japanese" then "jpn"
        in "japanese_vertical" then "jpn_vert"
        in "english" then "eng"
        else value.to_s.strip
        end
      end

      # inline_image_text を :include / :exclude / :captionize に正規化する
      def normalize_inline_image_text(value)
        case value.to_s.strip.downcase
        in "" | "include" then :include
        in "exclude" | "remove" then :exclude
        in "captionize" | "caption_only" | "caption" then :captionize
        else :include
        end
      end

      # 正の整数に変換する。不正値なら default を返す
      def normalize_positive_integer(value, default)
        integer = Integer(value)
        integer.positive? ? integer : default
      rescue StandardError
        default
      end

      # 設定オブジェクトから安全にキー値を取得する（メソッド呼び出し or Hash アクセス）
      def setting_value(source, key)
        return nil unless source

        if source.respond_to?(key)
          source.public_send(key)
        else
          source[key] || source[key.to_s]
        end
      rescue StandardError
        nil
      end

      # 設定オブジェクトから数値を取得し、Float に変換する（失敗時は 0.0）
      def fetch_value(source, key)
        raw = if source.respond_to?(key)
                source.public_send(key)
              else
                source[key] || source[key.to_s]
              end
        raw.to_f
      rescue StandardError
        0.0
      end

      # OCR モード設定値のアクセサ
      def ocr_mode = @ocr.mode

      # イラスト内テキスト処理ポリシーのアクセサ
      def inline_image_text = @ocr.inline_image_text

      # 同一行とみなす Y 座標差の閾値のアクセサ
      def line_merge_tolerance = @line_merge_tolerance
    end
  end
end
