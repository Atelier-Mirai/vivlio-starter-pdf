# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.1] - 2026-03-21

### Added
- CLI 実装 (exe/vivlio-starter-pdf)
- --version/-v オプションでバージョン表示
- --help/-h オプションで使用方法と説明を表示
- エラーハンドリングと不明オプションの処理

### Improved
- ユーザー体験の向上（インストール後の動作確認可能）
- 標準的な CLI インターフェース準拠

## [1.0.0] - 2026-03-21

### 🎉 最初のメジャーリリース

vivlio-starter-pdf 1.0.0 としてリリース！HexaPDF を活用した高度な PDF 解析・後処理機能を提供する AGPL 拡張プラグインが完成しました。

### ✅ 実績と品質保証
- **vivlio-starter** Enhanced Mode での実稼働実績
- **高度な PDF 処理**: HexaPDF ベースの精密なテキスト・画像抽出
- **日本語 OCR 完全対応**: Tesseract 連携と誤読修正機能
- **画像位置合わせ**: テキスト行と画像の精密な座標マッピング

### 🚀 主要機能
- **PDF → Markdown 変換**: HexaPDF で高精度にテキスト・画像を抽出
- **OCR 連携**: スキャン PDF を自動検出し、日本語 OCR を実行
- **画像抽出**: PDF 内の XObject を解析し、WebP 形式で書き出し
- **OCR テキスト補正**: 日本語空白圧縮、括弧正規化、prh 辞書による誤読修正
- **隠しノンブル**: 入稿用 PDF の塗り足し領域にページ番号をオーバーレイ
- **PDF アウトライン**: HTML 見出しを解析し、PDF のブックマークツリーを構築

### 🔧 技術的特徴
- **Ruby 4.0+** モダン開発標準準拠
- **Data.define** を活用した型安全なデータ構造
- **HexaPDF** による高精度 PDF 解析
- **ruby-vips** による高速画像処理
- **AGPL-3.0** ライセンス（HexaPDF に準拠）

### 📚 ドキュメント整備
- 詳細な README と機能一覧
- 外部ツールの自動案内機能
- 設定例と API 使用例の充実

### 🔌 vivlio-starter 連携
- プラグイン専用設計でシームレスな統合
- Standard Mode から Enhanced Mode への自動切り替え
- 設定ファイルによる柔軟な制御

### 🌏 日本語特化機能
- Tesseract 日本語 OCR エンジン対応
- 日本語テキストの空白圧縮処理
- 括弧の正規化と誤読修正
- 出版向けの文字処理最適化

---

## [Unreleased]

### Planned
- パフォーマンス最適化（大規模 PDF 対応）
- 追加 OCR エンジン対応
- クラウド OCR サービス連携
- PDF 暗号化対応
