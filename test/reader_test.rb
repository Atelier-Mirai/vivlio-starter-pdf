# frozen_string_literal: true

require "open3"
require "tmpdir"
require "test_helper"

# Reader クラスのテストスイート
class ReaderTest < Minitest::Test
  # テスト用サンプル PDF のパス（テキスト埋め込み版）
  SAMPLE_PDF = File.expand_path("../../vivlio-starter/sources/three-elements-pages.pdf", __dir__)
  # テスト用サンプル PDF のパス（OCR 必須版）
  OCR_SAMPLE_PDF = File.expand_path("../../vivlio-starter/sources/three-elements-ocr.pdf", __dir__)

  # execute が page_texts と pages を正しく返すことを検証する
  def test_execute_returns_page_texts_and_pages_for_sample_pdf
    skip "sample pdf is not available" unless File.exist?(SAMPLE_PDF)
    skip "ImageMagick is not available" unless imagemagick_available?

    Dir.mktmpdir do |dir|
      result = VivlioStarter::Pdf::Reader.new(
        SAMPLE_PDF,
        page_separator: true,
        images_dir: dir,
        image_reference_dir: "images/10-three-elements-pages"
      ).execute

      assert_operator(result[:pages], :>=, 1)
      assert_kind_of(Array, result[:page_texts])
      assert_kind_of(Array, result[:page_chunks])
      assert_operator(result[:page_texts].length, :>=, 1)
      assert_equal(result[:page_texts].length, result[:page_chunks].length)
      assert_includes(result[:markdown], "プログラミング")
      assert_kind_of(Array, result[:images])
      refute_empty(result[:images])
      first_image = result[:images].first
      assert_equal(1, first_image[:page])
      assert_match(%r{\Aimages/10-three-elements-pages/}, first_image[:reference_path])
      assert_match(/\.webp\z/, first_image[:reference_path])
      assert_match(/\.webp\z/, first_image[:output_path])
      assert_includes(result[:markdown], "![](#{first_image[:reference_path]})")
      assert_match(/!\[\]\(images\/10-three-elements-pages\/page-001-image-01\.webp\)\z/, result[:page_chunks].first)
      assert(File.exist?(first_image[:output_path]))
    end
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

  # find_regions_from_profile が小さなギャップを跨いで行をグループ化することを検証する
  def test_find_regions_from_profile_groups_rows_across_small_gaps
    reader = VivlioStarter::Pdf::Reader.new(SAMPLE_PDF)
    profile = Array.new(40, 0) + Array.new(80, 1) + Array.new(12, 0) + Array.new(70, 1) + Array.new(60, 0)

    regions = reader.send(:find_regions_from_profile, profile, profile.length, max_gap: 20, min_height: 100)

    assert_equal(1, regions.length)
    assert_equal(40, regions.first.fetch(:y))
    assert_equal(162, regions.first.fetch(:height))
  end

  # illustration_region_candidate? が大きなイラスト形状を受け入れることを検証する
  def test_illustration_region_candidate_accepts_large_illustration_shape
    reader = VivlioStarter::Pdf::Reader.new(SAMPLE_PDF)
    region = VivlioStarter::Pdf::Reader::IllustrationRegion.new(left: 240.0, top: 420.0, width: 1480.0, height: 880.0)

    accepted = reader.send(:illustration_region_candidate?, region, 2480.0, 3509.0)

    assert_equal(true, accepted)
  end

  # illustration_region_candidate? がバナー状の横長領域を拒否することを検証する
  def test_illustration_region_candidate_rejects_banner_like_wide_regions
    reader = VivlioStarter::Pdf::Reader.new(SAMPLE_PDF)
    region = VivlioStarter::Pdf::Reader::IllustrationRegion.new(left: 160.0, top: 215.0, width: 2040.0, height: 505.0)

    accepted = reader.send(:illustration_region_candidate?, region, 2480.0, 3509.0)

    assert_equal(false, accepted)
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
    skip "ocr sample pdf is not available" unless File.exist?(OCR_SAMPLE_PDF)
    skip "OCR dependencies are not available" unless ocr_dependencies_available?
    skip "Vips is not available" unless vips_available?
    skip "ImageMagick is not available" unless imagemagick_available?

    Dir.mktmpdir do |dir|
      result = VivlioStarter::Pdf::Reader.new(
        OCR_SAMPLE_PDF,
        page_separator: true,
        images_dir: dir,
        image_reference_dir: "images/10-three-elements-ocr",
        ocr: { mode: "always", languages: ["jpn"], dpi: 300, psm: 3, inline_image_text: "include" }
      ).execute

      normalized_first_page = result[:page_texts].first.gsub(/[[:space:]]+/, "")
      normalized_second_page = result[:page_texts][1].gsub(/[[:space:]]+/, "")

      assert_equal(7, result[:pages])
      assert_includes(normalized_first_page, "ログラミング技術習得の三要素")
      assert_includes(normalized_second_page, "技術習得には次の三要素")
      refute_includes(result[:page_texts].first, "Detected ")
      refute_empty(result[:images])
      assert_includes(result[:markdown], "![](images/10-three-elements-ocr/")
      assert(File.exist?(result[:images].first[:output_path]))
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
