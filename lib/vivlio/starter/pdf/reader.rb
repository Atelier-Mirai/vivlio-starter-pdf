# frozen_string_literal: true

require "hexapdf"
require "fileutils"
require "open3"
require "tmpdir"
require "yaml"

module Vivlio
  module Starter
    module PDF
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
        # ページのテキスト・行・画像出現をまとめたコンテンツ
        PageContent = Data.define(:text, :lines, :image_occurrences)
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
        OcrResult = Data.define(:text, :lines, :blocks, :source_image_path, :image_width, :image_height, :temp_dir)

        # --- イラスト検出用定数 ---
        # イラスト領域とみなす最小面積比
        MIN_ILLUSTRATION_AREA_RATIO = 0.02
        # テキスト領域と区別するアスペクト比上限
        ILLUSTRATION_TEXT_ASPECT_MAX = 6.0
        # 前景検出の輝度閾値（この値未満のピクセルを前景とする）
        FOREGROUND_THRESHOLD = 210
        # 行プロファイル閾値の標準偏差スケール係数
        ROW_ACTIVITY_STDDEV_SCALE = 0.5
        # 列単位の前景活性度閾値
        COLUMN_ACTIVITY_THRESHOLD = 0.05
        # ガウシアン平滑化のシグマ比率（画像高さに対する割合）
        PROFILE_SMOOTHING_SIGMA_RATIO = 0.012
        # シグマの下限・上限
        MIN_PROFILE_SMOOTHING_SIGMA = 3
        MAX_PROFILE_SMOOTHING_SIGMA = 25

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
              buffer = +fragment.text
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
              .gsub(/(?<=[一-龯ぁ-ゖァ-ヶー々〆ヵヶ]) (?=[一-龯ぁ-ゖァ-ヶー々〆ヵヶ])/, "")
              .gsub(/(?<=[一-龯ぁ-ゖァ-ヶー々〆ヵヶ]) (?=[、。，．：；！？）】』」])/, "")
              .gsub(/(?<=[（【『「]) (?=[一-龯ぁ-ゖァ-ヶー々〆ヵヶA-Za-z0-9])/, "")
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
        def initialize(pdf_path, page_separator: true, text_area: nil, line_merge_tolerance: 2.0, images_dir: nil, image_reference_dir: nil, ocr: nil)
          @pdf_path = pdf_path
          @page_separator = page_separator != false
          @text_area = normalize_text_area(text_area)
          @line_merge_tolerance = line_merge_tolerance.to_f
          @images_dir = images_dir&.to_s&.strip
          @image_reference_dir = image_reference_dir&.to_s&.strip
          @ocr = normalize_ocr(ocr)
        end

        # PDF を解析し、Markdown テキスト・画像アセット・メタデータを含む Hash を返す
        # @return [Hash] :markdown, :page_texts, :page_chunks, :pages, :images
        def execute
          document = HexaPDF::Document.open(pdf_path)
          page_texts = []
          page_chunks = []
          images = []

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
            ensure
              cleanup_ocr_temp_dir(resolution&.ocr_temp_dir)
            end
          end

          {
            markdown: build_markdown(page_chunks),
            page_texts:,
            page_chunks:,
            pages: document.pages.count,
            images: images.map(&:to_h)
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

          resolved_content, ocr_temp_dir = extract_page_ocr_content(page, index, content.image_occurrences)
          ResolvedPage.new(content: resolved_content, ocr_applied: true, ocr_temp_dir:)
        rescue StandardError
          raise if ocr_mode == :always

          ResolvedPage.new(content:, ocr_applied: false, ocr_temp_dir: nil)
        end

        # OCR を実行してページコンテンツを再構築する
        # テキスト後処理（空白圧縮・括弧正規化・prh 辞書置換）を適用する
        def extract_page_ocr_content(page, index, image_occurrences)
          result = ocr_page_result(page, index)
          lines = normalize_ocr_lines(result.lines)
          text = if lines.empty?
                   postprocess_ocr_text(result.text)
                 else
                   sanitize(lines.map(&:text).join("\n"))
                 end

          resolved_image_occurrences = ocr_image_occurrences(page, image_occurrences, result)
          page_content = if text.empty?
                           PageContent.new(text: "", lines: [], image_occurrences: resolved_image_occurrences)
                         else
                           PageContent.new(text:, lines:, image_occurrences: resolved_image_occurrences)
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
        # pdftoppm でページ画像を生成し、Tesseract でテキスト認識する
        def ocr_page_result(page, index)
          temp_dir = Dir.mktmpdir("vivlio-pdf-ocr")
          prefix = File.join(temp_dir, "page")
          stdout, status = Open3.capture2e(*ocr_render_command(prefix, index + 1))
          raise Error, stdout.strip unless status.success?

          source_image_path = Dir.glob("#{prefix}-*.png").sort.first
          raise Error, "OCR 用のページ画像を生成できませんでした" unless source_image_path

          tsv = capture_ocr_output(*ocr_tsv_command(source_image_path))
          image_width, image_height = png_dimensions(source_image_path)

          OcrResult.new(
            text: capture_ocr_output(*ocr_text_command(source_image_path)),
            lines: extract_ocr_lines(tsv, page),
            blocks: [],
            source_image_path:,
            image_width:,
            image_height:,
            temp_dir:
          )
        rescue StandardError
          cleanup_ocr_temp_dir(temp_dir)
          raise
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

        # Tesseract によるプレーンテキスト出力コマンドを組み立てる
        def ocr_text_command(image_path)
          [
            "tesseract",
            image_path,
            "stdout",
            "-l", @ocr.languages.join("+"),
            "--psm", @ocr.psm.to_s
          ]
        end

        # Tesseract による TSV 出力コマンドを組み立てる（座標情報取得用）
        def ocr_tsv_command(image_path)
          ocr_text_command(image_path) + ["tsv"]
        end

        # 外部コマンドを実行し、stdout を返す。失敗時は Error を送出する
        def capture_ocr_output(*command)
          stdout, stderr, status = Open3.capture3(*command)
          raise Error, [stderr, stdout].find { !it.to_s.strip.empty? }.to_s.strip unless status.success?

          stdout
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

          inline_occurrences + extract_illustration_regions_vips(result.source_image_path).map { build_ocr_image_occurrence(page, it, result) }
        rescue StandardError
          inline_occurrences
        end

        # vips を使って OCR ページ画像からイラスト領域を自動検出する
        # 前景マスク → 行プロファイル → ガウシアン平滑化 → 領域分割 の流れで処理する
        def extract_illustration_regions_vips(source_image_path)
          vips = require_vips!
          image = vips::Image.new_from_file(source_image_path)
          mask = vips_foreground_mask(image)
          row_profile = smooth_profile(build_row_profile(mask), sigma: profile_smoothing_sigma(image.height))
          stats = profile_statistics(row_profile)
          threshold = stats.fetch(:average) + (stats.fetch(:stddev) * ROW_ACTIVITY_STDDEV_SCALE)

          regions = find_regions_from_profile(
            row_profile,
            image.height,
            threshold:,
            max_gap: [20, (image.height * 0.006).round].max,
            min_height: [100, (image.height * 0.03).round].max
          )

          regions.filter_map { build_foreground_region(mask, it, image.width, image.height) }
        end

        # 画像をグレースケール化し、前景ピクセルの二値マスクを生成する
        def vips_foreground_mask(image)
          gray = image.colourspace("b-w")
          gray
            .relational_const(:less, [FOREGROUND_THRESHOLD])
            .cast(:uchar)
            .linear([255.0], [0])
            .cast(:uchar)
        end

        # 各行の前景ピクセル密度（0.0〜1.0）を算出して行プロファイルを構築する
        def build_row_profile(mask)
          (0...mask.height).map do |y|
            row = mask.crop(0, y, mask.width, 1)
            row.avg / 255.0
          end
        end

        # 行プロファイルにガウシアン平滑化を適用してノイズを抑制する
        def smooth_profile(values, sigma:)
          sigma = [[sigma.to_f, MIN_PROFILE_SMOOTHING_SIGMA].max, MAX_PROFILE_SMOOTHING_SIGMA].min
          radius = [((sigma * 2).ceil), 1].max
          denom = 2.0 * sigma**2

          values.map.with_index do |_, index|
            total = 0.0
            weights = 0.0

            (-radius..radius).each do |offset|
              position = index + offset
              next if position.negative? || position >= values.length

              weight = Math.exp(-(offset**2) / denom)
              weights += weight
              total += values[position] * weight
            end

            weights.positive? ? total / weights : values[index]
          end
        end

        # 画像高さに応じたガウシアン平滑化のシグマ値を算出する
        def profile_smoothing_sigma(image_height)
          (image_height * PROFILE_SMOOTHING_SIGMA_RATIO).clamp(MIN_PROFILE_SMOOTHING_SIGMA, MAX_PROFILE_SMOOTHING_SIGMA)
        end

        # プロファイル値の平均と標準偏差を算出する
        def profile_statistics(values)
          return { average: 0.0, stddev: 0.0 } if values.empty?

          average = values.sum / values.length.to_f
          variance = values.sum { (it - average)**2 } / values.length.to_f
          { average:, stddev: Math.sqrt(variance) }
        end

        # 行プロファイルから閾値を超える連続領域を検出する
        # max_gap 以内のギャップは同一領域として結合し、min_height 未満の領域は除外する
        def find_regions_from_profile(profile, image_height, threshold: 0.5, max_gap:, min_height:)
          regions = []
          in_region = false
          start_y = 0
          gap = 0

          Array(profile).each_with_index do |value, y|
            if value.to_f >= threshold
              start_y = y unless in_region
              in_region = true
              gap = 0
            elsif in_region
              gap += 1
              next unless gap > max_gap

              height = y - start_y - gap + 1
              regions << { y: start_y, height: } if height >= min_height
              in_region = false
              gap = 0
            end
          end

          if in_region
            height = image_height - start_y
            regions << { y: start_y, height: } if height >= min_height
          end

          regions
        end

        # 検出した行領域から列活性度を分析し、IllustrationRegion を構築する
        # 面積比やアスペクト比で候補をフィルタリングする
        def build_foreground_region(mask, group, image_width, image_height)
          top = group.fetch(:y)
          height = group.fetch(:height)
          slice = mask.crop(0, top, image_width, height)
          active_columns = column_activity(slice, image_width, height)
          return nil if active_columns.empty?

          left = [active_columns.min - 8, 0].max
          right = [active_columns.max + 9, image_width].min
          width = right - left
          candidate = IllustrationRegion.new(left:, top: [top - 8, 0].max, width:, height: [height + 16, image_height - top].min)
          expanded = expand_illustration_region(candidate, image_width, image_height)
          return nil unless illustration_region_candidate?(expanded, image_width, image_height)

          area_ratio = (expanded.width * expanded.height).to_f / (image_width * image_height)
          return nil if area_ratio < MIN_ILLUSTRATION_AREA_RATIO

          expanded
        rescue StandardError
          nil
        end

        # マスク画像のスライスから前景活性のある列インデックスを収集する
        def column_activity(slice, image_width, height)
          (0...image_width).each_with_object([]) do |x, active|
            column = slice.crop(x, 0, 1, height)
            activity = column.avg / 255.0
            active << x if activity >= COLUMN_ACTIVITY_THRESHOLD
          end
        end

        # イラスト領域にパディングを追加して拡張する
        def expand_illustration_region(region, image_width, image_height)
          padding_x = [((region.width * 0.04).round), ((image_width * 0.01).round)].max
          padding_y = [((region.height * 0.02).round), ((image_height * 0.005).round)].max
          left = [region.left - padding_x, 0].max
          top = [region.top - padding_y, 0].max
          right = [region.left + region.width + padding_x, image_width].min
          bottom = [region.top + region.height + padding_y, image_height].min

          IllustrationRegion.new(left:, top:, width: [right - left, 1].max, height: [bottom - top, 1].max)
        end

        # 領域がイラストの候補として妥当か（サイズ・アスペクト比）を判定する
        def illustration_region_candidate?(region, image_width, image_height)
          return false unless region.width.positive? && region.height.positive?
          return false if region.width < image_width * 0.35
          return false if region.height < image_height * 0.08
          return false if region.width * region.height < image_width * image_height * 0.035

          aspect_ratio = region.width.to_f / region.height
          aspect_ratio >= 1.05 && aspect_ratio <= 2.4
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
        # 日本語スペース除去 → 断片結合 → 括弧正規化 → prh 辞書置換
        def postprocess_ocr_text(text)
          sanitized = sanitize(text)
          return "" if sanitized.empty?

          sanitized = collapse_ocr_japanese_spaces(sanitized)
          sanitized = collapse_fragmented_words(sanitized)
          sanitized = normalize_ocr_brackets(sanitized)
          sanitized = apply_prh_replacements(sanitized)
          sanitize(sanitized)
        end

        # --- OCR テキスト補正用の文字クラス正規表現 ---
        CJK_CHAR = /[\p{Han}\p{Hiragana}\p{Katakana}ー々〆ヵヶ]/.freeze
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

        # prh 辞書の置換ルールをテキストに適用する
        def apply_prh_replacements(text)
          prh_replacements.reduce(text.to_s) do |memo, (matcher, expected)|
            memo.gsub(matcher, expected)
          end
        end

        # config/textlint_prh.yml から prh 置換ルールを読み込む（メモ化）
        # 各ルールの patterns を Regexp にコンパイルし、[matcher, expected] の配列を返す
        def prh_replacements
          @prh_replacements ||= begin
            path = File.join(Dir.pwd, "config", "textlint_prh.yml")
            unless File.file?(path)
              []
            else
              data = YAML.safe_load(File.read(path, encoding: "UTF-8"), aliases: true) || {}
              Array(data["rules"]).flat_map do |rule|
                expected = rule["expected"].to_s
                next [] if expected.empty?

                Array(rule["patterns"]).filter_map do |pattern|
                  matcher = compile_prh_pattern(pattern)
                  matcher ? [matcher, expected] : nil
                end
              end
            end
          rescue StandardError
            []
          end
        end

        # prh パターンを Regexp にコンパイルする
        # "/pattern/" 形式は正規表現、それ以外はリテラルマッチ
        def compile_prh_pattern(pattern)
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
          languages = %w[jpn] if languages.empty?
          languages.uniq
        end

        # "japanese" → "jpn" など、エイリアスを Tesseract 言語コードに変換する
        def normalize_ocr_language_alias(value)
          case value.to_s.strip.downcase.tr("-", "_")
          in "" then ""
          in "japanese" then "jpn"
          in "japanese_vertical" then "jpn_vert"
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
end
