defmodule HephaestusOban.Runner do
  @moduledoc """
  Oban-backed `Hephaestus.Runtime.Runner` implementation.

  `start_instance/3` extracts `:workflow_version` from `opts` before persisting
  the instance and enqueuing the first `AdvanceWorker`. That same version is then
  propagated through every worker job as `"workflow_version"` so retries,
  resumes, and step result inserts stay tied to the concrete workflow revision
  that started the instance.

  ## start_instance/3 options

    * `:storage` — storage backend tuple used to persist instances
    * `:config_key` — key used to resolve runtime config from `:persistent_term`
    * `:oban` — Oban instance name used for inserts
    * `:id` — required business key used as the workflow instance id
    * `:workflow_version` — workflow revision stored on the instance and passed
      through Oban job args (defaults to `1`)
  """

  alias Hephaestus.Core.Instance
  alias Hephaestus.Runtime.Runner, as: RunnerBehaviour
  alias HephaestusOban.{AdvanceWorker, FailureHandler, ResumeWorker}
  alias HephaestusOban.JobMetadata

  @behaviour RunnerBehaviour

  @config_prefix {HephaestusOban, :config}

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.get(opts, :config_key, __MODULE__)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @spec start_link(keyword()) :: :ignore
  def start_link(opts) do
    config = %{
      key: Keyword.fetch!(opts, :config_key),
      repo: Keyword.fetch!(opts, :repo),
      oban: Keyword.fetch!(opts, :oban),
      storage: Keyword.fetch!(opts, :storage)
    }

    :persistent_term.put(config_key(config.key), config)

    case FailureHandler.attach() do
      :ok -> :ignore
      {:error, {:already_exists, _handler_id}} -> :ignore
    end
  end

  @impl RunnerBehaviour
  @doc """
  Starts a workflow instance and enqueues the initial `AdvanceWorker`.

  The required `:id` option and `:workflow_version` option flow into
  `Instance.new/4` and the
  initial Oban job args as `"workflow_version"`, ensuring downstream workers
  execute against the same workflow revision.
  """
  @spec start_instance(module(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def start_instance(workflow, context, opts) when is_atom(workflow) and is_map(context) do
    storage = Keyword.fetch!(opts, :storage)
    config_key = Keyword.fetch!(opts, :config_key)
    oban = Keyword.fetch!(opts, :oban)
    workflow_version = Keyword.get(opts, :workflow_version, 1)
    id = Keyword.fetch!(opts, :id)

    instance = Instance.new(workflow, workflow_version, context, id)
    :ok = storage_put(storage, instance)

    job_meta = JobMetadata.build(workflow, instance.id)

    changeset =
      AdvanceWorker.new(
        %{
          "instance_id" => instance.id,
          "config_key" => config_key,
          "workflow" => to_string(workflow),
          "workflow_version" => workflow_version
        },
        job_meta
      )

    case Oban.insert(oban, changeset) do
      {:ok, _job} -> {:ok, instance.id}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl RunnerBehaviour
  @spec resume(String.t(), atom()) :: :ok | {:error, :instance_not_found}
  def resume(instance_id, event) when is_binary(instance_id) and is_atom(event) do
    with {:ok, config, instance} <- load_instance_config(instance_id),
         step_ref when not is_nil(step_ref) <- instance.current_step,
         {:ok, _job} <- insert_resume_job(config, instance_id, step_ref, to_string(event)) do
      :ok
    else
      {:error, :instance_not_found} -> {:error, :instance_not_found}
      nil -> {:error, :instance_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl RunnerBehaviour
  @spec schedule_resume(String.t(), atom(), pos_integer()) ::
          {:ok, integer()} | {:error, :instance_not_found | term()}
  def schedule_resume(instance_id, step_ref, delay_ms)
      when is_binary(instance_id) and is_atom(step_ref) and is_integer(delay_ms) and delay_ms > 0 do
    with {:ok, config, instance} <- load_instance_config(instance_id) do
      job_meta = JobMetadata.build(instance.workflow, instance_id, step_ref: step_ref)

      changeset =
        ResumeWorker.new(
          %{
            "instance_id" => instance_id,
            "step_ref" => to_string(step_ref),
            "event" => "timeout",
            "config_key" => config.key,
            "workflow" => to_string(instance.workflow),
            "workflow_version" => instance.workflow_version
          },
          [scheduled_at: DateTime.add(DateTime.utc_now(), delay_ms, :millisecond)] ++ job_meta
        )

      case Oban.insert(config.oban, changeset) do
        {:ok, %Oban.Job{id: job_id}} -> {:ok, job_id}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp insert_resume_job(config, instance_id, step_ref, event) do
    instance = load_instance(config, instance_id)
    job_meta = JobMetadata.build(instance.workflow, instance_id, step_ref: step_ref)

    changeset =
      ResumeWorker.new(
        %{
          "instance_id" => instance_id,
          "step_ref" => to_string(step_ref),
          "event" => event,
          "config_key" => config.key,
          "workflow" => to_string(instance.workflow),
          "workflow_version" => instance.workflow_version
        },
        job_meta
      )

    Oban.insert(config.oban, changeset)
  end

  defp load_instance_config(instance_id) do
    @config_prefix
    |> config_entries()
    |> Enum.find_value({:error, :instance_not_found}, fn {_key, config} ->
      case storage_get(config.storage, instance_id) do
        {:ok, instance} -> {:ok, config, instance}
        {:error, :not_found} -> nil
      end
    end)
  end

  defp load_instance(config, instance_id) do
    {storage_mod, storage_name} = config.storage

    case storage_mod.get(storage_name, instance_id) do
      {:ok, instance} -> instance
      {:error, :not_found} -> raise "workflow instance not found: #{instance_id}"
    end
  end

  defp config_entries(_prefix) do
    :persistent_term.get()
    |> Enum.filter(fn
      {{HephaestusOban, :config, _config_key}, _config} -> true
      _other -> false
    end)
  end

  defp storage_put({storage_mod, storage_name}, instance),
    do: storage_mod.put(storage_name, instance)

  defp storage_get({storage_mod, storage_name}, instance_id),
    do: storage_mod.get(storage_name, instance_id)

  defp config_key(key), do: {elem(@config_prefix, 0), elem(@config_prefix, 1), key}
end
