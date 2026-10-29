defmodule BingoApp.Bingo.Card do
  @moduledoc """
  ビンゴカードを表す値オブジェクト（不変）。

  ## なぜエンティティではなく値オブジェクトなのか

  カードは参加者に紐づくので一見エンティティに見えるが、同一性は
  `Participant.id` が担っているため、カード自身に ID を持たせる必要がない。
  値オブジェクトとして扱い `mark/2` が「新しいカードを返す」形にすることで、
  ビンゴ判定という最もバグりやすいロジックを純粋関数のまま検証できる。

  ## 格子の持ち方

  `grid` は行優先（`grid |> Enum.at(row) |> Enum.at(col)`）。
  列（col）が B / I / N / G / O に対応する。
  画面はそのまま行単位で描画でき、ライン判定も素直に書ける。
  """

  # alias BingoApp.Bingo.{Cell, Number} は
  #   alias BingoApp.Bingo.Cell
  #   alias BingoApp.Bingo.Number
  # をまとめて書ける糖衣構文（{} で複数モジュールをまとめてエイリアス化）。
  alias BingoApp.Bingo.{Cell, Number}

  # --- モジュール属性（@xxx）------------------------------------------------
  # OOP の「クラス定数」「static final」に近い。ただしインスタンス（構造体の値）
  # には一切保存されず、コンパイル時にその場の値へ展開される（マクロ的な仕組み）。
  # つまり Card 構造体をいくら作っても size は毎回 5 という定数がそのまま埋め込まれるだけで、
  # 「インスタンスごとのフィールド」ではない。
  @size 5
  # 中央は FREE マス
  @free_position {2, 2}
  @free_column_index 2

  # @line_ids: 5行 + 5列 + 斜め2本 = 12本のライン識別子を、コンパイル時に一度だけ計算しておく定数。
  #   Enum.map(0..(@size - 1), &{:row, &1})
  #     0..4 という Range（範囲）を Enum.map で1件ずつ変換する。
  #     `&{:row, &1}` は無名関数の省略記法（キャプチャ構文）。フルで書くと
  #       fn i -> {:row, i} end
  #     `&1` が「1番目の引数」を指すプレースホルダ。
  #   {:row, 0} のようなタプル（tuple）が「row0番目」を表す識別子（IDのようなもの）。
  #   `++` はリスト同士の連結演算子。3つの Enum.map の結果を1本のリストにまとめている。
  @line_ids Enum.map(0..(@size - 1), &{:row, &1}) ++
              Enum.map(0..(@size - 1), &{:col, &1}) ++
              [{:diag, :down}, {:diag, :up}]

  # struct（構造体）の定義。OOP でいう「フィールドを1つだけ持つクラス」に近いが、
  # メソッドは持てず、あくまで純粋なデータの入れ物。振る舞い（関数）は
  # このモジュール内に別途 def/defp として並べて定義する（データと振る舞いの分離）。
  # @enforce_keys [:grid] により、grid を渡さずに構造体は作れない。
  @enforce_keys [:grid]
  defstruct [:grid]

  # --- 型定義（あくまでドキュメント/dialyzer用。実行時には強制されない）-------
  # position: {0..4, 0..4} のように、Range を要素にしたタプル型。「行, 列」の座標。
  @type position :: {0..4, 0..4}
  # line_id: `|` は「直和型（Union Type）」。OOP でいうと Enum クラス＋タグ付き値の代わり。
  #   {:row, 0..4} か {:col, 0..4} か {:diag, :down | :up} のいずれか、という意味。
  @type line_id :: {:row, 0..4} | {:col, 0..4} | {:diag, :down | :up}
  @type t :: %__MODULE__{grid: [[Cell.t()]]}

  # --- 以下、単なる「定数を返す関数」。OOP の getter に近いが、
  #     どのインスタンス（card の値）を渡しても結果は常に同じ（インスタンスの状態に依存しない）。
  #     引数がない場合 `size()` は `size` と書ける（Elixir では 0 引数関数は () 省略可）。
  @spec size() :: pos_integer()
  def size, do: @size

  @spec free_position() :: position()
  def free_position, do: @free_position

  @spec line_ids() :: [line_id()]
  def line_ids, do: @line_ids

  # ----------------------------------------------------------------
  # 生成
  # ----------------------------------------------------------------

  @doc """
  列ごとの番号リストからカードを組み立てる（決定的・純粋）。

  引数は B / I / N / G / O の順に 5 つのリスト。
  N 列だけは中央が FREE になるため 4 個であることを要求する。
  「5 個渡して 1 個黙って捨てる」設計にすると、テストで指定した番号が
  消える理由が読み手に分からなくなるため、個数で明示させている。
  """
  # build/1 は下にもう一つ定義がある（72行目）＝「多節関数（multi-clause function）」。
  #   OOP のオーバーロードに似ているが、Elixir では「型」ではなく「パターン＋ガード」で
  #   どの節を使うか決まる。呼び出されると上から順に条件に一致する節を探して実行する。
  # `when is_list(columns) and length(columns) == @size` は「ガード節」。
  #   引数の形だけでなく「追加の真偽条件」で節を選べるようにする仕組み。
  #   ここでは「リストであり、かつ長さが5であること」を満たす呼び出しだけこの節が処理する。
  @spec build([[Number.t()]]) :: {:ok, t()} | {:error, term()}
  def build(columns) when is_list(columns) and length(columns) == @size do
    # with 式: 「railway-oriented programming（成功時だけ先に進める）」の Elixir 版。
    #   `:ok <- validate_columns(columns)` は validate_columns の戻り値が :ok にマッチすれば
    #   先へ進み、マッチしなければ（つまり {:error, ...} が返れば）その値をそのまま
    #   build/1 全体の戻り値として即座に返す（例外を投げずに早期リターンする代替手段）。
    with :ok <- validate_columns(columns) do
      grid =
        columns
        # |> はパイプ演算子。`columns |> f()` は `f(columns)` と同じ意味。
        # 「値を上から下へ順番に加工していく」流れを、ネストした関数呼び出しより
        # 読みやすく書くための糖衣構文（OOPのメソッドチェーン .map().filter() に近い発想）。
        |> Enum.with_index()
        # Enum.with_index: [a, b, c] を [{a, 0}, {b, 1}, {c, 2}] のように連番付きへ変換。
        |> Enum.map(fn {numbers, col_index} -> column_cells(numbers, col_index) end)
        # 列優先で作ったものを行優先に転置する
        # Enum.zip_with(& &1): 複数リストの「同じ位置の要素」同士を束ねる関数。
        #   [[列0の5要素], [列1の5要素], ...] のような「列のリスト」を、
        #   [[行0の5要素], [行1の5要素], ...] という「行のリスト」に転置している
        #   （行列の transpose を1行でやっている）。
        |> Enum.zip_with(& &1)

      # {:ok, ...} / {:error, ...} というタグ付きタプルを返すのは Elixir の定番パターン。
      #   例外を投げる代わりに「成功/失敗」を戻り値の形で明示する（Rust の Result やHaskellのEitherに相当）。
      {:ok, %__MODULE__{grid: grid}}
    end
  end

  # ガード条件に一致しなかった（リストでない／長さが5でない）場合はこちらの節が実行される。
  # 引数を使わないので `_columns` とアンダースコア始まりにして「意図的に無視している」ことを示す。
  def build(_columns), do: {:error, :invalid_columns}

  # 関数名末尾の `!` は「失敗したら {:error, ...} を返す代わりに例外を投げる」というElixir/Ruby流の慣習。
  #   呼び出し側が「失敗もあり得るので処理を分ける」(build/1) か
  #   「失敗は想定外なので落ちてほしい」(build!/1) かを選べるよう、両方を用意するのが定番。
  @spec build!([[Number.t()]]) :: t()
  def build!(columns) do
    # case式: 値をパターンにマッチさせて分岐する（switch文に近いが、パターンマッチで分解も同時に行える）。
    case build(columns) do
      {:ok, card} -> card
      {:error, reason} -> raise ArgumentError, "invalid card columns: #{inspect(reason)}"
    end
  end

  @doc """
  ランダムなカードを生成する。

  このモジュールで唯一の非決定的な関数。乱数という副作用をここ 1 箇所に
  閉じ込めることで、それ以外のロジック（マーク・ライン判定）は
  すべて決定的なテストで網羅できる。
  """
  @spec random() :: t()
  def random do
    Number.columns()
    |> Enum.with_index()
    |> Enum.map(fn {column, index} ->
      # if は式（value を返す）。三項演算子の代わりに if/else の結果をそのまま変数へ束縛できる。
      count = if index == @free_column_index, do: @size - 1, else: @size
      column |> Number.range_for() |> Enum.take_random(count)
    end)
    # build!/1 は上で定義した「失敗したら例外を投げる版」。
    # random/0 は自分で作った columns が必ず正しい形になる保証があるので、
    # {:ok, _}/{:error, _} で毎回分岐させるより build! で押し切った方が読みやすい、という判断。
    |> build!()
  end

  # ----------------------------------------------------------------
  # 参照
  # ----------------------------------------------------------------

  # 引数の `%__MODULE__{grid: grid}` は「struct から grid フィールドだけ取り出す」パターンマッチ。
  #   OOPの `card.grid` に相当する処理を、引数の分解と同時にやっている。
  @spec rows(t()) :: [[Cell.t()]]
  def rows(%__MODULE__{grid: grid}), do: grid

  # 引数 `{row, col}` はタプルの分割代入。呼び出し例: at(card, {1, 3})
  @spec at(t(), position()) :: Cell.t()
  def at(%__MODULE__{grid: grid}, {row, col}), do: grid |> Enum.at(row) |> Enum.at(col)

  @doc """
  指定した番号がカード上に存在すればその位置を、なければ nil を返す。
  """
  @spec position_of(t(), Number.t()) :: position() | nil
  def position_of(%__MODULE__{grid: grid}, number) do
    # Enum.find_value: リストを順に見て、コールバックが truthy（nil/false以外）な値を
    #   最初に返した時点でその値を返す（OOPの for文 + break + 戻り値、を1関数にまとめたもの）。
    #   見つからなければ全体として nil を返す。
    Enum.find_value(Enum.with_index(grid), fn {row_cells, row} ->
      # 内側でも同じ find_value を使い、行の中から列方向に探している（二重ループのfor文に相当）。
      Enum.find_value(Enum.with_index(row_cells), fn
        # `^number` はピン演算子。
        #   通常パターンマッチの変数は「新しく束縛（代入）」されるが、
        #   `^` を付けると「既にある変数 number の値と一致するかどうか照合する」動作に変わる。
        #   つまりこの節は「セルの number フィールドが、引数で渡された number と等しいときだけ」マッチする。
        {%Cell{number: ^number}, col} -> {row, col}
        # 上のパターンに一致しなかった全部のケース（アンダースコア始まりで中身を無視）。
        _other -> nil
      end)
    end)
  end

  @spec has_number?(t(), Number.t()) :: boolean()
  def has_number?(card, number), do: position_of(card, number) != nil

  @spec numbers(t()) :: [Number.t()]
  def numbers(%__MODULE__{grid: grid}) do
    grid
    # List.flatten: [[1,2],[3,4]] のようなネストしたリストを [1,2,3,4] に平坦化する。
    |> List.flatten()
    # Enum.reject(&Cell.free?/1): 「Cell.free?/1 が true を返す要素」を取り除く。
    #   `&Cell.free?/1` はキャプチャ構文で、既存の名前付き関数をそのまま無名関数として渡す書き方
    #   （fn cell -> Cell.free?(cell) end と同じ。/1 は「引数が1個の関数」という意味＝アリティ）。
    |> Enum.reject(&Cell.free?/1)
    # Enum.map(& &1.number): 各 cell から number フィールドだけ取り出す。
    #   `&1.number` は `fn cell -> cell.number end` の省略形。
    |> Enum.map(& &1.number)
  end

  @spec marked_numbers(t()) :: [Number.t()]
  def marked_numbers(%__MODULE__{grid: grid}) do
    grid
    |> List.flatten()
    # `&(...)` の中に and でつないだ複合条件を書ける（fn cell -> Cell.marked?(cell) and not Cell.free?(cell) end と同じ）。
    |> Enum.filter(&(Cell.marked?(&1) and not Cell.free?(&1)))
    |> Enum.map(& &1.number)
  end

  # ----------------------------------------------------------------
  # 操作
  # ----------------------------------------------------------------

  @doc """
  番号をマークした新しいカードを返す。

  「その番号が抽選済みか」はカード単体では判断できないため、ここでは検証しない。
  抽選済みかどうかの検証は集約ルート（`Bingo.Game`）の責務。
  カードが知っているのは「その番号が自分の上にあるか」「もう塗られていないか」だけ。
  """
  # 戻り値の型が {:ok, t()} | {:error, :not_on_card | :already_marked} であることに注目。
  #   OOPで例外を投げがちな「失敗しうる操作」を、Elixirでは「失敗の種類までタプルで明示する戻り値」
  #   として設計するのが定番（呼び出し側は case/with で必ず分岐を書かされるので、握りつぶしにくい）。
  @spec mark(t(), Number.t()) :: {:ok, t()} | {:error, :not_on_card | :already_marked}
  def mark(%__MODULE__{} = card, number) do
    case position_of(card, number) do
      nil ->
        {:error, :not_on_card}

      position ->
        if card |> at(position) |> Cell.marked?() do
          {:error, :already_marked}
        else
          # update_at は下で定義している private 関数。
          #   &Cell.mark/1 は「セル1つを受け取ってマーク済みセルを返す関数」をそのまま渡している
          #   （マークする処理自体は Cell モジュールに委譲し、Card は「どのマスを差し替えるか」だけを担当）。
          {:ok, update_at(card, position, &Cell.mark/1)}
        end
    end
  end

  # ----------------------------------------------------------------
  # ビンゴ判定
  # ----------------------------------------------------------------

  @doc """
  そのラインを構成する 5 マスの位置を返す。
  """
  # positions/1 は4つの節に分かれている多節関数。
  #   引数のタプルの「形（1要素目のアトム）」によってどの節が呼ばれるか決まる。
  #   OOPでいう「引数の型ごとのオーバーロード」や、Visitorパターンのdispatchに近い発想だが、
  #   ここでは型ではなく値そのものの形（アトム :row / :col / :diag）で分岐している。
  @spec positions(line_id()) :: [position()]
  def positions({:row, row}), do: Enum.map(0..(@size - 1), &{row, &1})
  def positions({:col, col}), do: Enum.map(0..(@size - 1), &{&1, col})
  def positions({:diag, :down}), do: Enum.map(0..(@size - 1), &{&1, &1})
  def positions({:diag, :up}), do: Enum.map(0..(@size - 1), &{&1, @size - 1 - &1})

  @spec line_complete?(t(), line_id()) :: boolean()
  def line_complete?(%__MODULE__{} = card, line_id) do
    # Enum.all?: 全要素がコールバックで true になるかを判定（他言語の every() に相当）。
    line_id |> positions() |> Enum.all?(&Cell.marked?(at(card, &1)))
  end

  @doc """
  成立しているライン（縦 5・横 5・斜め 2 の計 12 本）をすべて返す。
  """
  @spec completed_lines(t()) :: [line_id()]
  def completed_lines(%__MODULE__{} = card) do
    Enum.filter(@line_ids, &line_complete?(card, &1))
  end

  @doc """
  あと 1 マスでそろうライン（リーチ）。

  `completed_lines/1` と同じ走査で、しきい値だけが違う。
  「リーチ」は画面を盛り上げるための情報だが、どのマスが塗られているかを
  知っているのはカードだけなので、判定はここに置く。
  """
  @spec reach_lines(t()) :: [line_id()]
  def reach_lines(%__MODULE__{} = card) do
    Enum.filter(@line_ids, fn line_id ->
      marked =
        line_id
        |> positions()
        |> Enum.count(&Cell.marked?(at(card, &1)))

      marked == @size - 1
    end)
  end

  @spec bingo?(t()) :: boolean()
  def bingo?(%__MODULE__{} = card), do: completed_lines(card) != []

  # ----------------------------------------------------------------
  # 内部
  # ----------------------------------------------------------------
  # ここから下は `defp`（private function）。
  #   OOPの private メソッドと同じ役割で、モジュールの外からは呼び出せない
  #   （テストからも通常はこの関数を直接叩かず、build/1 などの公開APIを経由して間接的に検証する）。

  # column_cells/2 も多節関数。第2引数が @free_column_index（＝2）のときと
  #   それ以外のときで別の処理をする、というのをガードなしのパターンマッチだけで実現している。
  defp column_cells(numbers, @free_column_index) do
    {free_row, _col} = @free_position

    numbers
    # List.insert_at: 指定インデックスに要素を挿入（元のリストは変えず、新しいリストを返す＝非破壊的）。
    |> List.insert_at(free_row, :free)
    |> Enum.map(&Cell.new/1)
  end

  defp column_cells(numbers, _col_index), do: Enum.map(numbers, &Cell.new/1)

  # update_at: 「grid の中の1マスだけ関数で更新した、新しい card」を作って返す。
  #   OOPなら `card.grid[row][col] = fun(card.grid[row][col])` と書ける破壊的更新に相当する処理を、
  #   Elixirでは元のデータを一切書き換えず「新しいgridを作り、新しいcardを作る」ことで表現する。
  defp update_at(%__MODULE__{grid: grid} = card, {row, col}, fun) do
    # List.update_at(list, index, fun): 指定indexの要素だけ fun で変換した新しいリストを返す。
    #   ここでは「行」を更新するために、行の中でさらに List.update_at で「列」を更新している（ネスト更新）。
    new_grid = List.update_at(grid, row, &List.update_at(&1, col, fun))

    # struct update構文。card自体は変更せず、gridだけ差し替えた新しいcardを作る。
    %{card | grid: new_grid}
  end

  defp validate_columns(columns) do
    Number.columns()
    |> Enum.zip(columns)
    |> Enum.with_index()
    # Enum.reduce_while: 通常のreduce（畳み込み）と同じく「アキュムレータ（ここでは :ok）を
    #   引き継ぎながら1件ずつ処理する」が、コールバックが {:halt, 値} を返した時点で
    #   即座にループを打ち切れる（OOPでいう for文の中の break + 早期return に相当）。
    #   {:cont, 値} を返せば次の要素へ継続する。
    |> Enum.reduce_while(:ok, fn {{column, numbers}, index}, :ok ->
      expected = if index == @free_column_index, do: @size - 1, else: @size
      range = Number.range_for(column)

      # cond式: どのif/else節にも属さない「複数条件を上から順に判定するswitch」。
      #   Elixirのcaseはパターンマッチ、condは真偽値条件で分岐する、という使い分け。
      cond do
        length(numbers) != expected ->
          {:halt, {:error, {:wrong_count, column, expected}}}

        Enum.any?(numbers, &(&1 not in range)) ->
          {:halt, {:error, {:out_of_column_range, column}}}

        length(Enum.uniq(numbers)) != length(numbers) ->
          {:halt, {:error, {:duplicated, column}}}

        true ->
          {:cont, :ok}
      end
    end)
  end
end
