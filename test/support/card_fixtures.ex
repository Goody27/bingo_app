defmodule BingoApp.CardFixtures do
  @moduledoc """
  テスト用の決定的なカード。

  グリッド（行優先）:

      |  B |  I |   N  |  G |  O |
      |  1 | 16 |  31  | 46 | 61 |
      |  2 | 17 |  32  | 47 | 62 |
      |  3 | 18 | FREE | 48 | 63 |
      |  4 | 19 |  33  | 49 | 64 |
      |  5 | 20 |  34  | 50 | 65 |
  """

  alias BingoApp.Bingo.Card

  @columns [
    [1, 2, 3, 4, 5],
    [16, 17, 18, 19, 20],
    # N 列は中央が FREE なので 4 個
    [31, 32, 33, 34],
    [46, 47, 48, 49, 50],
    [61, 62, 63, 64, 65]
  ]

  @spec columns() :: [[pos_integer()]]
  def columns, do: @columns

  @spec fixed_card() :: Card.t()
  def fixed_card, do: Card.build!(@columns)

  # fixed_card とは 1 つも番号が重ならないカード。
  # 「一部の参加者だけがビンゴする」状況を決定的に作るために使う。
  @other_columns [
    [6, 7, 8, 9, 10],
    [21, 22, 23, 24, 25],
    [36, 37, 38, 39],
    [51, 52, 53, 54, 55],
    [66, 67, 68, 69, 70]
  ]

  @spec other_card() :: Card.t()
  def other_card, do: Card.build!(@other_columns)

  @doc """
  呼ばれるたびに先頭から順にカードを配る card_factory。
  参加者ごとに違うカードを持たせたいときに使う（足りなければ最後のカードを使い回す）。
  """
  @spec sequential_factory([Card.t()]) :: (-> Card.t())
  def sequential_factory([_ | _] = cards) do
    {:ok, agent} = Agent.start_link(fn -> cards end)

    fn ->
      Agent.get_and_update(agent, fn
        [card | rest] -> {card, rest}
        [] -> {List.last(cards), []}
      end)
    end
  end

  @doc """
  複数の番号を順にマークする。1 つでも失敗したら raise する（テストの意図を明確にするため）。
  """
  @spec mark_all(Card.t(), [pos_integer()]) :: Card.t()
  def mark_all(card, numbers) do
    Enum.reduce(numbers, card, fn number, acc ->
      case Card.mark(acc, number) do
        {:ok, marked} -> marked
        {:error, reason} -> raise "failed to mark #{number}: #{inspect(reason)}"
      end
    end)
  end
end
