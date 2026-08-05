# frozen_string_literal: true

# ================================================================
# Test helper: robustness/robustness_helper.rb
# ================================================================
# 堅牢性テストは「壊れた PDF を置いた作業ディレクトリ」を都度組み立てる。
# 出力先を汚さないよう、毎回 Dir.mktmpdir の中で完結させる。
# ================================================================

require "tmpdir"
require "fileutils"

module RobustnessHelper
  # HexaPDF はページボックスの配列を破壊的に扱うため、共有・凍結した配列を渡せない
  # （FrozenError になる）。呼ばれるたびに新しい配列を作る。
  def a4_box = [0, 0, 595, 842]

  def in_workdir
    Dir.mktmpdir("vsp-robustness-") do |dir|
      Dir.chdir(dir) { yield }
    end
  end

  # 検証用の正常な PDF を作る
  def make_pdf(path, pages: 3)
    doc = HexaPDF::Document.new
    pages.times { doc.pages.add(a4_box) }
    doc.write(path, optimize: true)
    path
  end

  # 中身が PDF ですらないファイル
  def make_broken_pdf(path, content: "not a pdf at all")
    File.write(path, content)
    path
  end

  # ユーザーパスワード付きの PDF
  def make_encrypted_pdf(path)
    doc = HexaPDF::Document.new
    doc.pages.add(a4_box)
    doc.encrypt(owner_password: "owner", user_password: "secret")
    doc.write(path)
    path
  end

  def provider = VivlioStarter::Pdf::EnhancedProvider.new

  # 権限を落とせない環境（root など）では検証にならないので skip する
  def skip_unless_permission_enforced(path)
    File.chmod(0o444, path)
    skip("root 実行では権限が無視されるため検証できません") if File.writable?(path)
  end

  # ログ出力（LogHelper）を伏せる。堅牢性テストは戻り値と副作用だけを見る
  def silently
    original = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = original
  end
end
