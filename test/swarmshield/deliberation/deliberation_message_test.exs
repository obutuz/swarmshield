defmodule Swarmshield.Deliberation.DeliberationMessageTest do
  use Swarmshield.DataCase, async: true

  alias Swarmshield.AccountsFixtures
  alias Swarmshield.Deliberation.DeliberationMessage
  alias Swarmshield.DeliberationFixtures

  describe "changeset/2" do
    test "valid attributes produce a valid changeset" do
      attrs = DeliberationFixtures.valid_deliberation_message_attributes()
      workspace = AccountsFixtures.workspace_fixture()
      session = DeliberationFixtures.analysis_session_fixture(%{workspace_id: workspace.id})

      instance =
        DeliberationFixtures.agent_instance_fixture(%{
          workspace_id: workspace.id,
          analysis_session_id: session.id
        })

      changeset =
        DeliberationMessage.changeset(
          %DeliberationMessage{
            analysis_session_id: session.id,
            agent_instance_id: instance.id
          },
          attrs
        )

      assert changeset.valid?
    end

    test "requires message_type" do
      attrs = DeliberationFixtures.valid_deliberation_message_attributes(%{message_type: nil})
      changeset = DeliberationMessage.changeset(%DeliberationMessage{}, attrs)

      refute changeset.valid?
      assert %{message_type: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires content" do
      attrs = DeliberationFixtures.valid_deliberation_message_attributes(%{content: nil})
      changeset = DeliberationMessage.changeset(%DeliberationMessage{}, attrs)

      refute changeset.valid?
      assert %{content: ["can't be blank"]} = errors_on(changeset)
    end

    test "accepts all valid message_types" do
      for msg_type <- [
            :analysis,
            :argument,
            :counter_argument,
            :evidence,
            :summary,
            :vote_rationale
          ] do
        attrs =
          DeliberationFixtures.valid_deliberation_message_attributes(%{message_type: msg_type})

        changeset = DeliberationMessage.changeset(%DeliberationMessage{}, attrs)

        assert changeset.valid?, "Expected message_type #{msg_type} to be valid"
      end
    end

    test "rejects invalid message_type" do
      attrs =
        DeliberationFixtures.valid_deliberation_message_attributes(%{message_type: :invalid})

      changeset = DeliberationMessage.changeset(%DeliberationMessage{}, attrs)

      refute changeset.valid?
      assert %{message_type: [_msg]} = errors_on(changeset)
    end

    test "round defaults to 1" do
      attrs = DeliberationFixtures.valid_deliberation_message_attributes()
      changeset = DeliberationMessage.changeset(%DeliberationMessage{}, attrs)

      assert Ecto.Changeset.get_field(changeset, :round) == 1
    end

    test "tokens_used defaults to 0" do
      changeset = DeliberationMessage.changeset(%DeliberationMessage{}, %{})
      assert Ecto.Changeset.get_field(changeset, :tokens_used) == 0
    end

    test "metadata defaults to empty map" do
      changeset = DeliberationMessage.changeset(%DeliberationMessage{}, %{})
      assert Ecto.Changeset.get_field(changeset, :metadata) == %{}
    end

    test "in_reply_to_id nil is valid (first message in thread)" do
      attrs = DeliberationFixtures.valid_deliberation_message_attributes()
      changeset = DeliberationMessage.changeset(%DeliberationMessage{}, attrs)

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :in_reply_to_id) == nil
    end

    test "in_reply_to_id accepts a valid UUID" do
      reply_id = Ecto.UUID.generate()

      attrs =
        DeliberationFixtures.valid_deliberation_message_attributes(%{
          in_reply_to_id: reply_id
        })

      changeset = DeliberationMessage.changeset(%DeliberationMessage{}, attrs)

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :in_reply_to_id) == reply_id
    end

    test "content can be up to 100KB" do
      large_content = String.duplicate("a", 102_400)

      attrs =
        DeliberationFixtures.valid_deliberation_message_attributes(%{content: large_content})

      changeset = DeliberationMessage.changeset(%DeliberationMessage{}, attrs)

      assert changeset.valid?
    end

    test "content exceeding 100KB is rejected" do
      oversized_content = String.duplicate("a", 102_401)

      attrs =
        DeliberationFixtures.valid_deliberation_message_attributes(%{content: oversized_content})

      changeset = DeliberationMessage.changeset(%DeliberationMessage{}, attrs)

      refute changeset.valid?
      assert %{content: [msg]} = errors_on(changeset)
      assert msg =~ "should be at most"
    end
  end

  describe "round validation" do
    test "round 0 is rejected (must be >= 1)" do
      attrs = DeliberationFixtures.valid_deliberation_message_attributes(%{round: 0})
      changeset = DeliberationMessage.changeset(%DeliberationMessage{}, attrs)

      refute changeset.valid?
      assert %{round: [msg]} = errors_on(changeset)
      assert msg =~ "greater than or equal to 1"
    end

    test "round 1 is valid (minimum)" do
      attrs = DeliberationFixtures.valid_deliberation_message_attributes(%{round: 1})
      changeset = DeliberationMessage.changeset(%DeliberationMessage{}, attrs)

      assert changeset.valid?
    end

    test "round 10 is valid" do
      attrs = DeliberationFixtures.valid_deliberation_message_attributes(%{round: 10})
      changeset = DeliberationMessage.changeset(%DeliberationMessage{}, attrs)

      assert changeset.valid?
    end
  end

  describe "fixture and database persistence" do
    test "creates a deliberation message with default attributes" do
      message = DeliberationFixtures.deliberation_message_fixture()

      assert message.id
      assert message.analysis_session_id
      assert message.agent_instance_id
      assert message.message_type == :analysis
      assert message.content =~ "Initial analysis"
      assert message.round == 1
      assert message.tokens_used == 150
      assert message.metadata == %{}
      assert is_nil(message.in_reply_to_id)
    end

    test "creates a deliberation message with custom attributes" do
      workspace = AccountsFixtures.workspace_fixture()

      message =
        DeliberationFixtures.deliberation_message_fixture(%{
          workspace_id: workspace.id,
          message_type: :counter_argument,
          content: "I disagree with the initial assessment.",
          round: 2,
          tokens_used: 200
        })

      assert message.message_type == :counter_argument
      assert message.content == "I disagree with the initial assessment."
      assert message.round == 2
      assert message.tokens_used == 200
    end

    test "in_reply_to_id references valid message" do
      workspace = AccountsFixtures.workspace_fixture()
      msg1 = DeliberationFixtures.deliberation_message_fixture(%{workspace_id: workspace.id})

      msg2 =
        DeliberationFixtures.deliberation_message_fixture(%{
          workspace_id: workspace.id,
          analysis_session_id: msg1.analysis_session_id,
          in_reply_to_id: msg1.id,
          message_type: :counter_argument,
          content: "Replying to the initial analysis"
        })

      assert msg2.in_reply_to_id == msg1.id
    end

    test "reloaded message matches inserted data" do
      message = DeliberationFixtures.deliberation_message_fixture()
      reloaded = Repo.get!(DeliberationMessage, message.id)

      assert reloaded.message_type == message.message_type
      assert reloaded.content == message.content
      assert reloaded.round == message.round
    end
  end
end
