defmodule BingoAppWeb.Plugs.VisitorId do
  @moduledoc """
  ブラウザごとに安定した ID をセッションに発行する。

  これがそのまま `participant_id`（ドメイン上の参加者 ID）になる。
  LiveView プロセスの pid を参加者 ID にしてしまうと、リロードのたびに
  別人扱いになりカードが作り直されるので、セッションに持たせる。

  ログイン機能は無いので「その人であること」の保証は無いが、
  「同じブラウザが戻ってきたら同じカードを返す」ためにはこれで足りる。
  """

  import Plug.Conn

  @session_key "visitor_id"

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_session(conn, @session_key) do
      nil -> put_session(conn, @session_key, generate())
      _id -> conn
    end
  end

  defp generate do
    16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
