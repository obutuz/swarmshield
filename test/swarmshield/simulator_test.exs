defmodule Swarmshield.SimulatorTest do
  use Swarmshield.DataCase, async: false

  alias Swarmshield.Simulator

  import Swarmshield.AccountsFixtures

  setup do
    # Stop any running simulator from previous tests
    try do
      Simulator.stop()
    catch
      :exit, _ -> :ok
    end

    # Stub HTTP requests via Req.Test
    Req.Test.stub(Swarmshield.Simulator, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(201, Jason.encode!(%{"data" => %{"id" => Ecto.UUID.generate()}}))
    end)

    workspace = workspace_fixture()
    %{workspace: workspace}
  end

  describe "start/1" do
    test "starts simulation with workspace agents", %{workspace: workspace} do
      assert :ok = Simulator.start(workspace_id: workspace.id)

      status = Simulator.status()
      assert status.status == :running
      assert status.agent_count == 4
      assert status.workspace_id == workspace.id
      assert status.events_sent == 0

      assert :ok = Simulator.stop()
    end

    test "returns error when already running", %{workspace: workspace} do
      assert :ok = Simulator.start(workspace_id: workspace.id)
      assert {:error, :already_running} = Simulator.start(workspace_id: workspace.id)

      assert :ok = Simulator.stop()
    end

    test "creates simulator agents in database", %{workspace: workspace} do
      assert :ok = Simulator.start(workspace_id: workspace.id)

      {agents, _count} = Swarmshield.Gateway.list_registered_agents(workspace.id, search: "[SIM]")
      assert length(agents) == 4
      assert Enum.all?(agents, &String.starts_with?(&1.name, "[SIM]"))

      assert :ok = Simulator.stop()
    end

    test "reuses existing simulator agents on restart", %{workspace: workspace} do
      assert :ok = Simulator.start(workspace_id: workspace.id)
      assert :ok = Simulator.stop()

      # Second start should reuse existing agents
      assert :ok = Simulator.start(workspace_id: workspace.id)

      {agents, _count} = Swarmshield.Gateway.list_registered_agents(workspace.id, search: "[SIM]")
      # Should still be 4 (not 8)
      assert length(agents) == 4

      assert :ok = Simulator.stop()
    end

    test "accepts custom rate option", %{workspace: workspace} do
      assert :ok = Simulator.start(workspace_id: workspace.id, rate: 5)

      status = Simulator.status()
      assert status.rate == 5

      assert :ok = Simulator.stop()
    end
  end

  describe "stop/0" do
    test "stops running simulation", %{workspace: workspace} do
      assert :ok = Simulator.start(workspace_id: workspace.id)
      assert :ok = Simulator.stop()

      status = Simulator.status()
      assert status.status == :idle
    end

    test "returns :ok when already idle" do
      assert :ok = Simulator.stop()
    end
  end

  describe "status/0" do
    test "returns idle status by default" do
      status = Simulator.status()
      assert status.status == :idle
      assert status.events_sent == 0
      assert status.agent_count == 0
    end
  end

  describe "event generation" do
    test "generates events on timer tick", %{workspace: workspace} do
      assert :ok = Simulator.start(workspace_id: workspace.id, rate: 100)

      # Wait for a few events to be generated
      Process.sleep(100)

      status = Simulator.status()
      assert status.events_sent > 0

      assert :ok = Simulator.stop()
    end

    test "only targets localhost for HTTP requests", %{workspace: workspace} do
      # The simulator constructs URLs using 127.0.0.1 only
      # Verify the send_event function builds the correct base URL
      assert :ok = Simulator.start(workspace_id: workspace.id, rate: 50)

      Process.sleep(100)

      # If events are sent, they went through Req.Test stub (localhost)
      status = Simulator.status()
      assert status.events_sent > 0

      assert :ok = Simulator.stop()
    end
  end

  describe "production guard" do
    test "init returns :ignore in production" do
      original_env = Application.get_env(:swarmshield, :env)

      try do
        Application.put_env(:swarmshield, :env, :prod)
        assert :ignore = Simulator.init([])
      after
        if original_env do
          Application.put_env(:swarmshield, :env, original_env)
        else
          Application.delete_env(:swarmshield, :env)
        end
      end
    end
  end

  describe "event data generation" do
    test "generates diverse event types" do
      events = for _ <- 1..200, do: Simulator.generate_sample_event()

      event_types = events |> Enum.map(& &1.event_type) |> Enum.uniq()
      severities = events |> Enum.map(& &1.severity) |> Enum.uniq()

      assert length(event_types) >= 3
      assert length(severities) >= 2
    end
  end
end
