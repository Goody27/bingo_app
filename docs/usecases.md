# ユースケース

## 1. アクター

```mermaid
flowchart LR
    H(("主催者<br/>Host"))
    P(("参加者<br/>Participant"))
    W(("観戦者<br/>Watcher"))

    subgraph UC["ユースケース"]
        U1["ルームを作る"]
        U2["ルームを削除する"]
        U3["ルームに参加する"]
        U4["抽選を開始する"]
        U5["番号を引く"]
        U6["ゲームを終了する"]
        U7["進行を見る"]
    end

    H --> U1
    H --> U2
    H --> U4
    H --> U5
    H --> U6
    H --> U3
    P --> U3
    P --> U7
    W --> U7

    style H fill:#eef2ff,stroke:#6366f1
    style P fill:#ecfdf5,stroke:#10b981
    style W fill:#fafafa,stroke:#a1a1aa
```

| アクター | 定義 | 識別方法 |
|---|---|---|
| 主催者 | そのルームを作った人 | `Room.host_id == visitor_id` を集約が保持して判定 |
| 参加者 | カードを持っている人 | `Game.participants` に載っている |
| 観戦者 | ルームを開いているが未参加 | 上のどちらでもない |

> 主催者も `join` すればカードを持てる（主催者かつ参加者）。

---

## 2. ユースケース一覧

| # | ユースケース | アクター | 入口（Context API） | ドメイン操作 | 発生イベント | 失敗理由 |
|---:|---|---|---|---|---|---|
| 1 | ルームを作る | 主催者 | `Rooms.create_room/1` | — | `{:room_created, room}` | `:invalid_name` `:name_too_long` `:missing_host` |
| 2 | ルームを削除する | 主催者 | `Rooms.delete_room/1` | — | `{:room_deleted, room}` | `:not_found` |
| 3 | ゲームを用意する | （画面表示時に自動） | `Bingo.ensure_game/2` | `Game.new/2` | — | `:invalid_required_lines` |
| 4 | ルームに参加する | 参加者・主催者 | `Bingo.join/3` | `Game.join/4` | `ParticipantJoined` + 追いつき `CellMarked`* | `:invalid_name` `:already_finished` |
| 5 | 抽選を開始する | 主催者 | `Bingo.start_drawing/2` | `Game.start/3` | `GameStarted` | `:not_host` `:no_participants` `:already_started` |
| 6 | 番号を引く | 主催者 | `Bingo.draw/2` | `Game.draw_number/3` | `NumberDrawn` + `CellMarked`* + `BingoAchieved`* + `GameFinished`? | `:not_host` `:not_started` `:already_finished` `:exhausted` |
| 7 | ゲームを終了する | 主催者 | `Bingo.finish/2` | `Game.finish/3` | `GameFinished` | `:not_host` `:already_finished` |
| 8 | 退室する | 参加者 | `Bingo.leave/2` | `Game.leave/3` | `ParticipantLeft` | `:not_participating` |
| 9 | 進行を見る | 全員 | `Bingo.snapshot/2` | `Snapshot.build/2` | — | `:game_not_found` |

`*` = 人数分ゼロ回以上　`?` = 条件付きで 1 回

---

## 3. レイヤごとの責務

1 回の操作が層をどう通るか。

```mermaid
flowchart TB
    subgraph L1["Web 層"]
        direction TB
        A1["handle_event で受ける"]
        A2["socket は更新しない"]
        A3["失敗したら message/1 でフラッシュ"]
    end
    subgraph L2["Context 層"]
        B1["room_id からプロセスを解決"]
        B2["理由 → 日本語メッセージの対応表"]
    end
    subgraph L3["プロセス層"]
        C1["現在時刻を与えて純粋関数を呼ぶ"]
        C2["新しい state を保持"]
        C3["events を Publisher へ"]
    end
    subgraph L4["ドメイン層"]
        D1["認可 → 状態 → ルールの順に検証"]
        D2["ok + 新しい state + events を返す"]
    end

    L1 --> L2 --> L3 --> L4

    style L4 fill:#ecfdf5,stroke:#10b981
```

### handle_event が薄いことの実例

```elixir
def handle_event("draw", _params, socket) do
  {:noreply, dispatch(socket, &Bingo.draw(&1.room.id, &1.visitor_id))}
end

defp dispatch(socket, fun) do
  case fun.(socket.assigns) do
    :ok -> socket                                              # 画面は更新しない
    {:error, reason} -> put_flash(socket, :error, Bingo.message(reason))
  end
end
```

ビンゴのルール判断がここに一切無い。`GameServer` の `handle_call` も同様に、
どれも「純粋関数を渡すだけ」の同じ形をしている。判断がその層に無いことが
コードの形として現れている。

---

## 4. シーケンス図

### UC-6 番号を引く（本命のシナリオ）

```mermaid
sequenceDiagram
    autonumber
    actor Host as 主催者
    participant LVH as LiveView<br/>（主催者）
    participant CTX as BingoApp.Bingo
    participant GS as GameServer
    participant G as Game（純粋）
    participant PS as PubSub
    participant LVP as LiveView<br/>（参加者）

    Host->>LVH: 「番号を引く」クリック
    LVH->>CTX: draw(room_id, visitor_id)
    CTX->>GS: call :draw, actor_id
    GS->>G: draw_number(game, actor_id, utc_now)

    Note over G: ensure_host → ensure_status<br/>Deck.draw → 全員のカードを自動マーク<br/>→ ビンゴ判定（参加順）

    G-->>GS: ok, 新しい状態, イベント列 NumberDrawn → CellMarked 複数 → BingoAchieved 条件付き
    GS->>GS: 新しい状態を保持
    GS->>PS: broadcast(events)
    GS-->>CTX: :ok
    CTX-->>LVH: :ok

    Note over LVH: ここでは何も描画しない

    PS-->>LVH: bingo_event NumberDrawn
    PS-->>LVP: bingo_event NumberDrawn

    LVH->>CTX: snapshot(room_id, viewer_id)
    LVP->>CTX: snapshot(room_id, viewer_id)

    LVH-->>Host: 再描画 + push_event fx:drawn
    LVP-->>LVP: 再描画 + 演出（ルーレット→着地）
```

**ポイントは 11〜16**。自分が起こした操作の結果も PubSub 経由で受け取る。
`handle_event` の中で socket を更新すると「自分の画面を更新するコード」と
「他人の画面を更新するコード」の 2 系統ができ、必ずどちらかがズレる。
更新経路を `handle_info` の 1 本に寄せれば、主催者も参加者も同じイベント列を見る。

### UC-4 ルームに参加する（途中参加の追いつき）

```mermaid
sequenceDiagram
    autonumber
    actor P as 参加者
    participant LV as LiveView
    participant CTX as BingoApp.Bingo
    participant GS as GameServer
    participant G as Game（純粋）
    participant PRE as Presence

    P->>LV: 名前を入力して送信
    LV->>CTX: join(room_id, visitor_id, name)
    CTX->>GS: call :join, id, name
    GS->>G: join(game, id, name, now)

    alt すでに参加済み（リロード・別タブ）
        Note over G: 冪等。カードは作り直さない
        G-->>GS: ok, 変更なし, イベントなし
    else 新規参加
        Note over G: card_factory でカードを 1 枚発行<br/>すでに引かれた番号をまとめて反映<br/>（運が良ければ入室即ビンゴ）
        G-->>GS: ok, 新しい状態, イベント列 ParticipantJoined → CellMarked 複数 → BingoAchieved 条件付き
    end

    GS-->>CTX: :ok
    CTX-->>LV: :ok
    LV->>PRE: track_self room_id, visitor_id, name
    Note over LV: 画面更新は PubSub 経由で届く
```

`join` を冪等にしているのが肝。LiveView はマウントのたびに `join` を呼ぶので、
ここが冪等でないとリロードのたびにカードが作り直され、塗った内容も順位も消える。

### UC-5 抽選を開始する（認可の流れ）

```mermaid
sequenceDiagram
    autonumber
    actor X as 参加者（非主催者）
    participant LV as LiveView
    participant CTX as BingoApp.Bingo
    participant GS as GameServer
    participant G as Game（純粋）

    Note over LV: そもそもボタンを描画していない<br/>（@snapshot.host が false）

    X->>LV: devtools から draw イベントを送信
    LV->>CTX: draw(room_id, visitor_id)
    CTX->>GS: call :draw, actor_id
    GS->>G: draw_number(game, actor_id, now)
    G-->>GS: error :not_host
    GS-->>CTX: error :not_host
    CTX-->>LV: error :not_host
    LV-->>X: フラッシュ「主催者のみ操作できます」

    Note over G: 状態は一切変わらない。<br/>イベントも発生しないので<br/>他の画面にも影響しない
```

`actor_id` はセッション cookie 由来の `visitor_id` で、`socket.assigns` に
入っているためクライアントから偽装できない。画面側の `@snapshot.host` は
「押せないボタンを見せない」ための親切であって、防御ではない。

---

## 5. エラーの流れ

ドメインは `:not_host` のような**理由（atom）**を返すだけで、文言を持たない。
表示に近い Context 層で日本語に翻訳する。

```mermaid
flowchart LR
    D["ドメイン<br/>error :not_host"] --> C["Context<br/>Bingo.message/1"]
    C --> W["Web<br/>フラッシュ「主催者のみ操作できます」"]

    style D fill:#ecfdf5,stroke:#10b981
```

これでドメイン層が UI の都合（言語・文言・トーン）から自由でいられる。

| 理由 | メッセージ |
|---|---|
| `:not_host` | 主催者のみ操作できます |
| `:not_started` | まだ抽選が始まっていません |
| `:already_started` | すでに抽選が始まっています |
| `:already_finished` | このゲームは終了しています |
| `:no_participants` | 参加者がいないため開始できません |
| `:exhausted` | すべての番号を引き終えました |
| `:invalid_name` | 名前を入力してください |
| `:game_not_found` | このゲームはすでに終了しています |

---

## 6. 演出の位置づけ

ドメインイベントを受けた **Web 層が** ブラウザへ効果を指示する。
ドメインは演出を知らない。

```mermaid
flowchart LR
    E["ドメインイベント"] --> LV["LiveView<br/>play/3"]
    LV -->|push_event| JS["fx.js"]

    E1["NumberDrawn"] -.-> F1["fx:drawn<br/>ルーレット → 着地<br/>自分のカードなら金色"]
    E2["BingoAchieved"] -.-> F2["fx:bingo<br/>紙吹雪 + ファンファーレ"]
    E3["リーチ数の増加*"] -.-> F3["fx:reach<br/>バナー + チャイム"]
    E4["GameStarted"] -.-> F4["fx:start"]

    style JS fill:#fef3c7,stroke:#f59e0b
```

`*` リーチだけはイベントではなく、スナップショットの前後を比べて
「増えた瞬間」に鳴らしている。`Card.reach_lines/1` は純粋関数なので
判定そのものはドメイン側にある。

### 性能上の注意

1 回の抽選で参加者の人数ぶん `CellMarked` が飛ぶ。素通しすると
「人数 × 人数」回スナップショットを作り直すことになるので、
LiveView は**他人の `CellMarked` を捨てている**。

```elixir
def handle_info({:bingo_event, %Events.CellMarked{} = event}, socket) do
  if event.participant_id == socket.assigns.visitor_id do
    {:noreply, load_snapshot(socket)}
  else
    {:noreply, socket}   # 他人のマークは自分の画面に影響しない
  end
end
```
