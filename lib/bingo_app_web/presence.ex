defmodule BingoAppWeb.Presence do
  @moduledoc """
  「いま接続している人」を追跡する。

  ## ドメインの参加者との違い

  ここが扱うのは接続状態であって、ゲームのドメインではない。
  ブラウザを閉じた人は Presence から消えるが、`Bingo` 集約の中には
  参加者として残り続ける（カードも順位も保持される）。

  そのため参加者一覧の表示は

    * 名前・カード・ビンゴ順位 → `Bingo` のスナップショット（正）
    * オンライン表示           → Presence（飾り）

  という重ね方をする。Presence を正にしてしまうと、
  リロードした瞬間に参加者が消えるような設計になってしまう。
  """

  use Phoenix.Presence,
    otp_app: :bingo_app,
    pubsub_server: BingoApp.PubSub

  @spec topic(String.t()) :: String.t()
  def topic(room_id), do: "room_presence:" <> room_id

  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(room_id), do: Phoenix.PubSub.subscribe(BingoApp.PubSub, topic(room_id))

  @doc """
  呼び出したプロセス（= LiveView プロセス）の接続を追跡する。
  プロセスが終われば自動的に外れる。
  """
  @spec track_self(String.t(), String.t(), map()) :: {:ok, binary()} | {:error, term()}
  def track_self(room_id, participant_id, meta \\ %{}) do
    track(
      self(),
      topic(room_id),
      participant_id,
      Map.put(meta, :online_at, System.system_time(:second))
    )
  end

  @doc """
  オンラインの participant_id 集合。
  """
  @spec online_ids(String.t()) :: MapSet.t(String.t())
  def online_ids(room_id) do
    room_id |> topic() |> list() |> Map.keys() |> MapSet.new()
  end
end
