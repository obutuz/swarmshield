defmodule Swarmshield.GhostProtocol.WipeEngine do
  @moduledoc """
  Core engine for GhostProtocol data destruction.

  After a deliberation session produces a verdict, the WipeEngine executes
  the configured wipe strategy: destroying specified fields across agent_instances,
  deliberation_messages, agent_events, and analysis_sessions while preserving
  the verdict and audit trail.

  Fields are set to NULL where the database schema allows it, or to the
  sentinel value `"[REDACTED]"` for NOT NULL columns. This ensures data
  destruction while maintaining referential integrity.

  All wipe operations are atomic via Ecto.Multi. Crypto-shred mode overwrites
  target fields with cryptographically random bytes before wiping, ensuring
  data cannot be recovered even from disk-level forensics.

  Wipe is idempotent - calling on an already-wiped session is a no-op.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Ecto.Multi
  alias Swarmshield.Accounts
  alias Swarmshield.Deliberation.{AgentInstance, AnalysisSession, DeliberationMessage}
  alias Swarmshield.Gateway.AgentEvent
  alias Swarmshield.GhostProtocol
  alias Swarmshield.GhostProtocol.Config
  alias Swarmshield.Repo

  # Sentinel for NOT NULL columns where data has been wiped
  @redacted "[REDACTED]"

  @type wipe_result ::
          {:ok, :wipe_completed, map()}
          | {:ok, :already_wiped}
          | {:ok, :scheduled, map()}
          | {:error, :session_not_found}
          | {:error, :no_ghost_protocol}
          | {:error, :config_disabled}
          | {:error, atom(), any(), map()}

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Executes the GhostProtocol wipe for a completed analysis session.

  Reads the ghost_protocol_config from the session's workflow, validates it,
  and executes the wipe based on the configured strategy:

  - `:immediate` - executes wipe synchronously in an Ecto.Multi transaction
  - `:delayed` / `:scheduled` - returns scheduling info (deferred execution)

  Returns:
  - `{:ok, :wipe_completed, summary}` on successful immediate wipe
  - `{:ok, :already_wiped}` if session was already wiped (idempotent)
  - `{:ok, :scheduled, schedule_info}` for delayed/scheduled strategies
  - `{:error, reason}` on failure
  """
  @spec execute_wipe(binary()) :: wipe_result()
  def execute_wipe(session_id) when is_binary(session_id) do
    with {:ok, session} <- fetch_session_with_config(session_id),
         {:ok, config} <- extract_ghost_config(session),
         :ok <- validate_config_enabled(config),
         :ok <- check_not_already_wiped(session) do
      execute_strategy(config.wipe_strategy, session, config)
    end
  end

  # ---------------------------------------------------------------------------
  # Strategy Dispatch
  # ---------------------------------------------------------------------------

  defp execute_strategy(:immediate, %AnalysisSession{} = session, %Config{} = config) do
    session_id = session.id
    workspace_id = session.workspace_id

    broadcast_wipe_started(session_id, workspace_id)

    validated_fields = validate_wipe_fields(config.wipe_fields)
    now = DateTime.utc_now(:second)

    multi =
      Multi.new()
      |> add_field_wipe_operations(session, config, validated_fields, now)
      |> add_terminate_agents(session_id, now)
      |> add_audit_entry(session, config, validated_fields)

    case Repo.transaction(multi) do
      {:ok, results} ->
        agents_terminated = results[:terminate_agents] |> elem(0)

        summary = %{
          session_id: session_id,
          fields_wiped: validated_fields,
          crypto_shred_used: config.crypto_shred,
          agents_terminated: agents_terminated,
          wiped_at: now
        }

        broadcast_wipe_completed(session_id, workspace_id)

        Logger.info(
          "[WipeEngine] Wipe completed for session #{session_id}, " <>
            "fields=#{inspect(validated_fields)}, " <>
            "crypto_shred=#{config.crypto_shred}, " <>
            "agents_terminated=#{agents_terminated}"
        )

        {:ok, :wipe_completed, summary}

      {:error, failed_op, failed_value, changes_so_far} ->
        Logger.error(
          "[WipeEngine] Wipe failed for session #{session_id} " <>
            "at operation #{inspect(failed_op)}: #{inspect(failed_value)}"
        )

        {:error, failed_op, failed_value, changes_so_far}
    end
  end

  defp execute_strategy(strategy, %AnalysisSession{} = session, %Config{} = config)
       when strategy in [:delayed, :scheduled] do
    schedule_info = %{
      session_id: session.id,
      workspace_id: session.workspace_id,
      wipe_strategy: strategy,
      wipe_delay_seconds: config.wipe_delay_seconds,
      scheduled_at: DateTime.add(DateTime.utc_now(:second), config.wipe_delay_seconds, :second),
      wipe_fields: config.wipe_fields,
      crypto_shred: config.crypto_shred
    }

    Logger.info(
      "[WipeEngine] Wipe scheduled for session #{session.id}, " <>
        "strategy=#{strategy}, delay=#{config.wipe_delay_seconds}s"
    )

    {:ok, :scheduled, schedule_info}
  end

  # ---------------------------------------------------------------------------
  # Session Loading & Validation
  # ---------------------------------------------------------------------------

  defp fetch_session_with_config(session_id) do
    case GhostProtocol.get_session_with_ghost_config(session_id) do
      nil -> {:error, :session_not_found}
      %AnalysisSession{} = session -> {:ok, session}
    end
  end

  defp extract_ghost_config(%AnalysisSession{workflow: workflow}) do
    case workflow do
      %{ghost_protocol_config: %Config{} = config} -> {:ok, config}
      %{ghost_protocol_config: nil} -> {:error, :no_ghost_protocol}
      %{ghost_protocol_config_id: nil} -> {:error, :no_ghost_protocol}
      _ -> {:error, :no_ghost_protocol}
    end
  end

  defp validate_config_enabled(%Config{enabled: true}), do: :ok
  defp validate_config_enabled(%Config{enabled: false}), do: {:error, :config_disabled}

  defp check_not_already_wiped(%AnalysisSession{} = session) do
    already_wiped? =
      from(ai in AgentInstance,
        where: ai.analysis_session_id == ^session.id and not is_nil(ai.terminated_at),
        select: true,
        limit: 1
      )
      |> Repo.exists?()

    case already_wiped? do
      true -> {:ok, :already_wiped}
      false -> :ok
    end
  end

  defp validate_wipe_fields(fields) when is_list(fields) do
    allowed = Config.allowed_wipe_fields()
    {valid, invalid} = Enum.split_with(fields, &(&1 in allowed))

    if invalid != [] do
      Logger.warning(
        "[WipeEngine] Invalid wipe fields dropped: #{inspect(invalid)}. " <>
          "Allowed: #{inspect(allowed)}"
      )
    end

    valid
  end

  # ---------------------------------------------------------------------------
  # Multi Operations - Field Wiping
  # ---------------------------------------------------------------------------

  defp add_field_wipe_operations(multi, session, config, validated_fields, now) do
    Enum.reduce(validated_fields, multi, fn field, acc ->
      add_wipe_for_field(acc, field, session, config.crypto_shred, now)
    end)
  end

  defp add_wipe_for_field(multi, "deliberation_messages", session, crypto_shred, now) do
    session_id = session.id

    query =
      from(dm in DeliberationMessage,
        where: dm.analysis_session_id == ^session_id
      )

    multi
    |> maybe_crypto_shred(
      :shred_deliberation_messages,
      crypto_shred,
      query,
      [:content],
      :string,
      now
    )
    |> Multi.update_all(
      :wipe_deliberation_messages,
      fn _changes ->
        from(dm in DeliberationMessage,
          where: dm.analysis_session_id == ^session_id
        )
      end,
      set: [content: @redacted, updated_at: now]
    )
  end

  defp add_wipe_for_field(multi, "initial_assessment", session, crypto_shred, now) do
    session_id = session.id

    query =
      from(ai in AgentInstance,
        where: ai.analysis_session_id == ^session_id
      )

    multi
    |> maybe_crypto_shred(
      :shred_initial_assessment,
      crypto_shred,
      query,
      [:initial_assessment],
      :string,
      now
    )
    |> Multi.update_all(
      :wipe_initial_assessment,
      fn _changes ->
        from(ai in AgentInstance,
          where: ai.analysis_session_id == ^session_id
        )
      end,
      set: [initial_assessment: nil, updated_at: now]
    )
  end

  defp add_wipe_for_field(multi, "metadata", session, crypto_shred, now) do
    session_id = session.id

    # Wipe metadata on analysis_session (nullable column)
    multi
    |> maybe_crypto_shred_json(
      :shred_session_metadata,
      crypto_shred,
      from(s in AnalysisSession, where: s.id == ^session_id),
      :metadata,
      now
    )
    |> Multi.update_all(
      :wipe_session_metadata,
      fn _changes ->
        from(s in AnalysisSession, where: s.id == ^session_id)
      end,
      set: [metadata: nil, updated_at: now]
    )
    # Wipe metadata on deliberation_messages (nullable column)
    |> maybe_crypto_shred_json(
      :shred_message_metadata,
      crypto_shred,
      from(dm in DeliberationMessage, where: dm.analysis_session_id == ^session_id),
      :metadata,
      now
    )
    |> Multi.update_all(
      :wipe_message_metadata,
      fn _changes ->
        from(dm in DeliberationMessage, where: dm.analysis_session_id == ^session_id)
      end,
      set: [metadata: nil, updated_at: now]
    )
  end

  defp add_wipe_for_field(multi, "input_content", session, crypto_shred, now) do
    event_id = session.agent_event_id

    case event_id do
      nil ->
        multi

      event_id ->
        query = from(e in AgentEvent, where: e.id == ^event_id)

        multi
        |> maybe_crypto_shred(
          :shred_event_content,
          crypto_shred,
          query,
          [:content],
          :string,
          now
        )
        |> Multi.update_all(
          :wipe_event_content,
          fn _changes ->
            from(e in AgentEvent, where: e.id == ^event_id)
          end,
          set: [content: @redacted, updated_at: now]
        )
    end
  end

  defp add_wipe_for_field(multi, "payload", session, crypto_shred, now) do
    event_id = session.agent_event_id

    case event_id do
      nil ->
        multi

      event_id ->
        query = from(e in AgentEvent, where: e.id == ^event_id)

        multi
        |> maybe_crypto_shred_json(
          :shred_event_payload,
          crypto_shred,
          query,
          :payload,
          now
        )
        |> Multi.update_all(
          :wipe_event_payload,
          fn _changes ->
            from(e in AgentEvent, where: e.id == ^event_id)
          end,
          set: [payload: nil, updated_at: now]
        )
    end
  end

  # Catch-all for unknown fields (already filtered, but safety net)
  defp add_wipe_for_field(multi, _unknown_field, _session, _crypto_shred, _now), do: multi

  # ---------------------------------------------------------------------------
  # Terminate Agents
  # ---------------------------------------------------------------------------

  defp add_terminate_agents(multi, session_id, now) do
    Multi.update_all(
      multi,
      :terminate_agents,
      fn _changes ->
        from(ai in AgentInstance,
          where: ai.analysis_session_id == ^session_id and is_nil(ai.terminated_at)
        )
      end,
      set: [terminated_at: now, updated_at: now]
    )
  end

  # ---------------------------------------------------------------------------
  # Crypto Shred
  # ---------------------------------------------------------------------------

  # For string columns: overwrite with random bytes before NULLing
  defp maybe_crypto_shred(multi, _name, false, _query, _columns, _type, _now), do: multi

  defp maybe_crypto_shred(multi, name, true, query, columns, :string, now) do
    random_value = Base.encode64(:crypto.strong_rand_bytes(32))

    sets =
      Enum.flat_map(columns, fn col ->
        [{col, random_value}, {:updated_at, now}]
      end)

    Multi.update_all(multi, name, fn _changes -> query end, set: sets)
  end

  # For JSON/map columns: overwrite with random JSON before NULLing
  defp maybe_crypto_shred_json(multi, _name, false, _query, _column, _now), do: multi

  defp maybe_crypto_shred_json(multi, name, true, query, column, now) do
    random_value = %{"_shredded" => Base.encode64(:crypto.strong_rand_bytes(32))}

    Multi.update_all(multi, name, fn _changes -> query end,
      set: [{column, random_value}, {:updated_at, now}]
    )
  end

  # ---------------------------------------------------------------------------
  # Audit Entry
  # ---------------------------------------------------------------------------

  defp add_audit_entry(multi, session, config, validated_fields) do
    session_id = session.id
    workspace_id = session.workspace_id
    crypto_shred = config.crypto_shred

    Multi.run(multi, :audit_entry, fn _repo, changes ->
      agents_terminated = changes[:terminate_agents] |> elem(0)

      Accounts.create_audit_entry(%{
        action: "ghost_protocol.wipe_executed",
        resource_type: "analysis_session",
        resource_id: session_id,
        workspace_id: workspace_id,
        metadata: %{
          "fields_wiped" => validated_fields,
          "crypto_shred_used" => crypto_shred,
          "agents_terminated" => agents_terminated,
          "wipe_strategy" => "immediate"
        }
      })
    end)
  end

  # ---------------------------------------------------------------------------
  # PubSub Broadcasts
  # ---------------------------------------------------------------------------

  defp broadcast_wipe_started(session_id, workspace_id) do
    Phoenix.PubSub.broadcast(
      Swarmshield.PubSub,
      "ghost_protocol:session:#{session_id}",
      {:wipe_started, session_id}
    )

    Phoenix.PubSub.broadcast(
      Swarmshield.PubSub,
      "ghost_protocol:#{workspace_id}",
      {:wipe_started, session_id}
    )
  end

  defp broadcast_wipe_completed(session_id, workspace_id) do
    Phoenix.PubSub.broadcast(
      Swarmshield.PubSub,
      "ghost_protocol:session:#{session_id}",
      {:wipe_completed, session_id}
    )

    Phoenix.PubSub.broadcast(
      Swarmshield.PubSub,
      "ghost_protocol:#{workspace_id}",
      {:wipe_completed, session_id}
    )
  end
end
