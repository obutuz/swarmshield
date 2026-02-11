defmodule Swarmshield.LLM.BudgetTest do
  use Swarmshield.DataCase, async: false

  alias Swarmshield.LLM.Budget

  import Swarmshield.AccountsFixtures

  setup do
    table_name = :"budget_test_#{System.unique_integer([:positive])}"
    cache_name = :"budget_cache_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {Budget,
         name: :"budget_srv_#{System.unique_integer([:positive])}",
         table: table_name,
         budget_cache: cache_name}
      )

    %{pid: pid, table: table_name, cache: cache_name}
  end

  describe "track_usage/4" do
    test "tracks tokens and cost", %{table: table} do
      workspace_id = Ecto.UUID.generate()

      assert :ok = Budget.track_usage(workspace_id, 1000, 5, table: table)

      usage = Budget.get_usage(workspace_id, table: table)
      assert usage.total_tokens == 1000
      assert usage.total_cost_cents == 5
    end

    test "accumulates multiple calls atomically", %{table: table} do
      workspace_id = Ecto.UUID.generate()

      Budget.track_usage(workspace_id, 500, 2, table: table)
      Budget.track_usage(workspace_id, 300, 1, table: table)

      usage = Budget.get_usage(workspace_id, table: table)
      assert usage.total_tokens == 800
      assert usage.total_cost_cents == 3
    end

    test "handles zero tokens and cost", %{table: table} do
      workspace_id = Ecto.UUID.generate()
      assert :ok = Budget.track_usage(workspace_id, 0, 0, table: table)
    end

    test "concurrent calls are atomic", %{table: table} do
      workspace_id = Ecto.UUID.generate()

      tasks =
        for _i <- 1..100 do
          Task.async(fn -> Budget.track_usage(workspace_id, 10, 1, table: table) end)
        end

      Task.await_many(tasks)

      usage = Budget.get_usage(workspace_id, table: table)
      assert usage.total_tokens == 1000
      assert usage.total_cost_cents == 100
    end
  end

  describe "check_budget/2" do
    test "returns remaining budget", %{table: table, cache: cache} do
      workspace_id = Ecto.UUID.generate()
      Budget.track_usage(workspace_id, 100, 10, table: table)

      assert {:ok, remaining} =
               Budget.check_budget(workspace_id, table: table, budget_cache: cache)

      assert is_integer(remaining)
      assert remaining > 0
    end

    test "returns budget_exceeded when over limit", %{table: table, cache: cache} do
      workspace_id = Ecto.UUID.generate()
      Budget.track_usage(workspace_id, 1_000_000, 100_000, table: table)

      assert {:error, :budget_exceeded} =
               Budget.check_budget(workspace_id, table: table, budget_cache: cache)
    end

    test "returns full budget for unused workspace", %{table: table, cache: cache} do
      workspace_id = Ecto.UUID.generate()

      assert {:ok, remaining} =
               Budget.check_budget(workspace_id, table: table, budget_cache: cache)

      assert remaining > 0
    end
  end

  describe "get_usage/2" do
    test "returns zero for unknown workspace", %{table: table} do
      usage = Budget.get_usage(Ecto.UUID.generate(), table: table)

      assert usage.total_tokens == 0
      assert usage.total_cost_cents == 0
      assert usage.period_start == nil
    end
  end

  describe "reset_usage/2" do
    test "resets counters to zero", %{table: table} do
      workspace_id = Ecto.UUID.generate()
      Budget.track_usage(workspace_id, 5000, 25, table: table)
      Budget.reset_usage(workspace_id, table: table)

      usage = Budget.get_usage(workspace_id, table: table)
      assert usage.total_tokens == 0
      assert usage.total_cost_cents == 0
      assert usage.period_start != nil
    end
  end

  describe "ETS table recovery" do
    test "returns safe defaults when table doesn't exist" do
      usage = Budget.get_usage(Ecto.UUID.generate(), table: :nonexistent_table)
      assert usage.total_tokens == 0
      assert usage.total_cost_cents == 0
    end
  end

  describe "database-driven budget limits" do
    test "uses workspace settings llm_budget_limit_cents", %{table: table, cache: cache} do
      workspace = workspace_fixture(%{settings: %{"llm_budget_limit_cents" => 10_000}})

      # Track usage just under the limit
      Budget.track_usage(workspace.id, 100, 9_999, table: table)

      assert {:ok, 1} =
               Budget.check_budget(workspace.id, table: table, budget_cache: cache)

      # Track one more cent to exceed
      Budget.track_usage(workspace.id, 1, 1, table: table)

      assert {:error, :budget_exceeded} =
               Budget.check_budget(workspace.id, table: table, budget_cache: cache)
    end

    test "falls back to default when no settings configured", %{table: table, cache: cache} do
      workspace = workspace_fixture(%{settings: %{}})

      assert {:ok, 50_000} =
               Budget.check_budget(workspace.id, table: table, budget_cache: cache)
    end

    test "caches budget limit from DB", %{table: table, cache: cache} do
      workspace = workspace_fixture(%{settings: %{"llm_budget_limit_cents" => 25_000}})

      # First call fetches from DB
      assert {:ok, 25_000} =
               Budget.check_budget(workspace.id, table: table, budget_cache: cache)

      # Second call uses cache (verifiable because same result, same opts)
      assert {:ok, 25_000} =
               Budget.check_budget(workspace.id, table: table, budget_cache: cache)
    end
  end

  describe "atomic reserve_budget/3" do
    test "reserves budget atomically", %{table: table, cache: cache} do
      workspace = workspace_fixture(%{settings: %{"llm_budget_limit_cents" => 100}})

      assert {:ok, 90} =
               Budget.reserve_budget(workspace.id, 10, table: table, budget_cache: cache)

      # Budget shows reserved amount
      usage = Budget.get_usage(workspace.id, table: table)
      assert usage.total_cost_cents == 10
    end

    test "rejects when reservation would exceed limit", %{table: table, cache: cache} do
      workspace = workspace_fixture(%{settings: %{"llm_budget_limit_cents" => 100}})

      Budget.track_usage(workspace.id, 0, 95, table: table)

      assert {:error, :budget_exceeded} =
               Budget.reserve_budget(workspace.id, 10, table: table, budget_cache: cache)

      # Reservation was rolled back
      usage = Budget.get_usage(workspace.id, table: table)
      assert usage.total_cost_cents == 95
    end

    test "concurrent reservations cannot exceed limit", %{table: table, cache: cache} do
      workspace = workspace_fixture(%{settings: %{"llm_budget_limit_cents" => 50}})

      # Launch 100 concurrent reservations of 10 cents each (only 5 should succeed)
      results =
        1..100
        |> Enum.map(fn _ ->
          Task.async(fn ->
            Budget.reserve_budget(workspace.id, 10, table: table, budget_cache: cache)
          end)
        end)
        |> Task.await_many()

      successes = Enum.count(results, &match?({:ok, _}, &1))
      failures = Enum.count(results, &match?({:error, :budget_exceeded}, &1))

      # Exactly 5 should succeed (50 / 10 = 5)
      assert successes == 5
      assert failures == 95

      # Final usage should be exactly at limit
      usage = Budget.get_usage(workspace.id, table: table)
      assert usage.total_cost_cents == 50
    end
  end

  describe "settle_reservation/5" do
    test "adjusts reservation to actual cost", %{table: table, cache: cache} do
      workspace = workspace_fixture(%{settings: %{"llm_budget_limit_cents" => 1000}})

      # Reserve 10 cents
      {:ok, _} = Budget.reserve_budget(workspace.id, 10, table: table, budget_cache: cache)

      # Actual cost was 7 cents
      :ok = Budget.settle_reservation(workspace.id, 10, 7, 150, table: table)

      usage = Budget.get_usage(workspace.id, table: table)
      assert usage.total_cost_cents == 7
      assert usage.total_tokens == 150
    end
  end

  describe "release_reservation/3" do
    test "releases full reservation on failure", %{table: table, cache: cache} do
      workspace = workspace_fixture(%{settings: %{"llm_budget_limit_cents" => 1000}})

      {:ok, _} = Budget.reserve_budget(workspace.id, 10, table: table, budget_cache: cache)

      :ok = Budget.release_reservation(workspace.id, 10, table: table)

      usage = Budget.get_usage(workspace.id, table: table)
      assert usage.total_cost_cents == 0
    end
  end
end
