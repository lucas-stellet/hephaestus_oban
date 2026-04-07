defmodule HephaestusOban.Runner do
  @moduledoc false

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
  @spec start_instance(module(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def start_instance(workflow, context, opts) when is_atom(workflow) and is_map(context) do
    storage = Keyword.fetch!(opts, :storage)
    config_key = Keyword.fetch!(opts, :config_key)
    oban = Keyword.fetch!(opts, :oban)

    instance = Instance.new(workflow, context)
    :ok = storage_put(storage, instance)

    job_meta = JobMetadata.build(workflow, instance.id)

    changeset =
      AdvanceWorker.new(
        %{
          "instance_id" => instance.id,
          "config_key" => config_key,
          "workflow" => to_string(workflow)
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
            "workflow" => to_string(instance.workflow)
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
          "workflow" => to_string(instance.workflow)
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

  defp storage_put({storage_mod, storage_name}, instance), do: storage_mod.put(storage_name, instance)

  defp storage_get({storage_mod, storage_name}, instance_id), do: storage_mod.get(storage_name, instance_id)

  defp config_key(key), do: {elem(@config_prefix, 0), elem(@config_prefix, 1), key}
end
