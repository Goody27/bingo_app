defmodule BingoApp.Bingo.CardTest do
  use ExUnit.Case, async: true

  import BingoApp.CardFixtures

  alias BingoApp.Bingo.{Card, Cell}

  describe "build/1" do
    test "列優先の入力が行優先のグリッドに転置される" do
      card = fixed_card()

      assert [row0 | _rest] = Card.rows(card)
      assert Enum.map(row0, & &1.number) == [1, 16, 31, 46, 61]
      assert card |> Card.at({4, 4}) |> Map.fetch!(:number) == 65
      assert card |> Card.at({0, 4}) |> Map.fetch!(:number) == 61
      assert card |> Card.at({4, 0}) |> Map.fetch!(:number) == 5
    end

    test "中央は FREE で最初からマーク済み" do
      card = fixed_card()
      center = Card.at(card, Card.free_position())

      assert Cell.free?(center)
      assert Cell.marked?(center)
    end

    test "FREE 以外のマスは未マークで始まる" do
      card = fixed_card()

      assert Card.marked_numbers(card) == []
      assert length(Card.numbers(card)) == 24
    end

    test "列の個数が違えば拒否する" do
      [b, i, _n, g, o] = columns()

      assert {:error, {:wrong_count, :n, 4}} = Card.build([b, i, [31, 32, 33, 34, 35], g, o])
      assert {:error, {:wrong_count, :b, 5}} = Card.build([[1, 2, 3], i, [31, 32, 33, 34], g, o])
    end

    test "列の担当範囲外の番号を拒否する" do
      [_b, i, n, g, o] = columns()

      assert {:error, {:out_of_column_range, :b}} = Card.build([[1, 2, 3, 4, 16], i, n, g, o])
    end

    test "列内の重複を拒否する" do
      [_b, i, n, g, o] = columns()

      assert {:error, {:duplicated, :b}} = Card.build([[1, 1, 2, 3, 4], i, n, g, o])
    end
  end

  describe "random/0" do
    test "常に妥当なカードを生成する" do
      for _i <- 1..50 do
        card = Card.random()
        numbers = Card.numbers(card)

        assert length(numbers) == 24
        assert Enum.uniq(numbers) == numbers
        assert Cell.free?(Card.at(card, Card.free_position()))
      end
    end

    test "各列の番号がその列の担当範囲に収まる" do
      card = Card.random()

      for {column, col_index} <- Enum.with_index(BingoApp.Bingo.Number.columns()) do
        range = BingoApp.Bingo.Number.range_for(column)

        numbers =
          card
          |> Card.rows()
          |> Enum.map(&Enum.at(&1, col_index))
          |> Enum.reject(&Cell.free?/1)
          |> Enum.map(& &1.number)

        assert Enum.all?(numbers, &(&1 in range)),
               "column #{column} has numbers outside #{inspect(range)}: #{inspect(numbers)}"
      end
    end
  end

  describe "mark/2" do
    test "カード上の番号をマークできる" do
      assert {:ok, card} = Card.mark(fixed_card(), 17)

      assert card |> Card.at({1, 1}) |> Cell.marked?()
      assert Card.marked_numbers(card) == [17]
    end

    test "カードに無い番号は拒否する" do
      assert {:error, :not_on_card} = Card.mark(fixed_card(), 75)
    end

    test "同じ番号を二度マークできない" do
      {:ok, card} = Card.mark(fixed_card(), 17)

      assert {:error, :already_marked} = Card.mark(card, 17)
    end

    test "元のカードは変化しない（不変性）" do
      card = fixed_card()
      {:ok, marked} = Card.mark(card, 17)

      assert Card.marked_numbers(card) == []
      assert Card.marked_numbers(marked) == [17]
    end
  end

  describe "completed_lines/1 と bingo?/1" do
    test "初期状態ではビンゴしていない" do
      card = fixed_card()

      assert Card.completed_lines(card) == []
      refute Card.bingo?(card)
    end

    test "FREE を含む行だけではビンゴにならない" do
      # 中央行のうち FREE 以外を 3 つだけ塗る
      card = mark_all(fixed_card(), [3, 18, 48])

      refute Card.bingo?(card)
    end

    test "横一列でビンゴ" do
      card = mark_all(fixed_card(), [1, 16, 31, 46, 61])

      assert Card.completed_lines(card) == [{:row, 0}]
      assert Card.bingo?(card)
    end

    test "縦一列でビンゴ" do
      card = mark_all(fixed_card(), [1, 2, 3, 4, 5])

      assert Card.completed_lines(card) == [{:col, 0}]
    end

    test "斜め（左上→右下）は FREE を利用して 4 つでビンゴ" do
      card = mark_all(fixed_card(), [1, 17, 49, 65])

      assert Card.completed_lines(card) == [{:diag, :down}]
    end

    test "斜め（右上→左下）も FREE を利用して 4 つでビンゴ" do
      card = mark_all(fixed_card(), [61, 47, 19, 5])

      assert Card.completed_lines(card) == [{:diag, :up}]
    end

    test "同時に複数ラインが成立しうる" do
      # 行 0 と 列 0 を同時に完成させる
      card = mark_all(fixed_card(), [1, 16, 31, 46, 61, 2, 3, 4, 5])

      assert Card.completed_lines(card) == [{:row, 0}, {:col, 0}]
    end

    test "全マス塗ると 12 ライン成立する" do
      card = mark_all(fixed_card(), Card.numbers(fixed_card()))

      assert length(Card.completed_lines(card)) == 12
      assert Card.completed_lines(card) == Card.line_ids()
    end
  end

  describe "positions/1" do
    test "各ラインはちょうど 5 マスで構成される" do
      for line_id <- Card.line_ids() do
        positions = Card.positions(line_id)

        assert length(positions) == 5
        assert Enum.uniq(positions) == positions
      end
    end

    test "斜めラインは中央の FREE を通る" do
      assert Card.free_position() in Card.positions({:diag, :down})
      assert Card.free_position() in Card.positions({:diag, :up})
    end
  end

  describe "position_of/2 と has_number?/2" do
    test "番号の位置を引ける" do
      card = fixed_card()

      assert Card.position_of(card, 1) == {0, 0}
      assert Card.position_of(card, 34) == {4, 2}
      assert Card.position_of(card, 75) == nil
      assert Card.has_number?(card, 34)
      refute Card.has_number?(card, 75)
    end
  end
end
