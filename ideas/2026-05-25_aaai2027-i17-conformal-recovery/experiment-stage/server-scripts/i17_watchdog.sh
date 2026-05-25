#!/usr/bin/env bash
# I17 watchdog — runs every 5 min from cron. Idempotent.
#
# - If the tmux session 'i17' is missing, recreate it and start the launcher.
# - If the launcher heartbeat is older than 5 min, kill the launcher window and restart.
# - If any GPU stays <5% utilization for >15 min AND queue has pending jobs, log a warning.
# - If any job's log hasn't grown in 30 min, log a warning (likely hang).
# - Rotate logs/jobs older than 14 days into logs/jobs/archive/.

set -u
SESSION=${I17_SESSION:-i17}
PROJECT=${I17_ROOT:-/root/i17_conformal}
SCRIPTS=$PROJECT/scripts
STATE=$PROJECT/state
LOGS=$PROJECT/logs
WD_LOG=$LOGS/watchdog.log
HB=$STATE/launcher_heartbeat

mkdir -p "$STATE" "$LOGS/jobs/archive"
exec >> "$WD_LOG" 2>&1
echo "----- $(date -Is) watchdog tick -----"

start_launcher_window() {
  echo "starting launcher window in tmux session=$SESSION"
  tmux new-window -t "$SESSION" -n launcher -d \
    "bash -lc 'source ~/miniconda3/etc/profile.d/conda.sh && conda activate i17_conformal && cd $PROJECT && python $SCRIPTS/i17_launcher.py 2>&1 | tee -a $LOGS/launcher.log'"
}

ensure_session() {
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "tmux session $SESSION missing -> creating"
    tmux new-session -d -s "$SESSION" -n shell
    start_launcher_window
    return 0
  fi
  if ! tmux list-windows -t "$SESSION" -F '#W' | grep -qx launcher; then
    echo "launcher window missing -> starting"
    start_launcher_window
    return 0
  fi
}

check_heartbeat() {
  if [[ ! -f $HB ]]; then
    echo "no heartbeat file yet"
    return 0
  fi
  local age_s
  age_s=$(( $(date +%s) - $(date -d "$(cat "$HB")" +%s) ))
  echo "launcher heartbeat age: ${age_s}s"
  if (( age_s > 300 )); then
    echo "heartbeat stale (>300s) -> killing launcher window and restarting"
    tmux kill-window -t "$SESSION:launcher" 2>/dev/null || true
    sleep 2
    start_launcher_window
  fi
}

check_gpus() {
  # Persist per-GPU low-util counters across runs in state/gpu_low_util_count.json
  # "remaining" = jobs in queue.jsonl that are neither active nor completed.
  # The naive `wc -l queue - wc -l completed` over-counts because queue.jsonl is
  # append-only and accumulates retryN entries; the set-difference is the truth.
  local remaining
  remaining=$(python3 - <<PYEOF
import json
from pathlib import Path
state = Path("$STATE")
queue_ids = set()
qf = state / "queue.jsonl"
if qf.exists():
    with qf.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                queue_ids.add(json.loads(line)["id"])
            except (ValueError, KeyError):
                pass
active_ids = set()
af = state / "active_jobs.json"
if af.exists():
    try:
        active_ids = set(json.loads(af.read_text()).keys())
    except ValueError:
        pass
completed_ids = set()
cf = state / "completed.jsonl"
if cf.exists():
    with cf.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                completed_ids.add(json.loads(line)["id"])
            except (ValueError, KeyError):
                pass
print(len(queue_ids - active_ids - completed_ids))
PYEOF
)
  remaining=${remaining:-0}
  local counter=$STATE/gpu_low_util.tsv
  touch "$counter"
  while IFS=, read -r idx util _; do
    idx=$(echo "$idx" | tr -d ' ')
    util=$(echo "$util" | tr -d ' %')
    if [[ "$util" =~ ^[0-9]+$ ]] && (( util < 5 )); then
      prev=$(grep -P "^$idx\t" "$counter" 2>/dev/null | awk '{print $2}')
      prev=${prev:-0}
      new=$(( prev + 1 ))
      grep -vP "^$idx\t" "$counter" > "$counter.tmp" 2>/dev/null || true
      echo -e "$idx\t$new" >> "$counter.tmp"
      mv "$counter.tmp" "$counter"
      if (( new >= 3 && remaining > 0 )); then
        echo "WARN gpu$idx idle (<5% util) for $((new * 5)) min; queue has $remaining pending"
      fi
    else
      # reset counter
      grep -vP "^$idx\t" "$counter" > "$counter.tmp" 2>/dev/null || true
      mv "$counter.tmp" "$counter"
    fi
  done < <(nvidia-smi --query-gpu=index,utilization.gpu,memory.used --format=csv,noheader)
}

check_job_logs() {
  find "$LOGS/jobs" -maxdepth 1 -name '*.log' -mmin +30 -print 2>/dev/null | while read -r f; do
    # Only flag if the job is still in active_jobs
    jid=$(basename "$f" .log)
    if grep -q "\"$jid\"" "$STATE/active_jobs.json" 2>/dev/null; then
      echo "WARN job $jid log idle >30 min: $f"
    fi
  done
}

archive_old_logs() {
  find "$LOGS/jobs" -maxdepth 1 -name '*.log' -mtime +14 -exec mv {} "$LOGS/jobs/archive/" \; 2>/dev/null
}

ensure_session
check_heartbeat
check_gpus
check_job_logs
archive_old_logs
echo "watchdog tick done"
