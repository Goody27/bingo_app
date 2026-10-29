defmodule BingoApp.Bingo.Number do
  @moduledoc """
  抽選番号を表す値オブジェクト。

  ビンゴの番号は 1..75 で、15 個ずつ B / I / N / G / O の列に対応する。
  「1..75 の整数」という裸のデータではなく、この列との対応まで含めて
  1 つの概念として扱いたいのでモジュールに切り出している。

  実体は整数そのもの（構造体で包まない）。
  包むと `%Number{value: 7}` のような冗長さと変換コストが増える割に、
  範囲検証は生成時の一度きりで足りるため。
  """

  @min 1
  @max 75
  @per_column 15
  @columns [:b, :i, :n, :g, :o]

  @type t :: 1..75
  @type column :: :b | :i | :n | :g | :o

  @spec min() :: t
  def min, do: @min

  @spec max() :: t
  def max, do: @max

  @spec per_column() :: pos_integer()
  def per_column, do: @per_column

  @spec columns() :: [column]
  def columns, do: @columns

  @doc """
  有効な番号すべてを昇順で返す。デッキの初期化に使う。
  """
  @spec all() :: [t]
  def all, do: Enum.to_list(@min..@max)

  @doc """
  範囲を検証して番号を生成する。

  ## Examples

      iex> BingoApp.Bingo.Number.new(7)
      {:ok, 7}

      iex> BingoApp.Bingo.Number.new(76)
      {:error, :out_of_range}
  """
  @spec new(term()) :: {:ok, t} | {:error, :out_of_range}
  def new(value) when is_integer(value) and value >= @min and value <= @max, do: {:ok, value}
  def new(_value), do: {:error, :out_of_range}

  @spec valid?(term()) :: boolean()
  def valid?(value), do: is_integer(value) and value >= @min and value <= @max

  @doc """
  番号が属する列を返す。1..15 -> :b, 16..30 -> :i, ...
  """
  @spec column(t) :: column
  def column(value) when is_integer(value) and value >= @min and value <= @max do
    Enum.at(@columns, div(value - @min, @per_column))
  end

  @doc """
  列が担当する番号の範囲を返す。カード生成で列ごとに抽出するために使う。
  """
  @spec range_for(column) :: Range.t()
  def range_for(column) do
    index = Enum.find_index(@columns, &(&1 == column))
    (index * @per_column + @min)..((index + 1) * @per_column)
  end

  @doc """
  画面表示用のラベル。例: 7 -> "B7"
  """
  @spec label(t) :: String.t()
  def label(value) do
    value
    |> column()
    |> Atom.to_string()
    |> String.upcase()
    |> Kernel.<>(Integer.to_string(value))
  end
end
