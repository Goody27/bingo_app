defmodule BingoAppWeb.RoomLiveTest do
  @moduledoc """
  Web 層の結合テスト。

  ここで確かめたいのは「主催者の操作が、別ブラウザの参加者の画面に届くか」。
  2 つの conn を使って 2 人のブラウザを再現している
  （セッションが別なので `visitor_id`、つまり participant_id も別になる）。
  """
  use BingoAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import BingoApp.CardFixtures

  alias BingoApp.{Bingo, Rooms}
  alias BingoApp.Bingo.{Deck, Number}

  @row0 [1, 16, 31, 46, 61]

  defp visitor(conn) do
    conn = get(conn, ~p"/")
    {conn, Plug.Conn.get_session(conn, "visitor_id")}
  end

  defp deck_starting_with(numbers) do
    numbers = Enum.uniq(numbers)
    Deck.new!(numbers ++ (Number.all() -- numbers))
  end

  # ゲームプロセスを先に決定的な設定で起動しておく。
  # LiveView の mount が呼ぶ ensure_game は冪等なので、ここでの設定が保たれる。
  defp setup_room(host_id, opts \\ []) do
    {:ok, room} =
      Rooms.create_room(%{
        name: "テストルーム",
        host_id: host_id,
        required_lines: Keyword.get(opts, :required_lines, 1)
      })

    {:ok, _pid} =
      Bingo.ensure_game(room.id,
        host_id: host_id,
        deck: deck_starting_with(@row0),
        card_factory: &fixed_card/0
      )

    on_exit(fn -> Rooms.delete_room(room.id) end)

    room
  end

  # handle_event は socket を更新せず、反映は PubSub 経由の handle_info で起きる。
  # そのため render_submit/render_click の戻り値は 1 つ前の状態であり、
  # 反映後を見るには改めて render/1 する（実ブラウザでは直後に diff が届く）。
  defp join_as(view, name) do
    view
    |> form(~s(form[phx-submit="join"]), %{"name" => name})
    |> render_submit()

    render(view)
  end

  # LiveView の assigns から room_id / participant_id を取り出す
  defp guest_room(view), do: :sys.get_state(view.pid).socket.assigns.room.id
  defp guest_id(view), do: :sys.get_state(view.pid).socket.assigns.visitor_id

  defp click(view, event) do
    view |> element(~s(button[phx-click="#{event}"])) |> render_click()
  end

  describe "ルーム一覧" do
    test "ルームを作るとゲーム画面に遷移する", %{conn: conn} do
      {conn, _id} = visitor(conn)
      {:ok, view, html} = live(conn, ~p"/")

      assert html =~ "オンラインビンゴ"
      assert html =~ "まだルームがありません"

      {:error, {:live_redirect, %{to: to}}} =
        view
        |> form(~s(form[phx-submit="create"]), %{"name" => "忘年会", "required_lines" => "1"})
        |> render_submit()

      assert to =~ ~r"^/rooms/"

      on_exit(fn ->
        "/rooms/" <> id = to
        Rooms.delete_room(id)
      end)
    end

    test "作成者には主催表示と削除ボタンが出る", %{conn: conn} do
      {conn, host_id} = visitor(conn)
      room = setup_room(host_id)

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ room.name
      assert html =~ "あなたが主催"
      assert html =~ "削除"
    end

    test "他人のルームには削除ボタンが出ない", %{conn: conn} do
      {_host_conn, host_id} = visitor(build_conn())
      room = setup_room(host_id)

      {guest_conn, _guest_id} = visitor(conn)
      {:ok, _view, html} = live(guest_conn, ~p"/")

      assert html =~ room.name
      refute html =~ "あなたが主催"
    end

    test "存在しないルームは一覧へ戻される", %{conn: conn} do
      {conn, _id} = visitor(conn)

      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/rooms/no-such-room")
    end
  end

  describe "参加とカード配布" do
    test "名前を入れるとカードが配られる", %{conn: conn} do
      {conn, host_id} = visitor(conn)
      room = setup_room(host_id)

      {:ok, view, html} = live(conn, ~p"/rooms/#{room.id}")

      assert html =~ "参加する"
      refute html =~ "あなたのカード"

      html = join_as(view, "主催者")

      assert html =~ "あなたのカード"
      assert html =~ "FREE"
      refute html =~ "カードをもらう"
    end

    test "名前が空なら弾かれる", %{conn: conn} do
      {conn, host_id} = visitor(conn)
      room = setup_room(host_id)

      {:ok, view, _html} = live(conn, ~p"/rooms/#{room.id}")

      assert join_as(view, "   ") =~ "名前を入力してください"
    end

    test "リロードしても同じカードのまま（再入室が冪等）", %{conn: conn} do
      {conn, host_id} = visitor(conn)
      room = setup_room(host_id)

      {:ok, view, _html} = live(conn, ~p"/rooms/#{room.id}")
      join_as(view, "主催者")

      {:ok, snapshot} = Bingo.snapshot(room.id, host_id)
      before_card = snapshot.my_card

      # 同じセッションで入り直す
      {:ok, view2, html} = live(conn, ~p"/rooms/#{room.id}")

      assert html =~ "あなたのカード"
      refute render(view2) =~ "カードをもらう"

      {:ok, snapshot} = Bingo.snapshot(room.id, host_id)
      assert snapshot.my_card == before_card
    end
  end

  describe "主催者の操作と参加者へのリアルタイム反映" do
    setup %{conn: conn} do
      {host_conn, host_id} = visitor(conn)
      {guest_conn, guest_id} = visitor(build_conn())
      room = setup_room(host_id)

      {:ok, host_view, _html} = live(host_conn, ~p"/rooms/#{room.id}")
      {:ok, guest_view, _html} = live(guest_conn, ~p"/rooms/#{room.id}")

      join_as(host_view, "主催者")
      join_as(guest_view, "ゲスト")

      %{room: room, host: host_view, guest: guest_view, host_id: host_id, guest_id: guest_id}
    end

    test "参加者一覧が両方の画面に出る", %{host: host, guest: guest} do
      assert render(host) =~ "主催者"
      assert render(host) =~ "ゲスト"
      assert render(guest) =~ "主催者"
      assert render(guest) =~ "ゲスト"
    end

    test "主催者にだけ抽選ボタンが出る", %{host: host, guest: guest} do
      assert render(host) =~ "抽選を開始する"

      guest_html = render(guest)
      refute guest_html =~ "抽選を開始する"
      assert guest_html =~ "主催者が開始するのを待っています"
    end

    test "引いた番号が参加者の画面にも即座に反映される", %{host: host, guest: guest} do
      click(host, "start")
      assert render(guest) =~ "抽選中"

      click(host, "draw")

      # 固定した山なので 1 が引かれる
      assert render(host) =~ Number.label(1)
      assert render(guest) =~ Number.label(1)
      assert render(guest) =~ "個抽選済み"
      assert render(guest) =~ "残り 74 個"
    end

    test "抽選だけでビンゴが自動判定される", %{room: room, guest: guest, host: host} do
      click(host, "start")

      # 参加者は何もクリックしない。抽選だけで行 0 が揃う
      for _i <- 1..5, do: click(host, "draw")

      # 主催者が先に参加しているので 1 着は主催者、ゲストは 2 着。
      # フラッシュは最後に届いた達成イベントで上書きされるので、
      # 主催者の画面にはゲストの達成が出る（自分の順位はカードのバッジが持つ）。
      assert render(guest) =~ "ビンゴ！ 2 着です"
      assert render(host) =~ "さんがビンゴしました"
      assert render(host) =~ "1 着 ・ 上がり"

      {:ok, snapshot} = Bingo.snapshot(room.id, nil)
      # 同じカードなので主催者も同時に上がり、参加順に 1 着 2 着がつく
      assert [%{name: "主催者", rank: 1}, %{name: "ゲスト", rank: 2}] = snapshot.winners
    end

    test "上がったカードには以降の番号が塗られない", %{guest: guest, host: host} do
      click(host, "start")

      # 行 0 で上がったあと、列 0 の番号を引いても塗られない
      for _i <- 1..8, do: click(host, "draw")

      html = render(guest)
      assert html =~ "上がり"
      assert html =~ "このカードは上がりです"

      {:ok, snapshot} = Bingo.snapshot(guest_room(guest), guest_id(guest))
      refute 2 in BingoApp.Bingo.Card.marked_numbers(snapshot.my_card)
    end

    test "カードにクリックできる要素が無い", %{guest: guest, host: host} do
      click(host, "start")
      click(host, "draw")

      html = render(guest)

      refute html =~ ~s(phx-click="mark")
      assert html =~ "番号が引かれると自動でマークされます"
    end

    test "参加者には主催者用のボタンが出ない", %{guest: guest} do
      html = render(guest)

      refute html =~ ~s(phx-click="start")
      refute html =~ ~s(phx-click="draw")
      refute html =~ ~s(phx-click="finish")
    end

    test "ボタンが無くてもイベントは送れるので、サーバ側で拒否する", %{guest: guest, host: host} do
      click(host, "start")

      # ボタンを介さず draw イベントを直接送る（改変したクライアントの再現）
      assert render_click(guest, "draw", %{}) =~ "主催者のみ操作できます"
      assert render_click(guest, "finish", %{}) =~ "主催者のみ操作できます"

      # 状態は一切動いていない
      assert render(host) =~ "READY"
      assert render(host) =~ "抽選中"
    end

    test "主催者が終了させると両方の画面が終了になる", %{host: host, guest: guest} do
      click(host, "start")
      click(host, "finish")

      assert render(host) =~ "終了"
      assert render(guest) =~ "終了"
      refute render(host) =~ "番号を引く"
    end
  end
end
