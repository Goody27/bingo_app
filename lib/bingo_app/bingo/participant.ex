defmodule BingoApp.Bingo.Participant do
  @moduledoc """
  ゲームに参加している 1 人を表すエンティティ（`Game` 集約の内部）。

  ## Presence の「接続中ユーザー」とは別物

  こちらは「カードを保有し、ビンゴを達成しうるドメイン上の参加者」。
  ブラウザを閉じても集約の中に残り続けるので、リロードして戻ってきたときに
  同じカードを引き継げる。画面の「オンライン表示」は Presence が別に担当する。

  ## 集約ルート経由でしか操作しない

  このモジュールの関数は `Game` からのみ呼ばれる。
  LiveView などの外側が直接 `Participant` を書き換えることは想定しない。
  """

  # alias: 他モジュールを短い名前で参照するための宣言。
  # これ以降 `BingoApp.Bingo.Card` を単に `Card` と書ける（import と違い関数は持ち込まない、名前だけの別名）。
  alias BingoApp.Bingo.Card

  # --- struct（構造体）の定義 -------------------------------------------
  # Elixir に「クラス」はない。データは struct（タグ付きの Map）で表現し、
  # 振る舞い（関数）は同名モジュール内に並べて置く、というのが定番の形。
  #
  # @enforce_keys: ここに挙げたキーを渡さずに `%__MODULE__{}` を作ろうとすると
  #   コンパイル/実行時エラーになる。「id や card が nil のまま存在する参加者」
  #   という不正な状態を型レベルというより構造レベルで作れなくしている
  #   （DDD でいう「エンティティは常に不変条件を満たす」を Elixir 流に守る方法）。
  # defstruct: 実際にどのフィールドを持つ struct か（デフォルト値も宣言できるが今回は無し）。
  @enforce_keys [:id, :name, :card, :joined_at]
  defstruct [:id, :name, :card, :joined_at]

  # --- @type / @spec: 型「ヒント」------------------------------------------
  # Elixir は動的型付け言語なので、これらは実行時には何も強制しない。
  # dialyzer という静的解析ツールや、人間が読むためのドキュメントとして機能する。
  #
  # `id()` のような型を先に定義しておくと、単なる String.t() より意図が伝わる
  # （「名前でも文字列だが id ではない」を型名で区別できる、という程度の効能）。
  @type id :: String.t()
  @type t :: %__MODULE__{
          id: id(),
          name: String.t(),
          card: Card.t(),
          joined_at: DateTime.t()
        }

  # --- new/4: このエンティティのコンストラクタ ------------------------------
  # 引数部分の `%Card{} = card` は「パターンマッチ」。
  #   単なる型チェックではなく、「Card struct の形をした値であること」を
  #   関数呼び出し時に照合し、一致しなければ FunctionClauseError になる。
  # 関数型らしい点: このモジュールに「Participant を書き換える」処理は無い。
  #   new はまっさらな struct を「組み立てて返す」だけで、副作用（DB保存など）は持たない。
  #   永続化やイベント発行は呼び出し側（集約ルート Game やその外）の責務。
  @spec new(id(), String.t(), Card.t(), DateTime.t()) :: t()
  def new(id, name, %Card{} = card, %DateTime{} = joined_at) do
    %__MODULE__{id: id, name: name, card: card, joined_at: joined_at}
  end

  # --- put_card/2: 状態「変更」に見えるが実体は新しい値を作って返す関数 ------
  # `%{participant | card: card}` は struct の update 構文。
  #   「participant をコピーして card フィールドだけ差し替えた、別の新しい struct」を作る。
  #   元の participant 変数の中身はこの呼び出しでは一切変化しない（immutable）。
  # DDD 的な「エンティティの状態遷移」は OOP のように既存オブジェクトを mutate するのではなく、
  #   「次の状態を表す新しい値を返す」ことで表現する、というのが Elixir/関数型の流儀。
  # `def ..., do: ...` は本体が1行のときに使える省略記法（`def foo do ... end` と同じ意味）。
  @spec put_card(t(), Card.t()) :: t()
  def put_card(%__MODULE__{} = participant, %Card{} = card), do: %{participant | card: card}

  # --- bingo?/1: 判定を Card モジュールへ委譲するだけの関数 -------------------
  # 引数の `%__MODULE__{card: card}` は「struct の中から card フィールドだけ取り出す」
  #   パターンマッチ（分割代入に近い）。id や name は使わないので束縛しない。
  # 関数名末尾の `?` は Elixir/Ruby 由来の慣習で「boolean を返す関数」の印（言語仕様ではなくただの命名規則）。
  # Participant 自身は「ビンゴかどうか」の判定ロジックを持たず、Card に委譲している点に注目
  #   （判定の知識は Card という値オブジェクトに閉じ込め、Participant は「誰が持っているか」だけを知る）。
  @spec bingo?(t()) :: boolean()
  def bingo?(%__MODULE__{card: card}), do: Card.bingo?(card)
end
