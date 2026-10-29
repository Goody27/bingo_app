defmodule BingoApp.Bingo.Game do
  @moduledoc """
  ビンゴゲームの集約ルート（Aggregate Root）。**純粋関数のみ**で構成される。

  ## 集約の責務

  この集約が守る不変条件は次の通り。

    1. 同じ番号は二度抽選されない（`Deck` に委譲）
    2. `:drawing` 状態でなければ抽選できない
    3. **マークは抽選の結果として集約が行う** — 参加者に塗る操作は無い。
       クライアントから「塗る」を受け付けないので、抽選されていない番号が
       塗られることが構造的に起こりえない
    4. 参加者は自分のカードしか持たない（他人の `card` に触れる経路が無い）
    5. カードは入室時に一度だけ発行され、以後は数字の配置が変わらない
    6. ビンゴ達成は集約が自動判定する。自己申告させないし、同じ人が二度順位を取らない
    7. ビンゴ達成者のカードは上がり。以降は自動マークの対象から外れ、順位が確定する
    8. 抽選の開始・実行・終了は主催者しかできない。画面でボタンを隠すだけでは
       任意の phx-click を送られたときに防げないので、集約が操作者を裁定する

  ## プロセスを持たない理由

  このモジュールは GenServer ではない。状態を保持するのは `GameServer` の仕事で、
  ここは「現在の状態 + 操作 → 新しい状態 + 起きたこと」を計算するだけ。
  おかげでビンゴ判定のような壊れやすいロジックを、プロセスも PubSub も
  起動せずにテストできる。

  ## 操作関数の形

  すべての操作は `{:ok, game, events} | {:error, reason}` を返す。
  時刻は副作用なので呼び出し側から `now` として受け取る。
  """

  alias BingoApp.Bingo.{Card, Deck, Events, GameConfig, Number, Participant}

  @enforce_keys [:room_id, :deck, :config, :card_factory]
  defstruct [
    :room_id,
    :deck,
    :config,
    # 主催者の participant_id。誰が抽選を操作してよいかの判定に使う。
    # nil のままなら誰も操作できない（既定で拒否する）
    :host_id,
    # カード発行方針。集約に残る唯一の非決定性を 1 箇所に閉じ込めるための差し替え口
    :card_factory,
    status: :waiting,
    # 新しい順（先頭が最新の抽選番号）
    drawn: [],
    participants: %{},
    # 達成順。%{participant_id:, name:, rank:, lines:}
    winners: []
  ]

  @type status :: :waiting | :drawing | :finished
  @type room_id :: String.t()
  @type winner :: %{
          participant_id: Participant.id(),
          name: String.t(),
          rank: pos_integer(),
          lines: [Card.line_id()]
        }
  @type t :: %__MODULE__{
          room_id: room_id(),
          deck: Deck.t(),
          config: GameConfig.t(),
          host_id: Participant.id() | nil,
          card_factory: (-> Card.t()),
          status: status(),
          drawn: [Number.t()],
          participants: %{Participant.id() => Participant.t()},
          winners: [winner()]
        }

  @type result :: {:ok, t(), [Events.t()]} | {:error, atom()}

  # ----------------------------------------------------------------
  # 生成
  # ----------------------------------------------------------------

  @doc """
  新しいゲームを作る。

  ## Options

    * `:host_id`      - 主催者の participant_id。省略すると誰も抽選を操作できない
    * `:deck`         - 抽選順を固定したいとき。既定はシャッフル済みの山
    * `:config`       - 勝利条件。既定は 1 ライン
    * `:card_factory` - カードを 1 枚作る 0 引数関数。既定は `&Card.random/0`

  `:deck` と `:card_factory` は、この集約に入り込む非決定性（乱数）を
  外から差し替えるための口。既定値のままなら本番の挙動になり、
  テストでは固定の抽選順・固定のカードを渡して完全に決定的に検証できる。
  """
  @spec new(room_id(), keyword()) :: t()
  def new(room_id, opts \\ []) when is_binary(room_id) do
    %__MODULE__{
      room_id: room_id,
      host_id: Keyword.get(opts, :host_id),
      deck: Keyword.get(opts, :deck) || Deck.new(),
      config: Keyword.get(opts, :config) || GameConfig.new!(),
      card_factory: Keyword.get(opts, :card_factory) || (&Card.random/0)
    }
  end

  # ----------------------------------------------------------------
  # 操作
  # ----------------------------------------------------------------

  @doc """
  参加者を加える。カードはここで一度だけ発行される。

  すでに同じ ID が参加済みなら **何もせず成功を返す**（イベントも発生しない）。
  リロードや再接続のたびに LiveView が `join` を呼んでもカードが作り直されないようにするため。
  「参加中かどうか」を呼び出し側に判定させると、判定と参加の間に競合が入りうる。
  """
  @spec join(t(), Participant.id(), String.t(), DateTime.t()) :: result()
  def join(%__MODULE__{status: :finished}, _id, _name, _now), do: {:error, :already_finished}

  def join(%__MODULE__{} = game, participant_id, name, now) do
    cond do
      Map.has_key?(game.participants, participant_id) ->
        # 再入室は冪等に扱う
        {:ok, game, []}

      blank?(name) ->
        {:error, :invalid_name}

      true ->
        participant = Participant.new(participant_id, name, game.card_factory.(), now)
        game = put_participant(game, participant)

        joined = %Events.ParticipantJoined{
          room_id: game.room_id,
          participant_id: participant_id,
          name: name,
          at: now
        }

        # 途中参加でも不利にならないよう、すでに引かれている番号を反映しておく。
        # 自動マークなので「後から入った人だけ塗り忘れる」が起きない。
        {game, catch_up_events} = catch_up(game, participant_id, now)

        {:ok, game, [joined | catch_up_events]}
    end
  end

  @doc """
  参加者を取り除く（明示的な退室）。接続断では呼ばない。
  """
  @spec leave(t(), Participant.id(), DateTime.t()) :: result()
  def leave(%__MODULE__{} = game, participant_id, now) do
    case Map.fetch(game.participants, participant_id) do
      :error ->
        {:error, :not_participating}

      {:ok, participant} ->
        game = %{game | participants: Map.delete(game.participants, participant_id)}

        event = %Events.ParticipantLeft{
          room_id: game.room_id,
          participant_id: participant_id,
          name: participant.name,
          at: now
        }

        {:ok, game, [event]}
    end
  end

  @doc """
  抽選を開始する。主催者しか呼べず、参加者が 1 人もいない状態でも開始できない。
  """
  @spec start(t(), Participant.id(), DateTime.t()) :: result()
  def start(%__MODULE__{} = game, actor_id, now) do
    with :ok <- ensure_host(game, actor_id),
         :ok <- ensure_status(game, :waiting) do
      if map_size(game.participants) == 0 do
        {:error, :no_participants}
      else
        game = %{game | status: :drawing}
        {:ok, game, [%Events.GameStarted{room_id: game.room_id, at: now}]}
      end
    end
  end

  @doc """
  番号を 1 つ抽選する。

  抽選と同時に、全参加者のカードの該当マスを集約が自動で塗る。
  参加者側に「塗る」操作は無いので、1 回の抽選が
  `[NumberDrawn, CellMarked, CellMarked, BingoAchieved, ...]` という
  ひとまとまりのイベント列を返すことがある。

  山が尽きたらそのままゲームを終了させる。
  """
  @spec draw_number(t(), Participant.id(), DateTime.t()) :: result()
  def draw_number(%__MODULE__{} = game, actor_id, now) do
    with :ok <- ensure_host(game, actor_id),
         :ok <- ensure_status(game, :drawing) do
      do_draw(game, now)
    end
  end

  defp do_draw(game, now) do
    case Deck.draw(game.deck) do
      {:error, :exhausted} ->
        {:error, :exhausted}

      {:ok, number, deck} ->
        game = %{game | deck: deck, drawn: [number | game.drawn]}

        drawn_event = %Events.NumberDrawn{
          room_id: game.room_id,
          number: number,
          column: Number.column(number),
          drawn_count: length(game.drawn),
          remaining_count: Deck.remaining_count(deck),
          at: now
        }

        {game, mark_events} = apply_to_all(game, number, now)
        events = [drawn_event | mark_events]

        if Deck.exhausted?(deck) do
          {game, finish_events} = do_finish(game, :deck_exhausted, now)
          {:ok, game, events ++ finish_events}
        else
          {:ok, game, events}
        end
    end
  end

  @doc """
  主催者がゲームを終了させる。
  """
  @spec finish(t(), Participant.id(), DateTime.t()) :: result()
  def finish(%__MODULE__{} = game, actor_id, now) do
    with :ok <- ensure_host(game, actor_id),
         :ok <- refute_status(game, :finished) do
      {game, events} = do_finish(game, :closed_by_host, now)
      {:ok, game, events}
    end
  end

  @doc """
  その participant_id が主催者か。画面でボタンを出すかどうかの判断に使う。
  """
  @spec host?(t(), Participant.id() | nil) :: boolean()
  def host?(%__MODULE__{host_id: nil}, _actor_id), do: false
  def host?(%__MODULE__{host_id: host_id}, actor_id), do: host_id == actor_id

  # ----------------------------------------------------------------
  # 参照（読み取り専用）
  # ----------------------------------------------------------------

  @spec status(t()) :: status()
  def status(%__MODULE__{status: status}), do: status

  @spec fetch_participant(t(), Participant.id()) ::
          {:ok, Participant.t()} | {:error, :not_participating}
  def fetch_participant(%__MODULE__{participants: participants}, participant_id) do
    case Map.fetch(participants, participant_id) do
      {:ok, participant} -> {:ok, participant}
      :error -> {:error, :not_participating}
    end
  end

  @doc """
  参加順に並べた参加者一覧。
  """
  @spec participants(t()) :: [Participant.t()]
  def participants(%__MODULE__{participants: participants}) do
    participants |> Map.values() |> Enum.sort_by(& &1.joined_at, DateTime)
  end

  @spec participant_count(t()) :: non_neg_integer()
  def participant_count(%__MODULE__{participants: participants}), do: map_size(participants)

  @doc """
  抽選済みの番号（新しい順）。
  """
  @spec drawn_numbers(t()) :: [Number.t()]
  def drawn_numbers(%__MODULE__{drawn: drawn}), do: drawn

  @spec latest_number(t()) :: Number.t() | nil
  def latest_number(%__MODULE__{drawn: []}), do: nil
  def latest_number(%__MODULE__{drawn: [number | _rest]}), do: number

  @spec drawn?(t(), Number.t()) :: boolean()
  def drawn?(%__MODULE__{drawn: drawn}, number), do: number in drawn

  @spec remaining_count(t()) :: non_neg_integer()
  def remaining_count(%__MODULE__{deck: deck}), do: Deck.remaining_count(deck)

  @spec winners(t()) :: [winner()]
  def winners(%__MODULE__{winners: winners}), do: winners

  @spec winner?(t(), Participant.id()) :: boolean()
  def winner?(%__MODULE__{winners: winners}, participant_id) do
    Enum.any?(winners, &(&1.participant_id == participant_id))
  end

  # ----------------------------------------------------------------
  # 内部：自動マーク
  # ----------------------------------------------------------------

  # 主催者以外の操作を拒否する。
  #
  # 画面側でボタンを隠すだけでは「表示上の制御」でしかなく、
  # クライアントは任意の phx-click イベントを送れてしまう。
  # 誰が操作してよいかはゲームのルールなので、集約が裁定する。
  # host_id が未設定なら誰も通さない（既定で拒否）。
  defp ensure_host(%__MODULE__{} = game, actor_id) do
    if host?(game, actor_id), do: :ok, else: {:error, :not_host}
  end

  defp ensure_status(%__MODULE__{status: status}, status), do: :ok
  defp ensure_status(%__MODULE__{status: :waiting}, :drawing), do: {:error, :not_started}
  defp ensure_status(%__MODULE__{status: :drawing}, :waiting), do: {:error, :already_started}
  defp ensure_status(%__MODULE__{status: :finished}, _expected), do: {:error, :already_finished}

  defp refute_status(%__MODULE__{status: status}, status), do: {:error, :already_finished}
  defp refute_status(%__MODULE__{}, _status), do: :ok

  defp put_participant(%__MODULE__{} = game, %Participant{} = participant) do
    %{game | participants: Map.put(game.participants, participant.id, participant)}
  end

  # 抽選された番号を全参加者のカードに反映する。
  #
  # 参加順に走査するのは、1 回の抽選で複数人が同時にビンゴしたときの順位を
  # 決定的にするため。Map の列挙順に任せると、同じ入力でも順位が変わりうる。
  defp apply_to_all(game, number, now) do
    game
    |> participants()
    |> Enum.map(& &1.id)
    |> Enum.reduce({game, []}, fn participant_id, {acc, events} ->
      {next, new_events} = apply_number(acc, participant_id, number, now)
      {next, events ++ new_events}
    end)
  end

  # 途中参加者のカードに、すでに引かれている番号をまとめて反映する。
  # drawn は新しい順に積まれているので、抽選された順に戻してから適用する
  # （同時ビンゴの順位づけと同じ理由で、適用順を決めておく必要がある）。
  defp catch_up(game, participant_id, now) do
    game.drawn
    |> Enum.reverse()
    |> Enum.reduce({game, []}, fn number, {acc, events} ->
      {next, new_events} = apply_number(acc, participant_id, number, now)
      {next, events ++ new_events}
    end)
  end

  # 1 人のカードに 1 番号を反映する。塗る必要が無ければ何も起こさない。
  defp apply_number(game, participant_id, number, now) do
    participant = Map.get(game.participants, participant_id)

    cond do
      # 上がったカードは以降触らない（不変条件 7）
      is_nil(participant) or winner?(game, participant_id) ->
        {game, []}

      true ->
        mark_card(game, participant, number, now)
    end
  end

  defp mark_card(game, participant, number, now) do
    case Card.mark(participant.card, number) do
      # カードにその番号が無い／すでに塗られている。どちらも異常ではない
      {:error, _reason} ->
        {game, []}

      {:ok, card} ->
        lines_before = Card.completed_lines(participant.card)
        lines_after = Card.completed_lines(card)

        participant = Participant.put_card(participant, card)
        game = put_participant(game, participant)

        marked = %Events.CellMarked{
          room_id: game.room_id,
          participant_id: participant.id,
          number: number,
          at: now
        }

        {game, bingo_events} =
          maybe_achieve_bingo(game, participant, lines_before, lines_after, now)

        {game, [marked | bingo_events]}
    end
  end

  # ----------------------------------------------------------------
  # 内部：その他
  # ----------------------------------------------------------------

  defp maybe_achieve_bingo(game, participant, lines_before, lines_after, now) do
    satisfied_before = GameConfig.satisfied?(game.config, lines_before)
    satisfied_after = GameConfig.satisfied?(game.config, lines_after)

    if satisfied_after and not satisfied_before and not winner?(game, participant.id) do
      rank = length(game.winners) + 1

      winner = %{
        participant_id: participant.id,
        name: participant.name,
        rank: rank,
        lines: lines_after
      }

      event = %Events.BingoAchieved{
        room_id: game.room_id,
        participant_id: participant.id,
        name: participant.name,
        lines: lines_after,
        rank: rank,
        at: now
      }

      {%{game | winners: game.winners ++ [winner]}, [event]}
    else
      {game, []}
    end
  end

  defp do_finish(game, reason, now) do
    game = %{game | status: :finished}

    event = %Events.GameFinished{
      room_id: game.room_id,
      reason: reason,
      winners: game.winners,
      at: now
    }

    {game, [event]}
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: true
end
