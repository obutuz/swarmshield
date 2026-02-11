defmodule SwarmshieldWeb.LiveHelpersTest do
  use ExUnit.Case, async: true

  alias SwarmshieldWeb.LiveHelpers

  describe "ephemeral?/1" do
    test "returns true when ghost_protocol_config is present" do
      session = %{workflow: %{ghost_protocol_config: %{id: "some-id"}}}
      assert LiveHelpers.ephemeral?(session)
    end

    test "returns false when ghost_protocol_config is nil" do
      session = %{workflow: %{ghost_protocol_config: nil}}
      refute LiveHelpers.ephemeral?(session)
    end

    test "returns false when workflow has no ghost_protocol_config key" do
      session = %{workflow: %{name: "test"}}
      refute LiveHelpers.ephemeral?(session)
    end

    test "returns false for nil session" do
      refute LiveHelpers.ephemeral?(nil)
    end
  end

  describe "format_relative_time/1" do
    test "returns 'Never' for nil" do
      assert LiveHelpers.format_relative_time(nil) == "Never"
    end

    test "returns 'Just now' for timestamps less than 60 seconds ago" do
      dt = DateTime.utc_now(:second)
      assert LiveHelpers.format_relative_time(dt) == "Just now"
    end

    test "returns minutes ago for timestamps less than an hour ago" do
      dt = DateTime.add(DateTime.utc_now(:second), -300, :second)
      assert LiveHelpers.format_relative_time(dt) == "5m ago"
    end

    test "returns hours ago for timestamps less than a day ago" do
      dt = DateTime.add(DateTime.utc_now(:second), -7200, :second)
      assert LiveHelpers.format_relative_time(dt) == "2h ago"
    end

    test "returns days ago for timestamps less than a week ago" do
      dt = DateTime.add(DateTime.utc_now(:second), -172_800, :second)
      assert LiveHelpers.format_relative_time(dt) == "2d ago"
    end

    test "returns formatted date for timestamps older than a week" do
      dt = DateTime.add(DateTime.utc_now(:second), -1_000_000, :second)
      result = LiveHelpers.format_relative_time(dt)
      # Should be in "Mon DD, YYYY" format
      assert result =~ ~r/\w+ \d{2}, \d{4}/
    end

    test "handles NaiveDateTime by converting to UTC" do
      ndt = NaiveDateTime.utc_now()
      assert LiveHelpers.format_relative_time(ndt) == "Just now"
    end
  end
end
