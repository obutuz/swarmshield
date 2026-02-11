# Seeds default policy rules and detection rules for SwarmShield.
# Idempotent - safe to run multiple times via on_conflict: :nothing.
#
# Requires a workspace to exist. Creates a "Default" workspace if none exists.
#
# Usage:
#   mix run priv/repo/seeds/policy_rules.exs

import Ecto.Query

alias Swarmshield.Accounts.Workspace
alias Swarmshield.Policies.DetectionRule
alias Swarmshield.Policies.PolicyRule
alias Swarmshield.Repo

now = DateTime.utc_now(:second)

# --- Find or create default workspace ---

workspace =
  case Repo.one(from(w in Workspace, limit: 1)) do
    nil ->
      {:ok, w} =
        %Workspace{}
        |> Workspace.changeset(%{name: "Default Workspace", slug: "default"})
        |> Repo.insert()

      IO.puts("[Seeds] Created default workspace: #{w.id}")
      w

    w ->
      IO.puts("[Seeds] Using existing workspace: #{w.id}")
      w
  end

workspace_id = workspace.id

# --- Detection Rules ---
# These are the pattern matchers referenced by pattern_match policy rules.
# Ecto.Enum fields must be atoms; :map fields must be maps (not JSON strings).

detection_rules = [
  %{
    id: Ecto.UUID.generate(),
    name: "Prompt Injection - Common Patterns",
    description: "Detects common prompt injection attempts in agent content",
    detection_type: :regex,
    pattern:
      "(?i)(ignore\\s+(previous|all|above)\\s+(instructions|prompts)|you\\s+are\\s+now|system\\s*:\\s*|<\\|im_start\\|>|\\[INST\\]|<<SYS>>)",
    keywords: [],
    severity: :high,
    enabled: true,
    category: "prompt_injection",
    workspace_id: workspace_id,
    inserted_at: now,
    updated_at: now
  },
  %{
    id: Ecto.UUID.generate(),
    name: "Prompt Injection - Jailbreak Attempts",
    description: "Detects jailbreak-style prompt injection patterns",
    detection_type: :regex,
    pattern:
      "(?i)(DAN\\s+mode|do\\s+anything\\s+now|pretend\\s+you|act\\s+as\\s+if|bypass\\s+(safety|filter|restriction))",
    keywords: [],
    severity: :high,
    enabled: true,
    category: "prompt_injection",
    workspace_id: workspace_id,
    inserted_at: now,
    updated_at: now
  },
  %{
    id: Ecto.UUID.generate(),
    name: "PII Detection - SSN",
    description: "Detects US Social Security Numbers in content",
    detection_type: :regex,
    pattern: "\\b\\d{3}-\\d{2}-\\d{4}\\b",
    keywords: [],
    severity: :critical,
    enabled: true,
    category: "pii",
    workspace_id: workspace_id,
    inserted_at: now,
    updated_at: now
  },
  %{
    id: Ecto.UUID.generate(),
    name: "PII Detection - Email Addresses",
    description: "Detects email addresses in agent content",
    detection_type: :regex,
    pattern: "\\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}\\b",
    keywords: [],
    severity: :medium,
    enabled: true,
    category: "pii",
    workspace_id: workspace_id,
    inserted_at: now,
    updated_at: now
  },
  %{
    id: Ecto.UUID.generate(),
    name: "PII Detection - Credit Card Numbers",
    description: "Detects credit card number patterns (Visa, MC, Amex, Discover)",
    detection_type: :regex,
    pattern: "\\b(?:4\\d{3}|5[1-5]\\d{2}|3[47]\\d{2}|6011)[- ]?\\d{4}[- ]?\\d{4}[- ]?\\d{1,4}\\b",
    keywords: [],
    severity: :critical,
    enabled: true,
    category: "pii",
    workspace_id: workspace_id,
    inserted_at: now,
    updated_at: now
  },
  %{
    id: Ecto.UUID.generate(),
    name: "Toxicity Keywords",
    description: "Detects harmful or toxic content keywords",
    detection_type: :keyword,
    keywords: [
      "kill",
      "harm",
      "attack",
      "exploit",
      "malware",
      "ransomware",
      "phishing",
      "suicide",
      "self-harm",
      "violence"
    ],
    severity: :high,
    enabled: true,
    category: "toxicity",
    workspace_id: workspace_id,
    inserted_at: now,
    updated_at: now
  },
  %{
    id: Ecto.UUID.generate(),
    name: "Data Exfiltration Patterns",
    description: "Detects patterns suggesting data exfiltration attempts",
    detection_type: :regex,
    pattern:
      "(?i)(curl\\s+.*\\|\\s*bash|wget\\s+-O|nc\\s+-e|base64\\s+(encode|decode)|eval\\s*\\(|exec\\s*\\()",
    keywords: [],
    severity: :critical,
    enabled: true,
    category: "exfiltration",
    workspace_id: workspace_id,
    inserted_at: now,
    updated_at: now
  },
  %{
    id: Ecto.UUID.generate(),
    name: "Secret Leakage Keywords",
    description: "Detects potential secret/credential leakage in content",
    detection_type: :keyword,
    keywords: [
      "api_key",
      "api-key",
      "apikey",
      "secret_key",
      "private_key",
      "access_token",
      "bearer",
      "authorization",
      "password",
      "credential"
    ],
    severity: :high,
    enabled: true,
    category: "secret_leakage",
    workspace_id: workspace_id,
    inserted_at: now,
    updated_at: now
  }
]

{dr_count, _} =
  Repo.insert_all(DetectionRule, detection_rules,
    on_conflict: :nothing,
    conflict_target: [:workspace_id, :name]
  )

IO.puts("[Seeds] #{dr_count} new detection rules created (#{length(detection_rules)} defined)")

# Load detection rule IDs for referencing in policy rules
detection_ids =
  Repo.all(
    from(d in DetectionRule,
      where: d.workspace_id == ^workspace_id,
      select: {d.category, d.id}
    )
  )
  |> Enum.group_by(fn {cat, _id} -> cat end, fn {_cat, id} -> id end)

prompt_injection_ids = Map.get(detection_ids, "prompt_injection", [])
pii_ids = Map.get(detection_ids, "pii", [])
toxicity_ids = Map.get(detection_ids, "toxicity", [])
exfiltration_ids = Map.get(detection_ids, "exfiltration", [])
secret_leakage_ids = Map.get(detection_ids, "secret_leakage", [])

# --- Policy Rules ---
# Ecto.Enum fields must be atoms; :map fields must be maps (not JSON strings).

policy_rules = [
  # Rate limiting
  %{
    id: Ecto.UUID.generate(),
    name: "Default Rate Limit - Per Agent",
    description: "Limits each agent to 100 events per minute to prevent abuse",
    rule_type: :rate_limit,
    action: :flag,
    priority: 50,
    enabled: true,
    config: %{"max_events" => 100, "window_seconds" => 60, "per" => "agent"},
    applies_to_agent_types: [],
    applies_to_event_types: [],
    workspace_id: workspace_id,
    inserted_at: now,
    updated_at: now
  },
  %{
    id: Ecto.UUID.generate(),
    name: "Burst Rate Limit - Per Agent",
    description: "Hard block if agent exceeds 500 events per minute (likely runaway)",
    rule_type: :rate_limit,
    action: :block,
    priority: 90,
    enabled: true,
    config: %{"max_events" => 500, "window_seconds" => 60, "per" => "agent"},
    applies_to_agent_types: [],
    applies_to_event_types: [],
    workspace_id: workspace_id,
    inserted_at: now,
    updated_at: now
  },

  # Pattern match - prompt injection
  %{
    id: Ecto.UUID.generate(),
    name: "Prompt Injection Detection",
    description: "Blocks events with prompt injection patterns",
    rule_type: :pattern_match,
    action: :block,
    priority: 80,
    enabled: true,
    config: %{"detection_rule_ids" => prompt_injection_ids},
    applies_to_agent_types: [],
    applies_to_event_types: [],
    workspace_id: workspace_id,
    inserted_at: now,
    updated_at: now
  },

  # Pattern match - PII detection
  %{
    id: Ecto.UUID.generate(),
    name: "PII Detection",
    description: "Flags events containing personally identifiable information",
    rule_type: :pattern_match,
    action: :flag,
    priority: 70,
    enabled: true,
    config: %{"detection_rule_ids" => pii_ids},
    applies_to_agent_types: [],
    applies_to_event_types: [],
    workspace_id: workspace_id,
    inserted_at: now,
    updated_at: now
  },

  # Pattern match - toxicity
  %{
    id: Ecto.UUID.generate(),
    name: "Toxicity Detection",
    description: "Flags events with harmful or toxic content keywords",
    rule_type: :pattern_match,
    action: :flag,
    priority: 60,
    enabled: true,
    config: %{"detection_rule_ids" => toxicity_ids},
    applies_to_agent_types: [],
    applies_to_event_types: [],
    workspace_id: workspace_id,
    inserted_at: now,
    updated_at: now
  },

  # Pattern match - exfiltration
  %{
    id: Ecto.UUID.generate(),
    name: "Data Exfiltration Detection",
    description: "Blocks events with data exfiltration patterns",
    rule_type: :pattern_match,
    action: :block,
    priority: 85,
    enabled: true,
    config: %{"detection_rule_ids" => exfiltration_ids},
    applies_to_agent_types: [],
    applies_to_event_types: [],
    workspace_id: workspace_id,
    inserted_at: now,
    updated_at: now
  },

  # Pattern match - secret leakage
  %{
    id: Ecto.UUID.generate(),
    name: "Secret Leakage Detection",
    description: "Flags events that may contain secrets or credentials",
    rule_type: :pattern_match,
    action: :flag,
    priority: 75,
    enabled: true,
    config: %{"detection_rule_ids" => secret_leakage_ids},
    applies_to_agent_types: [],
    applies_to_event_types: [],
    workspace_id: workspace_id,
    inserted_at: now,
    updated_at: now
  },

  # Payload size
  %{
    id: Ecto.UUID.generate(),
    name: "Content Size Limit",
    description: "Blocks events with content exceeding 1MB",
    rule_type: :payload_size,
    action: :block,
    priority: 95,
    enabled: true,
    config: %{"max_content_bytes" => 1_048_576, "max_payload_bytes" => 5_242_880},
    applies_to_agent_types: [],
    applies_to_event_types: [],
    workspace_id: workspace_id,
    inserted_at: now,
    updated_at: now
  }
]

{pr_count, _} =
  Repo.insert_all(PolicyRule, policy_rules,
    on_conflict: :nothing,
    conflict_target: [:workspace_id, :name]
  )

IO.puts("[Seeds] #{pr_count} new policy rules created (#{length(policy_rules)} defined)")
IO.puts("[Seeds] Policy rules and detection rules seeded successfully")
