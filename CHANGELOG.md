# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Planned
- パフォーマンス最適化（大規模 PDF 対応）
- 追加 OCR エンジン対応
- クラウド OCR サービス連携
- PDF 暗号化対応

## [1.2.0] - 2026-09-23

### Added
- **実行ファイルに `read` サブコマンドを足した** (`exe/vivlio-starter-pdf`): `vivlio-starter-pdf read PDF key=value …` で PDF を読み、`Reader#execute` の結果を JSON で標準出力へ書く。本体の `vs pdf:read` は Enhanced Mode でこの形を呼んでいたが、**実行ファイルは `--version` と `--help` しか知らず**、`Unknown option 'read'` で終わっていた。git 履歴を通して `read` は一度も無く、**Enhanced Mode は `vs` から一度も動いていなかった**（本体のテストは呼び出しをスタブしていた）。設定は本体が渡す 6 つ（`page_separator`・`text_area`・`line_merge_tolerance`・`images_dir`・`image_reference_dir`・`ocr`）を受け、知らないキーは黙って捨てずに止める。標準出力は JSON だけにし、誤りは標準エラーへ出す。実行ファイルを子プロセスで起動するテスト（`test/exe_test.rb`）を足した。

### Removed
- **隠しノンブルの書き込み（`stamp_nombre!`）を削除した** (`enhanced_provider.rb`): 本体はすでに Prawn ＋ `qpdf --overlay` の MIT 共通実装へ移しており、**プラグインのこのメソッドはどこからも呼ばれていなかった**。139 行のうち 92 行が到達不能なまま残り、テスト 2 件がそれを検証して緑を出していた——動かない機能を確かめる緑は、あるほうが害になる。

  本体が `Pdf.provider` に委ねるのは `page_count` / `ensure_blank_page_pdf` / `add_outline!` の 3 つだけである。ノンブルを戻す予定は無い。プラグインの有無で成果物が変わらないほうがよい種類の処理で、CombinePDF が named destinations を再構築しない問題もそれで解消している。公開 API が 1 つ減るので SemVer なら major だが、**1.2.0 とした**。呼び出しうるのは本体 `vivlio-starter` だけで、その本体はすでに呼んでいない。本体が 1.0.0 を迎えるのに合わせて配るため、プラグインだけが 2.0.0 になる並びを避けた。

### Fixed
- **文字を 1 字ずつ描く PDF で、各行が「全文＋先頭の 1 字を欠いた全文」に二重化していた** (`reader.rb` の `PageTextCollector#build_lines`): 行の組み立てが `buffer = +fragment.text` で始まっていた。`+` は凍結されていない文字列を複製せずに返すので、続く `<<` が先頭の断片の文字列そのものを行全体へ書き換える。`extract_page_content` は `text` と `lines` で組み立てを 2 回呼ぶため、2 回目の各行が膨らんでいた。Chrome（Vivliostyle）の PDF は字ごとに断片を描くので、`vs build` の PDF では全行がこうなる。最初のコミットからあった。Prawn で作る fixture は 1 行を 1 断片で描くため、通し経路のテストでは表に出なかった。複製して受けるようにし、複数断片の行を 2 回組み立てるテストを足した。
- **統合テストが、どの環境でも一度も走っていなかった** (`test/reader_test.rb`): fixture が隣の repo（`../vivlio-starter/sources/*.pdf`）を指していたが、その PDF は**どこにも存在しなかった**。`File.exist?` が false を返して skip するだけなので赤くならず、**この gem の中核である `reader.rb`（1,262 行）の通し経路は未検証のまま**だった。1.1.3 で直した OCR 補正の不具合も、それを捕まえるはずのテストが止まっていた。

  fixture を `test/fixtures/` へ同梱し、組み立て手順を `build_fixtures.rb` に残した。読む側が HexaPDF なので、作る側は Prawn にしてある——同じ実装で作って読むと、その実装の癖が打ち消し合って検証から外れる。OCR 用には文字レイヤーを持たない PDF（`scanned.pdf`）を焼いた。テストは **34 runs / 2 skips → 37 runs / 0 skips** になった。

- **Minitest 6 でテストが起動しなくなる状態だった** (`test/test_helper.rb`): `Object#stub` を使いながら `minitest/mock` を読んでいなかった。5 は autorun がついでに読むので通り、6 は `Dropped minitest/mock.rb. This has been extracted to the minitest-mock gem.`（History.rdoc）で読まれない。`bundle exec` 有無で結果が変わる状態でもあった。明示的に require し、`minitest-mock` を開発依存へ加えた。

- **正規表現の重複範囲の警告が 5 件出ていた** (`reader.rb`): `々` は `p{Han}`、`ヵ` `ヶ` は `p{Katakana}` と `ァ-ヶ` に含まれる。判定は変わらない（全コードポイントで照合して確認）が、毎回 5 行の警告が出ると警告そのものを読み飛ばすようになる。

### Changed
- **スキャンした PDF の OCR を約 4 倍速くした** (`reader.rb`): ページ全体を覆う埋め込みの画像（JPEG・PNG）があれば、`pdftoppm` でページを描き直さず、その画像を Tesseract へ渡す。描き直しは 300dpi・A4 の JPEG 1 枚で 23 秒かかり、読み取りの時間のほぼすべてだった（書き出しなら 0.05 秒）。24 ページのスキャンで 624 秒 → 151 秒、読み取りの結果は変わらない（原稿との一致の F 値 88.7% → 88.6%）。解像度はページの寸法からではなく画像の幅で見る。ページを実物より大きく作ったスキャン PDF（1542×2048pt に幅 2,057px）を設定の dpi で描き直すと、情報の増えない 3 倍の引き伸ばしになるため。幅が 1,600px に届かない画像は vips で拡大してから読む（幅 875px で確信度 88.8 → 92.2。300dpi の描き直しと同等で 0.5 秒）。回転の指定があるページ、縦横比が合わない画像、vips が無いときの小さな画像は、これまでどおり描き直す。`pdf_read.ocr.dpi` は描き直すページにだけ効く。あわせて Tesseract を 1 ページ 1 回の起動にした（これまでは TSV 用とテキスト用の 2 回）。残る時間の大半は図版の検出（vips・1 ページ約 3 秒）である。
- **OCR の言語を書かないときの既定を、日本語だけから日本語と英語（`jpn+eng`）にした**。`english` を `eng` へ読み替えるようにもした。英語を足すと、コードを含むページで識別子が 18 語中 7 → 16 語戻り、和文の文字の適合率も 93.7% → 97.6% に上がった。英字の少ない本でも和文は悪くならない（2 冊で測定）。
- **対応 Ruby を 3.4.10 / 4.0.7 にした**。4.0.7 は 2026-09-15 公開。
- **依存を最新へ上げた**: HexaPDF 1.6.0 → 1.10.0、Minitest → 6.0.6、minitest-reporters 1.7.1 → 1.8.0。
- **rubocop を入れた**（`.rubocop.yml`・`rake rubocop`・CI）。見るのは `Lint` と `Security` だけで、引用符や行数は見ない。読みやすさを削ってまで様式に従うものではなく、本体 `vivlio-starter` も同じ構えを採っている。現状 0 件。
- **README を実装に合わせた**: 機能表から隠しノンブルを外し、OCR 補正の出どころを `config/ocr_corrections.yml` と明記した（1.1.3 で prh 辞書から移したのに README が追随していなかった）。

## [1.1.3] - 2026-09-18 (未公開)

> rubygems へは出していない。ここに書いた修正は 1.2.0 に含めて配る。利用者から見た更新は 1.1.2 → 1.2.0 になるため、リリースノートでは 1.2.0 の節でまとめて説明している。

### Fixed
- **OCR の誤認識補正が 2026-08-04 から一度も効いていなかったのを直した** (`reader.rb`): 補正表の読み込み先が `config/textlint_prh.yml` と決め打ちで、本体側の `6bbc2007`「校正まわりの設定ファイル名を対にする」でこのファイルが `textlint_rewrite.yml` へ改名された際に取り残されていた。`File.file?` が false を返すので例外も警告も出ず、**空の表を当てて素通りする**——気付けない形で壊れていた。`vs pdf:read` の統合テストが「ログラミング技術習得の三要素」（先頭の「プ」が落ちたまま）を期待していたのが、動いていなかった証拠である。

### Changed
- **OCR の補正表を、校正辞書から独立した `config/ocr_corrections.yml` へ移した** (`reader.rb`): 走査の誤りと表記の方針は別物である。校正辞書に置くと**全原稿**に当たるため、本体側で実測すると `Al => AI`（OCR が AI をエルの小文字と読み違える補正）がアルミニウムの元素記号と人名 Al Gore を書き換え、`語芸 => 語彙` が「言語芸術」を「言語彙術」にしていた。しかも prh 由来の指摘は自動修正を持つので、`vs lint --fix` が黙って壊す。補正表を分ければ**当たるのは OCR したページのテキストだけ**になる。
  - 書式は従来どおり（`expected` ＋ `patterns`、`/…/` で正規表現）。読み取る本ごとに癖が違うので、著者が育てられるよう YAML のままにしてある。
  - `Al => AI` は既定に入れない。`Al` が AI なのかアルミニウムなのかは文脈でしか決まらず、機械に任せる項目ではない（雛形にコメントで残し、必要な本だけ有効にできるようにした）。
  - 補正表が無いプロジェクト（1.0 より前の雛形）では、従来どおり補正せずに素通りする。

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
