#!/usr/bin/env python3
"""I17 conformal-recovery — single-host GPU job launcher.

Lives at /root/i17_conformal/scripts/i17_launcher.py on the server.
Run inside tmux session `i17` window `launcher`. The watchdog restarts it if it dies.

Contract:
  - Reads pending jobs from {STATE}/queue.jsonl (append-only).
  - For each job: assigns a free GPU index, exports CUDA_VISIBLE_DEVICES,
    spawns the job's command as a subprocess with stdout/stderr -> {LOGS}/{job_id}.log,
    records the run in {STATE}/active_jobs.json.
  - On completion, appends to {STATE}/completed.jsonl and clears the GPU.
  - Persists everything to disk so a restart resumes correctly.
  - Refuses to launch a job whose `gpu_index` is already busy (the queue is authoritative
    about pinning; jobs may set "gpu_index": "any" to ask the launcher to pick).

queue.jsonl row example:
  {"id":"w1_smolvla_libero10_s42","cmd":"bash scripts/train.sh configs/...","gpu_index":0,
   "cwd":"/root/i17_conformal/FluxVLA","env":{"WANDB_RUN_NAME":"..."},
   "max_retries":2,"wave":"wave1"}
"""

from __future__ import annotations
import fcntl, json, os, signal, subprocess, sys, time
from datetime import datetime, timezone
from pathlib import Path

PROJECT = Path(os.environ.get("I17_ROOT", "/root/i17_conformal"))
STATE = PROJECT / "state"
LOGS = PROJECT / "logs" / "jobs"
QUEUE = STATE / "queue.jsonl"
ACTIVE = STATE / "active_jobs.json"
COMPLETED = STATE / "completed.jsonl"
WAVE_STATUS = STATE / "wave_status.md"
LAUNCHER_HB = STATE / "launcher_heartbeat"
NUM_GPUS = int(os.environ.get("I17_NUM_GPUS", "4"))
POLL_SECONDS = 20

for d in [STATE, LOGS]:
    d.mkdir(parents=True, exist_ok=True)


def now() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def heartbeat() -> None:
    LAUNCHER_HB.write_text(now())


def _read_jsonl(path: Path) -> list[dict]:
    if not path.exists():
        return []
    out = []
    with path.open() as f:
        for line in f:
            line = line.strip()
            if line:
                out.append(json.loads(line))
    return out


def load_active() -> dict[str, dict]:
    if not ACTIVE.exists():
        return {}
    return json.loads(ACTIVE.read_text())


def save_active(active: dict[str, dict]) -> None:
    tmp = ACTIVE.with_suffix(".tmp")
    tmp.write_text(json.dumps(active, indent=2))
    tmp.replace(ACTIVE)


def append_completed(record: dict) -> None:
    with COMPLETED.open("a") as f:
        f.write(json.dumps(record) + "\n")


def write_wave_status(active: dict[str, dict], queue: list[dict], completed_count: int) -> None:
    lines = [
        f"# I17 wave status — {now()}",
        "",
        f"- launcher heartbeat: {LAUNCHER_HB.read_text() if LAUNCHER_HB.exists() else 'unknown'}",
        f"- GPUs available: {NUM_GPUS}",
        f"- active jobs: {len(active)} / queue pending: {len(queue)} / completed: {completed_count}",
        "",
        "## Active jobs",
        "",
        "| id | gpu | started | wave | log |",
        "|---|---|---|---|---|",
    ]
    for jid, rec in active.items():
        lines.append(
            f"| `{jid}` | {rec['gpu_index']} | {rec['started_at']} | {rec.get('wave','?')} | `{rec['log']}` |"
        )
    lines += ["", "## Next 5 in queue", "", "| id | gpu | wave |", "|---|---|---|"]
    for j in queue[:5]:
        lines.append(f"| `{j['id']}` | {j.get('gpu_index','any')} | {j.get('wave','?')} |")
    WAVE_STATUS.write_text("\n".join(lines) + "\n")


def consume_queue() -> list[dict]:
    """Atomically read pending jobs and drain those that are already active or completed."""
    rows = _read_jsonl(QUEUE)
    active = load_active()
    completed_ids = {r["id"] for r in _read_jsonl(COMPLETED)}
    return [r for r in rows if r["id"] not in active and r["id"] not in completed_ids]


def claim_gpu(active: dict[str, dict], requested: int | str) -> int | None:
    busy = {rec["gpu_index"] for rec in active.values()}
    if isinstance(requested, int):
        return requested if requested not in busy else None
    # "any"
    for g in range(NUM_GPUS):
        if g not in busy:
            return g
    return None


def spawn_job(job: dict, gpu: int) -> dict:
    log_path = LOGS / f"{job['id']}.log"
    env = os.environ.copy()
    env["CUDA_VISIBLE_DEVICES"] = str(gpu)
    env["I17_JOB_ID"] = job["id"]
    env["I17_GPU"] = str(gpu)
    for k, v in (job.get("env") or {}).items():
        env[k] = str(v)
    cwd = job.get("cwd", "/root/i17_conformal/FluxVLA")
    log_f = open(log_path, "ab", buffering=0)
    log_f.write(f"\n===== launch {now()} | gpu={gpu} | id={job['id']} =====\n".encode())
    log_f.write(f"cmd: {job['cmd']}\n".encode())
    # Use shell -lc so we get the user's conda profile.d wiring.
    proc = subprocess.Popen(
        ["bash", "-lc", f"set -e; source ~/miniconda3/etc/profile.d/conda.sh; "
                        f"conda activate i17_conformal; cd {cwd}; {job['cmd']}"],
        stdout=log_f, stderr=subprocess.STDOUT, env=env, start_new_session=True,
    )
    return {
        "id": job["id"],
        "pid": proc.pid,
        "gpu_index": gpu,
        "started_at": now(),
        "wave": job.get("wave", "unknown"),
        "log": str(log_path),
        "cmd": job["cmd"],
        "cwd": cwd,
        "retries_left": int(job.get("max_retries", 2)),
        "original_job": job,
    }


def _proc_state(pid: int) -> str | None:
    """Return the kernel State letter (R/S/D/Z/T/...) for pid, or None if /proc/<pid> is gone.

    `os.kill(pid, 0)` returns success for zombies (the PID still exists in the table
    until reaped), so we must inspect /proc/<pid>/status to distinguish alive from
    zombie. See: 2026-05-25 incident where w1_smolvla_libero_spatial_s42 finished
    cleanly but the wrapper bash stayed `<defunct>` and the launcher reported the
    job as still active for 2h+.
    """
    try:
        with open(f"/proc/{pid}/status") as f:
            for line in f:
                if line.startswith("State:"):
                    parts = line.split()
                    return parts[1] if len(parts) > 1 else None
    except FileNotFoundError:
        return None
    return None


def _is_live_or_reap(pid: int) -> bool:
    """True iff pid exists AND is not a zombie. Opportunistically reap zombies we own."""
    state = _proc_state(pid)
    if state is None:
        return False
    if state == "Z":
        try:
            os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            pass
        return False
    return True


def check_running(active: dict[str, dict]) -> tuple[dict[str, dict], list[dict]]:
    """Return (still_running, finished_records)."""
    still, done = {}, []
    for jid, rec in active.items():
        if _is_live_or_reap(rec["pid"]):
            still[jid] = rec
            continue
        # finished — read exit by checking last lines of log
        log = Path(rec["log"])
        tail = b""
        if log.exists():
            with log.open("rb") as f:
                f.seek(max(0, log.stat().st_size - 4096))
                tail = f.read()
        # naive success check: look for known success markers — else mark as crashed
        # NOTE: markers are matched case-sensitively against the last 4 KiB of log.
        ok_markers = (
            b"Saved safetensors",
            b"saved final",
            b"Training completed",
            b"All steps finished",
            b"FINAL_SUCCESS",
        )
        crash_markers = (b"CUDA out of memory", b"Traceback", b"RuntimeError", b"OutOfMemoryError")
        status = "completed"
        if any(m in tail for m in crash_markers) and not any(m in tail for m in ok_markers):
            status = "crashed"
        done.append({**rec, "ended_at": now(), "status": status})
    return still, done


def maybe_requeue(rec: dict) -> dict | None:
    """If a crashed job has retries left, return a fresh queue entry; else None."""
    if rec["status"] != "crashed":
        return None
    job = rec["original_job"]
    retries_left = rec.get("retries_left", 0) - 1
    if retries_left < 0:
        return None
    new = dict(job)
    new["id"] = job["id"] + f"_retry{int(job.get('max_retries',2)) - retries_left}"
    new["max_retries"] = retries_left
    return new


def append_queue(jobs: list[dict]) -> None:
    with QUEUE.open("a") as f:
        for j in jobs:
            f.write(json.dumps(j) + "\n")


def loop() -> None:
    print(f"[{now()}] i17 launcher up; NUM_GPUS={NUM_GPUS} state={STATE}", flush=True)
    while True:
        heartbeat()
        active = load_active()

        # 1) reap finished
        active, done = check_running(active)
        for rec in done:
            append_completed(rec)
            print(f"[{now()}] finished id={rec['id']} status={rec['status']} gpu={rec['gpu_index']}", flush=True)
            requeue = maybe_requeue(rec)
            if requeue is not None:
                append_queue([requeue])
                print(f"[{now()}] requeued id={requeue['id']} (was {rec['id']})", flush=True)

        # 2) launch new
        queue = consume_queue()
        for job in queue:
            gpu = claim_gpu(active, job.get("gpu_index", "any"))
            if gpu is None:
                continue
            rec = spawn_job(job, gpu)
            active[rec["id"]] = rec
            print(f"[{now()}] launched id={rec['id']} pid={rec['pid']} gpu={gpu}", flush=True)

        save_active(active)
        write_wave_status(active, [j for j in consume_queue() if j["id"] not in active], sum(1 for _ in COMPLETED.open()) if COMPLETED.exists() else 0)
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    try:
        loop()
    except KeyboardInterrupt:
        print(f"[{now()}] launcher shutting down on KeyboardInterrupt", flush=True)
