defmodule Swarmshield.Policies do
  @moduledoc """
  The Policies context manages PolicyRule, DetectionRule, and PolicyViolation CRUD.

  Broadcasts PubSub events on rule changes for ETS cache invalidation.
  All operations are workspace-scoped. CRUD on security-critical resources
  (policy rules, detection rules) creates audit_entry records.
  """

  import Ecto.Query, warn: false
  alias Swarmshield.Repo

  alias Swarmshield.Accounts
  alias Swarmshield.Policies.{DetectionRule, PolicyRule, PolicyViolation}

  @default_page_size 50
  @max_page_size 100

  # ---------------------------------------------------------------------------
  # PolicyRule
  # ---------------------------------------------------------------------------

  @doc """
  Lists policy rules for a workspace with optional filters.

  Returns `{rules, total_count}`.

  ## Options

    * `:rule_type` - filter by rule type atom
    * `:action` - filter by action atom (:allow, :flag, :block)
    * `:enabled` - filter by enabled boolean
    * `:search` - search by name (case-insensitive ILIKE)
    * `:page` - page number (default 1)
    * `:page_size` - items per page (default 50, max 100)
  """
  def list_policy_rules(workspace_id, opts \\ [])

  def list_policy_rules(workspace_id, opts) when is_binary(workspace_id) do
    {_page, page_size, offset} = pagination_params(opts)

    base_query =
      from(r in PolicyRule, where: r.workspace_id == ^workspace_id)
      |> apply_policy_rule_filters(opts)

    total_count = Repo.aggregate(base_query, :count)

    rules =
      base_query
      |> order_by([r], desc: r.priority, asc: r.inserted_at)
      |> limit(^page_size)
      |> offset(^offset)
      |> Repo.all()

    {rules, total_count}
  end

  @doc """
  Lists only enabled policy rules for a workspace, ordered by priority DESC.

  Used by PolicyCache for ETS loading - returns rules ready for evaluation.
  """
  def list_enabled_policy_rules(workspace_id) when is_binary(workspace_id) do
    from(r in PolicyRule,
      where: r.workspace_id == ^workspace_id and r.enabled == true,
      order_by: [desc: r.priority]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single policy rule by ID.

  Raises `Ecto.NoResultsError` if not found.
  """
  def get_policy_rule!(id) when is_binary(id) do
    Repo.get!(PolicyRule, id)
  end

  @doc """
  Creates a policy rule. workspace_id is set server-side.

  Broadcasts PubSub event for ETS cache invalidation.
  Creates an audit entry.
  """
  def create_policy_rule(workspace_id, attrs, audit_metadata \\ %{})
      when is_binary(workspace_id) do
    result =
      %PolicyRule{workspace_id: workspace_id}
      |> PolicyRule.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, rule} ->
        broadcast_policy_rules_changed(workspace_id, :created, rule.id)
        create_policy_audit("policy_rule.created", rule, audit_metadata)
        {:ok, rule}

      error ->
        error
    end
  end

  @doc """
  Updates a policy rule.

  Broadcasts PubSub event for ETS cache invalidation.
  Creates an audit entry.
  """
  def update_policy_rule(%PolicyRule{} = rule, attrs, audit_metadata \\ %{}) do
    result =
      rule
      |> PolicyRule.changeset(attrs)
      |> Repo.update()

    case result do
      {:ok, updated} ->
        broadcast_policy_rules_changed(updated.workspace_id, :updated, updated.id)
        create_policy_audit("policy_rule.updated", updated, audit_metadata)
        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
  Deletes a policy rule.

  Returns error if the rule has linked violations (referential integrity).
  Broadcasts PubSub event for ETS cache invalidation.
  Creates an audit entry.
  """
  def delete_policy_rule(%PolicyRule{} = rule, audit_metadata \\ %{}) do
    violation_count =
      from(v in PolicyViolation, where: v.policy_rule_id == ^rule.id)
      |> Repo.aggregate(:count)

    if violation_count > 0 do
      changeset =
        rule
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.add_error(:id, "cannot delete rule with existing violations")

      {:error, changeset}
    else
      case Repo.delete(rule) do
        {:ok, deleted} ->
          broadcast_policy_rules_changed(deleted.workspace_id, :deleted, deleted.id)
          create_policy_audit("policy_rule.deleted", deleted, audit_metadata)
          {:ok, deleted}

        error ->
          error
      end
    end
  end

  # ---------------------------------------------------------------------------
  # DetectionRule
  # ---------------------------------------------------------------------------

  @doc """
  Lists detection rules for a workspace with optional filters.

  Returns `{rules, total_count}`.

  ## Options

    * `:detection_type` - filter by detection type atom
    * `:category` - filter by category string
    * `:enabled` - filter by enabled boolean
    * `:search` - search by name (case-insensitive ILIKE)
    * `:page` - page number (default 1)
    * `:page_size` - items per page (default 50, max 100)
  """
  def list_detection_rules(workspace_id, opts \\ [])

  def list_detection_rules(workspace_id, opts) when is_binary(workspace_id) do
    {_page, page_size, offset} = pagination_params(opts)

    base_query =
      from(r in DetectionRule, where: r.workspace_id == ^workspace_id)
      |> apply_detection_rule_filters(opts)

    total_count = Repo.aggregate(base_query, :count)

    rules =
      base_query
      |> order_by([r], asc: r.inserted_at)
      |> limit(^page_size)
      |> offset(^offset)
      |> Repo.all()

    {rules, total_count}
  end

  @doc """
  Lists only enabled detection rules for a workspace.

  Used by PolicyCache for ETS loading.
  """
  def list_enabled_detection_rules(workspace_id) when is_binary(workspace_id) do
    from(r in DetectionRule,
      where: r.workspace_id == ^workspace_id and r.enabled == true
    )
    |> Repo.all()
  end

  @doc """
  Gets a single detection rule by ID.

  Raises `Ecto.NoResultsError` if not found.
  """
  def get_detection_rule!(id) when is_binary(id) do
    Repo.get!(DetectionRule, id)
  end

  @doc """
  Creates a detection rule. workspace_id is set server-side.

  Broadcasts PubSub event for ETS cache invalidation.
  Creates an audit entry.
  """
  def create_detection_rule(workspace_id, attrs, audit_metadata \\ %{})
      when is_binary(workspace_id) do
    result =
      %DetectionRule{workspace_id: workspace_id}
      |> DetectionRule.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, rule} ->
        broadcast_detection_rules_changed(workspace_id, :created, rule.id)
        create_policy_audit("detection_rule.created", rule, audit_metadata)
        {:ok, rule}

      error ->
        error
    end
  end

  @doc """
  Updates a detection rule.

  Broadcasts PubSub event for ETS cache invalidation.
  Creates an audit entry.
  """
  def update_detection_rule(%DetectionRule{} = rule, attrs, audit_metadata \\ %{}) do
    result =
      rule
      |> DetectionRule.changeset(attrs)
      |> Repo.update()

    case result do
      {:ok, updated} ->
        broadcast_detection_rules_changed(updated.workspace_id, :updated, updated.id)
        create_policy_audit("detection_rule.updated", updated, audit_metadata)
        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
  Deletes a detection rule.

  Broadcasts PubSub event for ETS cache invalidation.
  Creates an audit entry.
  """
  def delete_detection_rule(%DetectionRule{} = rule, audit_metadata \\ %{}) do
    result = Repo.delete(rule)

    case result do
      {:ok, deleted} ->
        broadcast_detection_rules_changed(deleted.workspace_id, :deleted, deleted.id)
        create_policy_audit("detection_rule.deleted", deleted, audit_metadata)
        {:ok, deleted}

      error ->
        error
    end
  end

  # ---------------------------------------------------------------------------
  # PolicyViolation
  # ---------------------------------------------------------------------------

  @doc """
  Lists policy violations for a workspace with filters and pagination.

  Uses JOINs for event and rule preloads in a single query (not N+1).

  Returns `{violations, total_count}`.

  ## Options

    * `:policy_rule_id` - filter by policy rule UUID
    * `:agent_event_id` - filter by agent event UUID
    * `:action_taken` - filter by action taken atom
    * `:severity` - filter by severity atom
    * `:resolved` - filter by resolved boolean
    * `:from` - start datetime (inclusive)
    * `:to` - end datetime (inclusive)
    * `:page` - page number (default 1)
    * `:page_size` - items per page (default 50, max 100)
  """
  def list_policy_violations(workspace_id, opts \\ [])

  def list_policy_violations(workspace_id, opts) when is_binary(workspace_id) do
    {_page, page_size, offset} = pagination_params(opts)

    base_query =
      from(v in PolicyViolation,
        where: v.workspace_id == ^workspace_id,
        join: e in assoc(v, :agent_event),
        join: r in assoc(v, :policy_rule),
        preload: [agent_event: e, policy_rule: r]
      )
      |> apply_violation_filters(opts)

    total_count =
      from(v in PolicyViolation,
        where: v.workspace_id == ^workspace_id
      )
      |> apply_violation_filters(opts)
      |> Repo.aggregate(:count)

    violations =
      base_query
      |> order_by([v], desc: v.inserted_at)
      |> limit(^page_size)
      |> offset(^offset)
      |> Repo.all()

    {violations, total_count}
  end

  @doc """
  Gets a single policy violation by ID with preloaded associations.

  Raises `Ecto.NoResultsError` if not found.
  """
  def get_policy_violation!(id) when is_binary(id) do
    PolicyViolation
    |> Repo.get!(id)
    |> Repo.preload([:agent_event, :policy_rule])
  end

  @doc """
  Creates a policy violation. workspace_id, agent_event_id, and policy_rule_id
  are set server-side by the PolicyEngine.
  """
  def create_policy_violation(attrs) when is_map(attrs) do
    %PolicyViolation{
      workspace_id: attrs.workspace_id,
      agent_event_id: attrs.agent_event_id,
      policy_rule_id: attrs.policy_rule_id
    }
    |> PolicyViolation.changeset(
      Map.drop(attrs, [:workspace_id, :agent_event_id, :policy_rule_id])
    )
    |> Repo.insert()
  end

  @doc """
  Resolves a policy violation.

  Sets resolved=true, resolved_by_id, resolved_at, and optional resolution_notes.
  Returns error if the violation is already resolved (idempotency guard).
  Uses atomic update - no read-modify-write race.
  """
  def resolve_policy_violation(violation, resolver_id, notes \\ nil)

  def resolve_policy_violation(
        %PolicyViolation{resolved: false} = violation,
        resolver_id,
        notes
      )
      when is_binary(resolver_id) do
    now = DateTime.utc_now(:second)

    result =
      violation
      |> PolicyViolation.resolution_changeset(%{
        resolved: true,
        resolved_by_id: resolver_id,
        resolved_at: now,
        resolution_notes: notes
      })
      |> Repo.update()

    case result do
      {:ok, resolved} ->
        create_policy_audit("policy_violation.resolved", resolved, %{
          resolver_id: resolver_id,
          notes: notes
        })

        {:ok, resolved}

      error ->
        error
    end
  end

  def resolve_policy_violation(%PolicyViolation{resolved: true}, _resolver_id, _notes) do
    {:error, :already_resolved}
  end

  # ---------------------------------------------------------------------------
  # PubSub
  # ---------------------------------------------------------------------------

  @doc """
  Subscribes to policy rule change events for a workspace.
  """
  def subscribe_policy_rules(workspace_id) when is_binary(workspace_id) do
    Phoenix.PubSub.subscribe(Swarmshield.PubSub, "policy_rules:#{workspace_id}")
  end

  @doc """
  Subscribes to detection rule change events for a workspace.
  """
  def subscribe_detection_rules(workspace_id) when is_binary(workspace_id) do
    Phoenix.PubSub.subscribe(Swarmshield.PubSub, "detection_rules:#{workspace_id}")
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp broadcast_policy_rules_changed(workspace_id, action, rule_id) do
    Phoenix.PubSub.broadcast(
      Swarmshield.PubSub,
      "policy_rules:#{workspace_id}",
      {:policy_rules_changed, action, rule_id}
    )
  end

  defp broadcast_detection_rules_changed(workspace_id, action, rule_id) do
    Phoenix.PubSub.broadcast(
      Swarmshield.PubSub,
      "detection_rules:#{workspace_id}",
      {:detection_rules_changed, action, rule_id}
    )
  end

  defp create_policy_audit(action, resource, metadata) do
    resource_type =
      resource.__struct__
      |> Module.split()
      |> List.last()
      |> Macro.underscore()

    Accounts.create_audit_entry(%{
      action: action,
      resource_type: resource_type,
      resource_id: resource.id,
      workspace_id: resource.workspace_id,
      metadata: Map.merge(metadata, %{name: Map.get(resource, :name, nil)})
    })
  end

  defp pagination_params(opts) do
    page = opts |> Keyword.get(:page, 1) |> max(1)

    page_size =
      opts |> Keyword.get(:page_size, @default_page_size) |> min(@max_page_size) |> max(1)

    offset = (page - 1) * page_size

    {page, page_size, offset}
  end

  # Policy rule filters

  defp apply_policy_rule_filters(query, opts) do
    query
    |> maybe_filter_rule_type(Keyword.get(opts, :rule_type))
    |> maybe_filter_rule_action(Keyword.get(opts, :action))
    |> maybe_filter_enabled(Keyword.get(opts, :enabled))
    |> maybe_filter_rule_search(Keyword.get(opts, :search))
  end

  defp maybe_filter_rule_type(query, nil), do: query
  defp maybe_filter_rule_type(query, type), do: where(query, [r], r.rule_type == ^type)

  defp maybe_filter_rule_action(query, nil), do: query
  defp maybe_filter_rule_action(query, action), do: where(query, [r], r.action == ^action)

  # Detection rule filters

  defp apply_detection_rule_filters(query, opts) do
    query
    |> maybe_filter_detection_type(Keyword.get(opts, :detection_type))
    |> maybe_filter_category(Keyword.get(opts, :category))
    |> maybe_filter_enabled(Keyword.get(opts, :enabled))
    |> maybe_filter_detection_search(Keyword.get(opts, :search))
  end

  defp maybe_filter_detection_type(query, nil), do: query

  defp maybe_filter_detection_type(query, type),
    do: where(query, [r], r.detection_type == ^type)

  defp maybe_filter_category(query, nil), do: query
  defp maybe_filter_category(query, cat), do: where(query, [r], r.category == ^cat)

  # Shared filters

  defp maybe_filter_enabled(query, nil), do: query
  defp maybe_filter_enabled(query, enabled), do: where(query, [r], r.enabled == ^enabled)

  defp maybe_filter_rule_search(query, nil), do: query
  defp maybe_filter_rule_search(query, ""), do: query

  defp maybe_filter_rule_search(query, search) when is_binary(search) do
    sanitized = "%" <> String.replace(search, ["%", "_", "\\"], &"\\#{&1}") <> "%"
    where(query, [r], ilike(r.name, ^sanitized))
  end

  defp maybe_filter_detection_search(query, nil), do: query
  defp maybe_filter_detection_search(query, ""), do: query

  defp maybe_filter_detection_search(query, search) when is_binary(search) do
    sanitized = "%" <> String.replace(search, ["%", "_", "\\"], &"\\#{&1}") <> "%"
    where(query, [r], ilike(r.name, ^sanitized))
  end

  # Violation filters

  defp apply_violation_filters(query, opts) do
    query
    |> maybe_filter_violation_rule(Keyword.get(opts, :policy_rule_id))
    |> maybe_filter_violation_event(Keyword.get(opts, :agent_event_id))
    |> maybe_filter_violation_agent(Keyword.get(opts, :registered_agent_id))
    |> maybe_filter_violation_action(Keyword.get(opts, :action_taken))
    |> maybe_filter_violation_severity(Keyword.get(opts, :severity))
    |> maybe_filter_violation_resolved(Keyword.get(opts, :resolved))
    |> maybe_filter_violation_from(Keyword.get(opts, :from))
    |> maybe_filter_violation_to(Keyword.get(opts, :to))
  end

  defp maybe_filter_violation_rule(query, nil), do: query

  defp maybe_filter_violation_rule(query, rule_id),
    do: where(query, [v], v.policy_rule_id == ^rule_id)

  defp maybe_filter_violation_event(query, nil), do: query

  defp maybe_filter_violation_event(query, event_id),
    do: where(query, [v], v.agent_event_id == ^event_id)

  defp maybe_filter_violation_agent(query, nil), do: query

  defp maybe_filter_violation_agent(query, agent_id) do
    agent_event_ids =
      from(e in Swarmshield.Gateway.AgentEvent,
        where: e.registered_agent_id == ^agent_id,
        select: e.id
      )

    where(query, [v], v.agent_event_id in subquery(agent_event_ids))
  end

  defp maybe_filter_violation_action(query, nil), do: query

  defp maybe_filter_violation_action(query, action),
    do: where(query, [v], v.action_taken == ^action)

  defp maybe_filter_violation_severity(query, nil), do: query

  defp maybe_filter_violation_severity(query, severity),
    do: where(query, [v], v.severity == ^severity)

  defp maybe_filter_violation_resolved(query, nil), do: query

  defp maybe_filter_violation_resolved(query, resolved),
    do: where(query, [v], v.resolved == ^resolved)

  defp maybe_filter_violation_from(query, nil), do: query

  defp maybe_filter_violation_from(query, %DateTime{} = from),
    do: where(query, [v], v.inserted_at >= ^from)

  defp maybe_filter_violation_to(query, nil), do: query

  defp maybe_filter_violation_to(query, %DateTime{} = to),
    do: where(query, [v], v.inserted_at <= ^to)
end
