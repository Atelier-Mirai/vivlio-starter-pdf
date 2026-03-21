# vivlio-starter-pdf 1.0.0 Release Note

## 🎉 最初のメジャーリリース

vivlio-starter-pdf 1.0.0 をリリースできることを大変嬉しく思います。これは **vivlio-starter** の AGPL 拡張プラグインで、HexaPDF を活用した高度な PDF 解析・後処理機能を提供します。

## 🚀 主要機能

### PDF → Markdown 変換
- HexaPDF でテキスト・画像を高精度に抽出
- 精密な座標解析による行・段落の再構成
- Markdown 形式での構造化出力

### OCR 連携と日本語対応 🆕
- スキャン PDF を自動検出
- Tesseract による日本語 OCR 実行
- OCR テキストの空白圧縮と括弧正規化
- prh 辞書による誤読修正

### 画像抽出と位置合わせ
- PDF 内の XObject を解析し、WebP 形式で書き出し
- テキスト行と画像の精密な座標マッピング
- イラスト領域の自動検出と除外

### 出版向け機能
- **隠しノンブル**: 入稿用 PDF の塗り足し領域にページ番号をオーバーレイ
- **PDF アウトライン**: HTML 見出しを解析し、PDF のブックマークツリーを構築

## 📦 インストール

```ruby
# Gemfile
gem 'vivlio-starter-pdf', '~> 1.0.0'
```

```bash
bundle install
```

### 外部ツール（OCR 利用時）

```bash
brew install tesseract tesseract-lang poppler vips
```

## 💡 使用例

### vivlio-starter との連携（プラグイン専用）

```bash
# Enhanced Mode で自動的に HexaPDF/OCR パイプラインを使用
vs pdf:read document.pdf
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

## 🔧 設定

`config/book.yml` の `pdf_read` セクションで挙動を制御：

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

## ✅ テスト品質

- **網羅的なテストスイート**
- **実環境での動作検証**
- **外部ツール連携のテスト**

## 🔄 0.1.0 からの変更点

### 新機能
- 完全な OCR 連携と日本語対応
- 画像位置合わせの精密化
- PDF アウトライン生成機能
- 隠しノンブル機能

### 改善
- gemspec の RubyGems 公開設定
- ドキュメントの整備
- 外部ツールの自動案内

## 🎯 実績

- **vivlio-starter** Enhanced Mode で実稼働
- **日本語出版** 向けの最適化完了
- **HexaPDF** との高度な連携実現
- **AGPL-3.0** ライセンス準拠

## 📋 互換性

- **Ruby**: 4.0+
- **依存**: hexapdf (~> 1.0), ruby-vips (~> 2.2)
- **外部ツール**: Tesseract, poppler, libvips（OCR 使用時）
- **セマンティックバージョニング**: 1.x.x 系は後方互換性を保証

## 🙏 感謝

vivlio-starter-pdf の開発にあたり、HexaPDF の強力な PDF 処理能力と、日本語出版の現場でのニーズが大きな助けとなりました。特に OCR 連携と日本語テキスト処理についての知見は、本プラグインをより実用的なものにする上で不可欠でした。

---

**vivlio-starter-pdf 1.0.0**: 高度な PDF 処理のための強力な拡張プラグイン
