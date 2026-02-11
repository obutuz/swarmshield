defmodule SwarmshieldWeb.Api.V1.EventController do
  use SwarmshieldWeb, :controller

  alias Swarmshield.Accounts
  alias Swarmshield.Gateway

  action_fallback SwarmshieldWeb.FallbackController

  @allowed_params ~w(event_type content payload severity)

  def create(conn, params) do
    %{current_agent: agent_info, current_workspace: workspace} = conn.assigns

    attrs = Map.take(params, @allowed_params)
    source_ip = format_ip(conn.remote_ip)

    case Gateway.create_agent_event(workspace.id, agent_info.agent_id, attrs,
           source_ip: source_ip
         ) do
      {:ok, event} ->
        audit_event_creation(agent_info, workspace, event)

        conn
        |> put_status(:created)
        |> render(:show, event: event)

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  defp audit_event_creation(agent_info, workspace, event) do
    Task.Supervisor.start_child(
      Swarmshield.TaskSupervisor,
      fn ->
        try do
          Accounts.create_audit_entry(%{
            action: "event.created",
            resource_type: "agent_event",
            resource_id: event.id,
            workspace_id: workspace.id,
            actor_id: agent_info.agent_id,
            metadata: %{
              "event_type" => to_string(event.event_type),
              "status" => to_string(event.status),
              "severity" => to_string(event.severity)
            }
          })
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
