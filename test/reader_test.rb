# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"
require "test_helper"

# Reader クラスのテストスイート
class ReaderTest < Minitest::Test
  # 統合テスト用の PDF。**repo に同梱してある**（test/fixtures/build_fixtures.rb が作る）。
  # かつては隣の repo を指しており、その PDF は存在しないので常に skip していた。
  SAMPLE_PDF = File.expand_path("fixtures/sample.pdf", __dir__)
  # 文字レイヤーを持たない PDF。OCR を通さない限り 1 文字も取り出せない
  OCR_SAMPLE_PDF = File.expand_path("fixtures/scanned.pdf", __dir__)
  # OCR 結果を文字レイヤーとして埋め戻した PDF（字の間に空白が入っている）
  FRAGMENTED_PDF = File.expand_path("fixtures/fragmented.pdf", __dir__)

  # execute が page_texts と pages を正しく返すことを検証する
  def test_execute_returns_page_texts_and_pages_for_sample_pdf
    skip "ImageMagick is not available" unless imagemagick_available?

    Dir.mktmpdir do |dir|
      result = VivlioStarter::Pdf::Reader.new(
        SAMPLE_PDF,
        page_separator: true,
        images_dir: dir,
        image_reference_dir: "images/sample"
      ).execute

      assert_equal(2, result[:pages])
      assert_kind_of(Array, result[:page_texts])
      assert_kind_of(Array, result[:page_chunks])
      assert_operator(result[:page_texts].length, :>=, 1)
      assert_equal(result[:page_texts].length, result[:page_chunks].length)
      assert_includes(result[:markdown], "プログラミング")
      assert_kind_of(Array, result[:images])
      refute_empty(result[:images])
      first_image = result[:images].first
      assert_equal(1, first_image[:page])
      assert_match(%r{\Aimages/sample/}, first_image[:reference_path])
      assert_match(/\.webp\z/, first_image[:reference_path])
      assert_match(/\.webp\z/, first_image[:output_path])
      assert_includes(result[:markdown], "![](#{first_image[:reference_path]})")
      assert_match(%r{!\[\]\(images/sample/page-001-image-01\.webp\)}, result[:page_chunks].first)
      assert(File.exist?(first_image[:output_path]))
    end
  end

# OCR 結果を埋め戻した PDF は、字の間に空白が入る。そのまま Markdown にすると
# 読めないので、読み取りの途中で詰め直す（collapse_ocr_japanese_spaces /
# collapse_fragmented_words / normalize_ocr_brackets）。
#
# **この 3 つは、どのテストからも呼ばれていなかった。** 実物の PDF が repo に
# 無く、通し経路のテストが skip し続けていたためである。
def test_execute_collapses_spaces_scattered_between_characters
  text = VivlioStarter::Pdf::Reader.new(FRAGMENTED_PDF).execute[:page_texts].first

  assert_includes(text, "日本語を自然に使いこなせます。")
  # 英字の断片も詰める。CSS が "CS S" のまま残らないこと
  assert_includes(text, "HTMLやCSS")
  # CJK を含む半角括弧は全角へ寄せる
  assert_includes(text, "（何ができるのか）")
  refute_match(/日 本 語/, text)
end

  # OCR auto モードが断片化したテキストに対して Tesseract 出力を優先することを検証する
  def test_ocr_auto_prefers_tesseract_output_for_fragmented_text
    reader = VivlioStarter::Pdf::Reader.new(SAMPLE_PDF)
    content = VivlioStarter::Pdf::Reader::PageContent.new(
      text: "プ ロ グ ラ ミ ン グ を 学 ぶ と い う こ と は 単 に コ ー ド の 書 き 方 を 覚 え る こ と で は あ り ま せ ん",
      lines: [],
      image_occurrences: []
    )

    reader.stub :ocr_dependencies_ready?, true do
      reader.stub :ocr_page_result, VivlioStarter::Pdf::Reader::OcrResult.new(
        text: "プログラミングを学ぶということ",
        lines: [],
        blocks: [],
        source_image_path: "/tmp/page.png",
        image_width: 2480,
        image_height: 3509,
        temp_dir: nil
      ) do
        resolution = reader.send(:resolve_page_content, Object.new, 0, content)

        assert_equal(true, resolution.ocr_applied)
        assert_equal("プログラミングを学ぶということ", resolution.content.text)
      end
    end
  end

  # normalize_ocr がユーザーフレンドリーな言語エイリアスを受け入れることを検証する
  def test_normalize_ocr_accepts_user_friendly_language_aliases
    reader = VivlioStarter::Pdf::Reader.new(
      SAMPLE_PDF,
      ocr: { languages: %w[japanese japanese_vertical eng], inline_image_text: "captionize" }
    )

    normalized = reader.instance_variable_get(:@ocr)

    assert_equal(%w[jpn jpn_vert eng], normalized.languages)
    assert_equal(:captionize, normalized.inline_image_text)
  end

  # english は eng に読み替える。言語を書かなければ日本語と英語で読む
  def test_should_read_english_alias_and_default_to_japanese_and_english
    english = VivlioStarter::Pdf::Reader.new(SAMPLE_PDF, ocr: { languages: %w[japanese english] })
    default = VivlioStarter::Pdf::Reader.new(SAMPLE_PDF, ocr: {})

    assert_equal(%w[jpn eng], english.instance_variable_get(:@ocr).languages)
    assert_equal(%w[jpn eng], default.instance_variable_get(:@ocr).languages)
  end

  # apply_inline_image_text_policy が exclude モードで画像内の行を除外することを検証する
  def test_apply_inline_image_text_policy_excludes_lines_inside_images
    reader = VivlioStarter::Pdf::Reader.new(SAMPLE_PDF, ocr: { inline_image_text: "exclude" })
    lines = [
      VivlioStarter::Pdf::Reader::Line.new(y: 700.0, text: "本文行"),
      VivlioStarter::Pdf::Reader::Line.new(y: 420.0, text: "図中テキスト")
    ]
    images = [
      VivlioStarter::Pdf::Reader::ImageAsset.new(
        page: 1,
        index: 1,
        filename: "image.webp",
        output_path: "/tmp/image.webp",
        reference_path: "images/sample/image.webp",
        x: 100.0,
        top: 450.0,
        bottom: 380.0,
        center_y: 415.0,
        left: 40.0,
        right: 160.0,
        width: 120.0,
        height: 70.0
      )
    ]

    kept_lines, captions = reader.send(:apply_inline_image_text_policy, lines, images)

    assert_equal(["本文行"], kept_lines.map(&:text))
    assert_equal({}, captions)
  end

  # apply_inline_image_text_policy が captionize モードで画像内の行をキャプション化することを検証する
  def test_apply_inline_image_text_policy_captionizes_lines_inside_images
    reader = VivlioStarter::Pdf::Reader.new(SAMPLE_PDF, ocr: { inline_image_text: "captionize" })
    lines = [
      VivlioStarter::Pdf::Reader::Line.new(y: 700.0, text: "本文行"),
      VivlioStarter::Pdf::Reader::Line.new(y: 420.0, text: "あなただけの 主題 を。")
    ]
    images = [
      VivlioStarter::Pdf::Reader::ImageAsset.new(
        page: 1,
        index: 1,
        filename: "image.webp",
        output_path: "/tmp/image.webp",
        reference_path: "images/sample/image.webp",
        x: 100.0,
        top: 450.0,
        bottom: 380.0,
        center_y: 415.0,
        left: 40.0,
        right: 160.0,
        width: 120.0,
        height: 70.0
      )
    ]

    kept_lines, captions = reader.send(:apply_inline_image_text_policy, lines, images)

    assert_equal(["本文行"], kept_lines.map(&:text))
    assert_equal("あなただけの 主題 を。", captions.fetch("images/sample/image.webp"))
  end

  # build_page_chunk が行なしで画像がある場合にフォールバックテキストを保持することを検証する
  def test_build_page_chunk_keeps_fallback_text_when_images_exist_without_lines
    reader = VivlioStarter::Pdf::Reader.new(SAMPLE_PDF)
    image = VivlioStarter::Pdf::Reader::ImageAsset.new(
      page: 1,
      index: 1,
      filename: "image.webp",
      output_path: "/tmp/image.webp",
      reference_path: "images/sample/image.webp",
      x: 100.0,
      top: 450.0,
      bottom: 380.0,
      center_y: 415.0,
      left: 40.0,
      right: 160.0,
      width: 120.0,
      height: 70.0
    )

    chunk = reader.send(:build_page_chunk, [], [image], "OCR 本文")

    assert_equal("![](images/sample/image.webp)\n\nOCR 本文", chunk)
  end

  # filtered_image_occurrences がフルページスキャン画像を除外することを検証する
  def test_filtered_image_occurrences_excludes_full_page_scan_images
    reader = VivlioStarter::Pdf::Reader.new(SAMPLE_PDF)
    page = Class.new do
      def [](key) = key == :MediaBox ? [0.0, 0.0, 600.0, 800.0] : nil
    end.new
    full_page = VivlioStarter::Pdf::Reader::ImageOccurrence.new(
      x: 300.0,
      top: 790.0,
      bottom: 10.0,
      center_y: 400.0,
      left: 10.0,
      right: 590.0,
      width: 580.0,
      height: 780.0,
      object: Object.new
    )
    small_image = VivlioStarter::Pdf::Reader::ImageOccurrence.new(
      x: 300.0,
      top: 500.0,
      bottom: 350.0,
      center_y: 425.0,
      left: 120.0,
      right: 420.0,
      width: 300.0,
      height: 150.0,
      object: Object.new
    )

    filtered = reader.send(:filtered_image_occurrences, page, [full_page, small_image], suppress_full_page_scans: true)

    assert_equal([small_image], filtered)
  end

  # filtered_image_occurrences が include モードでフルページスキャンをフォールバックとして保持することを検証する
  def test_filtered_image_occurrences_keeps_full_page_scan_as_fallback_for_include
    reader = VivlioStarter::Pdf::Reader.new(SAMPLE_PDF, ocr: { inline_image_text: "include" })
    page = Class.new do
      def [](key) = key == :MediaBox ? [0.0, 0.0, 600.0, 800.0] : nil
    end.new
    full_page = VivlioStarter::Pdf::Reader::ImageOccurrence.new(
      x: 300.0,
      top: 790.0,
      bottom: 10.0,
      center_y: 400.0,
      left: 10.0,
      right: 590.0,
      width: 580.0,
      height: 780.0,
      object: Object.new
    )

    filtered = reader.send(:filtered_image_occurrences, page, [full_page], suppress_full_page_scans: true)

    assert_equal([], filtered)
  end

  # 図は、紙より濃い画素と色の付いた画素のまとまりで見つける。OCR で読めた文字の行は消してから探すので、
  # 本文は図にならない。小さな札（見出しの帯の色の札）と、ページの端に接する帯（飾り）も図にしない
  def test_should_find_figures_but_not_text_labels_or_edge_bands
    skip "Vips is not available" unless vips_available?

    reader = VivlioStarter::Pdf::Reader.new(SAMPLE_PDF)
    page = { MediaBox: [0, 0, 595.0, 842.0] }
    vips = reader.send(:require_vips!)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "page.png")
      canvas = vips::Image.black(2480, 3508, bands: 3).new_from_image([245, 245, 240])
      canvas = canvas.draw_rect([90, 60, 40], 500, 700, 1000, 600, fill: true)    # 写真（約 240pt × 144pt）
      canvas = canvas.draw_rect([30, 30, 30], 300, 2000, 1800, 300, fill: true)   # 字を読めた範囲（432pt × 72pt）
      canvas = canvas.draw_rect([20, 150, 140], 300, 2400, 200, 120, fill: true)  # 見出しの色の札（48pt × 29pt）
      canvas = canvas.draw_rect([230, 60, 80], 0, 0, 2480, 200, fill: true)       # ページ上端の飾りの帯
      canvas.write_to_file(path)
      # 字を読めた範囲（画像の 1px は 0.24pt）を、確信度の高い語として渡す。消さなければ図になる大きさ
      words = [VivlioStarter::Pdf::Reader::OcrWord.new(text: "本文", x: 70.0, y: 290.0, width: 435.0, size: 74.0, conf: 95.0)]

      regions = reader.send(:extract_illustration_regions_vips, path, words, page)

      assert_equal(1, regions.size)
      region = regions.first
      assert_in_delta(500, region.left, 16)
      assert_in_delta(700, region.top, 16)
      assert_in_delta(1000, region.width, 16)
      assert_in_delta(600, region.height, 16)
    end
  end

  # 白地の多い絵（細い線の格子）は、埋まった列・行が飛び飛びで、枠を削ると消える。削る前の枠を採る
  def test_should_keep_whole_box_of_sparse_illustration
    skip "Vips is not available" unless vips_available?

    reader = VivlioStarter::Pdf::Reader.new(SAMPLE_PDF)
    vips = reader.send(:require_vips!)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "page.png")
      canvas = vips::Image.black(2480, 3508, bands: 3).new_from_image([245, 245, 240])
      (0..30).each { canvas = canvas.draw_rect([40, 40, 40], 500 + (it * 32), 1000, 8, 640, fill: true) } # 縦の線（約 230pt × 154pt）
      (0..20).each { canvas = canvas.draw_rect([40, 40, 40], 500, 1000 + (it * 32), 968, 8, fill: true) } # 横の線
      canvas.write_to_file(path)

      regions = reader.send(:extract_illustration_regions_vips, path, [], { MediaBox: [0, 0, 595.0, 842.0] })

      assert_equal(1, regions.size)
      assert_in_delta(500, regions.first.left, 16)
      assert_in_delta(968, regions.first.width, 16)
      assert_in_delta(648, regions.first.height, 16)
    end
  end

  # 本体と book.yml は OCR を切る値を disable と書く。以前は disable を知らず :auto にしていた
  def test_should_accept_disable_as_ocr_off
    %w[disable disabled never off].each do |value|
      assert_equal(:never, VivlioStarter::Pdf::Reader.new(SAMPLE_PDF, ocr: { mode: value }).send(:ocr_mode), value)
    end
  end

  # 資源に無い色空間（dvipdfmx の `/CS0 cs`）のような 1 つの命令の失敗で、ページの読み取りを止めない。
  # 以前はページの画像の位置も捨て、OCR を切っても画像が 0 枚になった（切らなければ全ページを OCR した）
  def test_should_keep_images_on_page_with_broken_operator
    skip "ImageMagick が無い" unless imagemagick_available?

    Dir.mktmpdir do |dir|
      png = File.join(dir, "figure.png")
      system("magick", "-size", "120x80", "xc:steelblue", png)
      pdf = File.join(dir, "broken.pdf")
      document = HexaPDF::Document.new
      page = document.pages.add([0, 0, 595, 842])
      page.canvas.image(png, at: [100, 500], width: 240)
      page.contents = "/CS0 cs 0 0 0 sc\n#{page.contents}"
      document.write(pdf)
      reader = VivlioStarter::Pdf::Reader.new(pdf, images_dir: File.join(dir, "images"), ocr: { mode: "disable" })

      result = reader.stub(:run_tesseract, ->(*) { flunk "OCR を切ったのに Tesseract を呼んだ" }) { reader.execute }

      assert_equal(["page-001-image-01.webp"], result[:images].map { it[:filename] })
    end
  end

  # ocr_image_occurrences が埋め込み画像がない場合に vips を使用することを検証する
  def test_ocr_image_occurrences_uses_vips_when_embedded_images_are_absent
    reader = VivlioStarter::Pdf::Reader.new(SAMPLE_PDF)
    page = Class.new do
      def [](key) = key == :MediaBox ? [0.0, 0.0, 600.0, 800.0] : nil
    end.new
    result = VivlioStarter::Pdf::Reader::OcrResult.new(
      text: "",
      lines: [],
      blocks: [],
      source_image_path: "/tmp/page.png",
      image_width: 2480,
      image_height: 3509,
      temp_dir: nil
    )
    region = VivlioStarter::Pdf::Reader::IllustrationRegion.new(left: 568, top: 583, width: 1312, height: 721)

    reader.stub :scanned_page_image?, false do
      reader.stub :extract_illustration_regions_vips, [region] do
        occurrences = reader.send(:ocr_image_occurrences, page, [], result)

        assert_equal(1, occurrences.length)
        assert_instance_of(VivlioStarter::Pdf::Reader::RenderedPageCrop, occurrences.first.object)
      end
    end
  end

  # execute がスキャン PDF から OCR でテキストを抽出することを検証する（統合テスト）
  def test_execute_extracts_text_from_scanned_pdf_with_ocr
    skip "OCR dependencies are not available" unless ocr_dependencies_available?
    skip "Vips is not available" unless vips_available?
    skip "ImageMagick is not available" unless imagemagick_available?

    Dir.mktmpdir do |dir|
      result = VivlioStarter::Pdf::Reader.new(
        OCR_SAMPLE_PDF,
        page_separator: true,
        images_dir: dir,
        image_reference_dir: "images/scanned",
        ocr: { mode: "always", languages: ["jpn"], dpi: 300, psm: 3, inline_image_text: "include" }
      ).execute

      normalized_first_page = result[:page_texts].first.gsub(/[[:space:]]+/, "")
      normalized_second_page = result[:page_texts][1].gsub(/[[:space:]]+/, "")

      assert_equal(2, result[:pages])
      # 1 ページ目は読み取りが安定している。2 ページ目は OCR が崩しがちなので、
      # 何かしら日本語が取れたことだけを見る（OCR の精度はここで測るものではない）
      assert_includes(normalized_first_page, "プログラミング技術習得の三要素")
      assert_match(/\p{Han}|\p{Hiragana}|\p{Katakana}/, normalized_second_page)
      refute_includes(result[:page_texts].first, "Detected ")
      # **ページ全面のスキャン画像は図版として出さない。** それはページそのものであって
      # 図ではなく、Markdown に貼ると本文と同じ内容が二重になる
      # （suppress_full_page_scans: resolution.ocr_applied）。ページの中の図（見出しの下の青い四角）だけを
      # 切り出す（extract_illustration_regions_vips）
      assert_equal([1], result[:images].map { it[:page] })
      assert_operator(result[:images].first[:width], :<, 420 * 0.5)
      assert_includes(result[:markdown], "![](images/scanned/page-001-image-01.webp)")
    end
  end

  # スキャンのページは、ページを描き直さずに埋め込みの画像を読む。
  # 描き直し（pdftoppm）は 300dpi・A4 の JPEG で 1 ページ 23 秒かかり、読み取りの時間のほぼすべてだった。
  # scanned.pdf の画像は幅 875px と画素が足りないので、vips で 1,600px まで拡大してから読む
  def test_should_read_embedded_scan_image_without_rendering_page
    skip "OCR dependencies are not available" unless ocr_dependencies_available?
    skip "Vips is not available" unless vips_available?

    reader = VivlioStarter::Pdf::Reader.new(OCR_SAMPLE_PDF, ocr: { mode: "always", languages: ["jpn"], psm: 3 })
    document = HexaPDF::Document.open(OCR_SAMPLE_PDF)
    page = document.pages.first
    occurrences = reader.send(:extract_page_content, page, 0).image_occurrences

    result = reader.stub(:ocr_render_command, ->(*) { flunk "ページを描き直した（pdftoppm を呼んだ）" }) do
      reader.send(:ocr_page_result, page, 0, occurrences)
    end

    assert_equal(VivlioStarter::Pdf::Reader::MIN_OCR_IMAGE_WIDTH, result.image_width)
    assert_includes(result.text.gsub(/[[:space:]]+/, ""), "プログラミング技術習得の三要素")
  ensure
    reader&.send(:cleanup_ocr_temp_dir, result&.temp_dir)
  end

  # 画像の配置を整数で書いた PDF でも、スキャンのページと見分ける。
  # 座標が Integer で来ると縦横比の割り算が 0 になり、実物のスキャン PDF（1290×1916pt に
  # 1720×2555px）が描き直しへ落ちていた。Prawn で作る fixture は小数で置くので表に出なかった
  def test_should_detect_scanned_page_when_image_is_placed_with_integer_coordinates
    reader = VivlioStarter::Pdf::Reader.new(OCR_SAMPLE_PDF)
    page = HexaPDF::Document.open(OCR_SAMPLE_PDF).pages.first
    image = reader.send(:extract_page_content, page, 0).image_occurrences.first.object
    occurrence = VivlioStarter::Pdf::Reader::ImageOccurrence.new(
      x: 210, top: 595, bottom: 0, center_y: 297, left: 0, right: 420, width: 420, height: 595, object: image
    )

    assert_same(image, reader.send(:embedded_scan_image, page, [occurrence]))
  end

  # ページの一部に置いた図版は、スキャンのページとして扱わない（描き直して読む）
  def test_should_not_treat_inline_figure_as_scanned_page
    reader = VivlioStarter::Pdf::Reader.new(SAMPLE_PDF)
    page = HexaPDF::Document.open(SAMPLE_PDF).pages.first
    occurrences = reader.send(:extract_page_content, page, 0).image_occurrences

    refute_empty(occurrences)
    assert_nil(reader.send(:embedded_scan_image, page, occurrences))
  end

  # OCR の誤認識補正が config/ocr_corrections.yml から読まれ、OCR テキストに当たることを検証する。
  # 以前はプロジェクトの prh 校正辞書（textlint_prh.yml）を見ており、改名後は表が空のまま
  # 気づかれずに素通りしていた。あわせて、当てすぎないこと（言語芸術・Al）も確かめる
  def test_postprocess_ocr_text_applies_corrections_from_project_config
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config", "ocr_corrections.yml"), <<~YAML)
        version: 1
        rules:
          - expected: 人工知能
            patterns:
              - 入工知能
          - expected: 語彙
            patterns:
              - /語芸(?!術)/
          - expected: プログラミング
            patterns:
              - /(?<![ァ-ヶー])ログラミング/
      YAML

      reader = VivlioStarter::Pdf::Reader.new("dummy.pdf")
      Dir.chdir(dir) do
        assert_equal("人工知能の研究", reader.send(:postprocess_ocr_text, "入工知能の研究"))
        assert_equal("語彙が豊かだ", reader.send(:postprocess_ocr_text, "語芸が豊かだ"))
        assert_equal("プログラミング入門", reader.send(:postprocess_ocr_text, "ログラミング入門"))

        assert_equal("言語芸術としての詩", reader.send(:postprocess_ocr_text, "言語芸術としての詩"),
                     "「語芸」を含むが別語なので直さない")
        assert_equal("アナログラミング", reader.send(:postprocess_ocr_text, "アナログラミング"),
                     "直前がカタカナなら「プ」の欠落ではない")
      end
    end
  end

  # 補正表が無いプロジェクト（1.0 より前の雛形）では、補正せずに素通りさせる
  def test_postprocess_ocr_text_passes_through_without_corrections_file
    Dir.mktmpdir do |dir|
      reader = VivlioStarter::Pdf::Reader.new("dummy.pdf")
      Dir.chdir(dir) do
        assert_equal("入工知能の研究", reader.send(:postprocess_ocr_text, "入工知能の研究"))
      end
    end
  end

  # 行の組み立ては何度呼んでも同じ結果を返す。extract_page_content が text と lines で
  # 2 回呼ぶため、1 回目が断片の文字列を書き換えると、2 回目の各行が
  # 「全文＋先頭の断片を欠いた全文」に膨らむ（vs build の PDF で全行がこうなっていた）。
  # Prawn で作る fixture は 1 行を 1 断片で描くので、通し経路のテストでは表に出なかった
  def test_should_build_same_lines_on_every_call_when_line_has_several_fragments
    collector = VivlioStarter::Pdf::Reader::PageTextCollector.new(nil, bounds: nil, line_merge_tolerance: 2.0)
    fragment = VivlioStarter::Pdf::Reader::Fragment
    collector.fragments.push(
      fragment.new(x: 72.0, right: 82.0, y: 700.0, text: +"挑"),
      fragment.new(x: 82.0, right: 92.0, y: 700.0, text: +"戦"),
      fragment.new(x: 92.0, right: 102.0, y: 700.0, text: +"状"),
      fragment.new(x: 72.0, right: 82.0, y: 680.0, text: +"次"),
      fragment.new(x: 82.0, right: 92.0, y: 680.0, text: +"行")
    )

    first = collector.lines.map(&:text)
    second = collector.lines.map(&:text)

    assert_equal(%w[挑戦状 次行], first)
    assert_equal(first, second)
    assert_equal("挑戦状\n次行", collector.text)
  end

  # OCR の語を PDF の座標（pt）で返す。本体はこれを字に割り、見出しや段落を推定する。
  # ベースラインと大きさは行（level 4）の枠から取り、同じ行の語の高さをそろえる
  def test_should_convert_ocr_words_to_page_coordinates
    reader = VivlioStarter::Pdf::Reader.new(SAMPLE_PDF)
    page = { MediaBox: [0, 0, 600, 800] }
    tsv = [
      %w[level page_num block_num par_num line_num word_num left top width height conf text],
      %w[1 1 0 0 0 0 0 0 1200 1600 -1],
      %w[4 1 1 1 1 0 100 200 400 40 -1],
      %w[5 1 1 1 1 1 100 210 120 30 95.5 光の],
      %w[5 1 1 1 1 2 230 200 60 40 88.0 波],
      %w[5 1 1 1 1 3 300 205 10 10 -1]
    ].map { it.join("\t") }.join("\n")

    words = reader.send(:extract_ocr_words, tsv, page)

    assert_equal(%w[光の 波], words.map(&:text))
    assert_equal([50.0, 115.0], words.map(&:x))
    assert_equal([680.0, 680.0], words.map(&:y))
    assert_equal([60.0, 30.0], words.map(&:width))
    assert_equal([20.0, 20.0], words.map(&:size))
    assert_equal({ text: "光の", x: 50.0, y: 680.0, width: 60.0, size: 20.0, conf: 95.5 }, words.first.to_h)
  end

  # 囲みの地の割合は、紙の明るさ（中央値）より 10〜60 暗い面の割合で測る
  def test_should_measure_tint_relative_to_paper_brightness
    reader = VivlioStarter::Pdf::Reader.new(SAMPLE_PDF)
    histogram = Array.new(256, 0)
    histogram[230] = 80 # 紙
    histogram[200] = 15 # 囲みの地（紙より 30 暗い）
    histogram[20] = 5   # 文字

    assert_in_delta(0.15, reader.send(:tint_ratio, histogram))
  end

  # 大津のしきい値は、文字と紙の明るさのあいだに来る
  def test_should_find_otsu_threshold_between_text_and_paper
    reader = VivlioStarter::Pdf::Reader.new(SAMPLE_PDF)
    histogram = Array.new(256, 0)
    histogram[30] = 20
    histogram[220] = 80

    assert_includes(30...220, reader.send(:otsu_threshold, histogram))
  end

  # 二度読みは、確信度の平均ではなく確信度の高い語の字数で選ぶ。平均で選ぶと、字を落とした読みを
  # 選ぶことがある（絵の本の 40 ページ: 平均は二値化が高いが、字は 433 → 325 に減る）
  def test_should_choose_reading_with_more_confident_characters
    reader = VivlioStarter::Pdf::Reader.new(SAMPLE_PDF)
    header = %w[level page_num block_num par_num line_num word_num left top width height conf text].join("\t")
    tsv = ->(*words) { [header, *words.map { |conf, text| ["5", *Array.new(9, "1"), conf, text].join("\t") }].join("\n") }
    many_words = tsv.(["85", "光の波を"], ["82", "追いかける"], ["60", "かすれ"])
    few_words = tsv.(["97", "光の"])

    assert_equal(9, reader.send(:confident_characters, many_words))
    assert_equal(2, reader.send(:confident_characters, few_words))
  end

  # OCR するページごとに経過を (ページ番号, ページ数) で知らせる。OCR しないページでは呼ばない
  def test_should_report_progress_for_pages_read_by_ocr
    calls = []
    reader = VivlioStarter::Pdf::Reader.new(SAMPLE_PDF, progress: ->(page, total) { calls << [page, total] })
    reader.instance_variable_set(:@page_count, 24)
    content = VivlioStarter::Pdf::Reader::PageContent.new(text: "", lines: [], image_occurrences: [])

    reader.stub :ocr_required_for_page?, ->(_page, _content) { true } do
      reader.stub :extract_page_ocr_content, [content, nil] do
        reader.send(:resolve_page_content, nil, 4, content)
      end
    end
    reader.stub :ocr_required_for_page?, false do
      reader.send(:resolve_page_content, nil, 5, content)
    end

    assert_equal([[5, 24]], calls)
  end

  # スキャンの解像度はページの幅から見積もり、400dpi を超えれば 300dpi へ縮めて読む。
  # 600dpi のまま読むと、字が大きすぎて読み違える（97 章で F 値 89.3% → 縮めて 90.6%）
  def test_should_downscale_scan_above_400dpi
    skip "Vips is not available" unless vips_available?

    reader = VivlioStarter::Pdf::Reader.new(SAMPLE_PDF)
    a4 = { MediaBox: [0, 0, 595.0, 842.0] }

    assert_in_delta(600.0, reader.send(:scan_dpi, a4, 4958), 0.5)
    assert_in_delta(96.0, reader.send(:scan_dpi, { MediaBox: [0, 0, 1290, 1916] }, 1720), 0.5)

    Dir.mktmpdir do |dir|
      path = File.join(dir, "page.png")
      reader.send(:require_vips!)::Image.black(1200, 1600).write_to_file(path)
      downscaled, width, height = reader.send(:downscale_for_ocr, path, 600.0, dir)

      assert_equal([600, 800], [width, height])
      assert(File.exist?(downscaled))
    end
  end

  # 文字だけのページ（囲みの地が少ない）は二度読みしない
  def test_should_read_once_when_page_has_little_tint
    skip "Vips is not available" unless vips_available?

    reader = VivlioStarter::Pdf::Reader.new(SAMPLE_PDF)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "page.png")
      reader.send(:require_vips!)::Image.black(200, 200).invert.write_to_file(path) # 真っ白な紙
      calls = 0

      reader.stub :run_tesseract, ->(*) { calls += 1 and ["", ""] } do
        assert_equal(["text", "tsv", path], reader.send(:second_reading, path, dir, "text", "tsv"))
      end
      assert_equal(0, calls)
    end
  end

  # 英字の語の連なりは、位置の重なる英語の読みの語で、確信度が高ければ差し替える。和文の語と、
  # 和文の語に重なる英語の読みの崩れた語は採らない。差し替えた語は元の行の番号を引き継ぐ
  def test_should_replace_latin_words_with_confident_english_reading
    reader = VivlioStarter::Pdf::Reader.new(SAMPLE_PDF)
    header = %w[level page_num block_num par_num line_num word_num left top width height conf text]
    japanese_english = [
      header,
      %w[4 1 2 1 3 0 100 200 600 40 -1],
      %w[5 1 2 1 3 1 100 200 40 40 70.0 #],
      %w[5 1 2 1 3 2 160 200 140 40 75.0 Gparam],
      %w[5 1 2 1 3 3 320 200 200 40 95.0 シミュレーション]
    ].map { it.join("\t") }.join("\n")
    english = [
      header,
      %w[4 1 7 1 1 0 100 200 600 40 -1],
      %w[5 1 7 1 1 1 100 200 40 40 90.0 #],
      %w[5 1 7 1 1 2 158 200 172 40 92.0 @param],
      %w[5 1 7 1 1 3 320 200 200 40 40.0 Va—a-a—]
    ].map { it.join("\t") }.join("\n")

    merged = reader.send(:parse_tsv_rows, reader.send(:merge_english_words, japanese_english, english))
    words = merged.select { it.level == "5" }

    assert_equal(%w[# @param シミュレーション], words.map(&:text))
    assert_equal([%w[1 2 1 3]] * 3, words.map(&:line_key))
    assert_equal([158.0, 142.0], [words[1].left, words[1].width]) # 枠は連なりの範囲（100〜300）に収める
  end

  # 食い違う語の英語の読みの確信度が低ければ（「11」を「lL」・35）、日本語＋英語の読みを残す
  def test_should_keep_reading_when_english_reading_is_not_confident
    reader = VivlioStarter::Pdf::Reader.new(SAMPLE_PDF)
    header = %w[level page_num block_num par_num line_num word_num left top width height conf text]
    japanese_english = [
      header,
      %w[4 1 1 1 1 0 100 200 300 40 -1],
      %w[5 1 1 1 1 1 100 200 80 40 95.0 1915年],
      %w[5 1 1 1 1 2 180 200 40 40 33.9 11],
      %w[5 1 1 1 1 3 220 200 40 40 96.0 月]
    ].map { it.join("\t") }.join("\n")
    english = [header, %w[5 1 1 1 1 1 182 200 38 40 35.5 lL]].map { it.join("\t") }.join("\n")

    merged = reader.send(:parse_tsv_rows, reader.send(:merge_english_words, japanese_english, english))

    assert_equal(%w[1915年 11 月], merged.select { it.level == "5" }.map(&:text))
  end

  # 英語での読み直しは、英字の語が ENGLISH_PAGE_WORDS 以上のページだけ。言語が英語だけなら読み直さない
  def test_should_read_english_again_only_on_pages_with_many_latin_words
    header = %w[level page_num block_num par_num line_num word_num left top width height conf text].join("\t")
    tsv = ->(count) { [header, *Array.new(count) { |i| ["5", "1", "1", "1", "1", i + 1, i * 50, 0, 40, 20, 90, "word#{i}"].join("\t") }].join("\n") }
    japanese = VivlioStarter::Pdf::Reader.new(SAMPLE_PDF, ocr: { languages: %w[jpn eng] })
    english_only = VivlioStarter::Pdf::Reader.new(SAMPLE_PDF, ocr: { languages: %w[eng] })
    calls = []

    [[japanese, 19], [japanese, 20], [english_only, 30]].each do |reader, count|
      reader.stub :run_tesseract, ->(_path, _base, languages:) { calls << [count, languages] and ["", tsv.(count)] } do
        reader.send(:english_reading, "page.png", "/tmp", tsv.(count))
      end
    end

    assert_equal([[20, ["eng"]]], calls)
  end

  # Tesseract が読み飛ばした範囲（語の無いブロック）は、接し合うものをまとめて読み直す範囲にする。
  # 小さいものと、すでに読めた語が覆っているもの（囲みの中の文が別のブロックで読めている）は除く
  def test_should_find_skipped_regions_to_read_again
    reader = VivlioStarter::Pdf::Reader.new(SAMPLE_PDF)
    header = %w[level page_num block_num par_num line_num word_num left top width height conf text]
    rows = [
      header,
      %w[2 1 1 0 0 0 400 1000 800 100 -1], # 表の見出しの行（罫線で区切られた）
      %w[2 1 2 0 0 0 400 1100 800 200 -1], # 表の本体。上のブロックと接する
      %w[2 1 3 0 0 0 400 2000 100 40 -1],  # 小さい
      %w[2 1 4 0 0 0 300 2500 1800 300 -1], # 囲み。中の文は別のブロック 5 で読めている
      %w[2 1 5 0 0 0 320 2520 1700 260 -1],
      %w[5 1 5 1 1 1 320 2520 1700 260 95 本文]
    ].map { it.join("\t") }.join("\n")
    parsed = reader.send(:parse_tsv_rows, rows)
    words = parsed.select { it.level == "5" }

    assert_equal([[400.0, 1000.0, 1200.0, 1300.0]], reader.send(:skipped_regions, parsed, words, 2480, 3508))
  end

  # 読み直しは、確信度の高い字が十分にあり、もとの読みより多いときだけ採る。その範囲の語は読み直した語で
  # 置き換え、位置は切り出した所からページの画素へ戻す
  def test_should_replace_words_in_region_read_again
    skip "Vips is not available" unless vips_available?

    reader = VivlioStarter::Pdf::Reader.new(SAMPLE_PDF)
    header = %w[level page_num block_num par_num line_num word_num left top width height conf text]
    page_tsv = [
      header,
      %w[2 1 1 0 0 0 400 1000 800 300 -1],
      %w[5 1 2 1 1 1 1000 1100 100 40 95 5.32]
    ].map { it.join("\t") }.join("\n")
    region_tsv = [
      header,
      %w[1 1 0 0 0 0 0 0 848 348 -1],
      %w[4 1 1 1 1 0 30 30 700 40 -1],
      %w[5 1 1 1 1 1 30 30 200 40 96 カリウム],
      %w[5 1 1 1 1 2 300 30 80 40 95 2.2],
      %w[5 1 1 1 1 3 600 30 100 40 94 5.32]
    ].map { it.join("\t") }.join("\n")

    Dir.mktmpdir do |dir|
      path = File.join(dir, "page.png")
      reader.send(:require_vips!)::Image.black(2480, 3508).invert.write_to_file(path)
      merged = reader.stub(:run_tesseract, ["", region_tsv]) { reader.send(:reread_skipped_regions, path, dir, page_tsv, { MediaBox: [0, 0, 595.0, 842.0] }) }
      words = reader.send(:parse_tsv_rows, merged).select { it.level == "5" }

      assert_equal(%w[カリウム 2.2 5.32], words.map(&:text))
      assert_equal([406.0, 1006.0], [words.first.left, words.first.top]) # 余白 24px を引いた (376, 976) から
      unreadable = [header, %w[1 1 0 0 0 0 0 0 848 348 -1], %w[5 1 1 1 1 1 30 30 200 40 35 Ze]].map { it.join("\t") }.join("\n")
      assert_equal(page_tsv, reader.stub(:run_tesseract, ["", unreadable]) { reader.send(:reread_skipped_regions, path, dir, page_tsv, { MediaBox: [0, 0, 595.0, 842.0] }) })
    end
  end

  # 行の並びが最も鋭く出る角度を傾きとする。読み取りは傾いたままの画像で済ませ、語の位置だけを回す。
  # 傾いた行を囲んだ行の枠は、傾きのぶん高く出ているので縮める。図を切り出す画像は、回して大きさを保つ
  def test_should_measure_skew_and_straighten_scan
    skip "Vips is not available" unless vips_available?

    reader = VivlioStarter::Pdf::Reader.new(SAMPLE_PDF)
    vips = reader.send(:require_vips!)
    lines = (0...40).map { |row| (vips::Image.black(1000, 12) + 255).embed(120, 100 + (row * 36), 1240, 1754) }.reduce(:|)
    page = (lines > 0).ifthenelse(30, 230).cast(:uchar)
    tilted = page.similarity(angle: 1.0, background: [230]).then { it.crop((it.width - 1240) / 2, (it.height - 1754) / 2, 1240, 1754) }

    assert_in_delta(-1.0, reader.send(:skew_angle, tilted), 0.1)
    assert_in_delta(0.0, reader.send(:skew_angle, page), 0.05)
    # 1 本目の帯（中心 620, 106）は、1° 傾けた画像では中心 (633.5, 106) にあり、帯を囲む行の枠は 1000 × sin 1° だけ高い
    tsv = [
      %w[level page_num block_num par_num line_num word_num left top width height conf text],
      %w[1 1 0 0 0 0 0 0 1240 1754 -1],
      %w[4 1 1 1 1 0 134 91 1000 30 -1],
      %w[5 1 1 1 1 1 584 100 100 12 95 帯]
    ].map { it.join("\t") }.join("\n")
    Dir.mktmpdir do |dir|
      path = File.join(dir, "page.png")
      tilted.write_to_file(path)
      straightened, rotated = reader.send(:straighten, path, tsv, dir)
      line, word = reader.send(:parse_tsv_rows, rotated).reject { it.level == "1" }

      assert_equal([1240, 1754], vips::Image.new_from_file(straightened).then { [it.width, it.height] })
      assert_in_delta(0.0, reader.send(:skew_angle, vips::Image.new_from_file(straightened)), 0.1)
      assert_in_delta(570, word.left, 1)
      assert_in_delta(100, word.top, 1)
      assert_in_delta(12.5, line.height, 1)
    end
  end

  # 確信度の低い行は傾きを戻して読み直し、和文が確信度高く読めたときだけ置き換える。位置は、切り出した
  # 所と傾きを戻したずれを引いてページの画素へ戻す。英字の行（コード）と、傾けずに切り出しても同じように
  # 読める行（和文の文字列を含むコードの行）は置き換えない
  def test_should_reread_slanted_line_with_unslanted_reading
    skip "Vips is not available" unless vips_available?

    reader = VivlioStarter::Pdf::Reader.new(SAMPLE_PDF, ocr: { "languages" => %w[jpn eng] })
    header = %w[level page_num block_num par_num line_num word_num left top width height conf text]
    page_tsv = [
      header,
      %w[4 1 1 1 1 0 400 1000 1200 60 -1],
      %w[5 1 1 1 1 1 400 1000 500 60 4 BROKE],
      %w[5 1 1 1 1 2 1000 1000 600 60 10 DIED,PREVI],
      %w[4 1 2 1 1 0 400 1200 1200 60 -1],
      %w[5 1 2 1 1 1 400 1200 1200 60 96 本文の行です。]
    ].map { it.join("\t") }.join("\n")
    line_tsv = [
      header,
      %w[1 1 0 0 0 0 0 0 1340 100 -1],
      %w[4 1 1 1 1 0 70 20 1180 60 -1],
      %w[5 1 1 1 1 1 70 20 1180 60 95 「現代の教育方法が、探究という」]
    ].map { it.join("\t") }.join("\n")
    code_tsv = line_tsv.sub("「現代の教育方法が、探究という」", "x+=delta*Math.cos(angle)")
    upright_tsv = line_tsv.sub("\t95\t", "\t30\t")
    # 傾けずに切り出した読み（-upright）と、傾きを戻した読みを返し分ける
    tesseract = ->(slanted, upright) { ->(image, *, **) { ["", image.include?("upright") ? upright : slanted] } }

    Dir.mktmpdir do |dir|
      path = File.join(dir, "page.png")
      reader.send(:require_vips!)::Image.black(2480, 3508).invert.write_to_file(path)
      merged = reader.stub(:run_tesseract, tesseract.(line_tsv, upright_tsv)) { reader.send(:reread_slanted_lines, path, dir, page_tsv) }
      words = reader.send(:parse_tsv_rows, merged).select { it.level == "5" }

      assert_equal(%w[本文の行です。 「現代の教育方法が、探究という」], words.map(&:text))
      # 切り出しの左上 (340, 980) に、語の位置 (70, 20) から傾きを戻したずれ（tan 12° × 行の中ほど 50px ≈ 11px）を引いて足す
      assert_equal([399.0, 1000.0], [words.last.left, words.last.top])
      assert_equal(page_tsv, reader.stub(:run_tesseract, tesseract.(code_tsv, upright_tsv)) { reader.send(:reread_slanted_lines, path, dir, page_tsv) })
      assert_equal(page_tsv, reader.stub(:run_tesseract, tesseract.(line_tsv, line_tsv)) { reader.send(:reread_slanted_lines, path, dir, page_tsv) })
    end
  end

  private

  # ImageMagick（magick または convert）が PATH 上で利用可能かを確認する
  def imagemagick_available?
    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
      %w[magick convert].any? do |command|
        path = File.join(dir, command)
        File.executable?(path) && !File.directory?(path)
      end
    end
  end

  # ruby-vips が利用可能かを確認する
  def vips_available?
    require "vips"
    true
  rescue StandardError
    false
  end

  # OCR に必要な依存関係（pdftoppm, tesseract, jpn 言語データ）が揃っているかを確認する
  def ocr_dependencies_available?
    commands_available?(%w[pdftoppm tesseract]) && tesseract_languages.include?("jpn")
  end

  # 複数のコマンドがすべて利用可能かを確認する
  def commands_available?(commands)
    commands.all? { command_available?(it) }
  end

  # 指定コマンドが PATH 上で利用可能かを確認する
  def command_available?(command)
    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
      path = File.join(dir, command)
      File.executable?(path) && !File.directory?(path)
    end
  end

  # Tesseract にインストール済みの言語一覧を取得する
  def tesseract_languages
    output, status = Open3.capture2e("tesseract", "--list-langs")
    return [] unless status.success?

    output.lines.map(&:strip)
  rescue StandardError
    []
  end
end
