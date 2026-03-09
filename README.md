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
| **OCR 連携** | スキャン PDF を自動検出し、Tesseract で日本語 OCR を実行 |
| **OCR テキスト補正** | 日本語空白圧縮、括弧正規化、prh 辞書による誤読修正 |
| **隠しノンブル** | 入稿用 PDF の塗り足し領域にページ番号をオーバーレイ |
| **PDF アウトライン** | HTML 見出しを解析し、PDF のブックマークツリーを構築 |

## インストール

### gem としてインストール

```zsh
gem install vivlio-starter-pdf
```

### 外部ツール（OCR 利用時）

```zsh
brew install tesseract tesseract-lang poppler vips
```

## 使い方

### vivlio-starter との連携

インストールするだけで `vs pdf:read` が自動的に Enhanced Mode で動作します。

```zsh
vs pdf:read document.pdf
```

### スタンドアロン CLI

`vivlio-starter-pdf` は単体でも利用できます。

```zsh
# PDF からテキスト・画像を抽出（JSON 出力）
vivlio-starter-pdf read input.pdf

# 隠しノンブルを書き込み
vivlio-starter-pdf nombre output.pdf

# PDF にアウトライン（しおり）を付与
vivlio-starter-pdf outline output.pdf *.html --max-level=3
```

### Ruby API

```ruby
require "vivlio/starter/pdf"

# PDF → Markdown 変換
result = Vivlio::Starter::PDF::Reader.new("input.pdf",
  ocr: { mode: "auto", languages: ["jpn"], dpi: 300 }
).execute

# アウトライン付与
provider = Vivlio::Starter::Pdf::EnhancedProvider.new
provider.add_outline!(pdf_path, items, max_level: 3)

# 隠しノンブル
provider.stamp_nombre!(pdf_path, bleed_pt: 8.5)
```

## 設定

`config/book.yml` の `pdf_read` セクションで挙動を制御できます。

```yaml
pdf_read:
  text_area:
    top_margin: 18
    bottom_margin: 20
    inner_margin: 15
    outer_margin: 12
  page_separator: false
  ocr:
    mode: auto
    languages:
      - japanese
    dpi: 300
    psm: 3
    inline_image_text: include
```

## 依存ライブラリ

| ライブラリ | バージョン | 用途 |
| --- | --- | --- |
| [HexaPDF](https://hexapdf.gettalong.org/) | ~> 1.0 | PDF 解析・編集 |
| [ruby-vips](https://github.com/libvips/ruby-vips) | ~> 2.2 | 高速画像処理 |
| [Samovar](https://github.com/ioquatix/samovar) | ~> 2.2 | CLI フレームワーク |

### 外部ツール（任意）

| ツール | 用途 |
| --- | --- |
| Tesseract | OCR エンジン |
| poppler（pdftoppm） | PDF → 画像変換 |
| libvips | 画像処理バックエンド |

## 開発

```zsh
git clone https://github.com/Atelier-Mirai/vivlio-starter-pdf.git
cd vivlio-starter-pdf
bundle install
bundle exec rake test
```

## ライセンス

[GNU Affero General Public License v3.0 (AGPL-3.0)](LICENSE)

vivlio-starter 本体（MIT）とは異なるライセンスです。HexaPDF の AGPL ライセンスに準拠しています。

## 作者

[Atelier Mirai](https://github.com/Atelier-Mirai)
