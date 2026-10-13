# frozen_string_literal: true

# ================================================================
# File: test/fixtures/build_fixtures.rb
# ================================================================
# 用途:
#   統合テストが読む PDF を組み立てる。**生成物（sample.pdf）は repo に入れる**ので、
#   このスクリプトを走らせるのは中身を変えたいときだけでよい。
#
# なぜ生成物を置くのか:
#   かつて fixture は隣の repo（`../vivlio-starter/sources/*.pdf`）を指しており、
#   その PDF は**どこにも存在しなかった**。`File.exist?` が false を返して skip する
#   だけなので赤くはならず、**この gem の中核である reader.rb の通し経路は一度も
#   検証されないまま**だった。1.2.0 で直した OCR 補正の不具合も、それを捕まえる
#   はずのテストが走っていなかった。fixture を repo の中に置けば CI でも動く。
#
# なぜ Prawn で作るのか:
#   読む側が HexaPDF なので、作る側は別のライブラリにする。同じ実装で作って同じ
#   実装で読むと、その実装の癖が打ち消し合って検証から外れる。
#
# 書体:
#   HackGen35ConsoleNF（SIL OFL-1.1）。OFL は PDF への埋め込みと再配布を許すので、
#   生成した PDF を repo に置いてよい。既定では隣の vivlio-starter から借りるが、
#   VS_FIXTURE_FONT で上書きできる。
#
# 使い方:
#   bundle exec ruby test/fixtures/build_fixtures.rb
# ================================================================

require "prawn"
require "fileutils"
require "shellwords"
require "tmpdir"

FIXTURE_DIR = __dir__
FONT_PATH = ENV.fetch(
  "VS_FIXTURE_FONT",
  File.expand_path("../../../vivlio-starter/stylesheets/fonts/hackgen35/HackGen35ConsoleNF-Regular.ttf", __dir__)
)

abort "書体が見つかりません: #{FONT_PATH}（VS_FIXTURE_FONT で指定できます）" unless File.exist?(FONT_PATH)

# 埋め込む図版。中身は問われないので、小さく決まったものを作る。
# ImageMagick で作るのは、Ruby だけで PNG を組むより読み手に分かりやすいため。
def build_image(path)
  return path if File.exist?(path)

  unless system("magick -size 120x80 gradient:'#4a6fa5-#f0f4f8' #{path.shellescape}")
    abort "ImageMagick が要ります: brew install imagemagick"
  end
  path
end

image = build_image(File.join(FIXTURE_DIR, "figure.png"))

# --- 本文つき PDF（テキスト抽出・画像抽出の通し経路を見る） ---
#
# 1 ページ目に図版を置く。テストは「1 ページ目から画像が 1 枚取れ、markdown に
# ![](…webp) として現れる」を見るため、ここを崩すとテストの意味が変わる。
Prawn::Document.generate(File.join(FIXTURE_DIR, "sample.pdf"), page_size: [420, 595], margin: 40) do |pdf|
  pdf.font_families.update("HackGen" => { normal: FONT_PATH })
  pdf.font("HackGen")

  pdf.text "プログラミング技術習得の三要素", size: 16
  pdf.move_down 12
  pdf.image image, width: 120
  pdf.move_down 12
  pdf.text "プログラミングを学ぶということは、知識を蓄えることではありません。", size: 10
  pdf.move_down 6
  pdf.text "手を動かし、動くものを作り、そこから学び直すことの繰り返しです。", size: 10

  pdf.start_new_page
  pdf.text "第二章 読み書きする力", size: 16
  pdf.move_down 12
  pdf.text "文章を読む力と書く力は、コードを読む力と書く力に通じます。", size: 10
end

puts "作成しました: #{File.join(FIXTURE_DIR, 'sample.pdf')}"

# --- 文字レイヤーを持たない PDF（OCR 経路を見る） ---
#
# sample.pdf を画像へ焼き直して並べる。スキャンした紙と同じで、テキストは 1 文字も
# 入っていない。OCR を通さない限り何も取り出せないので、OCR 経路だけを切り出せる。
scanned = File.join(FIXTURE_DIR, "scanned.pdf")
Dir.mktmpdir do |work|
  base = File.join(work, "page")
  unless system("pdftoppm", "-r", "150", "-png", File.join(FIXTURE_DIR, "sample.pdf"), base)
    abort "poppler が要ります: brew install poppler"
  end

  pages = Dir.glob("#{base}-*.png").sort
  abort "ページ画像を作れませんでした" if pages.empty?

  Prawn::Document.generate(scanned, page_size: [420, 595], margin: 0) do |pdf|
    pages.each_with_index do |png, index|
      pdf.start_new_page if index.positive?
      pdf.image png, position: :center, vposition: :center, fit: [420, 595]
    end
  end
end

puts "作成しました: #{scanned}"

# --- 文字が 1 字ずつ離れた文字レイヤーを持つ PDF（OCR 補正の経路を見る） ---
#
# スキャン紙を OCR にかけ、その結果を文字レイヤーとして埋め戻した PDF は、この形に
# なる。読み取ると「で す。 日 本語 を 自然 に」のように字の間に空白が入るので、
# そのまま Markdown にすると読めない。collapse_ocr_japanese_spaces と
# collapse_fragmented_words が詰め直す担当だが、**どちらもテストから一度も
# 呼ばれていなかった**（実物の PDF がここに無かったため）。
#
# 実際の OCR 出力を見て形を写した。字の間に空白を撒き、括弧は半角で置く。
# **1 行が版面に収まる長さにする。** はみ出すと Prawn が折り返し、読み取り側の
# 行まとめと絡んで「補正が効いたのか、折り返しがそう見せたのか」が分からなくなる。
# ここで見たいのは詰め直しだけなので、要因を 1 つに絞る。
FRAGMENTED_LINES = [
  "日 本 語 を 自 然 に 使 い こ な せ ま す。",
  "H T M L や CS S の 文 法 も 身 に つ き ま す。",
  "(何 が で き る の か) を 理 解 し ま す。"
].freeze

fragmented = File.join(FIXTURE_DIR, "fragmented.pdf")
Prawn::Document.generate(fragmented, page_size: [420, 595], margin: 40) do |pdf|
  pdf.font_families.update("HackGen" => { normal: FONT_PATH })
  pdf.font("HackGen")

  FRAGMENTED_LINES.each do |line|
    pdf.text line, size: 10
    pdf.move_down 6
  end
end

puts "作成しました: #{fragmented}"
