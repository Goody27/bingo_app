# LoadTest モジュールの定義だけを持つファイル。副作用（実行）は一切しない。
#
# `scripts/load_test.exs`（CLI から `mix run` で叩く用）と、
# iex セッションから `c("scripts/load_test_lib.exs")` して
# `LoadTest.run(...)` を直接呼ぶ使い方の、両方から読み込まれる。
# 後者は「動いているサーバーと同じノードで負荷をかけ、
# その場でダッシュボードを見る」ためのもの（詳しくは load_test.exs 冒頭のコメント参照）。

defmodule LoadTest do
  @moduledoc false

  alias BingoApp.Bingo
  alias BingoApp.Bingo.GameRegistry
  alias BingoApp.Bingo.GameSupervisor

  @default_rooms 20
  @default_participants 30
  @default_draws 75

  # ------------------------------------------------------------------
  # エントリポイント
  # ------------------------------------------------------------------

  def run(opts) do
    rooms = Keyword.get(opts, :rooms, @default_rooms)
    participants = Keyword.get(opts, :participants, @default_participants)
    draws = Keyword.get(opts, :draws, @default_draws)
    duration = Keyword.get(opts, :duration)

    IO.puts("""

    == Bingo 負荷テスト ==
      ルーム数        : #{rooms}
      ルームごとの参加者: #{participants}
      1ルームの抽選回数: #{draws}
      モード          : #{if duration, do: "定常負荷 #{duration} 秒", else: "1回だけ実行"}
    """)

    print_system_snapshot("開始前")

    if duration do
      run_soak(rooms, participants, draws, duration)
    else
      run_once(rooms, participants, draws)
    end

    print_system_snapshot("終了後")
  end

  # ------------------------------------------------------------------
  # 1 回だけ実行するモード（瞬間最大風速）
  # ------------------------------------------------------------------

  defp run_once(rooms, participants, draws) do
    {wall_us, batch} = :timer.tc(fn -> run_batch(1, rooms, participants, draws) end)
    print_batch_report(batch, wall_us)
  end

  # ------------------------------------------------------------------
  # 定常負荷モード（作って→消化して→畳む、を繰り返す）
  # ------------------------------------------------------------------

  defp run_soak(rooms, participants, draws, duration_sec) do
    deadline = System.monotonic_time(:millisecond) + duration_sec * 1000
    run_soak_loop(1, rooms, participants, draws, deadline)
  end

  defp run_soak_loop(iteration, rooms, participants, draws, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      :ok
    else
      {wall_us, batch} = :timer.tc(fn -> run_batch(iteration, rooms, participants, draws) end)
      print_soak_line(iteration, batch, wall_us)
      run_soak_loop(iteration + 1, rooms, participants, draws, deadline)
    end
  end

  # ------------------------------------------------------------------
  # 1 バッチ = 「rooms 個のルームを同時に作って、参加者を入れて、
  # 主催者が draws 回抽選して、片付ける」を最後までやる単位
  # ------------------------------------------------------------------

  defp run_batch(iteration, rooms, participants, draws) do
    room_ids = for i <- 1..rooms, do: "load-#{iteration}-#{i}"

    {setup_us, join_latencies} =
      :timer.tc(fn ->
        room_ids
        |> Task.async_stream(&setup_room(&1, participants),
          max_concurrency: rooms,
          timeout: :infinity
        )
        |> Enum.flat_map(fn {:ok, latencies} -> latencies end)
      end)

    {draw_us, draw_results} =
      :timer.tc(fn ->
        room_ids
        |> Task.async_stream(&draw_room(&1, draws), max_concurrency: rooms, timeout: :infinity)
        |> Enum.flat_map(fn {:ok, results} -> results end)
      end)

    peak = system_snapshot()

    Task.async_stream(room_ids, &Bingo.close_game/1, max_concurrency: rooms, timeout: :infinity)
    |> Stream.run()

    %{
      rooms: rooms,
      setup_us: setup_us,
      draw_us: draw_us,
      join_latencies: join_latencies,
      draw_results: draw_results,
      peak: peak
    }
  end

  # 1 ルームぶんのセットアップ: ゲーム起動 → 主催者参加 → 参加者を並列で参加させる
  defp setup_room(room_id, participants) do
    host_id = "host"
    {:ok, _pid} = Bingo.ensure_game(room_id, host_id: host_id)

    {host_us, :ok} = :timer.tc(fn -> Bingo.join(room_id, host_id, "Host") end)

    guest_latencies =
      1..participants
      |> Task.async_stream(
        fn i ->
          id = "p#{i}"
          {us, :ok} = :timer.tc(fn -> Bingo.join(room_id, id, "Player #{i}") end)
          us
        end,
        max_concurrency: participants,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, us} -> us end)

    :ok = Bingo.start_drawing(room_id, host_id)

    [host_us | guest_latencies]
  end

  # 1 ルームぶんの抽選: 主催者が draws 回、順番に引く（同じ GenServer 宛なので直列）
  defp draw_room(room_id, draws) do
    host_id = "host"

    Enum.map(1..draws, fn _ ->
      {us, result} = :timer.tc(fn -> Bingo.draw(room_id, host_id) end)
      {result, us}
    end)
  end

  # ------------------------------------------------------------------
  # 集計・表示
  # ------------------------------------------------------------------

  defp print_batch_report(batch, wall_us) do
    draw_ok_latencies =
      batch.draw_results
      |> Enum.filter(fn {result, _us} -> result == :ok end)
      |> Enum.map(fn {_result, us} -> us end)

    exhausted_count =
      Enum.count(batch.draw_results, fn {result, _us} -> result == {:error, :exhausted} end)

    total_ops = length(batch.join_latencies) + length(batch.draw_results)

    IO.puts("""

    -- 結果 --
    合計時間        : #{ms(wall_us)} ms
    セットアップ    : #{ms(batch.setup_us)} ms （#{batch.rooms} ルーム × 参加者、並列）
    抽選            : #{ms(batch.draw_us)} ms （#{batch.rooms} ルーム並列 × ルーム内は直列）
    合計操作数      : #{total_ops} 回（#{Float.round(total_ops / (wall_us / 1_000_000), 1)} ops/sec）

    join のレイテンシ  : #{latency_line(batch.join_latencies)}
    draw のレイテンシ  : #{latency_line(draw_ok_latencies)}（山切れで即終了した抽選: #{exhausted_count} 回）

    ピーク時のプロセス状況:
    #{format_snapshot(batch.peak)}
    """)
  end

  defp print_soak_line(iteration, batch, wall_us) do
    draw_ok_latencies =
      batch.draw_results
      |> Enum.filter(fn {result, _us} -> result == :ok end)
      |> Enum.map(fn {_result, us} -> us end)

    total_ops = length(batch.join_latencies) + length(batch.draw_results)
    ops_per_sec = Float.round(total_ops / (wall_us / 1_000_000), 1)

    IO.puts(
      "batch ##{iteration}  " <>
        "#{ms(wall_us)}ms  " <>
        "#{ops_per_sec} ops/s  " <>
        "join p95=#{p95_ms(batch.join_latencies)}ms  " <>
        "draw p95=#{p95_ms(draw_ok_latencies)}ms  " <>
        "procs=#{batch.peak.process_count}  " <>
        "mem=#{batch.peak.memory_mb}MB  " <>
        "queue_max=#{batch.peak.max_queue_len}  " <>
        "games=#{batch.peak.game_count}"
    )
  end

  # ------------------------------------------------------------------
  # システム状況のスナップショット
  #
  # Registry / GameSupervisor は本来 Bingo コンテキストの内側だが、
  # これは運用・監視のためのスクリプトであってアプリケーションコードではないので、
  # 境界をまたいで直接覗いている（「操作」はしない。読むだけ）。
  # ------------------------------------------------------------------

  defp system_snapshot do
    memory = :erlang.memory(:total)

    %{
      process_count: :erlang.system_info(:process_count),
      memory_mb: Float.round(memory / 1_048_576, 1),
      game_count: GameSupervisor.count_games(),
      max_queue_len: max_message_queue_len()
    }
  end

  defp max_message_queue_len do
    GameRegistry.room_ids()
    |> Enum.map(fn room_id ->
      case GameRegistry.whereis(room_id) do
        nil ->
          0

        pid ->
          case Process.info(pid, :message_queue_len) do
            {:message_queue_len, n} -> n
            nil -> 0
          end
      end
    end)
    |> Enum.max(fn -> 0 end)
  end

  defp print_system_snapshot(label) do
    IO.puts("#{label}: #{format_snapshot(system_snapshot())}")
  end

  defp format_snapshot(s) do
    "プロセス数=#{s.process_count}  メモリ=#{s.memory_mb}MB  " <>
      "稼働中ゲーム=#{s.game_count}  最大メッセージキュー長=#{s.max_queue_len}"
  end

  # ------------------------------------------------------------------
  # レイテンシの集計（マイクロ秒のリスト → ミリ秒の統計行）
  # ------------------------------------------------------------------

  defp latency_line([]), do: "データなし"

  defp latency_line(list) do
    sorted = Enum.sort(list)
    mean = Enum.sum(sorted) / length(sorted)

    "件数=#{length(sorted)}  " <>
      "平均=#{us_to_ms(mean)}ms  " <>
      "p50=#{us_to_ms(percentile(sorted, 50))}ms  " <>
      "p95=#{us_to_ms(percentile(sorted, 95))}ms  " <>
      "p99=#{us_to_ms(percentile(sorted, 99))}ms  " <>
      "max=#{us_to_ms(List.last(sorted))}ms"
  end

  defp p95_ms([]), do: 0.0
  defp p95_ms(list), do: list |> Enum.sort() |> percentile(95) |> us_to_ms()

  # 線形補間つきパーセンタイル。sorted は昇順ソート済みの数値リストであること。
  defp percentile(sorted, p) do
    n = length(sorted)

    if n == 1 do
      hd(sorted)
    else
      rank = p / 100 * (n - 1)
      lower = trunc(rank)
      upper = min(lower + 1, n - 1)
      weight = rank - lower

      Enum.at(sorted, lower) * (1 - weight) + Enum.at(sorted, upper) * weight
    end
  end

  defp us_to_ms(us), do: Float.round(us / 1000, 2)
  defp ms(us), do: Float.round(us / 1000, 1)
end
