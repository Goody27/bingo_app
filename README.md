# BingoApp

Elixir / Phoenix LiveView で作ったオンラインビンゴアプリ。
主催者が番号を引くと、参加者全員のカードがリアルタイムで自動マークされ、
ビンゴが自動判定される。複数のゲームルームを同時に開催できる。

## 設計ドキュメント

DDD（ドメイン駆動設計）を意識した構成にしている。図つきの設計書は [`docs/`](docs/) にある。

| ドキュメント | 内容 |
|---|---|
| [docs/README.md](docs/README.md) | 全体像とレイヤ構成 |
| [docs/architecture.md](docs/architecture.md) | 境界づけられたコンテキスト、依存方向、OTP のプロセス構成 |
| [docs/domain-model.md](docs/domain-model.md) | 集約・値オブジェクト・ドメインイベント、状態遷移、不変条件 |
| [docs/usecases.md](docs/usecases.md) | アクターとユースケース、シーケンス図 |
| [docs/decisions.md](docs/decisions.md) | 設計判断とその理由 |

## 起動

```sh
mix setup          # 依存関係のインストール
mix phx.server     # http://localhost:4000
```

開発サーバーは全インターフェースで待ち受けるので、同じ Wi-Fi のスマホからも
`http://<このPCのIP>:4000` で参加できる（`config/dev.exs`）。

## テスト

```sh
mix test
```

| 対象 | 件数 | 何を検証しているか |
|---|---:|---|
| 値オブジェクト | 37 | ビンゴ判定、列の割当、カード生成 |
| 集約（純粋関数） | 38 | 不変条件 8 つ。プロセスも PubSub も起動しない |
| プロセス層 | 25 | Registry 解決、ルーム独立性、イベント配信、直列化 |
| Web 層 | 16 | 2ブラウザ間のリアルタイム同期、認可、演出 |

## 技術メモ

* Elixir は `.tool-versions` でこのプロジェクトだけ 1.17.3-otp-25 に固定している
  （依存ライブラリの新しい版が Elixir 1.15+ を要求するため）
* 永続化は行っていない。ルームもゲームもインメモリで、再起動すると消える
