defmodule BingoApp.Bingo.DeckTest do
  use ExUnit.Case, async: true

  alias BingoApp.Bingo.Deck

  describe "new/0" do
    test "75 枚の山ができる" do
      deck = Deck.new()

      assert Deck.remaining_count(deck) == 75
      refute Deck.exhausted?(deck)
    end
  end

  describe "new/1" do
    test "抽選順を指定できる" do
      assert {:ok, deck} = Deck.new([3, 1, 2])
      assert {:ok, 3, deck} = Deck.draw(deck)
      assert {:ok, 1, _deck} = Deck.draw(deck)
    end

    test "重複や範囲外を拒否する" do
      assert {:error, :duplicated} = Deck.new([1, 1])
      assert {:error, :invalid_number} = Deck.new([76])
    end
  end

  describe "draw/1" do
    test "引いた番号は山から取り除かれる" do
      deck = Deck.new!([10, 20, 30])

      assert {:ok, 10, deck} = Deck.draw(deck)
      assert Deck.remaining_count(deck) == 2
      assert {:ok, 20, deck} = Deck.draw(deck)
      assert {:ok, 30, deck} = Deck.draw(deck)
      assert Deck.exhausted?(deck)
    end

    test "空の山からは引けない" do
      deck = Deck.new!([])

      assert {:error, :exhausted} = Deck.draw(deck)
    end

    test "75 回引くと全番号が重複なく出る" do
      {numbers, deck} =
        Enum.map_reduce(1..75, Deck.new(), fn _i, deck ->
          {:ok, number, next} = Deck.draw(deck)
          {number, next}
        end)

      assert Enum.sort(numbers) == Enum.to_list(1..75)
      assert {:error, :exhausted} = Deck.draw(deck)
    end
  end
end
