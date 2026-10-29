defmodule BingoApp.Bingo.GameSupervisor do
  @moduledoc """
  ゲームプロセスの生成・破棄を受け持つ DynamicSupervisor。

  ## なぜ DynamicSupervisor なのか

  ゲームルームは実行時に任意の数だけ作られ、終わったら消える。
  起動時に子プロセスが確定している通常の Supervisor では表現できない。

  ## restart: :temporary にしている理由

  `GameServer` は `restart: :temporary`（GameServer 側で指定）。
  ゲームの状態はメモリ上にしか無いので、クラッシュ後に再起動しても
  **空っぽのゲームが同じ room_id で復活する**だけで、参加者から見れば
  カードも抽選履歴も消えている。それは「復旧」ではなく「静かな事故」なので、
  再起動せずに落ちきらせ、参加者には「ゲームが終了した」と見せる方が正直。

  （状態を残したいなら、イベントを永続化して再生する設計が別途必要になる。
   今はメモリのみと決めているので、この割り切りを明示しておく。）
  """

  use DynamicSupervisor

  alias BingoApp.Bingo.{GameRegistry, GameServer}

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  ゲームを 1 つ起動する。同じ room_id がすでに動いていれば
  `{:error, {:already_started, pid}}` が返る（Registry が `keys: :unique` のため）。
  """
  @spec start_game(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_game(room_id, opts \\ []) do
    child_opts = Keyword.put(opts, :room_id, room_id)
    DynamicSupervisor.start_child(__MODULE__, {GameServer, child_opts})
  end

  @doc """
  起動済みならその pid を、無ければ起動して返す（冪等）。

  「存在を確認してから起動する」を呼び出し側に書かせると、
  確認と起動の間に別プロセスが起動してしまう隙間ができる。
  ここで `already_started` を吸収して、その競合を無くしている。
  """
  @spec ensure_started(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(room_id, opts \\ []) do
    case start_game(room_id, opts) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  ゲームを終了させてプロセスを落とす。
  """
  @spec stop_game(String.t()) :: :ok | {:error, :game_not_found}
  def stop_game(room_id) do
    case GameRegistry.whereis(room_id) do
      nil -> {:error, :game_not_found}
      pid -> DynamicSupervisor.terminate_child(__MODULE__, pid)
    end
  end

  @spec count_games() :: non_neg_integer()
  def count_games do
    %{active: active} = DynamicSupervisor.count_children(__MODULE__)
    active
  end
end
