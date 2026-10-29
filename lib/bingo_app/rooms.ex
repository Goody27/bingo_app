defmodule BingoApp.Rooms do
  @moduledoc """
  境界づけられたコンテキスト「ルーム管理」の公開 API。

  部屋の作成・一覧・削除と、主催者かどうかの判定だけを扱う。
  ゲームの進行（抽選・カード・ビンゴ）は `BingoApp.Bingo` の領分で、
  こちらは一切関与しない。
  """

  alias BingoApp.Rooms.{Room, Store}

  @topic "rooms"
  @max_name_length 40

  # ----------------------------------------------------------------
  # 操作
  # ----------------------------------------------------------------

  @doc """
  ルームを作る。作成者がそのまま主催者になる。
  """
  @spec create_room(map()) :: {:ok, Room.t()} | {:error, atom()}
  def create_room(attrs) do
    name = attrs |> Map.get(:name, "") |> to_string() |> String.trim()
    host_id = Map.get(attrs, :host_id)
    required_lines = Map.get(attrs, :required_lines, 1)

    cond do
      name == "" ->
        {:error, :invalid_name}

      String.length(name) > @max_name_length ->
        {:error, :name_too_long}

      is_nil(host_id) ->
        {:error, :missing_host}

      true ->
        room = %Room{
          id: generate_id(),
          name: name,
          host_id: host_id,
          required_lines: required_lines,
          created_at: DateTime.utc_now()
        }

        :ok = Store.put(room)
        broadcast({:room_created, room})

        {:ok, room}
    end
  end

  @doc """
  ルームを削除する。進行中のゲームプロセスも一緒に畳む。
  """
  @spec delete_room(String.t()) :: :ok | {:error, :not_found}
  def delete_room(id) do
    case fetch_room(id) do
      {:error, :not_found} ->
        {:error, :not_found}

      {:ok, room} ->
        BingoApp.Bingo.close_game(id)
        :ok = Store.delete(id)
        broadcast({:room_deleted, room})
        :ok
    end
  end

  # ----------------------------------------------------------------
  # 参照
  # ----------------------------------------------------------------

  @doc """
  新しい順のルーム一覧。
  """
  @spec list_rooms() :: [Room.t()]
  def list_rooms do
    Store.all() |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
  end

  @spec fetch_room(String.t()) :: {:ok, Room.t()} | {:error, :not_found}
  def fetch_room(id) do
    case Store.fetch(id) do
      {:ok, room} -> {:ok, room}
      :error -> {:error, :not_found}
    end
  end

  @doc """
  その参加者が主催者か。抽選ボタンを出してよいかの判定に使う。
  """
  @spec host?(Room.t(), String.t() | nil) :: boolean()
  def host?(%Room{host_id: host_id}, participant_id), do: host_id == participant_id

  # ----------------------------------------------------------------
  # 購読
  # ----------------------------------------------------------------

  @doc """
  ルーム一覧の変化を購読する。`{:room_created, room}` などが届く。
  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(BingoApp.PubSub, @topic)

  defp broadcast(message), do: Phoenix.PubSub.broadcast(BingoApp.PubSub, @topic, message)

  @doc """
  エラー理由を画面表示用の日本語メッセージに変換する。
  """
  @spec message(atom()) :: String.t()
  def message(:invalid_name), do: "ルーム名を入力してください"
  def message(:name_too_long), do: "ルーム名は#{@max_name_length}文字までです"
  def message(:missing_host), do: "セッションが無効です。ページを再読み込みしてください"
  def message(:not_found), do: "ルームが見つかりません"
  def message(reason), do: "エラーが発生しました (#{inspect(reason)})"

  # URL に載せるので短く読みやすい文字種にする
  defp generate_id do
    8
    |> :crypto.strong_rand_bytes()
    |> Base.encode32(case: :lower, padding: false)
  end
end
