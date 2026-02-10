# Ralph Wiggum - Build Mode for SwarmShield

## STOP! READ THIS FIRST - MANDATORY INSTRUCTIONS (NON-NEGOTIABLE)

**YOU MUST FOLLOW THESE STEPS IN ORDER. NO EXCEPTIONS. NO SHORTCUTS.**

### STEP 0: ACKNOWLEDGE THESE INSTRUCTIONS
Before doing ANYTHING else, output this EXACTLY:
```
<ralph-instructions-acknowledged>
I have read the PROMPT_build.md instructions and will follow them in order.
</ralph-instructions-acknowledged>
```

### STEP 1: READ MANDATORY FILES (OUTPUT CONFIRMATION)
You MUST read these files and confirm you read them:
```
1. Read: scripts/ralph/progress.txt (check what exists - NO DUPLICATES)
2. Read: scripts/ralph/stories/ (find next story with passes: false)
3. Read: AGENTS.md (understand SwarmShield architecture)
```

Output this confirmation (COPY THIS FORMAT EXACTLY):
```
<ralph-files-read>
- progress.txt: Read, [N] stories completed so far
- stories: Read, current story is [STORY-ID]: [STORY-TITLE]
- AGENTS.md: Read, key patterns: [list 2 patterns]
</ralph-files-read>
```

### STEP 2: PRE-CODING CHECKLIST

Before writing ANY code, verify:

1. **Check existing code** - Use Tidewave/file reads to verify no duplicate schemas, contexts, or modules exist
2. **Check dependencies** - Verify all `dependsOn` stories are `passes: true`
3. **Check naming** - Module names match `Swarmshield.*` / `SwarmshieldWeb.*` conventions
4. **Check types** - All schemas use binary_id, utc_datetime, Ecto.Enum
5. **Check patterns** - Pattern matching over conditionals, extract values before async callbacks
6. **Check security** - No hardcoded values, no atom creation from user input, CSRF protection
7. **Use Context7/Tidewave** - Look up latest Phoenix 1.8 / LiveView 1.1 / Elixir 1.19 patterns

Output:
```
<ralph-checklist-verified>[STORY-ID]</ralph-checklist-verified>
```

### STEP 3: IMPLEMENT THE STORY

Only AFTER Steps 0-2 are complete can you write code.

**Mandatory quality gates (every story):**
- `mix format` passes
- `mix credo --strict` passes
- `mix test` passes
- All business logic is database-driven (zero hardcoded values)
- No N+1 queries (use preloads)
- No correlated subqueries (use JOINs or Ecto subqueries)
- No race conditions
- No direct Repo calls in LiveViews (use context functions)
- Pattern matching throughout
- Extract values before async callbacks (no socket copying)
- ETS caches: try/rescue in handle_continue, rescue ArgumentError in reads
- ETS cache invalidation: PubSub-driven, per-workspace (not global flush), debounced for bulk updates

**Query quality rules (every context function):**
```
1. NO correlated subqueries - Never write a query that executes a subquery per row.
   Use Ecto.Query.subquery/1 for derived tables, or rewrite as JOIN.

   # WRONG - correlated subquery per row
   from(a in Agent, where: a.event_count == subquery(
     from(e in Event, where: e.agent_id == parent_as(:agent).id, select: count())
   ))

   # CORRECT - JOIN with aggregate
   from(a in Agent,
     left_join: e in assoc(a, :events),
     group_by: a.id,
     select: {a, count(e.id)})

2. Proper JOINs over multiple queries - Never load parents then loop to load children.
   Use join/preload in a single query.

   # WRONG - 2 queries when 1 suffices
   agents = Repo.all(from a in Agent, where: a.workspace_id == ^wid)
   Enum.map(agents, fn a -> Repo.all(from e in Event, where: e.agent_id == ^a.id) end)

   # CORRECT - single query with preload
   Repo.all(from a in Agent, where: a.workspace_id == ^wid, preload: [:events])

3. Database-level aggregates - Use COUNT/SUM/AVG in SQL, never Enum.count on loaded records.

   # WRONG - loads all rows into memory
   events = Repo.all(from e in Event, where: e.workspace_id == ^wid)
   length(events)

   # CORRECT - database COUNT
   Repo.aggregate(from(e in Event, where: e.workspace_id == ^wid), :count)
   # Or for multiple aggregates:
   from(e in Event, where: e.workspace_id == ^wid,
     select: %{total: count(e.id), flagged: count(fragment("CASE WHEN ? = 'flagged' THEN 1 END", e.status))})

4. CTE/window functions for complex analytics - Use CTEs for dashboard stats, trend calculations.

   # CORRECT - CTE for multi-stat dashboard query
   stats_query = from(e in Event,
     where: e.workspace_id == ^wid and e.inserted_at >= ^since,
     select: %{
       total: count(e.id),
       flagged: filter(count(e.id), e.status == :flagged),
       blocked: filter(count(e.id), e.status == :blocked)
     })

   # CORRECT - window function for time-series
   from(e in Event,
     where: e.workspace_id == ^wid,
     select: %{
       hour: fragment("date_trunc('hour', ?)", e.inserted_at),
       count: over(count(e.id), partition_by: fragment("date_trunc('hour', ?)", e.inserted_at))
     })

5. Pagination MUST be database-level - Always LIMIT/OFFSET or cursor-based.
   Never Enum.slice on loaded records. Return {results, total_count} tuple.

   # CORRECT - database pagination
   query = from(e in Event, where: e.workspace_id == ^wid, order_by: [desc: e.inserted_at])
   total = Repo.aggregate(query, :count)
   results = Repo.all(from q in query, limit: ^limit, offset: ^offset)
   {results, total}

6. Atomic updates over read-modify-write - Use Repo.update_all for counters.

   # WRONG - race condition
   agent = Repo.get!(Agent, id)
   Agent.changeset(agent, %{event_count: agent.event_count + 1}) |> Repo.update()

   # CORRECT - atomic increment
   from(a in Agent, where: a.id == ^id)
   |> Repo.update_all(inc: [event_count: 1])
```

**Schema conventions:**
```elixir
@primary_key {:id, :binary_id, autogenerate: true}
@foreign_key_type :binary_id
timestamps(type: :utc_datetime)
```

**Migration conventions:**
```elixir
create_if_not_exists table(:name, primary_key: false) do
  add :id, :binary_id, primary_key: true
  # ... fields
  timestamps(type: :utc_datetime)
end
create_if_not_exists index(:name, [:field])
```

### STEP 4: LIVEVIEW SIGNAL (MANDATORY)

Before marking `passes: true`, output wiring details:

**IF LiveView needed:**
```
<ralph-liveview-created>
PATH: lib/swarmshield_web/live/[feature]_live.ex
ROUTE: live "/[feature]", [Module]Live (added to router.ex)
SIDEBAR: Added "[Feature]" to sidebar navigation
MOBILE: [Added / Not needed]
</ralph-liveview-created>
```

**IF backend-only (no UI):**
```
<ralph-no-liveview-needed>[reason]</ralph-no-liveview-needed>
```

### STEP 5: MARK STORY COMPLETE

1. Update the story JSON file: set `"passes": true`
2. Update `scripts/ralph/progress.txt` with the completed story
3. Commit with message: `[STORY-ID] Story title`
4. Output delivery verification:
```
<ralph-delivery-verified>[STORY-ID]</ralph-delivery-verified>
```

### STEP 6: CHECK FOR MORE WORK

After completing a story, check if there are more stories with `passes: false`.
- If yes: continue with next story (go to Step 1)
- If all stories in current phase are done, output:
```
<ralph-complete>ALL_TASKS_DONE</ralph-complete>
```

## SwarmShield Architecture Reference

SwarmShield is an AI Agent Firewall - "Cloudflare for AI Agents". It monitors, evaluates, and governs autonomous AI agent behavior using multi-agent deliberation with Claude Opus 4.6.

**Key concepts:**
- **Workspaces** - Top-level isolation boundary (all domain entities scoped to a workspace)
- **Registered Agents** - External AI agents being monitored
- **Agent Events** - Actions/outputs captured from monitored agents
- **Policy Rules** - ETS-cached allow/flag/block rules for sub-ms evaluation
- **Detection Rules** - Regex/keyword pattern matchers
- **Deliberation** - Multi-agent Opus 4.6 analysis of flagged events
- **Workflows** - Ordered analysis pipelines with multiple agent steps
- **Consensus** - Majority/supermajority/weighted voting on verdicts

**ETS Cache Architecture (20M+ users - no Nebulex, raw ETS + PubSub):**
| Cache | GenServer | ETS Table | What | Invalidation |
|-------|-----------|-----------|------|-------------|
| AuthCache | `Swarmshield.Authorization.AuthCache` | `:auth_permissions_cache` | user+workspace permissions | PubSub `auth:permissions_changed`, 5-min TTL |
| PolicyCache | `Swarmshield.Policies.PolicyCache` | `:policy_rules_cache`, `:detection_rules_cache` | Policy/detection rules per workspace | PubSub `policy_rules:*`, debounced |
| ApiKeyCache | `Swarmshield.Gateway.ApiKeyCache` | `:api_key_cache` | API key hash -> agent mapping | PubSub `agents:status_changed`, immediate |
| RateLimitCounters | (part of PolicyEngine) | `:rate_limit_counters` | Sliding window counters | TTL-based self-cleanup |
| LLM Budget | `Swarmshield.LLM.Budget` | `:llm_budget` | Workspace LLM spend | Direct ETS update_counter |

All caches follow the same pattern:
1. GenServer creates ETS table in `init/1`
2. `handle_continue(:load_cache)` wrapped in `try/rescue`
3. Public reads: ETS lookup, rescue `ArgumentError`, fallback to DB
4. Invalidation: PubSub subscription, per-workspace (never global flush)
5. Debounce bulk updates to prevent thundering herd

**File paths:**
- Schemas: `lib/swarmshield/[context]/[schema].ex`
- Contexts: `lib/swarmshield/[context].ex`
- LiveViews: `lib/swarmshield_web/live/[feature]_live.ex`
- Controllers: `lib/swarmshield_web/controllers/[name]_controller.ex`
- Tests: `test/swarmshield/[context]_test.exs`
- Test support: `test/support/fixtures/[context]_fixtures.ex`
- Migrations: `priv/repo/migrations/[timestamp]_[name].exs`

## MANDATORY SECURITY RULES (APPLY TO EVERY STORY)

These rules are NON-NEGOTIABLE. Every story must comply. Violations = immediate failure.

### 1. Mass Assignment Protection
Every changeset MUST use explicit `cast/3` with ONLY permitted fields:
```elixir
# CORRECT - explicit permitted fields
def changeset(struct, attrs) do
  struct
  |> cast(attrs, [:name, :description, :status])  # Only user-editable fields
  |> validate_required([:name])
end

# WRONG - includes sensitive fields
def changeset(struct, attrs) do
  struct
  |> cast(attrs, [:name, :description, :status, :api_key_hash, :workspace_id, :is_admin])
end
```
**NEVER cast these from user input:** `workspace_id` (set server-side), `api_key_hash`, `api_key_prefix`, `is_system`, `event_count`, `last_seen_at`, `evaluation_result`, `source_ip`, `version` (auto-increment)

### 2. handle_event Permission Checks (LiveViews)
Permission checks on mount are NOT sufficient. Every state-changing `handle_event` MUST re-verify authorization:
```elixir
# CORRECT - check permission in handle_event
def handle_event("delete", %{"id" => id}, socket) do
  if Authorization.has_permission?(socket.assigns.current_user, socket.assigns.current_workspace, "policies:delete") do
    # proceed
  else
    {:noreply, put_flash(socket, :error, "Unauthorized")}
  end
end
```

### 3. Workspace Scoping (MANDATORY on ALL queries)
Every query MUST filter by workspace_id. NEVER return cross-workspace data:
```elixir
# CORRECT - workspace scoped
def list_policy_rules(workspace_id) do
  from(r in PolicyRule, where: r.workspace_id == ^workspace_id)
  |> Repo.all()
end

# WRONG - no workspace scoping
def list_policy_rules do
  Repo.all(PolicyRule)
end
```
Show/detail views MUST verify the loaded record belongs to the current workspace. Return 404 (not 403) for wrong-workspace to prevent enumeration.

### 4. SQL Injection Prevention
ALWAYS use Ecto parameterized queries (`^` pin). NEVER string interpolation:
```elixir
# CORRECT
from(e in Event, where: e.status == ^status and e.workspace_id == ^workspace_id)

# CORRECT - parameterized fragment
from(e in Event, where: fragment("content ILIKE ?", ^"%#{sanitized}%"))

# WRONG - string interpolation
from(e in Event, where: fragment("content ILIKE '%#{user_input}%'"))
```

### 5. XSS Prevention
- NEVER use `raw/1` with user-supplied or LLM-generated content
- Phoenix auto-escapes in .heex templates - verify no `raw/1` on: event content, payload, deliberation messages, verdict reasoning, agent metadata, system_prompt display
- JSON responses: strip sensitive fields before rendering

### 6. CSRF Protection
- Browser pipeline MUST include `:protect_from_forgery` and `:put_secure_browser_headers`
- State-changing actions MUST use POST (never GET)
- Logout MUST use DELETE method with CSRF token (not a GET link)

### 7. API Authentication Security
- API keys: generate with `:crypto.strong_rand_bytes(32)`, store SHA256 hash only
- Hash-then-lookup pattern for key validation (hash input, query by hash)
- NEVER differentiate "agent not found" vs "invalid key" in error responses - use generic "invalid credentials"
- Failed auth attempts: log to audit_entry with source IP (NOT full token)
- Rate limit auth failures per IP (brute-force protection)

### 8. LLM Prompt Injection Prevention
When sending user-supplied event content to LLM:
- Use Anthropic API structured message format: system prompt in `system` parameter, user content in `user` role
- NEVER embed raw event content into system prompt strings
- Clearly demarcate system instructions vs user-supplied data
- Validate/sanitize LLM responses before storing (can echo injected content)

### 9. ReDoS Prevention (Detection Rules)
Admin-supplied regex patterns MUST be validated:
- Compile with `Regex.compile/1` and test against pathological input within a timeout
- Enforce maximum pattern length (10,000 chars)
- Execute regex matching with timeout (Task with timeout or byte limit)
- NEVER use `Code.eval_string` for pattern testing

### 10. Audit Trail (Security Events)
These actions MUST create audit_entry records:
- Auth failures (login, API key)
- Permission denied events
- CRUD on security-critical resources (policy rules, detection rules, agent definitions, roles, permissions)
- Agent suspension/revocation
- API key generation/rotation
- Workspace switches
- Deliberation triggers and verdicts
- Metadata must NEVER contain passwords, raw API keys, or tokens

### 11. Input Validation
- Enum fields: validate against `Ecto.Enum` values or explicit allowlists
- Numeric fields: validate upper/lower bounds (e.g., max_retries <= 10, threshold 0.0-1.0)
- Text fields: validate max byte_size in changeset
- API Content-Type: validate `application/json` header, return 415 if not
- source_ip: extract from `conn.remote_ip`, NEVER from request body
- Params: use explicit `Map.take` or pattern match, never pass raw params map

### 12. No Code Execution
NEVER pass user input to: `Code.eval_string`, `Code.eval_quoted`, `EEx.eval_string`, `:os.cmd`, `System.cmd`, `System.shell`. Template interpolation uses safe `String.replace/3` only.

### 13. PubSub Security
- PubSub broadcast payloads MUST NOT include: api_key_hash, raw rule configs, detection patterns, passwords
- LiveView PubSub subscription topics MUST use workspace_id from server-side assigns
- Include only minimum data needed for UI updates (IDs and action type)

### 14. Session Security
- Workspace ID in session re-validated on every request (user still has active role)
- Role/permission changes invalidate affected sessions
- API key regeneration invalidates old key immediately

### 15. Production Safety
- Health endpoint: use `Application.spec(:swarmshield, :vsn)` (NOT `Mix.Project` - unavailable in releases)
- Health endpoint: NEVER expose Elixir version, OTP version, internal IPs, DB version
- Debug routes (`/dev/mailbox`, LiveDashboard): environment-guarded, NEVER in production
- Simulator: ONLY runs in :dev/:test, locked to localhost

## CRITICAL ANTI-PATTERNS - NEVER DO THESE

1. **No socket copying in async**: Extract values BEFORE callbacks
2. **No unrescued handle_continue**: Always try/rescue ETS loading
3. **No direct Repo in LiveViews**: Use context functions
4. **No N+1 queries**: Always preload associations
5. **No hardcoded business values**: Everything database-driven
6. **No atom creation from user input**: Use String.to_existing_atom/1
7. **No old LiveView syntax**: Use Phoenix 1.8 / LiveView 1.1 patterns
8. **No conditionals where pattern matching works**: Use pattern matching
9. **No `raw/1` with user/LLM content**: Always let Phoenix auto-escape
10. **No string interpolation in SQL**: Always use `^` pin operator
11. **No sensitive fields in user-facing cast/3**: workspace_id, api_key_hash etc. set server-side
12. **No generic 500 errors leaking internals**: Rescue and return safe error messages

## BLOCKED? Output this:

If you cannot proceed (missing dependency, unclear requirement, test failure you can't fix):
```
<ralph-blocked>
STORY: [STORY-ID]
REASON: [detailed explanation]
ATTEMPTED: [what you tried]
NEEDS: [what human needs to do]
</ralph-blocked>
```
