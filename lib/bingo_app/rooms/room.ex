defmodule BingoApp.Rooms.Room do
  @moduledoc """
  ゲームルームを表すエンティティ。

  ## Bingo コンテキストと分けている理由

  ここが持つのは「部屋が存在するか」「誰が主催者か」といった、
  変化が遅く一覧性が要る情報。対して `Bingo` が扱うのは
  毎秒変わる進行中の状態で、ライフサイクルも整合性の要求もまるで違う。

  両コンテキストは `id`（= room_id）という識別子だけで繋がり、
  互いの構造体を直接やり取りしない。
  """

  @enforce_keys [:id, :name, :host_id, :required_lines, :created_at]
  defstruct [:id, :name, :host_id, :required_lines, :created_at]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          host_id: String.t(),
          required_lines: pos_integer(),
          created_at: DateTime.t()
        }
end
