defmodule BingoApp.Rooms.Store do
  @moduledoc """
  ルームのインメモリ保管庫。

  DB を使わないと決めているので、いまは Agent の中の Map が保管先。
  ここを ETS や Ecto に差し替えても `BingoApp.Rooms` の外には影響しない
  ——それが `Rooms` を境界として切っている実利。
  """

  use Agent

  alias BingoApp.Rooms.Room

  def start_link(_opts) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @spec put(Room.t()) :: :ok
  def put(%Room{} = room), do: Agent.update(__MODULE__, &Map.put(&1, room.id, room))

  @spec fetch(String.t()) :: {:ok, Room.t()} | :error
  def fetch(id), do: Agent.get(__MODULE__, &Map.fetch(&1, id))

  @spec all() :: [Room.t()]
  def all, do: Agent.get(__MODULE__, &Map.values/1)

  @spec delete(String.t()) :: :ok
  def delete(id), do: Agent.update(__MODULE__, &Map.delete(&1, id))
end
