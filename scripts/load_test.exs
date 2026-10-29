# Bingo.GameServer の負荷テスト（CLI から叩く入口）。
#
# 実際に LiveView がやるのと同じ手順（BingoApp.Bingo コンテキスト経由での
# ルーム作成・参加・抽選）を、複数ルーム × 複数参加者ぶん同時に走らせて、
# GenServer 呼び出しのレイテンシと、プロセス数・メモリの推移を測る。
#
# HTTP / WebSocket は経由しない。LiveView 層より下の「集約 = プロセス」の
# 部分がボトルネックになるかどうかを見るための負荷テストなので、
# あえてドメイン層の入口（Context 層）を直接叩いている。
# 本体（LoadTest モジュール）は load_test_lib.exs にある。
#
# ## 単独で走らせる（一番簡単。数字だけ見たいとき）
#
#   mix run scripts/load_test.exs
#   mix run scripts/load_test.exs --rooms 50 --participants 80
#   mix run scripts/load_test.exs --duration 30
#
# `--duration` を指定すると、指定秒数のあいだ「作って→消化して→畳む」を
# 繰り返し続ける（定常負荷。メモリリークやプロセスの溜まりを見るのに使う）。
# 指定しなければ 1 回だけ実行して終わる（瞬間最大風速を見るのに使う）。
#
# `mix run` は HTTP リスナーを起動しない（`server: true` は `mix phx.server`
# タスクが起動時に設定する値で、`mix run` はこれを立てない）。そのため
# **この形で走らせている間はダッシュボードには何も映らない**。見えるのは
# このスクリプト自身が最後に printf で出す集計だけ。これは「別の BEAM
# ノードを一時的に起こして、数字だけ取って終わる」動き方だから。
#
# ## ダッシュボードや observer_cli で「見ながら」走らせる
#
# ブラウザや observer_cli が見ているのは「今アプリが動いている、その
# BEAM ノード」。`mix run scripts/load_test.exs` は毎回まっさらな別ノードを
# 起こすので、すでに `mix phx.server` で起動しているノードとは状態が
# 一切共有されない＝ダッシュボードに変化が出なくて当然、ということになる。
#
# 同じノードで両方やるには、サーバーを起動したセッションの中で負荷をかける。
#
#   iex -S mix phx.server
#   iex> c("scripts/load_test_lib.exs")
#   iex> LoadTest.run(rooms: 50, participants: 80, duration: 30)
#
# この状態でブラウザから http://localhost:4000/dev/dashboard を開き、
# 「Processes」タブでメモリ順に並べ替えると、GameServer のプロセスが
# 何百個も並ぶのが見える（Home タブの合計メモリのグラフは数秒おきの
# 粗いサンプリングなので、一瞬で終わる負荷では動きが見えないことがある。
# 見たいときは `duration` を 30 秒以上にして、数秒待ってから確認する）。
#
# 同じ iex セッションで `:observer_cli.start()` を呼べば、
# ターミナル上に top コマンドのようなプロセス一覧も出せる
# （フルスクリーン表示になるので、抜けるときは `q` を押す）。

Code.require_file("load_test_lib.exs", __DIR__)

{opts, _rest, invalid} =
  OptionParser.parse(System.argv(),
    strict: [rooms: :integer, participants: :integer, draws: :integer, duration: :integer]
  )

if invalid != [] do
  IO.puts(:stderr, "不明なオプション: #{inspect(invalid)}")
  System.halt(1)
end

LoadTest.run(opts)
