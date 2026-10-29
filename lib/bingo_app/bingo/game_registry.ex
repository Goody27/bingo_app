defmodule BingoApp.Bingo.GameRegistry do
  @moduledoc """
  `room_id` からゲームプロセスを引くための Registry。

  ## なぜ pid ではなく room_id で呼ぶのか

  呼び出し側（LiveView やコンテキスト）が pid を持ち回ると、
  プロセスが再起動したときに古い pid を掴み続ける危険がある。
  Registry を挟めば、外側が知っているのは `room_id` という
  **ドメインの識別子だけ**で済み、プロセスの実体を意識しなくてよくなる。

  Registry はプロセスが死ぬと自動で登録を解除するので、
  「生きているゲーム」の一覧をここから引ける。
  """

  @doc """
  スーパーバイザの子として起動するための spec。
  `keys: :unique` なので 1 つの room_id に 1 プロセスしか登録できない
  （= 同じルームのゲームが二重に立ち上がらない）。
  """
  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: __MODULE__)
  end

  @doc """
  `GenServer.start_link(name: via(room_id))` の形で使う登録名。
  """
  @spec via(String.t()) :: {:via, Registry, {module(), String.t()}}
  def via(room_id), do: {:via, Registry, {__MODULE__, room_id}}

  @spec whereis(String.t()) :: pid() | nil
  def whereis(room_id) do
    case Registry.lookup(__MODULE__, room_id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  @spec alive?(String.t()) :: boolean()
  def alive?(room_id), do: whereis(room_id) != nil

  @doc """
  いま動いているゲームの room_id 一覧。
  """
  @spec room_ids() :: [String.t()]
  def room_ids do
    Registry.select(__MODULE__, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end
end
