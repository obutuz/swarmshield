# SwarmShield: AI Agent Firewall

**Multi-agent deliberation powered by Claude Opus 4.6. Ephemeral by design.**

SwarmShield intercepts every action AI agents take in real time. A sub-millisecond policy engine catches threats instantly. Flagged events trigger a swarm of five Claude Opus 4.6 agents — Security Analyst, Ethics Reviewer, Threat Hunter, Compliance Auditor, PII Guardian — that analyze in parallel, debate, and vote on a verdict. GhostProtocol destroys all session data after the verdict, leaving only the decision behind.

Built on Elixir/OTP — the same runtime that powers WhatsApp for 2 billion users. Each deliberation runs as an isolated lightweight process. Built entirely with Claude Code.

---

## Prerequisites

SwarmShield is built with Elixir/Phoenix. If you're coming from Node.js, here's everything you need to install.

### 1. Install Erlang and Elixir

**macOS (Homebrew):**

```bash
brew install erlang elixir
```

**Ubuntu/Debian:**

```bash
# Add Erlang Solutions repo
wget https://packages.erlang-solutions.com/erlang-solutions_2.0_all.deb
sudo dpkg -i erlang-solutions_2.0_all.deb
sudo apt-get update

sudo apt-get install esl-erlang elixir
```

**Windows (Chocolatey):**

```bash
choco install elixir
```

**Or use version managers** (like `nvm` for Node — these are the Elixir equivalents):

```bash
# Using mise (recommended — like nvm but for any language)
curl https://mise.run | sh
mise install erlang@28
mise install elixir@1.19

# Or using asdf
asdf plugin add erlang
asdf plugin add elixir
asdf install erlang 28.1.1
asdf install elixir 1.19.3-otp-28
```

Verify installation:

```bash
elixir --version
# Should show: Elixir 1.19.x (compiled with Erlang/OTP 28)
```

### 2. Install PostgreSQL

**macOS:**

```bash
brew install postgresql@17
brew services start postgresql@17
```

**Ubuntu/Debian:**

```bash
sudo apt-get install postgresql postgresql-contrib
sudo systemctl start postgresql
```

Ensure the default `postgres` user exists with password `postgres` (dev defaults):

```bash
# macOS — create postgres superuser if needed
createuser -s postgres

# Set password (enter 'postgres' when prompted)
psql -U postgres -c "ALTER USER postgres PASSWORD 'postgres';"
```

### 3. Anthropic API Key

SwarmShield uses Claude Opus 4.6 for multi-agent deliberation. You need an API key:

1. Get one at [console.anthropic.com](https://console.anthropic.com/)
2. Export it in your shell:

```bash
export ANTHROPIC_API_KEY=sk-ant-your-key-here
```

Add this to your `~/.bashrc`, `~/.zshrc`, or shell profile so it persists.

> **Note:** The app runs without an API key — you can browse the dashboard, events, and admin pages. Deliberations just won't trigger without it.

---

## Getting Started

```bash
# Clone the repo
git clone https://github.com/obutuz/swarmshield.git
cd swarmshield

# Install Elixir dependencies (like npm install)
mix deps.get

# Create the database, run migrations, and seed demo data
mix ecto.setup

# Start the server (like npm run dev)
mix phx.server
```

The app is now running at [http://localhost:4000](http://localhost:4000).

---

## Logging In

SwarmShield uses **magic link authentication** (no passwords). A demo account is pre-seeded:

1. Go to [http://localhost:4000/users/log-in](http://localhost:4000/users/log-in)
2. Enter: **`demo@hackathon.com`**
3. Click "Send magic link"
4. Open the dev mailbox at [http://localhost:4000/dev/mailbox](http://localhost:4000/dev/mailbox)
5. Click the magic link in the email

You're now logged in as a **super_admin** with full access to all features.

> **How `/dev/mailbox` works:** In development, emails aren't sent externally. Phoenix captures them in an in-memory inbox you can view at `/dev/mailbox`. This is where your magic link appears. This route only exists in dev mode.

---

## What You'll See

| Page | URL | What it does |
|------|-----|-------------|
| Landing | [/](http://localhost:4000/) | Animated globe, project overview |
| Dashboard | [/dashboard](http://localhost:4000/dashboard) | Live stats, recent events, active deliberations |
| Events | [/events](http://localhost:4000/events) | Real-time event stream with allow/flag/block badges |
| Deliberations | [/deliberations](http://localhost:4000/deliberations) | Multi-agent debate sessions with Opus 4.6 |
| GhostProtocol | [/ghost-protocol](http://localhost:4000/ghost-protocol) | Ephemeral sessions with data destruction |
| Audit Log | [/audit-log](http://localhost:4000/audit-log) | Immutable record of all system actions |
| Admin | [/admin/workflows](http://localhost:4000/admin/workflows) | Configure workflows, agents, policies, rules |

---

## Triggering a Deliberation

The seed data prints an API key and a `curl` command. You can also trigger from the dashboard:

1. Go to [/dashboard](http://localhost:4000/dashboard)
2. Select a demo scenario (e.g. "PII Data Leak")
3. Click "Send Event"
4. Watch the event get flagged by the policy engine
5. A deliberation spawns — navigate to [/deliberations](http://localhost:4000/deliberations)
6. Watch five Opus 4.6 agents analyze, debate, and vote in real-time

Or via the API:

```bash
curl -X POST http://localhost:4000/api/v1/events \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -d '{"event_type": "tool_call", "content": "User SSN is 123-45-6789", "severity": "medium"}'
```

The API key is displayed in your terminal when you run `mix ecto.setup`.

---

## Project Structure

If you're familiar with Node.js/Express, here's the mapping:

| Node.js concept | Elixir/Phoenix equivalent |
|-----------------|--------------------------|
| `package.json` | `mix.exs` |
| `npm install` | `mix deps.get` |
| `npm run dev` | `mix phx.server` |
| `node_modules/` | `deps/` |
| Express routes | `lib/swarmshield_web/router.ex` |
| React components | LiveView files in `lib/swarmshield_web/live/` |
| Prisma/Sequelize models | Ecto schemas in `lib/swarmshield/` |
| `.env` | `config/dev.exs` (compile-time) and env vars (runtime) |
| Jest/Mocha | ExUnit — `mix test` |
| Middleware | Plugs in `lib/swarmshield_web/plugs/` |

---

## Key Commands

```bash
mix phx.server          # Start the dev server
mix test                # Run the test suite (1750+ tests)
mix ecto.reset          # Drop, recreate, migrate, and reseed the database
mix credo --strict      # Lint (like ESLint)
mix dialyzer            # Static type analysis
iex -S mix phx.server   # Start with interactive Elixir shell (like node --inspect)
```

---

## Tech Stack

- **Elixir 1.19** / **Phoenix 1.8** / **LiveView 1.1** — real-time UI without JavaScript frameworks
- **PostgreSQL** / **Ecto** — database layer with migration system
- **Claude Opus 4.6** via `req_llm` — multi-agent deliberation engine
- **ETS** — in-memory cache for sub-millisecond policy evaluation
- **OTP Supervision** — fault-tolerant process management (each deliberation is isolated)
- **PubSub** — real-time updates pushed to browser (no polling)
- **DaisyUI** / **Tailwind CSS v4** — styling
- **Built 100% with Claude Code**

---

## License

MIT
