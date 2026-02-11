defmodule Swarmshield.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias Swarmshield.Repo

  alias Swarmshield.Accounts.{
    AuditEntry,
    User,
    UserNotifier,
    UserToken,
    UserWorkspaceRole,
    Workspace
  }

  @default_page_size 50
  @max_page_size 100

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  ## User registration

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    %User{}
    |> User.email_changeset(attrs)
    |> Repo.insert()
  end

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `Swarmshield.Accounts.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `Swarmshield.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Gets the user with the given magic link token.
  """
  def get_user_by_magic_link_token(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Logs the user in by magic link.

  There are three cases to consider:

  1. The user has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The user has not confirmed their email and no password is set.
     In this case, the user gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The user has not confirmed their email but a password is set.
     This cannot happen in the default implementation but may be the
     source of security pitfalls. See the "Mixing magic link and password registration" section of
     `mix help phx.gen.auth`.
  """
  def login_user_by_magic_link(token) do
    {:ok, query} = UserToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
      {%User{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        raise """
        magic link log in is not allowed for unconfirmed users with a password set!

        This cannot happen with the default implementation, which indicates that you
        might have adapted the code to a different use case. Please make sure to read the
        "Mixing magic link and password registration" section of `mix help phx.gen.auth`.
        """

      {%User{confirmed_at: nil} = user, _token} ->
        user
        |> User.confirm_changeset()
        |> update_user_and_delete_all_tokens()

      {user, token} ->
        Repo.delete!(token)
        {:ok, {user, []}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Delivers the magic link login instructions to the given user.
  """
  def deliver_login_instructions(%User{} = user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "login")
    Repo.insert!(user_token)
    UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token))
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## Token helper

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end

  ## Workspaces

  @doc """
  Lists all workspaces with pagination.

  Returns `{workspaces, total_count}`.

  ## Options

    * `:page` - page number (default 1)
    * `:page_size` - items per page (default 50, max 100)
  """
  def list_workspaces(opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)

    page_size =
      opts |> Keyword.get(:page_size, @default_page_size) |> min(@max_page_size) |> max(1)

    offset = (page - 1) * page_size

    query = from(w in Workspace, order_by: [asc: w.name])

    workspaces =
      query
      |> limit(^page_size)
      |> offset(^offset)
      |> Repo.all()

    total_count = Repo.aggregate(query, :count)

    {workspaces, total_count}
  end

  @doc """
  Gets a single workspace by ID. Returns `nil` if not found.
  """
  def get_workspace(id), do: Repo.get(Workspace, id)

  @doc """
  Gets a single workspace by ID. Raises `Ecto.NoResultsError` if not found.
  """
  def get_workspace!(id) do
    Repo.get!(Workspace, id)
  end

  @doc """
  Creates a workspace. Creates an audit entry for the action.
  """
  def create_workspace(attrs) do
    Repo.transact(fn ->
      with {:ok, workspace} <-
             %Workspace{}
             |> Workspace.changeset(attrs)
             |> Repo.insert() do
        create_audit_entry(%{
          action: "workspace.create",
          resource_type: "workspace",
          resource_id: workspace.id,
          metadata: %{"name" => workspace.name, "slug" => workspace.slug}
        })

        {:ok, workspace}
      end
    end)
  end

  @doc """
  Updates a workspace. Creates an audit entry for the action.
  """
  def update_workspace(%Workspace{} = workspace, attrs) do
    Repo.transact(fn ->
      with {:ok, updated} <-
             workspace
             |> Workspace.changeset(attrs)
             |> Repo.update() do
        create_audit_entry(%{
          action: "workspace.update",
          resource_type: "workspace",
          resource_id: updated.id,
          workspace_id: updated.id,
          metadata: %{"changes" => Map.keys(attrs) |> Enum.map(&to_string/1)}
        })

        {:ok, updated}
      end
    end)
  end

  @doc """
  Deletes a workspace. Returns error if workspace has associated domain data.
  Creates an audit entry for the action.
  """
  def delete_workspace(%Workspace{} = workspace) do
    Repo.transact(fn ->
      create_audit_entry(%{
        action: "workspace.delete",
        resource_type: "workspace",
        resource_id: workspace.id,
        metadata: %{"name" => workspace.name, "slug" => workspace.slug}
      })

      Repo.delete(workspace)
    end)
  end

  @doc """
  Gets a workspace by raw API key. Performs SHA256 hash lookup.
  Returns `nil` if no workspace matches.
  """
  def get_workspace_by_api_key(raw_key) when is_binary(raw_key) do
    hash = hash_api_key(raw_key)
    Repo.get_by(Workspace, api_key_hash: hash)
  end

  def get_workspace_by_api_key(_), do: nil

  @doc """
  Generates a cryptographically secure API key for a workspace.
  Returns `{:ok, {raw_key, updated_workspace}}` or `{:error, changeset}`.

  The raw key is shown once and never stored. Only the SHA256 hash is persisted.
  """
  def generate_workspace_api_key(%Workspace{} = workspace) do
    raw_bytes = :crypto.strong_rand_bytes(32)
    raw_key = "swrm_" <> Base.url_encode64(raw_bytes, padding: false)
    prefix = String.slice(raw_key, 0, 8)
    hash = hash_api_key(raw_key)

    Repo.transact(fn ->
      with {:ok, updated} <-
             workspace
             |> Workspace.api_key_changeset(%{api_key_hash: hash, api_key_prefix: prefix})
             |> Repo.update() do
        create_audit_entry(%{
          action: "workspace.api_key_generated",
          resource_type: "workspace",
          resource_id: updated.id,
          workspace_id: updated.id,
          metadata: %{"prefix" => prefix}
        })

        {:ok, {raw_key, updated}}
      end
    end)
  end

  defp hash_api_key(raw_key) do
    :crypto.hash(:sha256, raw_key) |> Base.encode16(case: :lower)
  end

  ## Role Assignments

  @doc """
  Assigns a user to a workspace with a role. Uses upsert to avoid race conditions -
  if the user already has a role in the workspace, it is replaced atomically.

  Creates an audit entry for the action.
  """
  def assign_user_to_workspace(%User{} = user, %Workspace{} = workspace, %{id: role_id} = role) do
    now = DateTime.utc_now(:second)

    attrs = %{user_id: user.id, workspace_id: workspace.id, role_id: role_id}

    Repo.transact(fn ->
      {:ok, uwr} =
        %UserWorkspaceRole{}
        |> UserWorkspaceRole.changeset(attrs)
        |> Repo.insert(
          on_conflict: [set: [role_id: role_id, updated_at: now]],
          conflict_target: [:user_id, :workspace_id],
          returning: true
        )

      create_audit_entry(%{
        action: "workspace.user_assigned",
        resource_type: "user_workspace_role",
        resource_id: uwr.id,
        actor_id: user.id,
        workspace_id: workspace.id,
        metadata: %{"role_name" => role.name, "user_email" => user.email}
      })

      Swarmshield.Authorization.invalidate_user_permissions(user.id, workspace.id)

      {:ok, uwr}
    end)
  end

  @doc """
  Removes a user from a workspace. Idempotent - returns `:ok` even if user
  is not a member. Creates an audit entry if a role was actually removed.
  """
  def remove_user_from_workspace(%User{} = user, %Workspace{} = workspace) do
    query =
      from(uwr in UserWorkspaceRole,
        where: uwr.user_id == ^user.id and uwr.workspace_id == ^workspace.id
      )

    {count, _} = Repo.delete_all(query)

    if count > 0 do
      create_audit_entry(%{
        action: "workspace.user_removed",
        resource_type: "user_workspace_role",
        actor_id: user.id,
        workspace_id: workspace.id,
        metadata: %{"user_email" => user.email}
      })

      Swarmshield.Authorization.invalidate_user_permissions(user.id, workspace.id)
    end

    :ok
  end

  @doc """
  Gets the user's role assignment for a workspace. Returns the UserWorkspaceRole
  with role preloaded, or nil if the user is not a member.
  """
  def get_user_workspace_role(%User{} = user, %Workspace{} = workspace) do
    from(uwr in UserWorkspaceRole,
      where: uwr.user_id == ^user.id and uwr.workspace_id == ^workspace.id,
      join: r in assoc(uwr, :role),
      preload: [role: r]
    )
    |> Repo.one()
  end

  @doc """
  Lists all workspaces a user belongs to, with their role preloaded.
  Uses JOIN preload (belongs_to) to avoid N+1.

  Returns `{workspace_roles, total_count}`.
  """
  def list_user_workspaces(%User{} = user, opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)

    page_size =
      opts |> Keyword.get(:page_size, @default_page_size) |> min(@max_page_size) |> max(1)

    offset = (page - 1) * page_size

    base_query =
      from(uwr in UserWorkspaceRole,
        where: uwr.user_id == ^user.id,
        join: w in assoc(uwr, :workspace),
        join: r in assoc(uwr, :role),
        preload: [workspace: w, role: r],
        order_by: [asc: w.name]
      )

    results =
      base_query
      |> limit(^page_size)
      |> offset(^offset)
      |> Repo.all()

    total_count =
      from(uwr in UserWorkspaceRole, where: uwr.user_id == ^user.id)
      |> Repo.aggregate(:count)

    {results, total_count}
  end

  ## Audit Entries

  @doc """
  Creates an immutable audit entry. Returns `{:ok, audit_entry}` or `{:error, changeset}`.

  Audit entries are insert-only and can never be updated or deleted.
  Metadata is automatically sanitized to remove sensitive fields.
  """
  def create_audit_entry(attrs) do
    %AuditEntry{}
    |> AuditEntry.create_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists audit entries for a workspace with filtering and pagination.

  `workspace_id` is mandatory - audit data is always workspace-scoped.

  ## Options

    * `:action` - filter by action string
    * `:actor_id` - filter by actor UUID
    * `:resource_type` - filter by resource type
    * `:from` - start datetime (inclusive)
    * `:to` - end datetime (inclusive)
    * `:page` - page number (default 1)
    * `:page_size` - items per page (default 50, max 100)

  Returns `{entries, total_count}`.
  """
  def list_audit_entries(workspace_id, opts \\ [])

  def list_audit_entries(workspace_id, opts) when is_binary(workspace_id) do
    page = max(Keyword.get(opts, :page, 1), 1)

    page_size =
      opts |> Keyword.get(:page_size, @default_page_size) |> min(@max_page_size) |> max(1)

    offset = (page - 1) * page_size

    base_query =
      from(a in AuditEntry, where: a.workspace_id == ^workspace_id)
      |> apply_audit_filters(opts)

    entries =
      base_query
      |> order_by([a], desc: a.inserted_at)
      |> limit(^page_size)
      |> offset(^offset)
      |> Repo.all()

    total_count = Repo.aggregate(base_query, :count)

    {entries, total_count}
  end

  defp apply_audit_filters(query, opts) do
    query
    |> maybe_filter_action(Keyword.get(opts, :action))
    |> maybe_filter_actor(Keyword.get(opts, :actor_id))
    |> maybe_filter_resource_type(Keyword.get(opts, :resource_type))
    |> maybe_filter_from(Keyword.get(opts, :from))
    |> maybe_filter_to(Keyword.get(opts, :to))
  end

  defp maybe_filter_action(query, nil), do: query
  defp maybe_filter_action(query, action), do: where(query, [a], a.action == ^action)

  defp maybe_filter_actor(query, nil), do: query
  defp maybe_filter_actor(query, actor_id), do: where(query, [a], a.actor_id == ^actor_id)

  defp maybe_filter_resource_type(query, nil), do: query

  defp maybe_filter_resource_type(query, resource_type),
    do: where(query, [a], a.resource_type == ^resource_type)

  defp maybe_filter_from(query, nil), do: query
  defp maybe_filter_from(query, from), do: where(query, [a], a.inserted_at >= ^from)

  defp maybe_filter_to(query, nil), do: query
  defp maybe_filter_to(query, to), do: where(query, [a], a.inserted_at <= ^to)
end
