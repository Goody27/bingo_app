defmodule BingoApp.Bingo.GameTest do
  @moduledoc """
  集約ルートのテスト。

  GenServer も PubSub も Phoenix も起動していないことに注目。
  ドメインロジックを純粋関数に切り出した見返りがこれで、
  不変条件をすべて値の比較だけで検証できる。
  """
  use ExUnit.Case, async: true

  import BingoApp.CardFixtures

  alias BingoApp.Bingo.{Card, Deck, Events, Game, GameConfig, Number, Participant}

  @base ~U[2026-09-11 12:00:00Z]
  # 主催者。テストでは alice が参加者かつ主催者
  @host "alice"

  # 固定カードの行 0（横一列）
  @row0 [1, 16, 31, 46, 61]
  # 固定カードの列 0（縦一列）
  @col0 [1, 2, 3, 4, 5]
  # 固定カードの斜め（左上→右下）。中央は FREE なので 4 つで成立する
  @diag_down [1, 17, 49, 65]
  # 固定カードに載っていない番号
  @not_on_card 75

  defp at(offset \\ 0), do: DateTime.add(@base, offset, :second)

  defp new_game(opts \\ []) do
    Game.new(
      Keyword.get(opts, :room_id, "room-1"),
      host_id: Keyword.get(opts, :host_id, @host),
      deck: Keyword.get(opts, :deck, Deck.new!(Number.all())),
      card_factory: Keyword.get(opts, :card_factory, &fixed_card/0),
      config: Keyword.get(opts, :config, GameConfig.new!())
    )
  end

  # 指定した番号が先に出るように積んだ山
  defp deck_starting_with(numbers) do
    numbers = Enum.uniq(numbers)
    Deck.new!(numbers ++ (Number.all() -- numbers))
  end

  defp join!(game, id, name, offset) do
    {:ok, game, _events} = Game.join(game, id, name, at(offset))
    game
  end

  defp start!(game, offset) do
    {:ok, game, _events} = Game.start(game, @host, at(offset))
    game
  end

  defp draw_times(game, count) do
    Enum.reduce(1..count//1, game, fn i, acc ->
      {:ok, next, _events} = Game.draw_number(acc, @host, at(100 + i))
      next
    end)
  end

  # alice が参加した進行中のゲームを作り、`order` の並びで `draws` 回だけ引いた状態にする。
  # 「あと 1 つでビンゴ」の状態を決定的に作れるようにするため、山の並びと抽選回数を分けて渡す。
  defp primed_game(order, draws, opts \\ []) do
    opts
    |> Keyword.put_new(:deck, deck_starting_with(order))
    |> new_game()
    |> join!("alice", "Alice", 0)
    |> start!(1)
    |> draw_times(draws)
  end

  # 指定の番号がすべて抽選済み（= 自動マーク済み）の状態
  defp ready_game(numbers, opts \\ []) do
    numbers = Enum.uniq(numbers)
    primed_game(numbers, length(numbers), opts)
  end

  defp card_of(game, participant_id) do
    {:ok, participant} = Game.fetch_participant(game, participant_id)
    participant.card
  end

  describe "new/2" do
    test "参加者なしの待機状態で始まる" do
      game = new_game()

      assert Game.status(game) == :waiting
      assert Game.participants(game) == []
      assert Game.drawn_numbers(game) == []
      assert Game.latest_number(game) == nil
      assert Game.winners(game) == []
      assert Game.remaining_count(game) == 75
    end
  end

  describe "join/4" do
    test "参加者が加わり ParticipantJoined が発生する" do
      assert {:ok, game, [event]} = Game.join(new_game(), "alice", "Alice", at())

      assert %Events.ParticipantJoined{participant_id: "alice", name: "Alice", room_id: "room-1"} =
               event

      assert Game.participant_count(game) == 1
      assert {:ok, %Participant{name: "Alice"}} = Game.fetch_participant(game, "alice")
    end

    test "入室時にカードが 1 枚発行される" do
      game = join!(new_game(), "alice", "Alice", 0)

      assert length(Card.numbers(card_of(game, "alice"))) == 24
      assert Card.marked_numbers(card_of(game, "alice")) == []
    end

    test "同じ ID の再入室は冪等で、カードが作り直されない" do
      game = join!(new_game(card_factory: &Card.random/0), "alice", "Alice", 0)
      {:ok, before} = Game.fetch_participant(game, "alice")

      # 再接続を想定して、別名で join し直しても既存の参加者が保たれる
      assert {:ok, game, []} = Game.join(game, "alice", "Alice again", at(5))

      assert {:ok, ^before} = Game.fetch_participant(game, "alice")
      assert Game.participant_count(game) == 1
    end

    test "名前が空なら拒否する" do
      assert {:error, :invalid_name} = Game.join(new_game(), "alice", "", at())
      assert {:error, :invalid_name} = Game.join(new_game(), "alice", "   ", at())
      assert {:error, :invalid_name} = Game.join(new_game(), "alice", nil, at())
    end

    test "途中参加者には既出の番号がまとめて反映される" do
      game =
        new_game(deck: deck_starting_with([1, 16, 31]))
        |> join!("alice", "Alice", 0)
        |> start!(1)
        |> draw_times(3)

      assert {:ok, game, events} = Game.join(game, "bob", "Bob", at(10))

      # 参加イベントのあとに、引かれた順で追いつきのマークが並ぶ
      assert [
               %Events.ParticipantJoined{participant_id: "bob"},
               %Events.CellMarked{participant_id: "bob", number: 1},
               %Events.CellMarked{participant_id: "bob", number: 16},
               %Events.CellMarked{participant_id: "bob", number: 31}
             ] = events

      assert Card.marked_numbers(card_of(game, "bob")) == [1, 16, 31]
    end

    test "終了後は参加できない" do
      game = new_game() |> join!("alice", "Alice", 0)
      {:ok, game, _events} = Game.finish(game, @host, at(1))

      assert {:error, :already_finished} = Game.join(game, "bob", "Bob", at(2))
    end

    test "参加者一覧は参加順に並ぶ" do
      game =
        new_game()
        |> join!("bob", "Bob", 10)
        |> join!("alice", "Alice", 0)
        |> join!("carol", "Carol", 20)

      assert Enum.map(Game.participants(game), & &1.name) == ["Alice", "Bob", "Carol"]
    end
  end

  describe "leave/3" do
    test "参加者を取り除き ParticipantLeft が発生する" do
      game = join!(new_game(), "alice", "Alice", 0)

      assert {:ok, game, [%Events.ParticipantLeft{participant_id: "alice", name: "Alice"}]} =
               Game.leave(game, "alice", at(1))

      assert Game.participant_count(game) == 0
    end

    test "参加していない人は退出できない" do
      assert {:error, :not_participating} = Game.leave(new_game(), "ghost", at())
    end
  end

  describe "start/2" do
    test "参加者がいなければ開始できない" do
      assert {:error, :no_participants} = Game.start(new_game(), @host, at())
    end

    test "開始すると抽選中になる" do
      game = join!(new_game(), "alice", "Alice", 0)

      assert {:ok, game, [%Events.GameStarted{room_id: "room-1"}]} =
               Game.start(game, @host, at(1))

      assert Game.status(game) == :drawing
    end

    test "二重開始は拒否する" do
      game = new_game() |> join!("alice", "Alice", 0) |> start!(1)

      assert {:error, :already_started} = Game.start(game, @host, at(2))
    end
  end

  describe "draw_number/2" do
    test "開始前は抽選できない" do
      game = join!(new_game(), "alice", "Alice", 0)

      assert {:error, :not_started} = Game.draw_number(game, @host, at(1))
    end

    test "引いた番号が最新として記録される" do
      game = new_game(deck: deck_starting_with([42])) |> join!("alice", "Alice", 0) |> start!(1)

      assert {:ok, game, [event | _rest]} = Game.draw_number(game, @host, at(2))

      assert %Events.NumberDrawn{
               number: 42,
               column: :n,
               drawn_count: 1,
               remaining_count: 74
             } = event

      assert Game.latest_number(game) == 42
      assert Game.drawn_numbers(game) == [42]
      assert Game.drawn?(game, 42)
      refute Game.drawn?(game, 43)
    end

    test "抽選済みは新しい順に積まれる" do
      game =
        new_game(deck: deck_starting_with([10, 20, 30]))
        |> join!("alice", "Alice", 0)
        |> start!(1)
        |> draw_times(3)

      assert Game.drawn_numbers(game) == [30, 20, 10]
      assert Game.latest_number(game) == 30
    end

    test "同じ番号は二度出ない（不変条件 1）" do
      game = new_game() |> join!("alice", "Alice", 0) |> start!(1) |> draw_times(75)

      drawn = Game.drawn_numbers(game)

      assert length(drawn) == 75
      assert Enum.sort(drawn) == Number.all()
    end

    test "山が尽きた抽選で GameFinished が発生する" do
      game = new_game() |> join!("alice", "Alice", 0) |> start!(1) |> draw_times(74)

      assert {:ok, game, events} = Game.draw_number(game, @host, at(999))

      assert %Events.NumberDrawn{} = hd(events)
      assert %Events.GameFinished{reason: :deck_exhausted} = List.last(events)
      assert Game.status(game) == :finished
      assert Game.remaining_count(game) == 0
    end

    test "終了後は抽選できない" do
      game = new_game() |> join!("alice", "Alice", 0) |> start!(1)
      {:ok, game, _events} = Game.finish(game, @host, at(2))

      assert {:error, :already_finished} = Game.draw_number(game, @host, at(3))
    end
  end

  describe "自動マーク（不変条件 3）" do
    test "抽選と同時にカードが塗られ、CellMarked が発生する" do
      game = new_game(deck: deck_starting_with([17])) |> join!("alice", "Alice", 0) |> start!(1)

      assert {:ok, game,
              [
                %Events.NumberDrawn{number: 17},
                %Events.CellMarked{participant_id: "alice", number: 17}
              ]} = Game.draw_number(game, @host, at(2))

      assert Card.marked_numbers(card_of(game, "alice")) == [17]
    end

    test "カードに無い番号ではマークイベントが出ない" do
      game =
        new_game(deck: deck_starting_with([@not_on_card]))
        |> join!("alice", "Alice", 0)
        |> start!(1)

      assert {:ok, game, [%Events.NumberDrawn{number: @not_on_card}]} =
               Game.draw_number(game, @host, at(2))

      assert Card.marked_numbers(card_of(game, "alice")) == []
    end

    test "全参加者のカードが同時に塗られる" do
      game =
        new_game(deck: deck_starting_with([17]))
        |> join!("alice", "Alice", 0)
        |> join!("bob", "Bob", 1)
        |> start!(2)

      assert {:ok, game,
              [
                %Events.NumberDrawn{number: 17},
                %Events.CellMarked{participant_id: "alice"},
                %Events.CellMarked{participant_id: "bob"}
              ]} = Game.draw_number(game, @host, at(3))

      assert Card.marked_numbers(card_of(game, "alice")) == [17]
      assert Card.marked_numbers(card_of(game, "bob")) == [17]
    end

    test "参加者がいなくても抽選自体は成立する" do
      game =
        new_game(deck: deck_starting_with([17]))
        |> join!("alice", "Alice", 0)
        |> start!(1)

      {:ok, game, _events} = Game.leave(game, "alice", at(2))

      assert {:ok, _game, [%Events.NumberDrawn{number: 17}]} =
               Game.draw_number(game, @host, at(3))
    end
  end

  describe "ビンゴ判定（不変条件 6）" do
    test "横一列が揃うと BingoAchieved が発生する" do
      game = primed_game(@row0, 4)

      assert {:ok, game, [_drawn, _marked, %Events.BingoAchieved{} = bingo]} =
               Game.draw_number(game, @host, at(300))

      assert bingo.participant_id == "alice"
      assert bingo.name == "Alice"
      assert bingo.rank == 1
      assert bingo.lines == [{:row, 0}]
      assert Game.winner?(game, "alice")
    end

    test "斜めは FREE を使って 4 つで成立する" do
      game = primed_game(@diag_down, 3)

      assert {:ok, _game, [_drawn, _marked, %Events.BingoAchieved{lines: [{:diag, :down}]}]} =
               Game.draw_number(game, @host, at(300))
    end

    test "リーチ止まりでは達成イベントが出ない" do
      game = primed_game(@row0, 4)

      refute Game.winner?(game, "alice")
      assert Game.winners(game) == []
    end

    test "達成者のカードは以降マークされない（不変条件 7）" do
      # 行 0 で上がったあと、列 0 の番号を引いても塗られない
      game = ready_game(@row0 ++ [2, 3])

      assert [%{participant_id: "alice", rank: 1}] = Game.winners(game)
      assert Card.marked_numbers(card_of(game, "alice")) == @row0
      refute 2 in Card.marked_numbers(card_of(game, "alice"))
    end

    test "同時にビンゴしたら参加順に順位がつく" do
      game =
        new_game(deck: deck_starting_with(@row0))
        |> join!("alice", "Alice", 0)
        |> join!("bob", "Bob", 1)
        |> join!("carol", "Carol", 2)
        |> start!(3)
        |> draw_times(4)

      assert {:ok, game, events} = Game.draw_number(game, @host, at(300))

      achieved = Enum.filter(events, &match?(%Events.BingoAchieved{}, &1))

      assert Enum.map(achieved, &{&1.name, &1.rank}) == [
               {"Alice", 1},
               {"Bob", 2},
               {"Carol", 3}
             ]

      assert Enum.map(Game.winners(game), & &1.rank) == [1, 2, 3]
    end

    test "途中参加でも追いつきマークでビンゴになりうる" do
      game = primed_game(@row0, 5)

      assert Game.winner?(game, "alice")

      # bob の入室時、すでに引かれた 5 つが一気に塗られて行 0 が揃う
      assert {:ok, game, events} = Game.join(game, "bob", "Bob", at(10))

      assert [%Events.BingoAchieved{participant_id: "bob", rank: 2, lines: [{:row, 0}]}] =
               Enum.filter(events, &match?(%Events.BingoAchieved{}, &1))

      assert Enum.map(Game.winners(game), & &1.participant_id) == ["alice", "bob"]
    end

    test "required_lines: 2 なら 1 ラインでは達成にならない" do
      config = GameConfig.new!(required_lines: 2)
      game = ready_game(@row0, config: config)

      refute Game.winner?(game, "alice")

      # 列 0 の残りを引き切ると 2 ライン目が成立する
      game = draw_times(game, 3)

      assert {:ok, _game, events} = Game.draw_number(game, @host, at(400))

      assert [%Events.BingoAchieved{rank: 1, lines: lines}] =
               Enum.filter(events, &match?(%Events.BingoAchieved{}, &1))

      assert lines == [{:row, 0}, {:col, 0}]
    end
  end

  describe "主催者の認可（不変条件 8）" do
    test "主催者以外は開始できない" do
      game = new_game() |> join!("alice", "Alice", 0) |> join!("bob", "Bob", 1)

      assert {:error, :not_host} = Game.start(game, "bob", at(2))
      assert Game.status(game) == :waiting
    end

    test "主催者以外は抽選できない" do
      game = new_game() |> join!("alice", "Alice", 0) |> join!("bob", "Bob", 1) |> start!(2)

      assert {:error, :not_host} = Game.draw_number(game, "bob", at(3))
      assert Game.drawn_numbers(game) == []
    end

    test "主催者以外は終了できない" do
      game = new_game() |> join!("alice", "Alice", 0) |> start!(1)

      assert {:error, :not_host} = Game.finish(game, "bob", at(2))
      assert Game.status(game) == :drawing
    end

    test "host_id を渡していないゲームは誰も操作できない（既定で拒否）" do
      game = new_game(host_id: nil) |> join!("alice", "Alice", 0)

      assert {:error, :not_host} = Game.start(game, "alice", at(1))
      assert {:error, :not_host} = Game.start(game, nil, at(1))
    end

    test "host?/2 で主催者かどうかを判定できる" do
      game = new_game()

      assert Game.host?(game, @host)
      refute Game.host?(game, "bob")
      refute Game.host?(game, nil)
    end

    test "認可は状態チェックより先に効く" do
      # 終了済みでも「主催者ではない」が先に返る（存在を漏らさない）
      game = new_game() |> join!("alice", "Alice", 0)
      {:ok, game, _events} = Game.finish(game, @host, at(1))

      assert {:error, :not_host} = Game.draw_number(game, "bob", at(2))
    end
  end

  describe "finish/2" do
    test "主催者が終了させられる" do
      game = new_game() |> join!("alice", "Alice", 0) |> start!(1)

      assert {:ok, game, [%Events.GameFinished{reason: :closed_by_host, winners: []}]} =
               Game.finish(game, @host, at(2))

      assert Game.status(game) == :finished
    end

    test "二重終了は拒否する" do
      game = new_game() |> join!("alice", "Alice", 0)
      {:ok, game, _events} = Game.finish(game, @host, at(1))

      assert {:error, :already_finished} = Game.finish(game, @host, at(2))
    end
  end
end
