defmodule BingoApp.Bingo.GameServerTest do
  @moduledoc """
  プロセス層のテスト。

  ビンゴのルール自体は `GameTest` で純粋関数として検証済みなので、
  ここで確かめるのは **プロセス境界の振る舞い** だけ:
  Registry による解決、ルーム間の独立性、イベント配信、直列化、state の非公開。
  """
  use ExUnit.Case, async: true

  import BingoApp.CardFixtures
  import ExUnit.CaptureLog

  alias BingoApp.Bingo.{
    Card,
    Deck,
    Events,
    Game,
    GameRegistry,
    GameServer,
    GameSupervisor,
    Number,
    Publisher,
    Snapshot
  }

  @row0 [1, 16, 31, 46, 61]

  defp deck_starting_with(numbers) do
    numbers = Enum.uniq(numbers)
    Deck.new!(numbers ++ (Number.all() -- numbers))
  end

  defp start_game!(opts \\ []) do
    room_id = "room-#{System.unique_integer([:positive])}"

    opts =
      Keyword.merge(
        [host_id: "alice", card_factory: &fixed_card/0, deck: deck_starting_with(@row0)],
        opts
      )

    {:ok, _pid} = GameSupervisor.start_game(room_id, opts)
    on_exit(fn -> GameSupervisor.stop_game(room_id) end)

    room_id
  end

  # プロセスの終了と Registry からの登録解除は非同期（Registry は監視プロセスの
  # DOWN を受けてから消す）。停止直後に判定すると競合するので、消えるまで待つ。
  defp wait_until_unregistered(room_id, tries \\ 100) do
    cond do
      not GameRegistry.alive?(room_id) -> :ok
      tries == 0 -> flunk("#{room_id} が Registry から消えませんでした")
      true -> Process.sleep(10) && wait_until_unregistered(room_id, tries - 1)
    end
  end

  defp drawing_game!(opts \\ []) do
    room_id = start_game!(opts)
    :ok = GameServer.join(room_id, "alice", "Alice")
    :ok = GameServer.start_drawing(room_id, "alice")
    room_id
  end

  describe "起動と Registry" do
    test "room_id で解決できる" do
      room_id = start_game!()

      assert is_pid(GameRegistry.whereis(room_id))
      assert GameRegistry.alive?(room_id)
      assert room_id in GameRegistry.room_ids()
    end

    test "同じ room_id は二重起動できない" do
      room_id = start_game!()

      assert {:error, {:already_started, pid}} = GameSupervisor.start_game(room_id)
      assert pid == GameRegistry.whereis(room_id)
    end

    test "ensure_started は冪等" do
      room_id = start_game!()
      pid = GameRegistry.whereis(room_id)

      assert {:ok, ^pid} = GameSupervisor.ensure_started(room_id)
    end

    test "停止すると Registry から消える" do
      room_id = start_game!()

      assert :ok = GameSupervisor.stop_game(room_id)
      wait_until_unregistered(room_id)

      refute GameRegistry.alive?(room_id)
      assert {:error, :game_not_found} = GameServer.snapshot(room_id)
    end

    test "存在しないルームへの操作は :game_not_found" do
      assert {:error, :game_not_found} = GameServer.draw("no-such-room", "alice")
      assert {:error, :game_not_found} = GameServer.join("no-such-room", "alice", "Alice")
      assert {:error, :game_not_found} = GameServer.snapshot("no-such-room", "alice")
    end
  end

  describe "ルームの独立性" do
    test "別ルームの状態は互いに影響しない" do
      room_a = drawing_game!()
      room_b = drawing_game!()

      :ok = GameServer.draw(room_a, "alice")
      :ok = GameServer.draw(room_a, "alice")
      :ok = GameServer.draw(room_b, "alice")

      {:ok, snap_a} = GameServer.snapshot(room_a, "alice")
      {:ok, snap_b} = GameServer.snapshot(room_b, "alice")

      assert snap_a.drawn_count == 2
      assert snap_b.drawn_count == 1
      assert snap_a.room_id == room_a
      assert snap_b.room_id == room_b
    end

    test "片方が落ちてももう片方は生き続ける" do
      room_a = drawing_game!()
      room_b = drawing_game!()

      :ok = GameSupervisor.stop_game(room_a)
      wait_until_unregistered(room_a)

      refute GameRegistry.alive?(room_a)
      assert GameRegistry.alive?(room_b)
      assert {:ok, %Snapshot{}} = GameServer.snapshot(room_b, "alice")
    end
  end

  describe "snapshot/2（集約のカプセル化）" do
    test "%Game{} ではなく Snapshot が返る" do
      room_id = start_game!()

      assert {:ok, %Snapshot{} = snapshot} = GameServer.snapshot(room_id, nil)
      refute match?(%Game{}, snapshot)
    end

    test "他人のカードは含まれない" do
      room_id = start_game!()
      :ok = GameServer.join(room_id, "alice", "Alice")
      :ok = GameServer.join(room_id, "bob", "Bob")

      {:ok, snapshot} = GameServer.snapshot(room_id, "alice")

      # 自分のカードはある
      assert %Card{} = snapshot.my_card
      # 参加者一覧には名前と達成状況しか出ない
      assert Enum.map(snapshot.participants, & &1.name) == ["Alice", "Bob"]
      refute Enum.any?(snapshot.participants, &Map.has_key?(&1, :card))
    end

    test "未参加の観戦者には自分用の情報が無い" do
      room_id = start_game!()
      :ok = GameServer.join(room_id, "alice", "Alice")

      {:ok, snapshot} = GameServer.snapshot(room_id, "watcher")

      refute Snapshot.joined?(snapshot)
      assert snapshot.my_card == nil
      assert snapshot.my_rank == nil
      # 参加者一覧は観戦者にも見える
      assert length(snapshot.participants) == 1
    end

    test "抽選の結果がカードに自動で反映される" do
      room_id = drawing_game!()
      :ok = GameServer.draw(room_id, "alice")

      {:ok, snapshot} = GameServer.snapshot(room_id, "alice")

      assert snapshot.latest_number == 1
      assert Card.marked_numbers(snapshot.my_card) == [1]
    end

    test "参加者一覧はビンゴ順、未達成者は参加順に並ぶ" do
      # carol だけが当たりのカードを持つように配る
      room_id =
        start_game!(card_factory: sequential_factory([other_card(), other_card(), fixed_card()]))

      :ok = GameServer.join(room_id, "alice", "Alice")
      :ok = GameServer.join(room_id, "bob", "Bob")
      :ok = GameServer.join(room_id, "carol", "Carol")
      :ok = GameServer.start_drawing(room_id, "alice")

      for _i <- 1..5, do: :ok = GameServer.draw(room_id, "alice")

      {:ok, snapshot} = GameServer.snapshot(room_id, "alice")

      assert Enum.map(snapshot.participants, & &1.name) == ["Carol", "Alice", "Bob"]
      assert [%{name: "Carol", rank: 1, bingo: true} | rest] = snapshot.participants
      assert Enum.all?(rest, &(&1.rank == nil))
    end

    test "ビンゴ達成者のカードは以降塗られない" do
      room_id = drawing_game!(deck: deck_starting_with(@row0 ++ [2, 3]))

      for _i <- 1..5, do: :ok = GameServer.draw(room_id, "alice")

      {:ok, snapshot} = GameServer.snapshot(room_id, "alice")
      assert snapshot.my_rank == 1

      # 上がったあとに引かれた 2 は塗られない
      :ok = GameServer.draw(room_id, "alice")

      {:ok, snapshot} = GameServer.snapshot(room_id, "alice")
      refute 2 in Card.marked_numbers(snapshot.my_card)
    end
  end

  describe "イベント配信" do
    test "購読者にドメインイベントが届く" do
      room_id = start_game!()
      :ok = Publisher.subscribe(room_id)

      :ok = GameServer.join(room_id, "alice", "Alice")
      assert_receive {:bingo_event, %Events.ParticipantJoined{name: "Alice"}}

      :ok = GameServer.start_drawing(room_id, "alice")
      assert_receive {:bingo_event, %Events.GameStarted{}}

      :ok = GameServer.draw(room_id, "alice")
      assert_receive {:bingo_event, %Events.NumberDrawn{number: 1, column: :b}}
      assert_receive {:bingo_event, %Events.CellMarked{participant_id: "alice", number: 1}}
    end

    test "1 回の操作で複数のイベントが順に届く" do
      room_id = drawing_game!()
      :ok = Publisher.subscribe(room_id)

      # 行 0 を揃える
      for _i <- 1..5, do: :ok = GameServer.draw(room_id, "alice")

      # 最後の抽選で NumberDrawn → CellMarked → BingoAchieved の順に届く
      assert_receive {:bingo_event, %Events.NumberDrawn{number: 61}}
      assert_receive {:bingo_event, %Events.CellMarked{number: 61}}
      assert_receive {:bingo_event, %Events.BingoAchieved{participant_id: "alice", rank: 1}}
    end

    test "別ルームのイベントは届かない" do
      room_a = drawing_game!()
      room_b = drawing_game!()

      :ok = Publisher.subscribe(room_a)
      :ok = GameServer.draw(room_b, "alice")

      refute_receive {:bingo_event, _event}, 100
    end

    test "失敗した操作ではイベントが発生しない" do
      room_id = drawing_game!()
      :ok = Publisher.subscribe(room_id)

      # すでに開始済みのゲームをもう一度開始しようとする
      assert {:error, :already_started} = GameServer.start_drawing(room_id, "alice")

      refute_receive {:bingo_event, _event}, 100
    end
  end

  describe "ドメインのエラーがそのまま返る" do
    test "開始前は抽選できない" do
      room_id = start_game!()
      :ok = GameServer.join(room_id, "alice", "Alice")

      assert {:error, :not_started} = GameServer.draw(room_id, "alice")
    end

    test "参加者がいなければ開始できない" do
      room_id = start_game!()

      assert {:error, :no_participants} = GameServer.start_drawing(room_id, "alice")
    end

    test "終了後の操作は拒否される" do
      room_id = drawing_game!()
      :ok = GameServer.finish(room_id, "alice")

      assert {:error, :already_finished} = GameServer.draw(room_id, "alice")
      assert {:error, :already_finished} = GameServer.start_drawing(room_id, "alice")
    end
  end

  describe "主催者の認可" do
    test "主催者以外の抽選要求はプロセスが拒否する" do
      room_id = drawing_game!()
      :ok = GameServer.join(room_id, "bob", "Bob")

      assert {:error, :not_host} = GameServer.draw(room_id, "bob")
      assert {:error, :not_host} = GameServer.finish(room_id, "bob")

      {:ok, snapshot} = GameServer.snapshot(room_id, "bob")
      assert snapshot.drawn_count == 0
      refute snapshot.host
    end

    test "snapshot の host フラグは閲覧者ごとに変わる" do
      room_id = drawing_game!()
      :ok = GameServer.join(room_id, "bob", "Bob")

      {:ok, host_view} = GameServer.snapshot(room_id, "alice")
      {:ok, guest_view} = GameServer.snapshot(room_id, "bob")

      assert host_view.host
      refute guest_view.host
    end
  end

  describe "直列化（集約 = プロセスの効果）" do
    test "同時抽選でも番号が重複しない" do
      room_id = drawing_game!(deck: Deck.new())

      1..30
      |> Task.async_stream(fn _i -> GameServer.draw(room_id, "alice") end, max_concurrency: 30)
      |> Stream.run()

      {:ok, snapshot} = GameServer.snapshot(room_id, "alice")

      assert snapshot.drawn_count == 30
      assert Enum.uniq(snapshot.drawn_numbers) == snapshot.drawn_numbers
      assert snapshot.remaining_count == 45
    end

    test "複数人が同時に参加しても全員分のカードが発行される" do
      room_id = start_game!(card_factory: &Card.random/0)

      1..20
      |> Task.async_stream(fn i -> GameServer.join(room_id, "p#{i}", "Player #{i}") end,
        max_concurrency: 20
      )
      |> Stream.run()

      {:ok, snapshot} = GameServer.snapshot(room_id, "p1")

      assert length(snapshot.participants) == 20
      assert %Card{} = snapshot.my_card
    end
  end

  describe "プロセスのライフサイクル" do
    test "クラッシュしても再起動されない（restart: :temporary）" do
      room_id = drawing_game!()
      pid = GameRegistry.whereis(room_id)

      capture_log(fn ->
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)
        assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000
      end)

      # 空のゲームが同じ room_id で復活していないこと
      wait_until_unregistered(room_id)
      refute GameRegistry.alive?(room_id)
    end
  end
end
