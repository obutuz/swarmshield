defmodule Swarmshield.LLM.Client do
  @moduledoc """
  HTTP client for calling Claude API via ReqLLM.

  All LLM calls go through this module which enforces:
  - Budget checks before each call
  - Retry with exponential backoff for transient errors (429/500/502/503)
  - Token usage and cost tracking after each call
  - Structured message format (prompt injection prevention)
  """

  require Logger

  alias Swarmshield.LLM.Budget

  @default_model "anthropic:claude-opus-4-6"
  @default_max_tokens 4096
  @default_temperature 0.7
  @default_timeout 60_000
  @max_retries 3
  @base_backoff_ms 1_000
  @retryable_statuses [429, 500, 502, 503]

  @type chat_opts :: [
          model: String.t(),
          temperature: float(),
          max_tokens: pos_integer(),
          system_prompt: String.t(),
          workspace_id: String.t(),
          timeout: pos_integer(),
          api_key: String.t(),
          backend: (String.t(), term(), keyword() -> {:ok, term()} | {:error, term()}),
          table: atom()
        ]

  @type chat_result :: %{
          text: String.t(),
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cost_cents: non_neg_integer(),
          model: String.t(),
          finish_reason: atom()
        }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @estimated_cost_cents 10

  @spec chat(ReqLLM.Context.t() | String.t(), chat_opts()) ::
          {:ok, chat_result()} | {:error, atom() | {atom(), term()}}
  def chat(messages, opts \\ []) do
    model_spec = Keyword.get(opts, :model, @default_model)
    workspace_id = Keyword.get(opts, :workspace_id)

    with :ok <- verify_api_key(opts),
         :ok <- reserve_workspace_budget(workspace_id, opts) do
      case execute_with_retry(messages, opts, model_spec, 0) do
        {:ok, result} ->
          settle_workspace_budget(workspace_id, result, opts)
          {:ok, result}

        {:error, _} = error ->
          release_workspace_budget(workspace_id, opts)
          error
      end
    end
  end

  @spec build_context(String.t(), String.t()) :: ReqLLM.Context.t()
  def build_context(system_prompt, user_content) do
    ReqLLM.Context.new([
      ReqLLM.Context.system(system_prompt),
      ReqLLM.Context.user(user_content)
    ])
  end

  # ---------------------------------------------------------------------------
  # Private - Retry Logic
  # ---------------------------------------------------------------------------

  defp execute_with_retry(messages, opts, model_spec, attempt) when attempt >= @max_retries do
    case do_call(messages, opts, model_spec) do
      {:ok, _} = success -> success
      {:error, {:retryable, status}} -> {:error, {:api_error, status}}
      {:error, _} = error -> error
    end
  end

  defp execute_with_retry(messages, opts, model_spec, attempt) do
    case do_call(messages, opts, model_spec) do
      {:ok, _} = success ->
        success

      {:error, {:retryable, status}} ->
        backoff = backoff_ms(attempt, opts)

        Logger.warning(
          "[LLM.Client] Retryable error #{status}, attempt #{attempt + 1}/#{@max_retries}, backoff #{backoff}ms"
        )

        sleep_fn = Keyword.get(opts, :sleep_fn, &Process.sleep/1)
        sleep_fn.(backoff)
        execute_with_retry(messages, opts, model_spec, attempt + 1)

      {:error, _} = error ->
        error
    end
  end

  defp do_call(messages, opts, model_spec) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    workspace_id = Keyword.get(opts, :workspace_id)
    backend = Keyword.get(opts, :backend, &ReqLLM.generate_text/3)

    call_opts =
      [
        temperature: Keyword.get(opts, :temperature, @default_temperature),
        max_tokens: Keyword.get(opts, :max_tokens, @default_max_tokens),
        timeout: timeout
      ]
      |> maybe_add_system_prompt(opts)
      |> maybe_add_api_key(opts)

    backend.(model_spec, messages, call_opts)
    |> classify_backend_result(model_spec, workspace_id, opts)
  rescue
    e in [Req.TransportError] ->
      classify_transport_error(e)

    e ->
      Logger.error("[LLM.Client] Unexpected error: #{Exception.message(e)}")
      {:error, {:unexpected, Exception.message(e)}}
  end

  defp classify_backend_result({:ok, %ReqLLM.Response{} = response}, model_spec, ws_id, opts) do
    handle_response(response, model_spec, ws_id, opts)
  end

  defp classify_backend_result({:ok, response}, model_spec, ws_id, opts) when is_map(response) do
    handle_map_response(response, model_spec, ws_id, opts)
  end

  defp classify_backend_result({:error, %{status: status}}, _, _, _)
       when status in @retryable_statuses do
    {:error, {:retryable, status}}
  end

  defp classify_backend_result({:error, %{status: status}}, _, _, _),
    do: {:error, {:api_error, status}}

  defp classify_backend_result({:error, %Jason.DecodeError{}}, _, _, _),
    do: {:error, :invalid_response}

  defp classify_backend_result({:error, reason}, _, _, _), do: classify_error(reason)

  defp classify_transport_error(%{reason: :timeout}), do: {:error, :timeout}

  defp classify_transport_error(e),
    do: {:error, {:transport_error, Exception.message(e)}}

  defp handle_response(response, model_spec, _workspace_id, _opts) do
    case ReqLLM.Response.ok?(response) do
      true ->
        result = extract_result(response, model_spec)
        {:ok, result}

      false ->
        classify_response_error(response.error)
    end
  end

  defp handle_map_response(response, model_spec, _workspace_id, _opts) do
    case Map.get(response, :error) do
      nil ->
        result = extract_map_result(response, model_spec)
        {:ok, result}

      error ->
        classify_response_error(error)
    end
  end

  defp classify_response_error(%{status: status}) when status in @retryable_statuses do
    {:error, {:retryable, status}}
  end

  defp classify_response_error(%{status: status}), do: {:error, {:api_error, status}}
  defp classify_response_error(error), do: {:error, {:api_error, error}}

  defp extract_result(response, model_spec) do
    usage = ReqLLM.Response.usage(response) || %{}
    text = ReqLLM.Response.text(response) || ""
    finish_reason = ReqLLM.Response.finish_reason(response)

    input_tokens = Map.get(usage, :input_tokens, 0)
    output_tokens = Map.get(usage, :output_tokens, 0)
    total_cost = Map.get(usage, :total_cost, 0.0)

    %{
      text: text,
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      cost_cents: dollars_to_cents(total_cost),
      model: model_to_string(model_spec),
      finish_reason: finish_reason
    }
  end

  defp extract_map_result(response, model_spec) do
    usage = Map.get(response, :usage, %{})

    %{
      text: Map.get(response, :text, ""),
      input_tokens: Map.get(usage, :input_tokens, 0),
      output_tokens: Map.get(usage, :output_tokens, 0),
      cost_cents: dollars_to_cents(Map.get(usage, :total_cost, 0.0)),
      model: model_to_string(model_spec),
      finish_reason: Map.get(response, :finish_reason, :stop)
    }
  end

  # ---------------------------------------------------------------------------
  # Private - Budget Integration
  # ---------------------------------------------------------------------------

  defp reserve_workspace_budget(nil, _opts), do: :ok

  defp reserve_workspace_budget(workspace_id, opts) do
    budget_opts = Keyword.take(opts, [:table, :budget_cache])

    case Budget.reserve_budget(workspace_id, @estimated_cost_cents, budget_opts) do
      {:ok, _remaining} -> :ok
      {:error, :budget_exceeded} -> {:error, :budget_exceeded}
    end
  end

  defp settle_workspace_budget(nil, _result, _opts), do: :ok

  defp settle_workspace_budget(workspace_id, result, opts) do
    total_tokens = result.input_tokens + result.output_tokens
    budget_opts = Keyword.take(opts, [:table, :budget_cache])

    Budget.settle_reservation(
      workspace_id,
      @estimated_cost_cents,
      result.cost_cents,
      total_tokens,
      budget_opts
    )
  end

  defp release_workspace_budget(nil, _opts), do: :ok

  defp release_workspace_budget(workspace_id, opts) do
    budget_opts = Keyword.take(opts, [:table, :budget_cache])
    Budget.release_reservation(workspace_id, @estimated_cost_cents, budget_opts)
  end

  # ---------------------------------------------------------------------------
  # Private - Helpers
  # ---------------------------------------------------------------------------

  defp verify_api_key(opts) do
    cond do
      Keyword.has_key?(opts, :api_key) ->
        :ok

      Keyword.has_key?(opts, :backend) ->
        :ok

      api_key_configured?() ->
        :ok

      true ->
        {:error, :api_key_not_configured}
    end
  end

  defp api_key_configured? do
    (ReqLLM.get_key(:anthropic_api_key) || System.get_env("ANTHROPIC_API_KEY")) not in [nil, ""]
  end

  defp maybe_add_system_prompt(call_opts, opts) do
    case Keyword.get(opts, :system_prompt) do
      nil -> call_opts
      prompt -> Keyword.put(call_opts, :system_prompt, prompt)
    end
  end

  defp maybe_add_api_key(call_opts, opts) do
    case Keyword.get(opts, :api_key) do
      nil -> call_opts
      key -> Keyword.put(call_opts, :api_key, key)
    end
  end

  defp classify_error(%{reason: :timeout}), do: {:error, :timeout}
  defp classify_error(%{reason: :econnrefused}), do: {:error, :connection_refused}
  defp classify_error(%{reason: reason}) when is_atom(reason), do: {:error, reason}
  defp classify_error(reason) when is_atom(reason), do: {:error, reason}
  defp classify_error(reason), do: {:error, {:unexpected, reason}}

  defp model_to_string(spec) when is_binary(spec), do: spec
  defp model_to_string(spec), do: inspect(spec)

  @spec dollars_to_cents(number()) :: non_neg_integer()
  defp dollars_to_cents(dollars) when is_number(dollars) do
    (dollars * 100) |> round() |> max(0)
  end

  defp backoff_ms(attempt, opts) do
    base_ms = Keyword.get(opts, :base_backoff_ms, @base_backoff_ms)
    base = base_ms * Integer.pow(2, attempt)
    jitter = if base > 0, do: :rand.uniform(max(div(base, 2), 1)), else: 0
    base + jitter
  end
end
