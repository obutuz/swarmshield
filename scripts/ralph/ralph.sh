#!/bin/bash
# Ralph Wiggum for SwarmShield - AFK Autonomous Loop
# Usage: ./ralph.sh [max_iterations]
# Example: ./ralph.sh 25

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
MAX_ITERATIONS=${1:-10}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROMPT_FILE="$SCRIPT_DIR/PROMPT_build.md"

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo -e "${RED}Error: $PROMPT_FILE not found${NC}"
  exit 1
fi

# Check for claude CLI
if ! command -v claude &> /dev/null; then
  echo -e "${RED}Error: 'claude' CLI not found. Please install Claude Code.${NC}"
  exit 1
fi

echo -e "${BLUE}"
echo "=================================================================="
echo "   Ralph Wiggum for SwarmShield - AFK Mode"
echo "=================================================================="
echo -e "${NC}"
echo -e "   Max iterations: ${YELLOW}$MAX_ITERATIONS${NC}"
echo -e "   Project: $PROJECT_ROOT"
echo -e "   Prompt: $PROMPT_FILE"
echo ""
echo -e "${YELLOW}Press Ctrl+C to stop at any time${NC}"
echo ""

cd "$PROJECT_ROOT"

# Track start time
START_TIME=$(date +%s)
SUCCESSFUL_ITERATIONS=0

for i in $(seq 1 $MAX_ITERATIONS); do
  ITERATION_START=$(date +%s)

  echo -e "${BLUE}"
  echo "=================================================================="
  echo "   Iteration $i of $MAX_ITERATIONS - $(date '+%Y-%m-%d %H:%M:%S')"
  echo "=================================================================="
  echo -e "${NC}"

  # Cleanup stale processes before each iteration
  echo -e "${YELLOW}Cleaning up stale processes...${NC}"
  pkill -f "mix test" 2>/dev/null || true
  pkill -f "mix compile" 2>/dev/null || true
  sleep 2  # Let processes terminate gracefully

  # Report any high-CPU BEAM processes
  HIGH_CPU=$(ps aux | grep beam.smp | grep -v grep | awk '$3 > 50 {print "  PID " $2 " at " $3 "% CPU"}')
  if [[ -n "$HIGH_CPU" ]]; then
    echo -e "${YELLOW}Warning: High CPU BEAM processes detected:${NC}"
    echo "$HIGH_CPU"
  fi

  # Create temporary file for output capture
  OUTPUT_FILE=$(mktemp)

  # Run Claude Code with the prompt
  if cat "$PROMPT_FILE" | claude -p --dangerously-skip-permissions 2>&1 | tee "$OUTPUT_FILE"; then
    ITERATION_SUCCESS=true
  else
    ITERATION_SUCCESS=false
  fi

  OUTPUT=$(cat "$OUTPUT_FILE")
  rm -f "$OUTPUT_FILE"

  # Calculate iteration time
  ITERATION_END=$(date +%s)
  ITERATION_TIME=$((ITERATION_END - ITERATION_START))

  echo ""
  echo -e "${YELLOW}Iteration $i completed in ${ITERATION_TIME}s${NC}"

  # Check for completion signal
  if echo "$OUTPUT" | grep -q "<ralph-complete>ALL_TASKS_DONE</ralph-complete>"; then
    END_TIME=$(date +%s)
    TOTAL_TIME=$((END_TIME - START_TIME))

    echo ""
    echo -e "${GREEN}"
    echo "=================================================================="
    echo "   SUCCESS! Ralph completed all tasks!"
    echo "=================================================================="
    echo -e "${NC}"
    echo -e "   Total iterations: ${GREEN}$i${NC}"
    echo -e "   Total time: ${GREEN}${TOTAL_TIME}s${NC}"
    echo -e "   Successful iterations: ${GREEN}$SUCCESSFUL_ITERATIONS${NC}"
    echo ""
    echo "Review the changes with: git log --oneline -20"
    exit 0
  fi

  # Check for blocked signal
  if echo "$OUTPUT" | grep -q "<ralph-blocked>"; then
    echo ""
    echo -e "${RED}"
    echo "=================================================================="
    echo "   BLOCKED! Ralph needs human intervention"
    echo "=================================================================="
    echo -e "${NC}"
    echo "Check these files for details:"
    echo "  - scripts/ralph/progress.txt"
    echo ""

    # Extract and display the blocker reason
    echo -e "${YELLOW}Blocker details:${NC}"
    echo "$OUTPUT" | grep -A 10 "<ralph-blocked>" || true

    exit 1
  fi

  # Verify mandatory checklist steps
  # Step 0: Instructions acknowledged
  if ! echo "$OUTPUT" | grep -q "<ralph-instructions-acknowledged>"; then
    echo -e "${RED}INSTRUCTIONS NOT ACKNOWLEDGED!${NC}"
  else
    echo -e "${GREEN}Instructions acknowledged${NC}"
  fi

  # Step 1: Files read confirmation
  if ! echo "$OUTPUT" | grep -q "<ralph-files-read>"; then
    echo -e "${RED}MANDATORY FILES NOT READ!${NC}"
  else
    echo -e "${GREEN}Mandatory files read${NC}"
  fi

  # Step 2: Pre-coding checklist verification
  if ! echo "$OUTPUT" | grep -q "<ralph-checklist-verified>"; then
    echo -e "${RED}PRE-CODING CHECKLIST NOT VERIFIED!${NC}"
  else
    echo -e "${GREEN}Pre-coding checklist verified${NC}"
  fi

  # Delivery verification
  if echo "$OUTPUT" | grep -q "\"passes\": true"; then
    if ! echo "$OUTPUT" | grep -q "<ralph-delivery-verified>"; then
      echo -e "${RED}DELIVERY NOT VERIFIED!${NC}"
    else
      echo -e "${GREEN}Delivery verified${NC}"
    fi
  fi

  # Check for LiveView creation signals
  if echo "$OUTPUT" | grep -q "<ralph-liveview-created>"; then
    echo -e "${GREEN}LiveView(s) created${NC}"
  elif echo "$OUTPUT" | grep -q "<ralph-no-liveview-needed>"; then
    echo -e "${YELLOW}No LiveView needed for this story${NC}"
  fi

  # Increment successful iterations if no errors
  if [[ "$ITERATION_SUCCESS" == "true" ]]; then
    ((SUCCESSFUL_ITERATIONS++))
  fi

  # Brief pause between iterations to prevent rate limiting
  echo ""
  echo -e "${YELLOW}Pausing 60s before next iteration...${NC}"
  sleep 60
done

END_TIME=$(date +%s)
TOTAL_TIME=$((END_TIME - START_TIME))

echo ""
echo -e "${YELLOW}"
echo "=================================================================="
echo "   Max iterations ($MAX_ITERATIONS) reached"
echo "=================================================================="
echo -e "${NC}"
echo -e "   Total time: ${TOTAL_TIME}s"
echo -e "   Successful iterations: $SUCCESSFUL_ITERATIONS"
echo ""
echo "Review status:"
echo "  - scripts/ralph/progress.txt"
echo ""
echo "To continue: ./ralph.sh $MAX_ITERATIONS"
exit 1
