defmodule BingoApp.Bingo do
  @moduledoc """
  境界づけられたコンテキスト「ゲーム進行」の公開 API（ファサード）。

  ## この境界の約束

  外側（LiveView など）が触ってよいのは **このモジュールだけ**。
  `Game` / `GameServer` / `GameRegistry` を直接 alias してはいけない。

  そうする理由は 2 つ。

    1. 「Registry で pid を引く」「DynamicSupervisor に子を追加する」といった
       プロセスの都合を、呼び出し側から完全に隠せる。
       外側が知っているのは `room_id` というドメインの識別子だけになる。
    2. 実装の置き換え（例えば将来イベントを永続化する）が、
       この境界の内側で完結する。

  ## 戻り値の形

  操作系は `:ok | {:error, reason}` のみを返す。
  画面更新に必要な情報は `subscribe/1` したプロセスに PubSub で届く。
  """

  alias BingoApp.Bingo.{GameConfig, GameServer, GameSupervisor, Publisher, Snapshot}

  @type room_id :: String.t()
  @type participant_id :: String.t()
  @type on_call :: :ok | {:error, atom()}

  # ----------------------------------------------------------------
  # ゲームのライフサイクル
  # ----------------------------------------------------------------

  @doc """
  ルームのゲームを起動する。すでに動いていれば何もしない（冪等）。

  ## Options

    * `:host_id`        - 主催者の participant_id。渡さないと誰も抽選を操作できない
    * `:required_lines` - 何ライン揃えば勝ちか（既定 1）

  「部屋に入ったら必要に応じてゲームを立ち上げる」という使い方を想定している。
  部屋の作成時に必ず起動する形にすると、プロセスが落ちたあと誰も入れなくなるため。
  """
  @spec ensure_game(room_id(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_game(room_id, opts \\ []) do
    with {:ok, config} <- GameConfig.new(Keyword.take(opts, [:required_lines])) do
      server_opts =
        opts
        |> Keyword.take([:deck, :card_factory, :host_id])
        |> Keyword.put(:config, config)

      GameSupervisor.ensure_started(room_id, server_opts)
    end
  end

  @doc """
  ゲームプロセスを落とす。ルーム自体の削除は `BingoApp.Rooms` の責務。
  """
  @spec close_game(room_id()) :: :ok | {:error, :game_not_found}
  defdelegate close_game(room_id), to: GameSupervisor, as: :stop_game

  @spec running?(room_id()) :: boolean()
  defdelegate running?(room_id), to: BingoApp.Bingo.GameRegistry, as: :alive?

  # ----------------------------------------------------------------
  # ドメイン操作
  # ----------------------------------------------------------------

  @spec join(room_id(), participant_id(), String.t()) :: on_call()
  defdelegate join(room_id, participant_id, name), to: GameServer

  @spec leave(room_id(), participant_id()) :: on_call()
  defdelegate leave(room_id, participant_id), to: GameServer

  @doc """
  抽選の操作系はすべて「誰が操作したか」を伴う。主催者以外は `{:error, :not_host}`。
  """
  @spec start_drawing(room_id(), participant_id()) :: on_call()
  defdelegate start_drawing(room_id, actor_id), to: GameServer

  @spec draw(room_id(), participant_id()) :: on_call()
  defdelegate draw(room_id, actor_id), to: GameServer

  @spec finish(room_id(), participant_id()) :: on_call()
  defdelegate finish(room_id, actor_id), to: GameServer

  # ----------------------------------------------------------------
  # 参照・購読
  # ----------------------------------------------------------------

  @spec snapshot(room_id(), participant_id() | nil) ::
          {:ok, Snapshot.t()} | {:error, :game_not_found}
  defdelegate snapshot(room_id, viewer_id \\ nil), to: GameServer

  @doc """
  ルームのドメインイベントを購読する。`{:bingo_event, event}` が届く。
  """
  @spec subscribe(room_id()) :: :ok | {:error, term()}
  defdelegate subscribe(room_id), to: Publisher

  @spec unsubscribe(room_id()) :: :ok
  defdelegate unsubscribe(room_id), to: Publisher

  @doc """
  エラー理由を画面表示用の日本語メッセージに変換する。

  ドメインは `:no_participants` のような**理由**を返すだけで、文言は持たない。
  表示に近いこの境界で翻訳することで、ドメイン層が UI の都合から自由でいられる。
  """
  @spec message(atom()) :: String.t()
  def message(:game_not_found), do: "このゲームはすでに終了しています"
  def message(:not_started), do: "まだ抽選が始まっていません"
  def message(:already_started), do: "すでに抽選が始まっています"
  def message(:already_finished), do: "このゲームは終了しています"
  def message(:not_drawing), do: "いまは操作できません"
  def message(:no_participants), do: "参加者がいないため開始できません"
  def message(:not_host), do: "主催者のみ操作できます"
  def message(:exhausted), do: "すべての番号を引き終えました"
  def message(:not_participating), do: "このゲームに参加していません"
  def message(:invalid_name), do: "名前を入力してください"
  def message(reason), do: "エラーが発生しました (#{inspect(reason)})"
end
