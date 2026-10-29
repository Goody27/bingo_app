defmodule BingoApp.Bingo.Snapshot do
  @moduledoc """
  集約の状態を「ある参加者の視点」に射影した読み取り専用のビューモデル。

  ## なぜ `%Game{}` をそのまま外に出さないのか

  集約の内部構造を返してしまうと、LiveView 側で

      game.participants |> Map.put(...)

  のような「集約の外での状態改変」が自然に書けてしまう。
  読み取り専用の別の型を返すことで、**外から state をいじる経路そのものを無くす**。

  ## viewer_id を取る理由

  ビンゴでは他人のカードの中身が見えてはいけない。
  「誰の視点か」を射影の入力にすることで、そもそも他人のカードが
  プロセスの外に出ない。これは表示上の都合ではなくドメインのルールなので、
  テンプレート側の書き方に委ねず、ここで担保する。
  """

  alias BingoApp.Bingo.{Card, Game, Number, Participant}

  @enforce_keys [:room_id, :status]
  defstruct [
    :room_id,
    :status,
    :viewer_id,
    # 抽選の状況
    latest_number: nil,
    drawn_numbers: [],
    drawn_count: 0,
    remaining_count: 0,
    # 全員に見せてよい情報
    participants: [],
    winners: [],
    # 閲覧者自身の情報（他人のカードは含まれない）
    my_card: nil,
    my_lines: [],
    my_reach: [],
    my_rank: nil,
    # 主催者だけに操作 UI を出すための表示用フラグ。
    # 実際の可否は集約が裁定するので、これはあくまで見た目の制御
    host: false
  ]

  @type participant_summary :: %{
          id: Participant.id(),
          name: String.t(),
          joined_at: DateTime.t(),
          bingo: boolean(),
          rank: pos_integer() | nil
        }

  @type t :: %__MODULE__{
          room_id: String.t(),
          status: Game.status(),
          viewer_id: Participant.id() | nil,
          latest_number: Number.t() | nil,
          drawn_numbers: [Number.t()],
          drawn_count: non_neg_integer(),
          remaining_count: non_neg_integer(),
          participants: [participant_summary()],
          winners: [Game.winner()],
          my_card: Card.t() | nil,
          my_lines: [Card.line_id()],
          my_reach: [Card.line_id()],
          my_rank: pos_integer() | nil,
          host: boolean()
        }

  @doc """
  ゲームの現在状態を、`viewer_id` の視点で射影する。

  `viewer_id` が nil（まだ参加していない観戦者）なら、自分用の情報は空のまま。
  """
  @spec build(Game.t(), Participant.id() | nil) :: t()
  def build(%Game{} = game, viewer_id) do
    winners = Game.winners(game)
    drawn = Game.drawn_numbers(game)

    %__MODULE__{
      room_id: game.room_id,
      status: Game.status(game),
      viewer_id: viewer_id,
      latest_number: Game.latest_number(game),
      drawn_numbers: drawn,
      drawn_count: length(drawn),
      remaining_count: Game.remaining_count(game),
      participants: summarize_participants(game, winners),
      winners: winners,
      host: Game.host?(game, viewer_id)
    }
    |> put_viewer_fields(game, viewer_id)
  end

  # 並び順はビンゴ順（1 着・2 着…）が先で、未達成者は参加順。
  # 「誰が何着か」がこの画面の主役なので、達成者を上に集める。
  defp summarize_participants(game, winners) do
    ranks = Map.new(winners, &{&1.participant_id, &1.rank})

    game
    |> Game.participants()
    |> Enum.map(fn participant ->
      rank = Map.get(ranks, participant.id)

      %{
        id: participant.id,
        name: participant.name,
        joined_at: participant.joined_at,
        bingo: rank != nil,
        rank: rank
      }
    end)
    |> Enum.sort_by(&sort_key/1, :asc)
  end

  # 達成者は rank 昇順、未達成者はその後ろに参加順で並ぶ。
  # DateTime をそのまま比較キーにできないので UNIX 秒に落とす。
  defp sort_key(%{rank: nil, joined_at: joined_at}),
    do: {1, DateTime.to_unix(joined_at, :microsecond)}

  defp sort_key(%{rank: rank}), do: {0, rank}

  defp put_viewer_fields(snapshot, _game, nil), do: snapshot

  defp put_viewer_fields(snapshot, game, viewer_id) do
    case Game.fetch_participant(game, viewer_id) do
      {:error, :not_participating} ->
        snapshot

      {:ok, participant} ->
        rank = Enum.find_value(snapshot.winners, &if(&1.participant_id == viewer_id, do: &1.rank))

        %{
          snapshot
          | my_card: participant.card,
            my_lines: Card.completed_lines(participant.card),
            my_reach: Card.reach_lines(participant.card),
            my_rank: rank
        }
    end
  end

  @doc """
  閲覧者がすでに参加しているか。
  """
  @spec joined?(t()) :: boolean()
  def joined?(%__MODULE__{my_card: nil}), do: false
  def joined?(%__MODULE__{}), do: true

  @spec bingo?(t()) :: boolean()
  def bingo?(%__MODULE__{my_rank: nil}), do: false
  def bingo?(%__MODULE__{}), do: true
end
