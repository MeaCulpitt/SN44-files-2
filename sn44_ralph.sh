#!/bin/bash
# sn44_ralph.sh
#
# Autonomous three-loop Ralph script for SN44 TurboVision miner.
# Runs Claude Code on a schedule matching Bittensor tempo cadence.
#
# Usage:
#   ./sn44_ralph.sh                    # run all three loops continuously
#   ./sn44_ralph.sh --loop fast        # run only the fast loop
#   ./sn44_ralph.sh --loop medium      # run only the medium loop
#   ./sn44_ralph.sh --loop slow        # run only the slow loop (interactive)
#   ./sn44_ralph.sh --once             # run one iteration of the appropriate loop and exit
#   ./sn44_ralph.sh --dry-run          # show what would run without executing
#
# Loop cadences (from CLAUDE.md):
#   Fast loop:   every tempo (~12 min = 720s). Observation only.
#   Medium loop: every 3-5 fast loops (~36-60 min). Triage and diagnosis.
#   Slow loop:   when medium loop produces READY_FOR_MUTATION. Interactive.
#
# Prerequisites:
#   - claude CLI installed and authenticated
#   - CLAUDE.md, subnet_config.json, and registry/ in current directory
#   - sv CLI available for deployment commands
#
# Logs: ./logs/fast_YYYYMMDD.log, ./logs/medium_YYYYMMDD.log, ./logs/slow_YYYYMMDD.log

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
FAST_INTERVAL=720          # seconds between fast loop iterations (~1 tempo)
MEDIUM_EVERY_N_FAST=4      # run medium loop after every N fast loop iterations
SLOW_CHECK_EVERY_N_FAST=5  # check for slow loop trigger after every N fast loops

LOG_DIR="./logs"
REGISTRY_DIR="./registry"
PROGRESS_FILE="${REGISTRY_DIR}/progress.txt"
REGISTRY_FILE="${REGISTRY_DIR}/agent_registry.jsonl"
MUTATIONS_FILE="${REGISTRY_DIR}/mutations.jsonl"

# Signals Claude Code outputs that the scripts detect
HOLD_SIGNAL="HOLD"
PLATEAU_SIGNAL="PLATEAU_REACHED"
READY_SIGNAL="READY_FOR_MUTATION"
DEPLOY_SIGNAL="DEPLOYING"

# ── Argument parsing ──────────────────────────────────────────────────────────
LOOP_MODE="all"
ONCE=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --loop) LOOP_MODE="$2"; shift 2 ;;
    --once) ONCE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ── Setup ─────────────────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR" "$REGISTRY_DIR"

log() {
  local level="$1"
  local msg="$2"
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$ts] [$level] $msg" | tee -a "${LOG_DIR}/${level}_$(date '+%Y%m%d').log"
}

check_prerequisites() {
  if ! command -v claude &>/dev/null; then
    echo "ERROR: claude CLI not found. Install Claude Code first."
    exit 1
  fi
  if [[ ! -f "CLAUDE.md" ]]; then
    echo "ERROR: CLAUDE.md not found. Run from your miner repo root."
    exit 1
  fi
  if [[ ! -f "subnet_config.json" ]]; then
    echo "ERROR: subnet_config.json not found."
    exit 1
  fi
  if [[ ! -f "${PROGRESS_FILE}" ]]; then
    echo "ERROR: ${PROGRESS_FILE} not found. Run: python registry/init_registry.py"
    exit 1
  fi
}

count_fast_loops_since_deploy() {
  # Count FAST entries after the last DEPLOYING entry in progress.txt
  if [[ ! -f "$PROGRESS_FILE" ]]; then echo 0; return; fi
  local last_deploy_line=0
  local line_num=0
  local fast_count=0
  while IFS= read -r line; do
    ((line_num++))
    if echo "$line" | grep -q "DEPLOYING"; then
      last_deploy_line=$line_num
      fast_count=0
    elif echo "$line" | grep -q "\] FAST"; then
      if [[ $last_deploy_line -gt 0 ]]; then
        ((fast_count++))
      fi
    fi
  done < "$PROGRESS_FILE"
  echo $fast_count
}

last_medium_diagnosis() {
  # Extract the last DIAGNOSIS line from progress.txt
  if [[ ! -f "$PROGRESS_FILE" ]]; then echo ""; return; fi
  grep "DIAGNOSIS\|MEDIUM.*diagnosis" "$PROGRESS_FILE" | tail -1
}

should_run_slow_loop() {
  local diagnosis
  diagnosis=$(last_medium_diagnosis)
  if echo "$diagnosis" | grep -qE "READY_FOR_MUTATION|QUALITY_GAP|ENSEMBLE_SATURATED"; then
    return 0  # true
  fi
  return 1    # false
}

# ── Fast loop ─────────────────────────────────────────────────────────────────
run_fast_loop() {
  log "fast" "Starting fast loop iteration"

  local prompt
  prompt="@CLAUDE.md @registry/agent_registry.jsonl @registry/progress.txt @subnet_config.json

You are running the FAST LOOP only.
Read Section 2 (Fast Loop) of CLAUDE.md. Execute exactly those steps.
Append one observation entry to registry/agent_registry.jsonl.
Append one FAST line to registry/progress.txt.
If the window gate is active (fewer than 5 fast loops since last DEPLOYING):
  note it in the FAST line as gate=N/5.
Do NOT run triage. Do NOT propose mutations. Do NOT deploy.
Output exactly one of:
  FAST_COMPLETE -- observation appended successfully
  FAST_ANOMALY:<reason> -- anomaly detected, medium loop should run now
  HOLD -- window gate active (include gate count)"

  if [[ "$DRY_RUN" == true ]]; then
    log "fast" "[DRY RUN] Would invoke claude with fast loop prompt"
    echo "FAST_COMPLETE"
    return
  fi

  local result
  result=$(claude --print "$prompt" 2>>"${LOG_DIR}/fast_$(date '+%Y%m%d').log")
  local exit_code=$?

  echo "$result" >> "${LOG_DIR}/fast_$(date '+%Y%m%d').log"

  if [[ $exit_code -ne 0 ]]; then
    log "fast" "ERROR: claude exited with code $exit_code"
    return 1
  fi

  log "fast" "Result: $(echo "$result" | tail -1)"
  echo "$result"
}

# ── Medium loop ───────────────────────────────────────────────────────────────
run_medium_loop() {
  log "medium" "Starting medium loop iteration"

  local prompt
  prompt="@CLAUDE.md @registry/agent_registry.jsonl @registry/progress.txt @subnet_config.json @registry/shadow_accuracy.json

You are running the MEDIUM LOOP only.
Read Section 2 (Medium Loop) of CLAUDE.md. Execute exactly those steps:
  1. Run the full triage protocol (Section 4).
  2. Produce exactly one diagnosis from the allowed list.
  3. Append a MEDIUM line and DIAGNOSIS line to registry/progress.txt.
  4. Update registry/shadow_accuracy.json if relevant.
Do NOT propose mutations. Do NOT deploy. Do NOT run sv push.
Output exactly one of:
  MEDIUM_STABLE -- no action needed
  MEDIUM_READY_FOR_MUTATION:<tier>:<description> -- slow loop should run
  MEDIUM_HOLD:<reason> -- window gate or attribution confidence too low
  MEDIUM_ERROR:<reason> -- triage found a critical issue to fix"

  if [[ "$DRY_RUN" == true ]]; then
    log "medium" "[DRY RUN] Would invoke claude with medium loop prompt"
    echo "MEDIUM_STABLE"
    return
  fi

  local result
  result=$(claude --print "$prompt" 2>>"${LOG_DIR}/medium_$(date '+%Y%m%d').log")
  local exit_code=$?

  echo "$result" >> "${LOG_DIR}/medium_$(date '+%Y%m%d').log"

  if [[ $exit_code -ne 0 ]]; then
    log "medium" "ERROR: claude exited with code $exit_code"
    return 1
  fi

  log "medium" "Result: $(echo "$result" | tail -1)"
  echo "$result"
}

# ── Slow loop (interactive) ───────────────────────────────────────────────────
run_slow_loop() {
  log "slow" "Starting slow loop -- INTERACTIVE (requires human approval)"

  echo ""
  echo "════════════════════════════════════════════════════════"
  echo "  SLOW LOOP -- mutation proposal requires your approval"
  echo "════════════════════════════════════════════════════════"
  echo ""
  echo "Medium loop has signalled READY_FOR_MUTATION."
  echo "Claude Code will now propose a mutation and validate it."
  echo "You will be asked to approve before any sv push executes."
  echo ""

  if [[ "$DRY_RUN" == true ]]; then
    log "slow" "[DRY RUN] Would invoke claude interactively for slow loop"
    return
  fi

  # Run interactively -- no --print flag so human can review and approve
  claude \
    "@CLAUDE.md" \
    "@registry/agent_registry.jsonl" \
    "@registry/progress.txt" \
    "@subnet_config.json" \
    "@registry/mutations.jsonl" \
    "@registry/shadow_accuracy.json" \
    "You are running the SLOW LOOP only.
Read Section 2 (Slow Loop) of CLAUDE.md. Execute exactly those steps:
  1. Verify all preconditions (Section 2, Slow Loop).
  2. Run the attribution protocol (Section 5) explicitly.
  3. Propose exactly ONE mutation with tier and shadow prediction.
  4. Validate against replay buffer / alignment checks.
  5. If deploying: output the exact sv push command for human review.
     WAIT for human confirmation before appending DEPLOYING to progress.txt.
  6. Append outcome to registry/mutations.jsonl and registry/progress.txt.
If any precondition fails: output SLOW_HOLD:<reason> and stop.
If plateau reached: output PLATEAU_REACHED."

  local exit_code=$?
  log "slow" "Slow loop completed (exit code: $exit_code)"

  # Check if plateau was reached
  if grep -q "PLATEAU_REACHED" "${LOG_DIR}/slow_$(date '+%Y%m%d').log" 2>/dev/null; then
    log "slow" "PLATEAU reached. Entering monitoring mode."
    return 2  # special exit code for plateau
  fi
}

# ── Main orchestrator ─────────────────────────────────────────────────────────
main() {
  check_prerequisites

  log "main" "Starting SN44 Ralph loop (mode: $LOOP_MODE)"
  log "main" "Fast interval: ${FAST_INTERVAL}s, Medium every: ${MEDIUM_EVERY_N_FAST} fast loops"

  local fast_iteration=0
  local plateau_reached=false

  # Single loop mode
  if [[ "$LOOP_MODE" == "fast" ]]; then
    run_fast_loop
    exit 0
  elif [[ "$LOOP_MODE" == "medium" ]]; then
    run_medium_loop
    exit 0
  elif [[ "$LOOP_MODE" == "slow" ]]; then
    run_slow_loop
    exit 0
  fi

  # Main orchestration loop
  while [[ "$plateau_reached" == false ]]; do
    ((fast_iteration++))
    log "main" "=== Iteration $fast_iteration ==="

    # ── Fast loop ──────────────────────────────────────────────────────────
    fast_result=$(run_fast_loop)
    fast_exit=$?

    if [[ $fast_exit -ne 0 ]]; then
      log "main" "Fast loop failed. Waiting ${FAST_INTERVAL}s before retry."
      sleep "$FAST_INTERVAL"
      continue
    fi

    # Check for anomaly -- trigger medium loop immediately if detected
    local run_medium=false
    if echo "$fast_result" | grep -q "FAST_ANOMALY"; then
      log "main" "Anomaly detected -- triggering medium loop immediately"
      run_medium=true
    elif (( fast_iteration % MEDIUM_EVERY_N_FAST == 0 )); then
      log "main" "Scheduled medium loop (every ${MEDIUM_EVERY_N_FAST} fast loops)"
      run_medium=true
    fi

    # ── Medium loop ────────────────────────────────────────────────────────
    if [[ "$run_medium" == true ]]; then
      medium_result=$(run_medium_loop)
      medium_exit=$?

      if [[ $medium_exit -ne 0 ]]; then
        log "main" "Medium loop failed. Continuing."
      elif echo "$medium_result" | grep -q "MEDIUM_READY_FOR_MUTATION"; then
        # ── Slow loop ──────────────────────────────────────────────────────
        log "main" "Medium loop signalled READY_FOR_MUTATION. Running slow loop."
        run_slow_loop
        slow_exit=$?

        if [[ $slow_exit -eq 2 ]]; then
          log "main" "PLATEAU reached. Switching to monitoring mode."
          plateau_reached=true
        fi
      elif echo "$medium_result" | grep -q "PLATEAU_REACHED"; then
        log "main" "PLATEAU reached via medium loop."
        plateau_reached=true
      fi
    fi

    if [[ "$plateau_reached" == true ]]; then
      break
    fi

    if [[ "$ONCE" == true ]]; then
      log "main" "--once flag set. Exiting after one iteration."
      exit 0
    fi

    log "main" "Sleeping ${FAST_INTERVAL}s until next fast loop..."
    sleep "$FAST_INTERVAL"
  done

  # ── Plateau monitoring mode ────────────────────────────────────────────────
  log "main" "Entering plateau monitoring mode (fast loop only)."
  echo ""
  echo "Plateau reached. Running fast loop only to watch for:"
  echo "  - Manifest changes (pgt_recipe_hash update)"
  echo "  - Competitor rank movement"
  echo "  - baseline_theta recalibration"
  echo ""

  while true; do
    fast_result=$(run_fast_loop)
    # In monitoring mode, only break out if manifest change detected
    if echo "$fast_result" | grep -q "MANIFEST_CHANGE\|CONFIG_CHANGE"; then
      log "main" "Manifest change detected. Exiting monitoring mode."
      log "main" "Re-run sn44_ralph.sh to begin a new iteration cycle."
      exit 0
    fi
    sleep "$FAST_INTERVAL"
  done
}

main "$@"
