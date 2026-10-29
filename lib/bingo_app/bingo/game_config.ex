defmodule BingoApp.Bingo.GameConfig do
  @moduledoc """
  ゲームの勝利条件を表す値オブジェクト。

  「何ラインそろったら勝ちか」はルーム作成時に決まり、途中で変わらない。
  `Game` に `required_lines` を裸の整数で持たせると、検証の置き場所が
  集約の中に散らばるので、生成時に一度だけ検証する型として切り出している。
  """

  alias BingoApp.Bingo.Card

  @max_lines 12

  defstruct required_lines: 1

  @type t :: %__MODULE__{required_lines: 1..12}

  @spec new(keyword()) :: {:ok, t()} | {:error, :invalid_required_lines}
  def new(opts \\ []) do
    required_lines = Keyword.get(opts, :required_lines, 1)

    if is_integer(required_lines) and required_lines >= 1 and required_lines <= @max_lines do
      {:ok, %__MODULE__{required_lines: required_lines}}
    else
      {:error, :invalid_required_lines}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, config} -> config
      {:error, reason} -> raise ArgumentError, "invalid game config: #{inspect(reason)}"
    end
  end

  @doc """
  成立ライン数が勝利条件を満たしているか。
  """
  @spec satisfied?(t(), [Card.line_id()]) :: boolean()
  def satisfied?(%__MODULE__{required_lines: required}, lines), do: length(lines) >= required
end
