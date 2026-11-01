# vivlio-starter-pdf

[![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL--3.0-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)
[![Ruby](https://img.shields.io/badge/Ruby-%3E%3D%203.4-red.svg)](https://www.ruby-lang.org/)

**vivlio-starter** の AGPL 拡張プラグイン。HexaPDF を活用した高度な PDF 解析・後処理機能を提供します。

## 概要

vivlio-starter 本体（MIT）が提供する Standard Mode を拡張し、以下の出版向け機能を追加します。

| 機能 | 説明 |
| --- | --- |
| **PDF → Markdown 変換** | HexaPDF でテキスト・画像を高精度に抽出し、Markdown に変換 |
| **画像抽出（WebP 化）** | PDF 内の XObject を解析し、WebP 形式で書き出し |
| **OCR 連携** | スキャン PDF を自動検出し、Tesseract で OCR を実行（既定は日本語と英語） |
| **OCR テキスト補正** | 日本語空白圧縮、括弧正規化、`config/ocr_corrections.yml` による誤読修正 |
| **PDF アウトライン** | 本体から渡された見出しの一覧をもとに、PDF のブックマークツリーを構築 |

## インストール

本体の導入スクリプトで Vivlio Starter をインストールした場合は、この gem と外部ツールも同時にインストールされています。追加の操作は必要ありません。

それ以外の方法で本体をインストールした場合は、次のコマンドを実行します。

```zsh
gem install vivlio-starter-pdf
vs doctor --fix
```

`vs doctor --fix` が、OCR と画像抽出に必要な外部ツール（[一覧](#外部ツール)）をインストールします。

## 使い方

### vivlio-starter との連携（プラグイン専用）

`vivlio-starter-pdf` は `vivlio-starter` の Enhanced Mode プラグインとしてのみ動作します。gem をインストールすると、`vs pdf:read` 実行時に HexaPDF / OCR ベースの拡張パイプラインへ自動切り替えされます。

```zsh
vs pdf:read document.pdf
```

本体はこの gem を require せず、実行ファイル `vivlio-starter-pdf read PDF key=value …` を別プロセスとして呼び、標準出力の JSON を受け取ります。AGPL のコードを MIT の本体へ取り込まないための分け方です。

標準（MIT）実装に戻して動作を比べたいときは、環境変数で無効化できます。

```zsh
VIVLIO_PDF_PLUGIN=disable vs build
```

### Ruby API

```ruby
require "vivlio_starter/pdf"

# PDF → Markdown 変換
result = VivlioStarter::Pdf::Reader.new("input.pdf",
  ocr: { mode: "auto", languages: ["jpn", "eng"], dpi: 300 }
).execute

# アウトライン付与
provider = VivlioStarter::Pdf::EnhancedProvider.new
provider.add_outline!(pdf_path, items, max_level: 3)

# ページ数
provider.page_count(pdf_path)
```

`add_outline!` は成功で `true`、失敗で `false` を返し、`page_count` は失敗で `nil` を返します。**例外は外へ出しません**（本体のビルドパイプラインの途中から呼ばれるため）。失敗しても入力 PDF は書き換えません。

`add_outline!` の `items` は `{ level:, text:, page: }` の配列です。`top:`（見出しの y 座標）を加えると、しおりの移動先がその位置になります。省くとページ全体が移動先になります。壊れた項目（不正な UTF-8 のタイトル・範囲外ページ・空タイトル）は 1 件ずつ飛ばして残りを書き込み、飛ばした理由をログに出します。

## 設定

`config/book.yml` の `pdf_read` セクションで挙動を制御できます。

```yaml
pdf_read:
  text_area:           # 柱が本文に混ざるときだけ、除く幅を mm で書く
    top_margin:
    bottom_margin:
    inner_margin:
    outer_margin:
  page_separator: false
  ocr:
    mode: auto
    languages:
      - japanese
      - english
    dpi: 300
    psm: 3
    inline_image_text: include
```

## 依存ライブラリ

| ライブラリ | バージョン | 用途 |
| --- | --- | --- |
| [HexaPDF](https://hexapdf.gettalong.org/) | ~> 1.0 | PDF 解析・編集 |
| [ruby-vips](https://github.com/libvips/ruby-vips) | ~> 2.2 | 高速画像処理 |

### 外部ツール

| ツール | 用途 |
| --- | --- |
| Tesseract、tesseract-lang | OCR エンジンと言語データ |
| poppler（pdftoppm、pdfimages） | PDF → 画像変換、HexaPDF が書き出せない画像の抽出 |
| libvips | 画像処理バックエンド |
| ImageMagick | 抽出した画像の WebP 変換 |

## 開発

```zsh
git clone https://github.com/Atelier-Mirai/vivlio-starter-pdf.git
cd vivlio-starter-pdf
bundle install
bundle exec rake        # rubocop（Lint / Security）+ 対応する全 Ruby でテスト
```

統合テストが読む PDF は `test/fixtures/` に同梱しています。中身を変えたいときだけ作り直してください（HackGen35 = SIL OFL-1.1 を埋め込みます）。

```zsh
bundle exec ruby test/fixtures/build_fixtures.rb
```

## ライセンス

[GNU Affero General Public License v3.0 (AGPL-3.0)](LICENSE)

vivlio-starter 本体（MIT）とは異なるライセンスです。HexaPDF の AGPL ライセンスに準拠しています。

## 作者

[Atelier Mirai](https://github.com/Atelier-Mirai)
