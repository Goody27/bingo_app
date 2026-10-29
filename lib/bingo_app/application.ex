defmodule BingoApp.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      BingoAppWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:bingo_app, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: BingoApp.PubSub},
      BingoAppWeb.Presence,
      # ルーム管理（Rooms コンテキスト）のインメモリ保管庫
      BingoApp.Rooms.Store,
      # ゲーム集約のプロセス群。Registry を先に立ち上げないと
      # GameServer が自分を登録できないので、この順序は入れ替えない
      BingoApp.Bingo.GameRegistry,
      BingoApp.Bingo.GameSupervisor,
      # Start to serve requests, typically the last entry
      BingoAppWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: BingoApp.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    BingoAppWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
