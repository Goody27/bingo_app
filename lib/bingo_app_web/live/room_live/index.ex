defmodule BingoAppWeb.RoomLive.Index do
  @moduledoc """
  ルーム一覧・作成画面。
  """
  use BingoAppWeb, :live_view

  alias BingoApp.Rooms

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket), do: Rooms.subscribe()

    {:ok,
     socket
     |> assign(:visitor_id, session["visitor_id"])
     |> assign(:form, new_form())
     |> assign(:rooms, Rooms.list_rooms())}
  end

  # ------------------------------------------------------------------
  # UI イベントの窓口。判断は Rooms コンテキストに委ねる
  # ------------------------------------------------------------------

  @impl true
  def handle_event("create", %{"name" => name, "required_lines" => required_lines}, socket) do
    attrs = %{
      name: name,
      host_id: socket.assigns.visitor_id,
      required_lines: String.to_integer(required_lines)
    }

    case Rooms.create_room(attrs) do
      {:ok, room} -> {:noreply, push_navigate(socket, to: ~p"/rooms/#{room.id}")}
      {:error, reason} -> {:noreply, put_flash(socket, :error, Rooms.message(reason))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Rooms.fetch_room(id) do
      {:ok, room} ->
        if Rooms.host?(room, socket.assigns.visitor_id) do
          Rooms.delete_room(id)
          {:noreply, socket}
        else
          {:noreply, put_flash(socket, :error, "主催者のみ削除できます")}
        end

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Rooms.message(reason))}
    end
  end

  # ルーム一覧の変化は PubSub 経由でだけ反映する（自分の操作も他人の操作も同じ経路）
  @impl true
  def handle_info({event, _room}, socket) when event in [:room_created, :room_deleted] do
    {:noreply, assign(socket, :rooms, Rooms.list_rooms())}
  end

  defp new_form, do: to_form(%{"name" => "", "required_lines" => "1"})

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-3xl px-4 py-10">
      <header class="mb-10">
        <h1 class="text-3xl font-bold tracking-tight text-zinc-900">オンラインビンゴ</h1>
        <p class="mt-2 text-sm text-zinc-600">ルームを作って URL を共有すると、みんなで遊べます。</p>
      </header>

      <section class="mb-12 rounded-2xl border border-zinc-200 bg-white p-6 shadow-sm">
        <h2 class="mb-4 text-lg font-semibold text-zinc-900">ルームを作る</h2>

        <.form for={@form} phx-submit="create" class="flex flex-col gap-4 sm:flex-row sm:items-end">
          <div class="flex-1">
            <label class="mb-1 block text-sm font-medium text-zinc-700">ルーム名</label>
            <input
              type="text"
              name="name"
              value={@form[:name].value}
              placeholder="忘年会ビンゴ"
              autocomplete="off"
              class="w-full rounded-lg border-zinc-300 focus:border-zinc-400 focus:ring-0"
            />
          </div>

          <div>
            <label class="mb-1 block text-sm font-medium text-zinc-700">勝利条件</label>
            <select
              name="required_lines"
              class="rounded-lg border-zinc-300 focus:border-zinc-400 focus:ring-0"
            >
              <option value="1">1 ライン</option>
              <option value="2">2 ライン</option>
              <option value="3">3 ライン</option>
            </select>
          </div>

          <button
            type="submit"
            class="rounded-lg bg-zinc-900 px-5 py-2.5 text-sm font-semibold text-white hover:bg-zinc-700"
          >
            作成する
          </button>
        </.form>
      </section>

      <section>
        <h2 class="mb-4 text-lg font-semibold text-zinc-900">開催中のルーム</h2>

        <p :if={@rooms == []} class="rounded-xl bg-zinc-50 p-6 text-sm text-zinc-500">
          まだルームがありません。
        </p>

        <ul class="space-y-3">
          <li
            :for={room <- @rooms}
            class="flex items-center justify-between rounded-xl border border-zinc-200 bg-white px-5 py-4"
          >
            <div>
              <.link
                navigate={~p"/rooms/#{room.id}"}
                class="font-semibold text-zinc-900 hover:underline"
              >
                {room.name}
              </.link>
              <p class="mt-0.5 text-xs text-zinc-500">
                {room.required_lines} ライン達成で勝利
                <span :if={Rooms.host?(room, @visitor_id)} class="ml-2 text-emerald-600">あなたが主催</span>
              </p>
            </div>

            <button
              :if={Rooms.host?(room, @visitor_id)}
              phx-click="delete"
              phx-value-id={room.id}
              data-confirm="このルームを削除しますか?"
              class="text-sm text-zinc-400 hover:text-red-600"
            >
              削除
            </button>
          </li>
        </ul>
      </section>
    </div>
    """
  end
end
