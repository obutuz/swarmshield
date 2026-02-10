defmodule Swarmshield.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Swarmshield.Accounts` context.
  """

  import Ecto.Query

  alias Swarmshield.Accounts
  alias Swarmshield.Accounts.Scope
  alias Swarmshield.Accounts.Workspace
  alias Swarmshield.Repo

  def unique_user_email, do: "user#{System.unique_integer()}@example.com"
  def valid_user_password, do: "hello world!"

  def valid_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      email: unique_user_email()
    })
  end

  def unconfirmed_user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> valid_user_attributes()
      |> Accounts.register_user()

    user
  end

  def user_fixture(attrs \\ %{}) do
    user = unconfirmed_user_fixture(attrs)

    token =
      extract_user_token(fn url ->
        Accounts.deliver_login_instructions(user, url)
      end)

    {:ok, {user, _expired_tokens}} =
      Accounts.login_user_by_magic_link(token)

    user
  end

  def user_scope_fixture do
    user = user_fixture()
    user_scope_fixture(user)
  end

  def user_scope_fixture(user) do
    Scope.for_user(user)
  end

  def set_password(user) do
    {:ok, {user, _expired_tokens}} =
      Accounts.update_user_password(user, %{password: valid_user_password()})

    user
  end

  def extract_user_token(fun) do
    {:ok, captured_email} = fun.(&"[TOKEN]#{&1}[TOKEN]")
    [_, token | _] = String.split(captured_email.text_body, "[TOKEN]")
    token
  end

  def override_token_authenticated_at(token, authenticated_at) when is_binary(token) do
    Swarmshield.Repo.update_all(
      from(t in Accounts.UserToken,
        where: t.token == ^token
      ),
      set: [authenticated_at: authenticated_at]
    )
  end

  def generate_user_magic_link_token(user) do
    {encoded_token, user_token} = Accounts.UserToken.build_email_token(user, "login")
    Swarmshield.Repo.insert!(user_token)
    {encoded_token, user_token.token}
  end

  def offset_user_token(token, amount_to_add, unit) do
    dt = DateTime.add(DateTime.utc_now(:second), amount_to_add, unit)

    Swarmshield.Repo.update_all(
      from(ut in Accounts.UserToken, where: ut.token == ^token),
      set: [inserted_at: dt, authenticated_at: dt]
    )
  end

  def unique_workspace_slug, do: "workspace-#{System.unique_integer([:positive])}"

  def valid_workspace_attributes(attrs \\ %{}) do
    slug = unique_workspace_slug()

    Enum.into(attrs, %{
      name: "Workspace #{slug}",
      slug: slug,
      description: "A test workspace"
    })
  end

  def workspace_fixture(attrs \\ %{}) do
    {:ok, workspace} =
      attrs
      |> valid_workspace_attributes()
      |> then(&Workspace.changeset(%Workspace{}, &1))
      |> Repo.insert()

    workspace
  end

  # Role fixtures

  def unique_role_name, do: "role_#{System.unique_integer([:positive])}"

  def valid_role_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: unique_role_name(),
      description: "A test role"
    })
  end

  def role_fixture(attrs \\ %{}) do
    alias Swarmshield.Accounts.Role

    {:ok, role} =
      attrs
      |> valid_role_attributes()
      |> then(&Role.changeset(%Role{}, &1))
      |> Repo.insert()

    role
  end

  def system_role_fixture(attrs \\ %{}) do
    alias Swarmshield.Accounts.Role

    {:ok, role} =
      attrs
      |> valid_role_attributes()
      |> Map.put_new(:is_system, true)
      |> then(&Role.system_changeset(%Role{}, &1))
      |> Repo.insert()

    role
  end

  # Permission fixtures

  def unique_permission_resource, do: "resource_#{System.unique_integer([:positive])}"

  def valid_permission_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      resource: unique_permission_resource(),
      action: "view",
      description: "A test permission"
    })
  end

  def permission_fixture(attrs \\ %{}) do
    alias Swarmshield.Accounts.Permission

    {:ok, permission} =
      attrs
      |> valid_permission_attributes()
      |> then(&Permission.changeset(%Permission{}, &1))
      |> Repo.insert()

    permission
  end

  # RolePermission fixtures

  def role_permission_fixture(role, permission) do
    alias Swarmshield.Accounts.RolePermission

    {:ok, role_permission} =
      %{role_id: role.id, permission_id: permission.id}
      |> then(&RolePermission.changeset(%RolePermission{}, &1))
      |> Repo.insert()

    role_permission
  end
end
