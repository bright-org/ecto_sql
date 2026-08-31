defmodule Ecto.Adapters.SQL.TaskSupervisor do
  @moduledoc false

  use Supervisor

  def child_spec(opts) do
    name = Keyword.fetch!(opts, :name)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    Supervisor.start_link(__MODULE__, :ok, name: name)
  end

  def async_nolink(supervisor, fun) when is_function(fun, 0) do
    owner = self()
    ref = make_ref()

    spec = %{
      id: make_ref(),
      start: {__MODULE__, :start_task, [__MODULE__, :run_async, [owner, ref, fun]]},
      restart: :temporary
    }

    {:ok, pid} = Supervisor.start_child(supervisor, spec)
    mref = Process.monitor(pid)
    {pid, ref, mref}
  end

  def yield({pid, ref, mref}, timeout) do
    receive do
      {^ref, {:ok, result}} ->
        Process.demonitor(mref, [:flush])
        {:ok, result}

      {:DOWN, ^mref, :process, ^pid, reason} ->
        {:exit, reason}
    after
      timeout ->
        nil
    end
  end

  def shutdown({pid, ref, mref}) do
    Process.exit(pid, :kill)

    receive do
      {^ref, {:ok, result}} ->
        Process.demonitor(mref, [:flush])
        {:ok, result}

      {:DOWN, ^mref, :process, ^pid, _reason} ->
        nil
    after
      1000 ->
        Process.demonitor(mref, [:flush])
        nil
    end
  end

  def start_task(module, function_name, args) do
    {:ok, :proc_lib.spawn_link(module, function_name, args)}
  end

  def run_async(owner, ref, fun) do
    send(owner, {ref, {:ok, fun.()}})
  end

  @impl true
  def init(:ok) do
    Supervisor.init([], strategy: :one_for_one)
  end
end
