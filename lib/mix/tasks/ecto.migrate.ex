defmodule Mix.Tasks.Ecto.Migrate do
  use Mix.Task
  import Mix.Ecto
  import Mix.EctoSQL

  @shortdoc "Runs the repository migrations on AtomVM"

  @aliases [
    n: :step,
    r: :repo
  ]

  @switches [
    all: :boolean,
    step: :integer,
    to: :integer,
    to_exclusive: :integer,
    quiet: :boolean,
    prefix: :string,
    pool_size: :integer,
    log_level: :string,
    log_migrations_sql: :boolean,
    log_migrator_sql: :boolean,
    strict_version_order: :boolean,
    repo: [:keep, :string],
    no_compile: :boolean,
    no_deps_check: :boolean,
    migrations_path: :keep
  ]

  @moduledoc """
  Runs the pending migrations for the given repository on AtomVM.

  Host Mix compiles migrations, packs the AVM with a one-shot Boot that calls
  `Phoenix.AtomVM.migrate/3` (tuple source — no Mix / no `.exs` load on device),
  then launches AtomVM so `Ecto.Migrator` runs there.

  CLI options match upstream `mix ecto.migrate` and are forwarded to
  `Ecto.Migrator` on AtomVM.

  Requires `ATOMVM_INSTALL_PREFIX` (same as `mix phoenix.atomvm.run`).
  Repo comes from `-r` / `:ecto_repos`, or `atomvm: [repo: ...]` in `mix.exs`.

  ## Examples

      $ mix ecto.migrate
      $ mix ecto.migrate -r Custom.Repo
      $ mix ecto.migrate -n 3
      $ mix ecto.migrate --to 20080906120000

  """

  @impl true
  def run(args) do
    run_atomvm!(args)
  end

  # Injected migrator — used by ecto_sql host unit tests only.
  @doc false
  def run(args, migrator) when is_function(migrator, 4) do
    repos = parse_repo(args)
    {opts, _} = OptionParser.parse!(args, strict: @switches, aliases: @aliases)
    opts = normalize_migrator_opts(opts)

    if log_level = opts[:log_level] do
      Logger.configure(level: String.to_existing_atom(log_level))
    end

    {:ok, _} = Application.ensure_all_started(:ecto_sql)

    for repo <- repos do
      ensure_repo(repo, args)
      paths = ensure_migrations_paths(repo, opts)
      pool = repo.config()[:pool]

      fun =
        if Code.ensure_loaded?(pool) and function_exported?(pool, :unboxed_run, 2) do
          &pool.unboxed_run(&1, fn -> migrator.(&1, paths, :up, opts) end)
        else
          &migrator.(&1, paths, :up, opts)
        end

      case Ecto.Migrator.with_repo(repo, fun, [mode: :temporary] ++ opts) do
        {:ok, _migrated, _apps} ->
          :ok

        {:error, error} ->
          Mix.raise("Could not start repo #{inspect(repo)}, error: #{inspect(error)}")
      end
    end

    :ok
  end

  defp run_atomvm!(args) do
    {opts, _} = OptionParser.parse!(args, strict: @switches, aliases: @aliases)
    opts = normalize_migrator_opts(opts)

    if log_level = opts[:log_level] do
      # Same as upstream Mix task (host-side). AtomVM has no Logger console backend.
      Logger.configure(level: String.to_existing_atom(log_level))
    end

    unless opts[:no_compile] do
      Mix.Task.run("compile")
    end

    packbeam = packbeam_mod!()
    compat = compat_beams_mod!()
    otp_app = Keyword.get(Mix.Project.config()[:atomvm] || [], :otp_app, Mix.Project.config()[:app])
    boot = Module.concat(["Phoenix.AtomVM.Boot"])
    start = Keyword.get(Mix.Project.config()[:atomvm] || [], :start, boot)

    unless start == boot do
      Mix.raise("atomvm: [start: ...] must be Phoenix.AtomVM.Boot, got #{inspect(start)}")
    end

    repos = atomvm_repos!(args)
    migrator_opts = migrator_opts_for_boot(opts)

    for repo <- repos do
      ensure_repo(repo, args)
      paths = ensure_migrations_paths(repo, opts)
      migrations = compile_migrations_from_paths!(paths)

      if migrations == [] do
        Mix.raise("no migrations found under #{inspect(paths)}")
      end

      packbeam.write_migrate_boot_beam!(repo, migrations, otp_app, migrator_opts)
      Mix.shell().info("Generated migrate Boot with #{length(migrations)} migration(s) for #{inspect(repo)}")

      compat.ensure_avm_deps!()

      case Mix.Task.run("atomvm.packbeam", []) do
        :ok -> :ok
        {:ok, _} -> :ok
        other -> other
      end

      launch_atomvm!(migrator_opts)
    end

    :ok
  end

  defp normalize_migrator_opts(opts) do
    opts =
      if opts[:to] || opts[:to_exclusive] || opts[:step] || opts[:all],
        do: opts,
        else: Keyword.put(opts, :all, true)

    if opts[:quiet],
      do: Keyword.merge(opts, log: false, log_migrations_sql: false, log_migrator_sql: false),
      else: opts
  end

  defp migrator_opts_for_boot(opts) do
    Keyword.take(opts, [
      :all,
      :step,
      :to,
      :to_exclusive,
      :log,
      :log_migrations_sql,
      :log_migrator_sql,
      :prefix,
      :strict_version_order,
      :pool_size
    ])
  end

  defp atomvm_repos!(args) do
    case parse_repo(args) do
      [_ | _] = repos ->
        repos

      [] ->
        avm = Keyword.get(Mix.Project.config(), :atomvm) || []

        case Keyword.get(avm, :repo) do
          nil ->
            Mix.raise("""
            no Ecto repos found. Configure :ecto_repos, pass -r, or set atomvm: [repo: ...] in mix.exs
            """)

          repo when is_atom(repo) ->
            [repo]
        end
    end
  end

  defp packbeam_mod! do
    mod = Module.concat(["Mix.Tasks.Phoenix.Atomvm.Packbeam"])

    unless Code.ensure_loaded?(mod) do
      Mix.raise("mix ecto.migrate requires Mix.Tasks.Phoenix.Atomvm.Packbeam (micro_phoenix)")
    end

    mod
  end

  defp compat_beams_mod! do
    mod = Module.concat(["Mix.Tasks.Phoenix.Atomvm.CompatBeams"])

    unless Code.ensure_loaded?(mod) do
      Mix.raise("mix ecto.migrate requires Mix.Tasks.Phoenix.Atomvm.CompatBeams (micro_phoenix)")
    end

    mod
  end

  defp compile_migrations_from_paths!(paths) when is_list(paths) do
    File.mkdir_p!(Mix.Project.compile_path())

    paths
    |> Enum.flat_map(fn dir ->
      unless File.dir?(dir) do
        Mix.raise("migrations directory not found: #{dir}")
      end

      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".exs"))
      |> Enum.reject(&(&1 == ".formatter.exs"))
      |> Enum.map(&Path.join(dir, &1))
    end)
    |> Enum.sort()
    |> Enum.map(fn path ->
      file = Path.basename(path)

      case Regex.run(~r/^(\d+)_(.+)\.exs$/, file) do
        [_, version, _] ->
          [{mod, bytecode} | _] = Code.compile_file(path)
          beam = Path.join(Mix.Project.compile_path(), "#{Atom.to_string(mod)}.beam")
          File.write!(beam, bytecode)
          Mix.shell().info("Compiled migration #{file} -> #{inspect(mod)}")
          {String.to_integer(version), mod}

        nil ->
          Mix.raise("invalid migration filename (expected TIMESTAMP_name.exs): #{file}")
      end
    end)
  end

  defp launch_atomvm!(migrator_opts) do
    prefix =
      System.get_env("ATOMVM_INSTALL_PREFIX") ||
        Mix.raise("""
        ATOMVM_INSTALL_PREFIX is not set.

        Example:

            export ATOMVM_INSTALL_PREFIX=/home/linsei/Work/ElixirChip/AtomVM/build
            mix ecto.migrate
        """)

    app = Mix.Project.config()[:app]
    root = File.cwd!()

    atomvm = Path.join(prefix, "src/AtomVM")
    atomvmlib = Path.join(prefix, "libs/atomvmlib.avm")
    estdlib = Path.join(prefix, "libs/estdlib/src/estdlib.avm")
    exavmlib = Path.join(prefix, "libs/exavmlib/lib/exavmlib.avm")
    app_avm = Path.join(root, "#{app}.avm")

    Enum.each([atomvm, atomvmlib, estdlib, exavmlib, app_avm], fn path ->
      unless File.exists?(path) do
        Mix.raise("missing #{path}")
      end
    end)

    Mix.shell().info("Starting AtomVM migrate with #{app_avm}")

    env = port_env()
    quiet? = migrator_opts[:log] == false

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(atomvm)},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:args, Enum.map([app_avm, atomvmlib, estdlib, exavmlib], &String.to_charlist/1)},
          {:cd, String.to_charlist(root)},
          {:env, env}
        ]
      )

    case await_migrate_done(port, "", 120_000, quiet?) do
      {:ok, output} ->
        stop_port(port)

        if String.contains?(output, "migrate_error") or
             String.contains?(output, "migrate_catch") do
          Mix.raise("AtomVM migrate reported an error (see output above)")
        end

        :ok

      {:error, :timeout, _output} ->
        stop_port(port)
        Mix.raise("AtomVM migrate timed out waiting for migrate log output")

      {:error, {:exit, status}, _output} ->
        Mix.raise("AtomVM exited with status #{status} before migrate finished")
    end
  end

  defp port_env do
    base = for {k, v} <- System.get_env(), do: {String.to_charlist(k), String.to_charlist(v)}

    ld =
      case System.get_env("ATOMVM_MBEDTLS_LIBDIR") do
        nil ->
          System.get_env("LD_LIBRARY_PATH") || ""

        dir ->
          case System.get_env("LD_LIBRARY_PATH") do
            nil -> dir
            "" -> dir
            existing -> dir <> ":" <> existing
          end
      end

    List.keystore(base, ~c"LD_LIBRARY_PATH", 0, {~c"LD_LIBRARY_PATH", String.to_charlist(ld)})
  end

  defp await_migrate_done(port, acc, timeout, quiet?) do
    receive do
      {^port, {:data, data}} ->
        acc = acc <> data
        IO.write(data)

        cond do
          quiet? ->
            # No "== Migrated" lines when log: false; stop after output goes quiet.
            await_migrate_quiescent(port, acc, 3_000)

          migrate_finished?(acc) ->
            await_migrate_quiescent(port, acc, 500)

          true ->
            await_migrate_done(port, acc, timeout, quiet?)
        end

      {^port, {:exit_status, status}} ->
        {:error, {:exit, status}, acc}
    after
      timeout ->
        {:error, :timeout, acc}
    end
  end

  # Migrator.run is sync; after the last upstream log, wait briefly for any
  # further "== Migrated" lines from additional versions, then stop the VM.
  defp await_migrate_quiescent(port, acc, quiet_ms) do
    receive do
      {^port, {:data, data}} ->
        acc = acc <> data
        IO.write(data)
        await_migrate_quiescent(port, acc, quiet_ms)

      {^port, {:exit_status, _status}} ->
        {:ok, acc}
    after
      quiet_ms ->
        {:ok, acc}
    end
  end

  defp migrate_finished?(output) do
    String.contains?(output, "== Migrated ") or
      String.contains?(output, "Migrations already up") or
      String.contains?(output, "migrate_error") or
      String.contains?(output, "migrate_catch")
  end

  defp stop_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) ->
        _ = System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)

      _ ->
        :ok
    end

    Port.close(port)
  rescue
    _ -> :ok
  end
end
