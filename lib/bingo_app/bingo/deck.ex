defmodule BingoApp.Bingo.Deck do
  @moduledoc """
  抽選に使う番号の山を表す値オブジェクト。

  ## なぜ「シャッフル済みリスト」なのか

  「残りの集合からランダムに 1 つ選ぶ」実装にすると `draw/1` 自体が
  非決定的になり、抽選を含むシナリオのテストが書けなくなる。
  現実のビンゴガラガラと同じく **生成時に一度だけ混ぜて、あとは順に取り出す**
  モデルにすることで、`draw/1` を完全な純粋関数に保てる。
  テストでは `new/1` に任意の順序を渡せば、抽選順を固定できる。
  """

  alias BingoApp.Bingo.Number

  @enforce_keys [:remaining]
  defstruct [:remaining]

  @type t :: %__MODULE__{remaining: [Number.t()]}

  @doc """
  1..75 をシャッフルした山を作る。このモジュールで唯一の非決定的な関数。
  """
  @spec new() :: t()
  def new, do: %__MODULE__{remaining: Enum.shuffle(Number.all())}

  @doc """
  抽選順を明示して山を作る（主にテスト用）。
  """
  @spec new([Number.t()]) :: {:ok, t()} | {:error, term()}
  def new(order) when is_list(order) do
    cond do
      Enum.any?(order, &(not Number.valid?(&1))) -> {:error, :invalid_number}
      length(Enum.uniq(order)) != length(order) -> {:error, :duplicated}
      true -> {:ok, %__MODULE__{remaining: order}}
    end
  end

  @spec new!([Number.t()]) :: t()
  def new!(order) do
    case new(order) do
      {:ok, deck} -> deck
      {:error, reason} -> raise ArgumentError, "invalid deck order: #{inspect(reason)}"
    end
  end

  @doc """
  番号を 1 つ引く。引いた番号と、その番号を取り除いた新しい山を返す。
  """
  @spec draw(t()) :: {:ok, Number.t(), t()} | {:error, :exhausted}
  def draw(%__MODULE__{remaining: []}), do: {:error, :exhausted}

  def draw(%__MODULE__{remaining: [number | rest]}),
    do: {:ok, number, %__MODULE__{remaining: rest}}

  @spec remaining_count(t()) :: non_neg_integer()
  def remaining_count(%__MODULE__{remaining: remaining}), do: length(remaining)

  @spec exhausted?(t()) :: boolean()
  def exhausted?(%__MODULE__{remaining: remaining}), do: remaining == []
end
