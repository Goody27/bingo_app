defmodule BingoApp.Bingo.Publisher do
  @moduledoc """
  ドメインイベントを PubSub に流す係。

  ## 副作用をここに閉じ込める

  集約（`Game`）はイベントを**返す**だけで、配信のことを知らない。
  `GameServer` は返ってきたイベントをこのモジュールに渡すだけで、
  「どのトピックに」「どういう形で」流すかを知らない。

  結果として、通知の仕組みを差し替えたくなったとき（例えば将来
  Webhook も飛ばしたくなったとき）に触る場所がここ 1 箇所で済む。

  ## メッセージ形式

  `{:bingo_event, event}` で包んで送る。
  LiveView の `handle_info` は他のメッセージも受け取るので、
  裸の構造体を流すとパターンマッチが衝突しやすいため。
  """

  alias BingoApp.Bingo.Events

  @pubsub BingoApp.PubSub

  @spec topic(String.t()) :: String.t()
  def topic(room_id), do: "bingo:room:" <> room_id

  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(room_id), do: Phoenix.PubSub.subscribe(@pubsub, topic(room_id))

  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(room_id), do: Phoenix.PubSub.unsubscribe(@pubsub, topic(room_id))

  @doc """
  イベント列を発生順に配信する。
  """
  @spec broadcast(String.t(), [Events.t()]) :: :ok
  def broadcast(room_id, events) when is_list(events) do
    Enum.each(events, fn event ->
      Phoenix.PubSub.broadcast(@pubsub, topic(room_id), {:bingo_event, event})
    end)
  end
end
