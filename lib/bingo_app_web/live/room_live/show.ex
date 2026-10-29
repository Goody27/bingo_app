defmodule BingoAppWeb.RoomLive.Show do
  @moduledoc """
  ゲーム画面（主催者・参加者の共通画面）。

  ## handle_event が薄いこと

  このモジュールの `handle_event` はどれも「コンテキストを呼んで、
  失敗したらフラッシュを出す」だけで、ビンゴのルール判断を一切持たない。
  「引けるか」「誰が引いてよいか」「ビンゴか」は `BingoApp.Bingo` の向こう側の話。

  ## 主催者判定について

  操作ボタンを出すかどうかは `@snapshot.host` で決めるが、これは **見た目の制御**
  でしかない。クライアントは任意の `phx-click` を送れるので、実際の可否は
  集約（`Game` の `ensure_host`）が裁定する。画面側の判定はあくまで
  「押せないボタンを見せない」ための親切であって、防御ではない。

  ## 画面更新の経路を 1 本にしている

  `handle_event` の中で socket を更新しない。
  自分の操作の結果も、他人の操作の結果も、どちらも PubSub 経由で
  `handle_info` に届いてから反映する。経路を 1 本にしておけば、
  主催者も参加者も同じイベント列を見ることになり、状態がズレない。

  ## 演出の出し方

  ドメインイベントを受けたときに `push_event/3` でブラウザに「効果の指示」を送る。
  ドメイン側はイベントを返すだけで演出を知らず、どう盛り上げるかは Web 層が決める。
  演出用の DOM は `phx-update="ignore"` で LiveView の管理外に置き、
  差分更新とアニメーションが競合しないようにしている。
  """
  use BingoAppWeb, :live_view

  alias BingoApp.Bingo
  alias BingoApp.Bingo.{Card, Cell, Events, Number, Snapshot}
  alias BingoApp.Rooms
  alias BingoAppWeb.Presence

  @impl true
  def mount(%{"id" => room_id}, session, socket) do
    case Rooms.fetch_room(room_id) do
      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, Rooms.message(:not_found))
         |> push_navigate(to: ~p"/")}

      {:ok, room} ->
        # 部屋に入ったタイミングでゲームプロセスを用意する（冪等）。
        # 主催者が誰かはここで集約に渡され、以降の認可はすべて集約が行う。
        {:ok, _pid} =
          Bingo.ensure_game(room.id, host_id: room.host_id, required_lines: room.required_lines)

        visitor_id = session["visitor_id"]

        if connected?(socket) do
          Bingo.subscribe(room.id)
          Presence.subscribe(room.id)
        end

        socket =
          socket
          |> assign(room: room, visitor_id: visitor_id, name_form: to_form(%{"name" => ""}))
          |> assign(online: Presence.online_ids(room.id))
          |> load_snapshot()
          |> track_if_joined()

        {:ok, socket}
    end
  end

  # ------------------------------------------------------------------
  # UI イベントの窓口（判断はすべて Bingo コンテキストに委譲）
  # ------------------------------------------------------------------

  @impl true
  def handle_event("join", %{"name" => name}, socket) do
    %{room: room, visitor_id: visitor_id} = socket.assigns

    case Bingo.join(room.id, visitor_id, name) do
      :ok ->
        Presence.track_self(room.id, visitor_id, %{name: name})
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Bingo.message(reason))}
    end
  end

  def handle_event("start", _params, socket) do
    {:noreply, dispatch(socket, &Bingo.start_drawing(&1.room.id, &1.visitor_id))}
  end

  def handle_event("draw", _params, socket) do
    {:noreply, dispatch(socket, &Bingo.draw(&1.room.id, &1.visitor_id))}
  end

  def handle_event("finish", _params, socket) do
    {:noreply, dispatch(socket, &Bingo.finish(&1.room.id, &1.visitor_id))}
  end

  # ------------------------------------------------------------------
  # 状態更新はここ 1 本だけ
  # ------------------------------------------------------------------

  # 他人がマークされただけでは自分の画面は何も変わらない。
  # 1 回の抽選で参加者の人数ぶん CellMarked が飛ぶので、素通しすると
  # 「人数 × 人数」回のスナップショット再構築になる。ここで落としておく。
  @impl true
  def handle_info({:bingo_event, %Events.CellMarked{} = event}, socket) do
    if event.participant_id == socket.assigns.visitor_id do
      {:noreply, load_snapshot(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:bingo_event, event}, socket) do
    previous = socket.assigns.snapshot
    socket = load_snapshot(socket)

    {:noreply, socket |> announce(event) |> play(event, previous)}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    {:noreply, assign(socket, :online, Presence.online_ids(socket.assigns.room.id))}
  end

  # ------------------------------------------------------------------
  # 演出（ドメインイベント → ブラウザへの効果指示）
  # ------------------------------------------------------------------

  defp play(socket, %Events.NumberDrawn{} = event, previous) do
    snapshot = socket.assigns.snapshot
    on_my_card = snapshot.my_card != nil and Card.has_number?(snapshot.my_card, event.number)

    socket
    |> push_event("fx:drawn", %{
      label: Number.label(event.number),
      number: event.number,
      mine: on_my_card
    })
    |> push_reach(previous)
  end

  defp play(socket, %Events.BingoAchieved{} = event, _previous) do
    push_event(socket, "fx:bingo", %{
      name: event.name,
      rank: event.rank,
      mine: event.participant_id == socket.assigns.visitor_id
    })
  end

  defp play(socket, %Events.GameStarted{}, _previous), do: push_event(socket, "fx:start", %{})
  defp play(socket, %Events.GameFinished{}, _previous), do: push_event(socket, "fx:finish", %{})
  defp play(socket, _event, _previous), do: socket

  # リーチが増えた瞬間だけ鳴らす。スナップショットの前後を比べるのが一番素直。
  defp push_reach(socket, previous) do
    snapshot = socket.assigns.snapshot
    before_count = if previous, do: length(previous.my_reach), else: 0

    if snapshot.my_rank == nil and length(snapshot.my_reach) > before_count do
      push_event(socket, "fx:reach", %{count: length(snapshot.my_reach)})
    else
      socket
    end
  end

  # 自分のビンゴだけは強めに知らせる
  defp announce(socket, %Events.BingoAchieved{participant_id: id, rank: rank} = event) do
    if id == socket.assigns.visitor_id do
      put_flash(socket, :info, "ビンゴ！ #{rank} 着です")
    else
      put_flash(socket, :info, "#{event.name} さんがビンゴしました（#{rank} 着）")
    end
  end

  defp announce(socket, _event), do: socket

  # ------------------------------------------------------------------
  # 内部ヘルパ
  # ------------------------------------------------------------------

  defp dispatch(socket, fun) do
    case fun.(socket.assigns) do
      :ok -> socket
      {:error, reason} -> put_flash(socket, :error, Bingo.message(reason))
    end
  end

  defp load_snapshot(socket) do
    case Bingo.snapshot(socket.assigns.room.id, socket.assigns.visitor_id) do
      {:ok, snapshot} -> assign(socket, :snapshot, snapshot)
      {:error, :game_not_found} -> assign(socket, :snapshot, nil)
    end
  end

  defp track_if_joined(socket) do
    %{room: room, visitor_id: visitor_id, snapshot: snapshot} = socket.assigns

    if connected?(socket) and snapshot && Snapshot.joined?(snapshot) do
      name = Enum.find_value(snapshot.participants, &if(&1.id == visitor_id, do: &1.name))
      Presence.track_self(room.id, visitor_id, %{name: name})
    end

    socket
  end

  defp status_label(:waiting), do: "開始前"
  defp status_label(:drawing), do: "抽選中"
  defp status_label(:finished), do: "終了"

  defp status_class(:waiting), do: "bg-zinc-200 text-zinc-700"
  defp status_class(:drawing), do: "bg-emerald-500 text-white"
  defp status_class(:finished), do: "bg-zinc-900 text-white"

  # ------------------------------------------------------------------
  # 描画
  # ------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- 演出用レイヤー。LiveView の差分更新とアニメーションが衝突しないよう管理外に置く --%>
    <div id="fx" phx-hook="Effects" phx-update="ignore"></div>

    <div class="mx-auto max-w-5xl px-4 py-6 sm:py-8">
      <.link navigate={~p"/"} class="text-sm text-zinc-500 hover:underline">&larr; ルーム一覧</.link>

      <header class="mb-6 mt-3 flex flex-wrap items-center gap-3">
        <h1 class="text-2xl font-bold text-zinc-900">{@room.name}</h1>
        <span
          :if={@snapshot}
          class={["rounded-full px-3 py-1 text-xs font-semibold", status_class(@snapshot.status)]}
        >
          {status_label(@snapshot.status)}
        </span>
        <span class="text-xs text-zinc-500">{@room.required_lines} ライン達成で勝利</span>
        <span
          :if={@snapshot && @snapshot.host}
          class="rounded-full bg-indigo-100 px-3 py-1 text-xs font-semibold text-indigo-700"
        >
          あなたが主催者
        </span>
      </header>

      <p :if={is_nil(@snapshot)} class="rounded-xl bg-white p-6 text-sm text-zinc-500 shadow-sm">
        このゲームは終了しました。
      </p>

      <div :if={@snapshot} class="grid gap-6 lg:grid-cols-[1fr_300px]">
        <div class="space-y-6">
          <.join_form :if={not Snapshot.joined?(@snapshot)} form={@name_form} />
          <.draw_panel snapshot={@snapshot} />
          <.card_panel :if={Snapshot.joined?(@snapshot)} snapshot={@snapshot} />
          <.drawn_board snapshot={@snapshot} />
        </div>

        <aside class="space-y-4">
          <.participant_list snapshot={@snapshot} online={@online} viewer_id={@visitor_id} />
          <.winner_list snapshot={@snapshot} />
        </aside>
      </div>
    </div>
    """
  end

  # 参加前の名前入力
  defp join_form(assigns) do
    ~H"""
    <section class="rounded-2xl border border-zinc-200 bg-white p-6 shadow-sm">
      <h2 class="mb-3 text-lg font-semibold text-zinc-900">参加する</h2>
      <.form for={@form} phx-submit="join" class="flex gap-3">
        <input
          type="text"
          name="name"
          value={@form[:name].value}
          placeholder="お名前"
          autocomplete="off"
          class="flex-1 rounded-lg border-zinc-300 focus:border-zinc-400 focus:ring-0"
        />
        <button
          type="submit"
          class="rounded-lg bg-zinc-900 px-5 py-2.5 text-sm font-semibold text-white hover:bg-zinc-700"
        >
          カードをもらう
        </button>
      </.form>
    </section>
    """
  end

  # 最新の抽選番号と主催者の操作
  defp draw_panel(assigns) do
    ~H"""
    <section class="overflow-hidden rounded-2xl bg-gradient-to-br from-zinc-900 to-zinc-700 p-6 text-white shadow-lg">
      <div class="flex flex-col items-center gap-6 sm:flex-row">
        <div class={[
          "relative flex h-32 w-32 shrink-0 items-center justify-center rounded-full",
          "bg-white/10 ring-4 ring-white/20 backdrop-blur",
          @snapshot.status == :drawing && @snapshot.latest_number && "animate-glow"
        ]}>
          <span
            :if={@snapshot.latest_number}
            class="bg-gradient-to-b from-white to-zinc-300 bg-clip-text text-5xl font-black tabular-nums text-transparent"
          >
            {Number.label(@snapshot.latest_number)}
          </span>
          <span :if={is_nil(@snapshot.latest_number)} class="text-sm tracking-widest text-white/40">
            READY
          </span>
        </div>

        <div class="flex-1 text-center sm:text-left">
          <p class="text-sm text-white/70">
            <span class="text-2xl font-bold tabular-nums text-white">{@snapshot.drawn_count}</span>
            個抽選済み ・ 残り {@snapshot.remaining_count} 個
          </p>

          <div :if={@snapshot.host} class="mt-4 flex flex-wrap justify-center gap-3 sm:justify-start">
            <button
              :if={@snapshot.status == :waiting}
              phx-click="start"
              class="rounded-lg bg-emerald-500 px-6 py-3 text-sm font-bold text-white shadow-lg transition hover:bg-emerald-400 active:scale-95"
            >
              抽選を開始する
            </button>
            <button
              :if={@snapshot.status == :drawing}
              phx-click="draw"
              class="rounded-lg bg-white px-8 py-3 text-sm font-bold text-zinc-900 shadow-lg transition hover:bg-zinc-100 active:scale-95"
            >
              番号を引く
            </button>
            <button
              :if={@snapshot.status != :finished}
              phx-click="finish"
              data-confirm="ゲームを終了しますか?"
              class="rounded-lg border border-white/30 px-4 py-3 text-sm text-white/70 transition hover:bg-white/10"
            >
              終了する
            </button>
          </div>

          <p
            :if={not @snapshot.host and @snapshot.status == :waiting}
            class="mt-3 text-sm text-white/60"
          >
            主催者が開始するのを待っています。
          </p>
        </div>
      </div>
    </section>
    """
  end

  # 自分のビンゴカード
  defp card_panel(assigns) do
    ~H"""
    <section class={[
      "rounded-2xl border p-6 shadow-sm transition",
      if(@snapshot.my_rank,
        do: "border-amber-400 bg-gradient-to-br from-amber-50 to-white",
        else: "border-zinc-200 bg-white"
      )
    ]}>
      <div class="mb-4 flex flex-wrap items-center gap-2">
        <h2 class="flex-1 text-lg font-semibold text-zinc-900">あなたのカード</h2>

        <span
          :if={@snapshot.my_rank}
          class="rounded-full bg-amber-500 px-3 py-1 text-xs font-bold text-white shadow"
        >
          ビンゴ！ {@snapshot.my_rank} 着 ・ 上がり
        </span>
        <span
          :if={is_nil(@snapshot.my_rank) and @snapshot.my_reach != []}
          class="animate-pulse rounded-full bg-rose-500 px-3 py-1 text-xs font-bold text-white"
        >
          リーチ ×{length(@snapshot.my_reach)}
        </span>
      </div>

      <div class="mx-auto grid max-w-sm grid-cols-5 gap-1.5 sm:max-w-md">
        <div
          :for={letter <- ~w(B I N G O)}
          class="pb-1 text-center text-sm font-black tracking-widest text-zinc-400"
        >
          {letter}
        </div>

        <%= for row <- Card.rows(@snapshot.my_card), cell <- row do %>
          <div class={[
            "flex aspect-square items-center justify-center rounded-lg text-lg font-bold tabular-nums transition-all duration-300",
            cond do
              Cell.free?(cell) ->
                "bg-zinc-800 text-[10px] tracking-wider text-white"

              Cell.marked?(cell) and cell.number == @snapshot.latest_number ->
                "animate-pop bg-emerald-500 text-white shadow-lg ring-4 ring-emerald-300"

              Cell.marked?(cell) ->
                "bg-emerald-500 text-white shadow-sm"

              true ->
                "bg-zinc-100 text-zinc-500"
            end
          ]}>
            {if Cell.free?(cell), do: "FREE", else: cell.number}
          </div>
        <% end %>
      </div>

      <p :if={@snapshot.my_rank} class="mt-4 text-center text-xs font-medium text-amber-700">
        このカードは上がりです。おめでとうございます。
      </p>
      <p :if={is_nil(@snapshot.my_rank)} class="mt-4 text-center text-xs text-zinc-400">
        番号が引かれると自動でマークされます。
      </p>
    </section>
    """
  end

  # 抽選済みの番号
  defp drawn_board(assigns) do
    ~H"""
    <section class="rounded-2xl border border-zinc-200 bg-white p-6 shadow-sm">
      <h2 class="mb-4 text-lg font-semibold text-zinc-900">抽選済みの番号</h2>

      <p :if={@snapshot.drawn_numbers == []} class="text-sm text-zinc-500">まだ引かれていません。</p>

      <div class="flex flex-wrap gap-1.5">
        <span
          :for={number <- @snapshot.drawn_numbers}
          class={[
            "inline-flex h-9 w-9 items-center justify-center rounded-full text-sm font-bold tabular-nums transition",
            if(number == @snapshot.latest_number,
              do: "animate-pop bg-zinc-900 text-white ring-2 ring-zinc-900 ring-offset-2",
              else: "bg-zinc-100 text-zinc-600"
            )
          ]}
        >
          {number}
        </span>
      </div>
    </section>
    """
  end

  # 参加者一覧（ドメインの参加者 + Presence のオンライン表示）
  defp participant_list(assigns) do
    ~H"""
    <section class="rounded-2xl border border-zinc-200 bg-white p-5 shadow-sm">
      <h2 class="mb-3 text-sm font-semibold text-zinc-900">
        参加者 <span class="text-zinc-400">{length(@snapshot.participants)}</span>
      </h2>

      <p :if={@snapshot.participants == []} class="text-sm text-zinc-500">まだ誰もいません。</p>

      <ul class="space-y-2">
        <li :for={participant <- @snapshot.participants} class="flex items-center gap-2 text-sm">
          <span class={[
            "h-2 w-2 shrink-0 rounded-full",
            if(MapSet.member?(@online, participant.id), do: "bg-emerald-500", else: "bg-zinc-300")
          ]} />
          <span class={["flex-1 truncate", participant.id == @viewer_id && "font-bold"]}>
            {participant.name}<span :if={participant.id == @viewer_id} class="text-zinc-400">（あなた）</span>
          </span>
          <span
            :if={participant.bingo}
            class="rounded bg-amber-500 px-1.5 py-0.5 text-xs font-bold text-white"
          >
            {participant.rank} 着
          </span>
        </li>
      </ul>
    </section>
    """
  end

  defp winner_list(assigns) do
    ~H"""
    <section
      :if={@snapshot.winners != []}
      class="rounded-2xl border border-amber-300 bg-amber-50 p-5 shadow-sm"
    >
      <h2 class="mb-3 text-sm font-semibold text-amber-900">ビンゴ達成</h2>
      <ol class="space-y-1.5">
        <li :for={winner <- @snapshot.winners} class="flex items-center gap-2 text-sm text-amber-900">
          <span class="font-black tabular-nums">{winner.rank}.</span>
          <span class="flex-1 truncate">{winner.name}</span>
          <span class="text-xs text-amber-600">{length(winner.lines)} ライン</span>
        </li>
      </ol>
    </section>
    """
  end
end
