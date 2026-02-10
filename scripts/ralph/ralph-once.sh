#!/bin/bash
# Ralph Wiggum for SwarmShield - Single Iteration (Human-In-The-Loop Mode)
# Usage: ./ralph-once.sh
# Runs one iteration in interactive mode where you can review each action.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROMPT_FILE="$SCRIPT_DIR/PROMPT_build.md"

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "Error: $PROMPT_FILE not found"
  exit 1
fi

# Check for claude CLI
if ! command -v claude &> /dev/null; then
  echo "Error: 'claude' CLI not found. Please install Claude Code."
  exit 1
fi

echo "=================================================================="
echo "   Ralph Wiggum for SwarmShield - Single Iteration (HITL)"
echo "=================================================================="
echo "   Project: $PROJECT_ROOT"
echo "   Prompt: $PROMPT_FILE"
echo ""
echo "Running in INTERACTIVE mode - you can review and approve each action."
echo ""

cd "$PROJECT_ROOT"

# Run in interactive mode (no -p flag, no --dangerously-skip-permissions)
cat "$PROMPT_FILE" | claude

echo ""
echo "=================================================================="
echo "   Iteration complete"
echo "=================================================================="
echo ""
echo "Review changes: git diff HEAD~1"
echo "View progress: cat scripts/ralph/progress.txt"
echo ""
echo "To continue: ./ralph-once.sh"
echo "To run autonomously: ./ralph.sh 10"
