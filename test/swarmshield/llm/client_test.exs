defmodule Swarmshield.LLM.ClientTest do
  use Swarmshield.DataCase, async: false

  alias Swarmshield.Accounts
  alias Swarmshield.LLM.{Budget, Client, KeyStore}

  setup do
    table_name = :"client_budget_#{System.unique_integer([:positive])}"

    _pid =
      start_supervised!(
        {Budget,
         name: :"client_budget_srv_#{System.unique_integer([:positive])}", table: table_name}
      )

    %{table: table_name}
  end

  # ---------------------------------------------------------------------------
  # Helper: mock backend
  # ---------------------------------------------------------------------------

  defp success_backend(text \\ "Hello!", usage \\ %{}) do
    merged_usage =
      Map.merge(
        %{input_tokens: 100, output_tokens: 50, total_tokens: 150, total_cost: 0.02},
        usage
      )

    fn _model, _messages, _opts ->
      {:ok,
       %{
         text: text,
         usage: merged_usage,
         finish_reason: :stop,
         error: nil
       }}
    end
  end

  defp counting_backend(counter_ref, responses) do
    fn _model, _messages, _opts ->
      count = :counters.get(counter_ref, 1)
      :counters.add(counter_ref, 1, 1)

      case Enum.at(responses, count) do
        nil -> List.last(responses)
        response -> response
      end
    end
  end

  defp base_opts(table) do
    [table: table, base_backoff_ms: 0, sleep_fn: fn _ms -> :ok end]
  end

  # ---------------------------------------------------------------------------
  # chat/2 - success cases
  # ---------------------------------------------------------------------------

  describe "chat/2 success" do
    test "returns chat result with text and usage", %{table: table} do
      opts = base_opts(table) ++ [backend: success_backend("Analysis complete")]

      assert {:ok, result} = Client.chat("analyze this", opts)

      assert result.text == "Analysis complete"
      assert result.input_tokens == 100
      assert result.output_tokens == 50
      assert result.cost_cents == 2
      assert result.finish_reason == :stop
      assert result.model == "anthropic:claude-opus-4-6"
    end

    test "uses custom model when specified", %{table: table} do
      backend = fn model, _messages, _opts ->
        send(self(), {:model_used, model})

        {:ok,
         %{
           text: "ok",
           usage: %{input_tokens: 0, output_tokens: 0, total_cost: 0.0},
           finish_reason: :stop,
           error: nil
         }}
      end

      opts = base_opts(table) ++ [backend: backend, model: "anthropic:claude-sonnet-4-5-20250929"]
      {:ok, result} = Client.chat("test", opts)

      assert result.model == "anthropic:claude-sonnet-4-5-20250929"
      assert_receive {:model_used, "anthropic:claude-sonnet-4-5-20250929"}
    end

    test "passes temperature and max_tokens to backend", %{table: table} do
      backend = fn _model, _messages, opts ->
        send(self(), {:call_opts, opts})

        {:ok,
         %{
           text: "ok",
           usage: %{input_tokens: 0, output_tokens: 0, total_cost: 0.0},
           finish_reason: :stop,
           error: nil
         }}
      end

      opts = base_opts(table) ++ [backend: backend, temperature: 0.3, max_tokens: 2048]
      {:ok, _} = Client.chat("test", opts)

      assert_receive {:call_opts, call_opts}
      assert call_opts[:temperature] == 0.3
      assert call_opts[:max_tokens] == 2048
    end

    test "passes system_prompt to backend", %{table: table} do
      backend = fn _model, _messages, opts ->
        send(self(), {:call_opts, opts})

        {:ok,
         %{
           text: "ok",
           usage: %{input_tokens: 0, output_tokens: 0, total_cost: 0.0},
           finish_reason: :stop,
           error: nil
         }}
      end

      opts = base_opts(table) ++ [backend: backend, system_prompt: "You are an analyst"]
      {:ok, _} = Client.chat("test", opts)

      assert_receive {:call_opts, call_opts}
      assert call_opts[:system_prompt] == "You are an analyst"
    end

    test "converts dollars to cents correctly", %{table: table} do
      opts = base_opts(table) ++ [backend: success_backend("ok", %{total_cost: 0.15})]

      assert {:ok, result} = Client.chat("test", opts)
      assert result.cost_cents == 15
    end

    test "handles zero cost", %{table: table} do
      opts = base_opts(table) ++ [backend: success_backend("ok", %{total_cost: 0.0})]

      assert {:ok, result} = Client.chat("test", opts)
      assert result.cost_cents == 0
    end
  end

  # ---------------------------------------------------------------------------
  # chat/2 - budget integration
  # ---------------------------------------------------------------------------

  describe "chat/2 budget integration" do
    test "tracks usage after successful call", %{table: table} do
      workspace_id = Ecto.UUID.generate()
      usage = %{input_tokens: 200, output_tokens: 100, total_cost: 0.05}

      opts =
        base_opts(table) ++
          [backend: success_backend("ok", usage), workspace_id: workspace_id]

      assert {:ok, _} = Client.chat("test", opts)

      budget_usage = Budget.get_usage(workspace_id, table: table)
      assert budget_usage.total_tokens == 300
      assert budget_usage.total_cost_cents == 5
    end

    test "checks budget before making call", %{table: table} do
      workspace_id = Ecto.UUID.generate()
      Budget.track_usage(workspace_id, 1_000_000, 100_000, table: table)

      call_count = :counters.new(1, [:atomics])

      backend = fn _model, _messages, _opts ->
        :counters.add(call_count, 1, 1)

        {:ok,
         %{
           text: "ok",
           usage: %{input_tokens: 0, output_tokens: 0, total_cost: 0.0},
           finish_reason: :stop,
           error: nil
         }}
      end

      opts = base_opts(table) ++ [backend: backend, workspace_id: workspace_id]
      assert {:error, :budget_exceeded} = Client.chat("test", opts)
      assert :counters.get(call_count, 1) == 0
    end

    test "skips budget check when no workspace_id", %{table: table} do
      opts = base_opts(table) ++ [backend: success_backend()]

      assert {:ok, _} = Client.chat("test", opts)
    end

    test "accumulates usage across multiple calls", %{table: table} do
      workspace_id = Ecto.UUID.generate()
      usage = %{input_tokens: 50, output_tokens: 25, total_cost: 0.01}

      opts =
        base_opts(table) ++
          [backend: success_backend("ok", usage), workspace_id: workspace_id]

      {:ok, _} = Client.chat("call 1", opts)
      {:ok, _} = Client.chat("call 2", opts)

      budget_usage = Budget.get_usage(workspace_id, table: table)
      assert budget_usage.total_tokens == 150
      assert budget_usage.total_cost_cents == 2
    end
  end

  # ---------------------------------------------------------------------------
  # chat/2 - API key validation
  # ---------------------------------------------------------------------------

  describe "chat/2 API key validation" do
    test "returns error when no API key configured" do
      assert {:error, :api_key_not_configured} = Client.chat("test", [])
    end

    test "accepts explicit api_key option", %{table: table} do
      backend = fn _model, _messages, opts ->
        send(self(), {:api_key, opts[:api_key]})

        {:ok,
         %{
           text: "ok",
           usage: %{input_tokens: 0, output_tokens: 0, total_cost: 0.0},
           finish_reason: :stop,
           error: nil
         }}
      end

      opts = base_opts(table) ++ [backend: backend, api_key: "sk-test-123"]
      {:ok, _} = Client.chat("test", opts)

      assert_receive {:api_key, "sk-test-123"}
    end

    test "skips API key check when backend is provided", %{table: table} do
      opts = base_opts(table) ++ [backend: success_backend()]
      assert {:ok, _} = Client.chat("test", opts)
    end
  end

  # ---------------------------------------------------------------------------
  # chat/2 - workspace key resolution
  # ---------------------------------------------------------------------------

  describe "chat/2 workspace key resolution" do
    setup %{table: table} do
      {:ok, workspace} =
        Accounts.create_workspace(%{
          name: "LLM Client Test",
          slug: "llm-client-test-#{System.unique_integer([:positive])}"
        })

      KeyStore.store_key(workspace.id, "sk-ant-workspace-key")

      %{workspace: workspace, table: table}
    end

    test "resolves API key from KeyStore when workspace_id provided", %{
      workspace: workspace,
      table: table
    } do
      backend = fn _model, _messages, opts ->
        send(self(), {:api_key, opts[:api_key]})

        {:ok,
         %{
           text: "ok",
           usage: %{input_tokens: 0, output_tokens: 0, total_cost: 0.0},
           finish_reason: :stop,
           error: nil
         }}
      end

      opts = base_opts(table) ++ [backend: backend, workspace_id: workspace.id]
      {:ok, _} = Client.chat("test", opts)

      assert_receive {:api_key, "sk-ant-workspace-key"}
    end

    test "explicit api_key takes precedence over workspace key", %{
      workspace: workspace,
      table: table
    } do
      backend = fn _model, _messages, opts ->
        send(self(), {:api_key, opts[:api_key]})

        {:ok,
         %{
           text: "ok",
           usage: %{input_tokens: 0, output_tokens: 0, total_cost: 0.0},
           finish_reason: :stop,
           error: nil
         }}
      end

      opts =
        base_opts(table) ++
          [backend: backend, workspace_id: workspace.id, api_key: "sk-explicit"]

      {:ok, _} = Client.chat("test", opts)

      assert_receive {:api_key, "sk-explicit"}
    end
  end

  # ---------------------------------------------------------------------------
  # chat/2 - error handling
  # ---------------------------------------------------------------------------

  describe "chat/2 error handling" do
    test "non-retryable client errors (400) return immediately", %{table: table} do
      call_count = :counters.new(1, [:atomics])

      backend = fn _model, _messages, _opts ->
        :counters.add(call_count, 1, 1)
        {:error, %{status: 400}}
      end

      opts = base_opts(table) ++ [backend: backend]
      assert {:error, {:api_error, 400}} = Client.chat("test", opts)
      assert :counters.get(call_count, 1) == 1
    end

    test "non-retryable 401 returns immediately", %{table: table} do
      call_count = :counters.new(1, [:atomics])

      backend = fn _model, _messages, _opts ->
        :counters.add(call_count, 1, 1)
        {:error, %{status: 401}}
      end

      opts = base_opts(table) ++ [backend: backend]
      assert {:error, {:api_error, 401}} = Client.chat("test", opts)
      assert :counters.get(call_count, 1) == 1
    end

    test "non-retryable 403 returns immediately", %{table: table} do
      call_count = :counters.new(1, [:atomics])

      backend = fn _model, _messages, _opts ->
        :counters.add(call_count, 1, 1)
        {:error, %{status: 403}}
      end

      opts = base_opts(table) ++ [backend: backend]
      assert {:error, {:api_error, 403}} = Client.chat("test", opts)
      assert :counters.get(call_count, 1) == 1
    end

    test "timeout error returned directly", %{table: table} do
      backend = fn _model, _messages, _opts ->
        {:error, :timeout}
      end

      opts = base_opts(table) ++ [backend: backend]
      assert {:error, :timeout} = Client.chat("test", opts)
    end

    test "connection refused error", %{table: table} do
      backend = fn _model, _messages, _opts ->
        {:error, %{reason: :econnrefused}}
      end

      opts = base_opts(table) ++ [backend: backend]
      assert {:error, :connection_refused} = Client.chat("test", opts)
    end

    test "unexpected errors are wrapped", %{table: table} do
      backend = fn _model, _messages, _opts ->
        {:error, "something weird"}
      end

      opts = base_opts(table) ++ [backend: backend]
      assert {:error, {:unexpected, "something weird"}} = Client.chat("test", opts)
    end

    test "backend raising exception is caught", %{table: table} do
      backend = fn _model, _messages, _opts ->
        raise "kaboom"
      end

      opts = base_opts(table) ++ [backend: backend]
      assert {:error, {:unexpected, "kaboom"}} = Client.chat("test", opts)
    end
  end

  # ---------------------------------------------------------------------------
  # chat/2 - retry logic
  # ---------------------------------------------------------------------------

  describe "chat/2 retry logic" do
    test "retries on 429 rate limit then succeeds", %{table: table} do
      counter = :counters.new(1, [:atomics])

      responses = [
        {:error, %{status: 429}},
        {:ok,
         %{
           text: "recovered",
           usage: %{input_tokens: 10, output_tokens: 5, total_cost: 0.001},
           finish_reason: :stop,
           error: nil
         }}
      ]

      opts = base_opts(table) ++ [backend: counting_backend(counter, responses)]
      assert {:ok, result} = Client.chat("test", opts)
      assert result.text == "recovered"
      assert :counters.get(counter, 1) == 2
    end

    test "retries on 500 server error then succeeds", %{table: table} do
      counter = :counters.new(1, [:atomics])

      responses = [
        {:error, %{status: 500}},
        {:ok,
         %{
           text: "ok",
           usage: %{input_tokens: 0, output_tokens: 0, total_cost: 0.0},
           finish_reason: :stop,
           error: nil
         }}
      ]

      opts = base_opts(table) ++ [backend: counting_backend(counter, responses)]
      assert {:ok, _} = Client.chat("test", opts)
      assert :counters.get(counter, 1) == 2
    end

    test "retries on 502 then succeeds", %{table: table} do
      counter = :counters.new(1, [:atomics])

      responses = [
        {:error, %{status: 502}},
        {:ok,
         %{
           text: "ok",
           usage: %{input_tokens: 0, output_tokens: 0, total_cost: 0.0},
           finish_reason: :stop,
           error: nil
         }}
      ]

      opts = base_opts(table) ++ [backend: counting_backend(counter, responses)]
      assert {:ok, _} = Client.chat("test", opts)
    end

    test "retries on 503 then succeeds", %{table: table} do
      counter = :counters.new(1, [:atomics])

      responses = [
        {:error, %{status: 503}},
        {:ok,
         %{
           text: "ok",
           usage: %{input_tokens: 0, output_tokens: 0, total_cost: 0.0},
           finish_reason: :stop,
           error: nil
         }}
      ]

      opts = base_opts(table) ++ [backend: counting_backend(counter, responses)]
      assert {:ok, _} = Client.chat("test", opts)
    end

    test "exhausts retries and returns api_error", %{table: table} do
      counter = :counters.new(1, [:atomics])

      responses = [
        {:error, %{status: 429}},
        {:error, %{status: 429}},
        {:error, %{status: 429}},
        {:error, %{status: 429}}
      ]

      opts = base_opts(table) ++ [backend: counting_backend(counter, responses)]
      assert {:error, {:api_error, 429}} = Client.chat("test", opts)
      assert :counters.get(counter, 1) == 4
    end

    test "does not retry on success after retries", %{table: table} do
      counter = :counters.new(1, [:atomics])

      responses = [
        {:error, %{status: 500}},
        {:error, %{status: 500}},
        {:ok,
         %{
           text: "finally",
           usage: %{input_tokens: 10, output_tokens: 5, total_cost: 0.001},
           finish_reason: :stop,
           error: nil
         }}
      ]

      opts = base_opts(table) ++ [backend: counting_backend(counter, responses)]
      assert {:ok, result} = Client.chat("test", opts)
      assert result.text == "finally"
      assert :counters.get(counter, 1) == 3
    end
  end

  # ---------------------------------------------------------------------------
  # build_context/2
  # ---------------------------------------------------------------------------

  describe "build_context/2" do
    test "creates context with system and user messages" do
      context = Client.build_context("You are an analyst", "Review this content")

      messages = ReqLLM.Context.to_list(context)
      assert length(messages) == 2

      [system_msg, user_msg] = messages
      assert system_msg.role == :system
      assert user_msg.role == :user
    end
  end

  # ---------------------------------------------------------------------------
  # cost calculation
  # ---------------------------------------------------------------------------

  describe "cost calculation" do
    test "small fractional costs round correctly", %{table: table} do
      usage = %{input_tokens: 10, output_tokens: 5, total_cost: 0.003}
      opts = base_opts(table) ++ [backend: success_backend("ok", usage)]

      {:ok, result} = Client.chat("test", opts)
      assert result.cost_cents == 0
    end

    test "large costs convert correctly", %{table: table} do
      usage = %{input_tokens: 1_000_000, output_tokens: 500_000, total_cost: 17.50}
      opts = base_opts(table) ++ [backend: success_backend("ok", usage)]

      {:ok, result} = Client.chat("test", opts)
      assert result.cost_cents == 1750
    end
  end
end
