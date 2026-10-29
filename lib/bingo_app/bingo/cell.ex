defmodule BingoApp.Bingo.Cell do
  @moduledoc """
  ビンゴカードの 1 マスを表す値オブジェクト。

  「番号」と「マーク済みかどうか」は必ずセットで意味を持つので 1 つの型にまとめる。
  中央の FREE マスだけは番号を持たず、最初からマーク済みとして生まれる。
  """

  alias BingoApp.Bingo.Number

  @enforce_keys [:number]
  defstruct [:number, marked: false]

  @type value :: Number.t() | :free
  @type t :: %__MODULE__{number: value(), marked: boolean()}

  @doc """
  マスを生成する。FREE マスは生成時点でマーク済みになる（ビンゴのルール）。
  """
  @spec new(value()) :: t()
  def new(:free), do: %__MODULE__{number: :free, marked: true}

  def new(number) do
    unless Number.valid?(number), do: raise(ArgumentError, "invalid number: #{inspect(number)}")
    %__MODULE__{number: number, marked: false}
  end

  @spec mark(t()) :: t()
  def mark(%__MODULE__{} = cell), do: %{cell | marked: true}

  @spec marked?(t()) :: boolean()
  def marked?(%__MODULE__{marked: marked}), do: marked

  @spec free?(t()) :: boolean()
  def free?(%__MODULE__{number: :free}), do: true
  def free?(%__MODULE__{}), do: false
end
