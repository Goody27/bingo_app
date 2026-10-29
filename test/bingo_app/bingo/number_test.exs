defmodule BingoApp.Bingo.NumberTest do
  use ExUnit.Case, async: true

  alias BingoApp.Bingo.Number

  doctest BingoApp.Bingo.Number

  describe "new/1" do
    test "1..75 の整数を受け付ける" do
      assert {:ok, 1} = Number.new(1)
      assert {:ok, 75} = Number.new(75)
    end

    test "範囲外や整数以外は拒否する" do
      assert {:error, :out_of_range} = Number.new(0)
      assert {:error, :out_of_range} = Number.new(76)
      assert {:error, :out_of_range} = Number.new("7")
      assert {:error, :out_of_range} = Number.new(nil)
    end
  end

  describe "column/1" do
    test "境界値が正しい列に割り当てられる" do
      assert Number.column(1) == :b
      assert Number.column(15) == :b
      assert Number.column(16) == :i
      assert Number.column(30) == :i
      assert Number.column(31) == :n
      assert Number.column(45) == :n
      assert Number.column(46) == :g
      assert Number.column(60) == :g
      assert Number.column(61) == :o
      assert Number.column(75) == :o
    end

    test "全番号がいずれかの列に属し、各列がちょうど 15 個になる" do
      counts =
        Number.all()
        |> Enum.group_by(&Number.column/1)
        |> Map.new(fn {k, v} -> {k, length(v)} end)

      assert counts == %{b: 15, i: 15, n: 15, g: 15, o: 15}
    end
  end

  describe "range_for/1" do
    test "列ごとの範囲を返す" do
      assert Number.range_for(:b) == 1..15
      assert Number.range_for(:n) == 31..45
      assert Number.range_for(:o) == 61..75
    end

    test "range_for と column が整合する" do
      for column <- Number.columns(), number <- Number.range_for(column) do
        assert Number.column(number) == column
      end
    end
  end

  describe "label/1" do
    test "列記号つきのラベルを返す" do
      assert Number.label(7) == "B7"
      assert Number.label(45) == "N45"
      assert Number.label(75) == "O75"
    end
  end

  describe "all/0" do
    test "1..75 を重複なく返す" do
      all = Number.all()

      assert length(all) == 75
      assert Enum.uniq(all) == all
      assert Enum.min(all) == 1
      assert Enum.max(all) == 75
    end
  end
end
