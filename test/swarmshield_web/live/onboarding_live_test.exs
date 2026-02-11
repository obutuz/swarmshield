defmodule SwarmshieldWeb.OnboardingLiveTest do
  use SwarmshieldWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Swarmshield.AccountsFixtures

  alias Swarmshield.Accounts

  setup %{conn: conn} do
    user = user_fixture()
    conn = log_in_user(conn, user)
    %{conn: conn, user: user}
  end

  describe "onboarding page" do
    test "renders the workspace creation form", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/onboarding")

      assert html =~ "Create Your Workspace"
      assert html =~ "Workspace Name"
      assert html =~ "Description"
      assert html =~ "Create Workspace"
    end

    test "redirects unauthenticated user to login", %{} do
      conn = build_conn()
      {:error, redirect} = live(conn, ~p"/onboarding")

      assert {:redirect, %{to: path}} = redirect
      assert path =~ "/users/log-in"
    end

    test "redirects user with existing workspace to dashboard", %{conn: conn, user: user} do
      workspace = workspace_fixture()
      role = role_fixture(%{name: "onboard_redirect_role"})
      {:ok, _} = Accounts.assign_user_to_workspace(user, workspace, role)

      assert {:error, {:live_redirect, %{to: "/dashboard"}}} = live(conn, ~p"/onboarding")
    end
  end

  describe "form validation" do
    test "auto-generates slug from workspace name", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/onboarding")

      html =
        lv
        |> form("#onboarding-form", workspace: %{name: "My Cool Workspace"})
        |> render_change()

      assert html =~ "my-cool-workspace"
    end

    test "shows validation error for empty name", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/onboarding")

      html =
        lv
        |> form("#onboarding-form", workspace: %{name: ""})
        |> render_change()

      assert html =~ "can&#39;t be blank" or html =~ "can't be blank"
    end

    test "shows validation error for too-long name", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/onboarding")

      long_name = String.duplicate("a", 256)

      html =
        lv
        |> form("#onboarding-form", workspace: %{name: long_name})
        |> render_change()

      assert html =~ "should be at most 255 character"
    end
  end

  describe "workspace creation" do
    test "creates workspace and shows API key on success", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/onboarding")

      html =
        lv
        |> form("#onboarding-form",
          workspace: %{name: "Test Workspace", description: "For testing"}
        )
        |> render_submit()

      assert html =~ "Workspace Created!"
      assert html =~ "Test Workspace"
      assert html =~ "swrm_"
      assert html =~ "Save this key now"

      # Verify the workspace was actually created in DB
      {workspaces, 1} = Accounts.list_user_workspaces(user, page_size: 10)
      workspace = hd(workspaces)
      assert workspace.workspace.name == "Test Workspace"
      assert workspace.workspace.slug == "test-workspace"
      assert workspace.role.name == "super_admin"
    end

    test "handles duplicate slug gracefully", %{conn: conn} do
      # Create a workspace with slug "my-workspace" first
      workspace_fixture(%{name: "My Workspace", slug: "my-workspace"})

      {:ok, lv, _html} = live(conn, ~p"/onboarding")

      html =
        lv
        |> form("#onboarding-form", workspace: %{name: "My Workspace"})
        |> render_submit()

      assert html =~ "has already been taken"
    end

    test "copy key button updates text", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/onboarding")

      # Create workspace first
      lv
      |> form("#onboarding-form", workspace: %{name: "Copy Test Workspace"})
      |> render_submit()

      # Click copy button
      html = render_click(lv, "copy_key")
      assert html =~ "Copied!"
    end

    test "continue to dashboard navigates away", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/onboarding")

      # Create workspace first
      lv
      |> form("#onboarding-form", workspace: %{name: "Navigate Test"})
      |> render_submit()

      # Click continue
      render_click(lv, "continue_to_dashboard")

      assert_redirect(lv, "/dashboard")
    end
  end

  describe "Accounts.onboard_workspace/2" do
    test "creates workspace with super_admin role and API key" do
      user = user_fixture()

      {:ok, result} =
        Accounts.onboard_workspace(user, %{
          "name" => "Onboard Test",
          "slug" => "onboard-test",
          "description" => "Testing onboard"
        })

      assert result.workspace.name == "Onboard Test"
      assert result.workspace.slug == "onboard-test"
      assert result.workspace.api_key_prefix != nil
      assert String.starts_with?(result.raw_api_key, "swrm_")

      # Verify user is super_admin in the workspace
      uwr = Accounts.get_user_workspace_role(user, result.workspace)
      assert uwr.role.name == "super_admin"

      # Verify API key works for lookup
      found = Accounts.get_workspace_by_api_key(result.raw_api_key)
      assert found.id == result.workspace.id
    end

    test "returns changeset error for invalid workspace data" do
      user = user_fixture()

      assert {:error, %Ecto.Changeset{}} =
               Accounts.onboard_workspace(user, %{"name" => "", "slug" => ""})
    end

    test "returns changeset error for duplicate slug" do
      workspace_fixture(%{name: "Existing", slug: "existing-slug"})
      user = user_fixture()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Accounts.onboard_workspace(user, %{
                 "name" => "Another",
                 "slug" => "existing-slug"
               })

      assert {"has already been taken", _} = changeset.errors[:slug]
    end
  end

  describe "Accounts.generate_slug/1" do
    test "converts name to lowercase hyphenated slug" do
      assert Accounts.generate_slug("My Workspace") == "my-workspace"
      assert Accounts.generate_slug("Hello World!!!") == "hello-world"
      assert Accounts.generate_slug("Test 123") == "test-123"
      assert Accounts.generate_slug("  spaces  ") == "spaces"
      assert Accounts.generate_slug("UPPERCASE") == "uppercase"
      assert Accounts.generate_slug("a") == "a"
      assert Accounts.generate_slug("") == ""
      assert Accounts.generate_slug(nil) == ""
    end
  end

  describe "Accounts.ensure_default_roles_and_permissions/0" do
    test "is idempotent" do
      assert :ok = Accounts.ensure_default_roles_and_permissions()
      assert :ok = Accounts.ensure_default_roles_and_permissions()

      # Verify roles exist
      assert %{name: "super_admin"} = Accounts.get_role_by_name("super_admin")
      assert %{name: "admin"} = Accounts.get_role_by_name("admin")
      assert %{name: "analyst"} = Accounts.get_role_by_name("analyst")
      assert %{name: "viewer"} = Accounts.get_role_by_name("viewer")
    end
  end
end
