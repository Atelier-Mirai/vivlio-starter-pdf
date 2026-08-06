# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

### Planned
- パフォーマンス最適化（大規模 PDF 対応）
- 追加 OCR エンジン対応
- クラウド OCR サービス連携
- PDF 暗号化対応

## [1.1.2] - 2026-08-07

### Changed
- **必要な Ruby を 4.0 以上から 3.4 以上へ緩めた** (`vivlio-starter-pdf.gemspec`): Ruby 4.0 固有の機能は使っていない。Prism のバージョン指定パースで全 13 ファイルを解析したところ 4.0.0 / 3.4.0 / 3.3.0 いずれも構文エラー 0 件で、実際の下限を決めていたのは `it`（暗黙ブロック引数・38 箇所）**単独**だった。`it` は 3.3 でも構文エラーにならず実行時 `NameError` になる——静的解析では見つからないので、Ruby 3.4.10 で実走して全テスト通過を確認している。コード変更はゼロ（gemspec 1 行のみ）。本体 `vivlio-starter` の緩和に合わせたもので、本体だけ緩めてもプラグインが `>= 4.0` のままでは 3.4 環境に入らない。

### Fixed
- **壊れたアウトライン項目 1 件が、しおりを全滅させていたのを直した** (`outline_writer.rb`): 見出しのタイトルに不正な UTF-8 バイトが混ざると `String#strip` が `Encoding::CompatibilityError` を投げ、`add_outline!` の rescue まで飛んで **PDF からしおりが丸ごと消えていた**。範囲外ページ・空タイトル・深すぎる階層はいずれも `on_skip` で 1 件ずつ飛ばす設計なのに、ここだけ全体を巻き添えにしていた。
  - `add_outline!` は `false` を返すだけで PDF 自体は出来上がるため、**成果物を開くまで誰も気付けない**種類の失敗だった。
  - 該当項目だけを飛ばし、理由（`title is not valid UTF-8, skipping outline entry: …`）を `on_skip` で報告する。原稿のどの見出しを直せばよいか分かる形にした。
  - `EncodingError` と `ArgumentError` の両方を捕まえる。壊れたバイト列に Ruby がどちらを投げるかはメソッド次第で（`strip` は `Encoding::CompatibilityError`、`match?` は `ArgumentError`）、その差でしおりの有無が決まってはならない。
- **アウトライン項目に `nil` 以外の想定外の型が混ざると全体が止まっていたのを直した** (`outline_writer.rb`): `fetch` が `respond_to?(:[])` だけで添字アクセスしていたため、配列に `String` や `Integer` が紛れると `TypeError: no implicit conversion of Symbol into Integer`（`Integer#[]` はビット参照）で落ちていた。Hash 風オブジェクトは従来どおり受けつつ、添字アクセスの失敗は既定値へ倒す。

### Added
- **堅牢性テストを整備した** (`test/robustness/`): 本体 `vivlio-starter` の `test/vivlio_starter/robustness/` と同じ位置づけで 14 件を追加。守る約束は 2 つ——**公開 API は例外を外へ出さない**（ビルドパイプラインの途中から呼ばれるため、失敗は戻り値で伝える）、**失敗しても入力を壊さない**（読み込んだのと同じパスへ書き戻すため、途中失敗で元 PDF が切り詰められると最も気付きにくい事故になる）。上記 2 件の修正はこのテストを書く過程で見つかったもの。
  - `broken_pdf_test.rb` — PDF でないファイル・0 バイト・存在しないパス・暗号化 PDF・書き込み不可ファイル。戻り値と、**入力のバイト列が不変であること**を固定
  - `outline_entry_test.rb` — 壊れた項目を 1 件ずつ飛ばして残りを書くこと、飛ばした理由を報告すること、全滅時に空のしおりツリーを残さないこと

## [1.1.1] - 2026-06-23

### Fixed
- 隠しノンブルのフォントを埋め込み可能な TTF に変更（FT-02）。HexaPDF 組込の標準 14 フォント `Helvetica` は PDF に埋め込まれず、印刷所入稿で「非埋め込みフォント」事故になっていた。書籍プロジェクト直下に同梱の `stylesheets/fonts/hackgen35/HackGen35ConsoleNF-Regular.ttf` があれば `font.map` へ登録して使用し、数字グリフのみをサブセット埋め込みする（極小）。同梱フォントが無い場合は従来どおり `Helvetica` にフォールバックしてビルドは継続する。`EnhancedProviderTest` を追加。

## [1.1.0] - 2026-06-10

### Changed
- 本体側に合わせ、lib/vivlio_starter/cli/pdf/配下にファイル構成を調整した。

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
