defmodule Swarmshield.Deliberation.DeliberationMessage do
  @moduledoc """
  DeliberationMessage captures individual messages in the deliberation
  phase - agent analyses, counter-arguments, and supporting evidence.

  This is the debate transcript. Messages can reference each other via
  in_reply_to_id for threaded discussions.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @message_types [:analysis, :argument, :counter_argument, :evidence, :summary, :vote_rationale]

  @max_content_bytes 102_400

  schema "deliberation_messages" do
    field :message_type, Ecto.Enum, values: @message_types
    field :content, :string
    field :round, :integer, default: 1
    field :in_reply_to_id, :binary_id
    field :tokens_used, :integer, default: 0
    field :metadata, :map, default: %{}

    belongs_to :analysis_session, Swarmshield.Deliberation.AnalysisSession
    belongs_to :agent_instance, Swarmshield.Deliberation.AgentInstance

    timestamps(type: :utc_datetime)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :message_type,
      :content,
      :round,
      :in_reply_to_id,
      :tokens_used,
      :metadata
    ])
    |> validate_required([:message_type, :content])
    |> validate_length(:content, max: @max_content_bytes, count: :bytes)
    |> validate_number(:round, greater_than_or_equal_to: 1)
    |> foreign_key_constraint(:analysis_session_id)
    |> foreign_key_constraint(:agent_instance_id)
  end
end
