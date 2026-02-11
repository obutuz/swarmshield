defmodule SwarmshieldWeb.Plugs.ApiAuth do
  @moduledoc """
  Plug that authenticates API requests using Bearer tokens.

  Extracts the token from the Authorization header, hashes it with SHA256,
  and looks up the RegisteredAgent via ETS-cached ApiKeyCache for sub-ms
  authentication at 20M+ users.

  On success, assigns `:current_agent` and `:current_workspace` to the conn
  and schedules an async `last_seen_at` update.

  On failure, returns JSON error responses:
  - 401 for authentication failures (missing/invalid credentials)
  - 403 for authorization failures (suspended, revoked, archived workspace)

  Security:
  - Error messages never differentiate "agent not found" vs "invalid token"
  - Failed auth attempts create audit_entry records with source IP
  - last_seen_at updates are async via Task.Supervisor to avoid write contention
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  alias Swarmshield.Accounts
  alias Swarmshield.Gateway
  alias Swarmshield.Gateway.ApiKeyCache

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with {:ok, token} <- extract_bearer_token(conn),
         key_hash = hash_token(token),
         {:ok, agent_info} <- authenticate_agent(key_hash),
         {:ok, workspace} <- validate_workspace(agent_info.workspace_id) do
      agent_id = agent_info.agent_id

      schedule_last_seen_update(agent_id)

      conn
      |> assign(:current_agent, agent_info)
      |> assign(:current_workspace, workspace)
    else
      {:error, :missing_authorization} ->
        audit_auth_failure(conn, "missing_authorization", nil)
        respond_unauthorized(conn, "missing_credentials")

      {:error, :invalid_format} ->
        audit_auth_failure(conn, "invalid_format", nil)
        respond_unauthorized(conn, "invalid_credentials")

      {:error, :invalid_credentials} ->
        audit_auth_failure(conn, "invalid_credentials", nil)
        respond_unauthorized(conn, "invalid_credentials")

      {:error, :agent_suspended} ->
        audit_auth_failure(conn, "agent_suspended", nil)
        respond_forbidden(conn, "agent_suspended")

      {:error, :agent_revoked} ->
        audit_auth_failure(conn, "agent_revoked", nil)
        respond_forbidden(conn, "agent_revoked")

      {:error, :workspace_archived} ->
        audit_auth_failure(conn, "workspace_archived", nil)
        respond_forbidden(conn, "workspace_archived")

      {:error, :workspace_suspended} ->
        audit_auth_failure(conn, "workspace_suspended", nil)
        respond_forbidden(conn, "workspace_suspended")
    end
  end

  # ---------------------------------------------------------------------------
  # Token extraction
  # ---------------------------------------------------------------------------

  defp extract_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      [<<bearer::binary-size(6), " ", token::binary>>]
      when byte_size(token) > 0 ->
        if String.downcase(bearer) == "bearer" do
          {:ok, String.trim(token)}
        else
          {:error, :invalid_format}
        end

      [_other] ->
        {:error, :invalid_format}

      [] ->
        {:error, :missing_authorization}

      _multiple ->
        {:error, :invalid_format}
    end
  end

  # ---------------------------------------------------------------------------
  # Token hashing
  # ---------------------------------------------------------------------------

  defp hash_token(token) do
    :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
  end

  # ---------------------------------------------------------------------------
  # Agent authentication via ETS cache
  # ---------------------------------------------------------------------------

  defp authenticate_agent(key_hash) do
    case ApiKeyCache.get_agent_by_key_hash(key_hash) do
      {:ok, %{status: :active} = agent_info} ->
        {:ok, agent_info}

      {:ok, %{status: :revoked}} ->
        {:error, :agent_revoked}

      {:error, :suspended} ->
        {:error, :agent_suspended}

      {:error, :not_found} ->
        {:error, :invalid_credentials}
    end
  end

  # ---------------------------------------------------------------------------
  # Workspace validation
  # ---------------------------------------------------------------------------

  defp validate_workspace(workspace_id) do
    case Accounts.get_workspace(workspace_id) do
      %{status: :active} = workspace ->
        {:ok, workspace}

      %{status: :archived} ->
        {:error, :workspace_archived}

      %{status: :suspended} ->
        {:error, :workspace_suspended}

      nil ->
        {:error, :invalid_credentials}
    end
  end

  # ---------------------------------------------------------------------------
  # Async last_seen_at update (non-blocking for 20M users)
  # ---------------------------------------------------------------------------

  defp schedule_last_seen_update(agent_id) do
    Task.Supervisor.start_child(
      Swarmshield.TaskSupervisor,
      fn ->
        try do
          Gateway.touch_agent_last_seen(agent_id)
        catch
          _kind, _reason -> :ok
        end
      end
    )
  end

  # ---------------------------------------------------------------------------
  # Error responses
  # ---------------------------------------------------------------------------

  defp respond_unauthorized(conn, error_code) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: error_code, message: "Authentication required"}))
    |> halt()
  end

  defp respond_forbidden(conn, error_code) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(403, Jason.encode!(%{error: error_code, message: "Access denied"}))
    |> halt()
  end

  # ---------------------------------------------------------------------------
  # Audit logging for failed auth attempts
  # ---------------------------------------------------------------------------

  defp audit_auth_failure(conn, reason, _token_prefix) do
    ip_address = format_ip(conn.remote_ip)

    attrs = %{
      action: "api_auth.failed",
      resource_type: "api_authentication",
      ip_address: ip_address,
      metadata: %{
        "reason" => reason,
        "path" => conn.request_path,
        "method" => conn.method
      }
    }

    Task.Supervisor.start_child(
      Swarmshield.TaskSupervisor,
      fn ->
        try do
          Accounts.create_audit_entry(attrs)
        catch
          _kind, _reason -> :ok
        end
      end
    )
  end

  defp format_ip(remote_ip) when is_tuple(remote_ip) do
    remote_ip |> :inet.ntoa() |> to_string()
  end

  defp format_ip(_), do: "unknown"
end
