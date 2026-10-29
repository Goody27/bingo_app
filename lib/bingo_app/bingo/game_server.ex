defmodule BingoApp.Bingo.GameServer do
  @moduledoc """
  1 ゲーム = 1 プロセス。集約 `Game` を載せるプロセス境界。

  ## このモジュールがやらないこと

  ビンゴのルールを **一切** 判断しない。
  「引けるか」「どのカードが塗られるか」「ビンゴか」はすべて `Game` の純粋関数が決める。
  ここの仕事は 3 つだけ:

    1. 集約の状態を保持する
    2. ドメイン操作に現在時刻を与えて呼ぶ
    3. 返ってきたドメインイベントを `Publisher` に渡す

  `handle_call` がどれも同じ形をしているのは、判断がこの層に無いことの現れ。

  ## なぜ集約をプロセスにすると整合性が守れるのか

  GenServer はメッセージを 1 件ずつ順に処理する。
  つまり「2 人が同時に操作して状態が壊れる」ことが**原理的に起きない**。
  DDD で普通なら必要になる楽観ロックやトランザクション制御が、
  プロセスという言語機構だけで済んでしまう。

  ## state を外に出さない

  `%Game{}` を返す API は用意していない。読み取りは `snapshot/2` のみで、
  返るのは閲覧者視点に射影した読み取り専用の `Snapshot` 構造体。
  集約の外から state に触る経路を、そもそも作らない。

  ## 戻り値が `:ok` だけな理由

  操作系は成否しか返さない。画面更新に必要な情報はすべて PubSub のイベントで届く。
  「呼び出しの戻り値でも画面を更新する」経路を作ると、自分の画面を更新するコードと
  他人の画面を更新するコードの 2 系統ができ、必ずどちらかがズレる。
  更新経路は `handle_info` の 1 本に寄せる。
  """

  use GenServer, restart: :temporary

  alias BingoApp.Bingo.{Game, GameRegistry, Publisher, Snapshot}

  # 誰も操作しないまま放置されたゲームは畳む（ルームを自由に作れるので後始末が要る）
  @idle_timeout :timer.minutes(60)

  @type on_call :: :ok | {:error, atom()}

  # ----------------------------------------------------------------
  # 起動
  # ----------------------------------------------------------------

  @doc """
  ## Options

    * `:room_id`      - 必須。Registry への登録キーになる
    * `:deck`, `:config`, `:card_factory` - `Game.new/2` にそのまま渡す
  """
  def start_link(opts) do
    room_id = Keyword.fetch!(opts, :room_id)
    GenServer.start_link(__MODULE__, opts, name: GameRegistry.via(room_id))
  end

  # ----------------------------------------------------------------
  # クライアント API（すべて room_id で呼ぶ）
  # ----------------------------------------------------------------

  @spec join(String.t(), String.t(), String.t()) :: on_call()
  def join(room_id, participant_id, name),
    do: call(room_id, {:join, participant_id, name})

  @spec leave(String.t(), String.t()) :: on_call()
  def leave(room_id, participant_id), do: call(room_id, {:leave, participant_id})

  @doc """
  抽選の操作系は、誰の操作かを `actor_id` として必ず受け取る。
  主催者かどうかの判定は集約が行うので、この層では素通しする。
  """
  @spec start_drawing(String.t(), String.t()) :: on_call()
  def start_drawing(room_id, actor_id), do: call(room_id, {:start_drawing, actor_id})

  @spec draw(String.t(), String.t()) :: on_call()
  def draw(room_id, actor_id), do: call(room_id, {:draw, actor_id})

  @spec finish(String.t(), String.t()) :: on_call()
  def finish(room_id, actor_id), do: call(room_id, {:finish, actor_id})

  @doc """
  閲覧者視点の読み取り専用スナップショット。
  """
  @spec snapshot(String.t(), String.t() | nil) ::
          {:ok, Snapshot.t()} | {:error, :game_not_found}
  def snapshot(room_id, viewer_id \\ nil), do: call(room_id, {:snapshot, viewer_id})

  # ----------------------------------------------------------------
  # サーバ実装
  # ----------------------------------------------------------------

  @impl true
  def init(opts) do
    room_id = Keyword.fetch!(opts, :room_id)
    game = Game.new(room_id, Keyword.take(opts, [:deck, :config, :card_factory, :host_id]))

    {:ok, game, @idle_timeout}
  end

  @impl true
  def handle_call({:join, participant_id, name}, _from, game) do
    execute(game, &Game.join(&1, participant_id, name, &2))
  end

  def handle_call({:leave, participant_id}, _from, game) do
    execute(game, &Game.leave(&1, participant_id, &2))
  end

  def handle_call({:start_drawing, actor_id}, _from, game) do
    execute(game, &Game.start(&1, actor_id, &2))
  end

  def handle_call({:draw, actor_id}, _from, game) do
    execute(game, &Game.draw_number(&1, actor_id, &2))
  end

  def handle_call({:finish, actor_id}, _from, game) do
    execute(game, &Game.finish(&1, actor_id, &2))
  end

  def handle_call({:snapshot, viewer_id}, _from, game) do
    {:reply, {:ok, Snapshot.build(game, viewer_id)}, game, @idle_timeout}
  end

  @impl true
  def handle_info(:timeout, game), do: {:stop, :normal, game}

  # ----------------------------------------------------------------
  # 内部
  # ----------------------------------------------------------------

  # ドメイン操作の唯一の実行経路。
  # 「純粋関数を呼ぶ → 新しい state を保持する → イベントを配信する」を 1 箇所にまとめ、
  # 操作を追加してもこの手順を書き忘れられないようにしている。
  defp execute(game, domain_fun) do
    case domain_fun.(game, DateTime.utc_now()) do
      {:ok, new_game, events} ->
        Publisher.broadcast(new_game.room_id, events)
        {:reply, :ok, new_game, @idle_timeout}

      {:error, reason} ->
        {:reply, {:error, reason}, game, @idle_timeout}
    end
  end

  defp call(room_id, message) do
    case GameRegistry.whereis(room_id) do
      nil -> {:error, :game_not_found}
      pid -> GenServer.call(pid, message)
    end
  end
end
