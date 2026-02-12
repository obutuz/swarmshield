defmodule Swarmshield.LLM.KeyStore do
  @moduledoc """
  ETS-cached, encrypted LLM API key storage per workspace.

  API keys are encrypted at rest using `Plug.Crypto.encrypt` with
  the application's `secret_key_base` and stored in
  `workspace.settings["llm_api_key_encrypted"]`.

  Architecture (follows ApiKeyCache pattern):
  - GenServer owns ETS table (lifecycle management)
  - All reads go directly to ETS (no GenServer bottleneck)
  - Cache miss triggers decrypt from workspace.settings
  - PubSub-driven invalidation on key changes
  """

  use GenServer

  require Logger

  import Ecto.Query, warn: false

  alias Swarmshield.Accounts
  alias Swarmshield.Repo

  @table :llm_key_store
  @salt "llm_api_key"
  @pubsub_topic "llm:key_changed"

  # ---------------------------------------------------------------------------
  # Client API - Direct ETS reads (no GenServer bottleneck)
  # ---------------------------------------------------------------------------

  @doc """
  Returns the decrypted LLM API key for a workspace.

  Accepts a workspace ID (string) or a `%Workspace{}` struct.
  When a struct is passed, skips the DB query on ETS cache miss.
  Returns `{:ok, api_key}` or `:error`.
  """
  @spec get_key(String.t() | map()) :: {:ok, String.t()} | :error
  def get_key(%{id: workspace_id, settings: settings}) when is_binary(workspace_id) do
    case ets_lookup(workspace_id) do
      {:ok, key} -> {:ok, key}
      :miss -> decrypt_and_cache(workspace_id, settings)
    end
  end

  def get_key(workspace_id) when is_binary(workspace_id) do
    case ets_lookup(workspace_id) do
      {:ok, key} -> {:ok, key}
      :miss -> load_and_cache(workspace_id)
    end
  end

  def get_key(_), do: :error

  @doc """
  Returns true if the workspace has a configured LLM API key.

  Accepts a workspace ID (string) or a `%Workspace{}` struct.
  """
  @spec has_key?(String.t() | map()) :: boolean()
  def has_key?(%{id: _, settings: _} = workspace) do
    match?({:ok, _}, get_key(workspace))
  end

  def has_key?(workspace_id) when is_binary(workspace_id) do
    match?({:ok, _}, get_key(workspace_id))
  end

  def has_key?(_), do: false

  @doc """
  Stores an LLM API key for a workspace.

  Encrypts the key, persists to workspace.settings, caches in ETS,
  and broadcasts invalidation via PubSub.
  """
  @spec store_key(String.t(), String.t()) :: :ok | {:error, term()}
  def store_key(workspace_id, api_key)
      when is_binary(workspace_id) and is_binary(api_key) do
    encrypted = encrypt(api_key)
    prefix = String.slice(api_key, 0, 8)

    case update_workspace_settings(workspace_id, encrypted, prefix) do
      {:ok, _workspace} ->
        cache_put(workspace_id, api_key)
        broadcast_change(workspace_id)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Removes the LLM API key for a workspace.
  """
  @spec delete_key(String.t()) :: :ok | {:error, term()}
  def delete_key(workspace_id) when is_binary(workspace_id) do
    case clear_workspace_settings(workspace_id) do
      {:ok, _workspace} ->
        cache_delete(workspace_id)
        broadcast_change(workspace_id)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the stored key prefix for display (e.g., "sk-ant-a" → "sk-ant-a...").
  Reads from workspace.settings, not the decrypted key.

  Accepts a workspace ID (string) or a `%Workspace{}` struct.
  Prefer passing the struct to avoid a redundant DB query.
  """
  @spec get_key_prefix(String.t() | map()) :: String.t() | nil
  def get_key_prefix(%{settings: settings}) do
    Map.get(settings || %{}, "llm_api_key_prefix")
  end

  def get_key_prefix(workspace_id) when is_binary(workspace_id) do
    case Repo.get(Accounts.Workspace, workspace_id) do
      nil -> nil
      %{settings: settings} -> Map.get(settings || %{}, "llm_api_key_prefix")
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    {:ok, %{}, {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, state) do
    try do
      :ets.new(@table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true
      ])

      Phoenix.PubSub.subscribe(Swarmshield.PubSub, @pubsub_topic)
      Logger.info("[LLM.KeyStore] ETS cache initialized")
    rescue
      e ->
        Logger.warning("[LLM.KeyStore] Setup failed: #{Exception.message(e)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:llm_key_changed, workspace_id}, state) do
    cache_delete(workspace_id)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Private - ETS operations
  # ---------------------------------------------------------------------------

  defp ets_lookup(workspace_id) do
    case :ets.lookup(@table, workspace_id) do
      [{^workspace_id, key}] -> {:ok, key}
      [] -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp cache_put(workspace_id, api_key) do
    :ets.insert(@table, {workspace_id, api_key})
  rescue
    ArgumentError -> :ok
  end

  defp cache_delete(workspace_id) do
    :ets.delete(@table, workspace_id)
  rescue
    ArgumentError -> :ok
  end

  # ---------------------------------------------------------------------------
  # Private - Encryption
  # ---------------------------------------------------------------------------

  defp encrypt(plaintext) do
    Plug.Crypto.encrypt(secret_key_base(), @salt, plaintext)
  end

  defp decrypt(token) do
    # max_age: :infinity — keys don't expire based on token age
    Plug.Crypto.decrypt(secret_key_base(), @salt, token, max_age: :infinity)
  end

  defp secret_key_base do
    Application.get_env(:swarmshield, SwarmshieldWeb.Endpoint)[:secret_key_base]
  end

  # ---------------------------------------------------------------------------
  # Private - Database operations
  # ---------------------------------------------------------------------------

  defp load_and_cache(workspace_id) do
    case Repo.get(Accounts.Workspace, workspace_id) do
      nil -> :error
      %{settings: settings} -> decrypt_and_cache(workspace_id, settings)
    end
  rescue
    e ->
      Logger.warning("[LLM.KeyStore] DB lookup failed: #{Exception.message(e)}")
      :error
  end

  defp decrypt_and_cache(workspace_id, settings) do
    with encrypted when is_binary(encrypted) <-
           Map.get(settings || %{}, "llm_api_key_encrypted"),
         {:ok, api_key} <- decrypt(encrypted) do
      cache_put(workspace_id, api_key)
      {:ok, api_key}
    else
      nil ->
        :error

      {:error, _} ->
        Logger.warning("[LLM.KeyStore] Failed to decrypt API key for workspace #{workspace_id}")
        :error
    end
  end

  defp update_workspace_settings(workspace_id, encrypted, prefix) do
    workspace = Repo.get!(Accounts.Workspace, workspace_id)
    current_settings = workspace.settings || %{}

    new_settings =
      Map.merge(current_settings, %{
        "llm_api_key_encrypted" => encrypted,
        "llm_api_key_prefix" => prefix
      })

    Accounts.update_workspace(workspace, %{settings: new_settings})
  end

  defp clear_workspace_settings(workspace_id) do
    workspace = Repo.get!(Accounts.Workspace, workspace_id)
    current_settings = workspace.settings || %{}

    new_settings =
      current_settings
      |> Map.delete("llm_api_key_encrypted")
      |> Map.delete("llm_api_key_prefix")

    Accounts.update_workspace(workspace, %{settings: new_settings})
  end

  defp broadcast_change(workspace_id) do
    Phoenix.PubSub.broadcast(
      Swarmshield.PubSub,
      @pubsub_topic,
      {:llm_key_changed, workspace_id}
    )
  end
end
