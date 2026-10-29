defmodule BingoApp.Bingo.Events do
  @moduledoc """
  ドメインイベントの定義。

  ## なぜ返り値としてイベントを返すのか

  集約の操作関数は `{:ok, game, events}` を返す。
  「新しい状態」と「何が起きたか」を分けて返すことで、

    * 判断（どう状態が変わるか）は純粋関数
    * 副作用（PubSub への配信）は GenServer

  という分担が成立する。GenServer は返ってきた `events` をそのまま配信するだけでよく、
  「何を通知すべきか」を知らなくて済む。

  また 1 回の操作が複数の結果を生む場合（番号を引いた結果 3 人が同時にビンゴ）を
  `[NumberDrawn, BingoAchieved, BingoAchieved, BingoAchieved]` と自然に表現できる。

  ## タイムスタンプを引数で受け取る理由

  各イベントは `at` を持つが、ドメイン関数の中で `DateTime.utc_now/0` を呼ぶと
  そこが副作用になり「同じ入力なら同じ出力」が崩れてテストが書けなくなる。
  そのため時刻は呼び出し側（= GenServer）から明示的に渡す。
  """

  alias BingoApp.Bingo.{Card, Number}

  defmodule ParticipantJoined do
    @moduledoc "参加者がゲームに加わった"
    @enforce_keys [:room_id, :participant_id, :name, :at]
    defstruct [:room_id, :participant_id, :name, :at]

    @type t :: %__MODULE__{
            room_id: String.t(),
            participant_id: String.t(),
            name: String.t(),
            at: DateTime.t()
          }
  end

  defmodule ParticipantLeft do
    @moduledoc "参加者がゲームから退出した（接続断ではなく明示的な退室）"
    @enforce_keys [:room_id, :participant_id, :name, :at]
    defstruct [:room_id, :participant_id, :name, :at]

    @type t :: %__MODULE__{
            room_id: String.t(),
            participant_id: String.t(),
            name: String.t(),
            at: DateTime.t()
          }
  end

  defmodule GameStarted do
    @moduledoc "抽選が開始された"
    @enforce_keys [:room_id, :at]
    defstruct [:room_id, :at]

    @type t :: %__MODULE__{room_id: String.t(), at: DateTime.t()}
  end

  defmodule NumberDrawn do
    @moduledoc "番号が 1 つ抽選された"
    @enforce_keys [:room_id, :number, :column, :drawn_count, :remaining_count, :at]
    defstruct [:room_id, :number, :column, :drawn_count, :remaining_count, :at]

    @type t :: %__MODULE__{
            room_id: String.t(),
            number: Number.t(),
            column: Number.column(),
            drawn_count: pos_integer(),
            remaining_count: non_neg_integer(),
            at: DateTime.t()
          }
  end

  defmodule CellMarked do
    @moduledoc "参加者が自分のカードのマスを塗った"
    @enforce_keys [:room_id, :participant_id, :number, :at]
    defstruct [:room_id, :participant_id, :number, :at]

    @type t :: %__MODULE__{
            room_id: String.t(),
            participant_id: String.t(),
            number: Number.t(),
            at: DateTime.t()
          }
  end

  defmodule BingoAchieved do
    @moduledoc "参加者がビンゴを達成した"
    @enforce_keys [:room_id, :participant_id, :name, :lines, :rank, :at]
    defstruct [:room_id, :participant_id, :name, :lines, :rank, :at]

    @type t :: %__MODULE__{
            room_id: String.t(),
            participant_id: String.t(),
            name: String.t(),
            lines: [Card.line_id()],
            rank: pos_integer(),
            at: DateTime.t()
          }
  end

  defmodule GameFinished do
    @moduledoc "ゲームが終了した"
    @enforce_keys [:room_id, :reason, :winners, :at]
    defstruct [:room_id, :reason, :winners, :at]

    @type reason :: :closed_by_host | :deck_exhausted
    @type t :: %__MODULE__{
            room_id: String.t(),
            reason: reason(),
            winners: [map()],
            at: DateTime.t()
          }
  end

  @type t ::
          ParticipantJoined.t()
          | ParticipantLeft.t()
          | GameStarted.t()
          | NumberDrawn.t()
          | CellMarked.t()
          | BingoAchieved.t()
          | GameFinished.t()
end
