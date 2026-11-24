#!/usr/bin/env python3
"""
RPi5 -> External HDD (EHDD) 1-Screen App TUI Backup Engine
Target: /mnt/ehdd/RPI5 (Windows NTFS H:\\RPI5)
"""

import sys
import os
import time
import subprocess
import shutil
import re
import signal

# Ensure UTF-8 output
sys.stdout.reconfigure(encoding='utf-8')

# ANSI Color & Formatting Constants
BOLD = "\033[1m"
DIM = "\033[2m"
GREEN = "\033[0;32m"
YELLOW = "\033[1;33m"
RED = "\033[0;31m"
BLUE = "\033[0;34m"
CYAN = "\033[0;36m"
MAGENTA = "\033[0;35m"
WHITE = "\033[1;37m"
NC = "\033[0m"
HIDE_CURSOR = "\033[?25l"
SHOW_CURSOR = "\033[?25h"
CLEAR_SCREEN = "\033[2J\033[H"
CURSOR_HOME = "\033[H"

MOUNT_POINT = "/mnt/ehdd"
TARGET_ROOT = "/mnt/ehdd/RPI5"
LOG_DIR = os.path.join(TARGET_ROOT, "logs")
REPORT_DIR = os.path.join(TARGET_ROOT, "reports")
LOCK_FILE = "/tmp/ehdd_backup.lock"
TIMESTAMP = time.strftime("%Y%m%d_%H%M%S")
DATE_HUMAN = time.strftime("%Y-%m-%d %H:%M:%S")

LOG_FILE = os.path.join(LOG_DIR, f"backup_{TIMESTAMP}.log")
REPORT_FILE = os.path.join(REPORT_DIR, f"backup_report_{TIMESTAMP}.md")

# Default Manifest Jobs
JOBS = [
    {
        "id": "photos",
        "name": "Photo & Video Archive",
        "src": "/mnt/usb/data",
        "dest": os.path.join(TARGET_ROOT, "data"),
        "sudo": False,
        "extra": [],
        "est_size": "150 GB",
        "status": "PENDING",
        "duration": "--",
        "files_xfr": "0",
        "bytes_xfr": "0 B",
    },
    {
        "id": "immich",
        "name": "Immich Photo Uploads",
        "src": "/mnt/usb/immich/upload",
        "dest": os.path.join(TARGET_ROOT, "immich_photos"),
        "sudo": False,
        "extra": [],
        "est_size": "15 GB",
        "status": "PENDING",
        "duration": "--",
        "files_xfr": "0",
        "bytes_xfr": "0 B",
    },
    {
        "id": "dad",
        "name": "Personal Backups - Dad",
        "src": "/mnt/usb/Dad",
        "dest": os.path.join(TARGET_ROOT, "Dad"),
        "sudo": False,
        "extra": [],
        "est_size": "23 GB",
        "status": "PENDING",
        "duration": "--",
        "files_xfr": "0",
        "bytes_xfr": "0 B",
    },
    {
        "id": "rahul",
        "name": "Personal Backups - Rahul",
        "src": "/mnt/usb/Rahul",
        "dest": os.path.join(TARGET_ROOT, "Rahul"),
        "sudo": False,
        "extra": [],
        "est_size": "23 GB",
        "status": "PENDING",
        "duration": "--",
        "files_xfr": "0",
        "bytes_xfr": "0 B",
    },
    {
        "id": "music",
        "name": "Music Archive",
        "src": "/mnt/usb/music",
        "dest": os.path.join(TARGET_ROOT, "music"),
        "sudo": False,
        "extra": [],
        "est_size": "8.7 GB",
        "status": "PENDING",
        "duration": "--",
        "files_xfr": "0",
        "bytes_xfr": "0 B",
    },
    {
        "id": "transmission",
        "name": "Transmission Downloads",
        "src": "/home/rahul/docker_data/transmission/download/complete",
        "dest": os.path.join(TARGET_ROOT, "transmission_downloads"),
        "sudo": False,
        "extra": [],
        "est_size": "24 GB",
        "status": "PENDING",
        "duration": "--",
        "files_xfr": "0",
        "bytes_xfr": "0 B",
    },
    {
        "id": "docker",
        "name": "Docker App Data & Configs",
        "src": "/home/rahul/docker_data",
        "dest": os.path.join(TARGET_ROOT, "docker_data"),
        "sudo": True,
        "extra": ["--exclude=/transmission/download"],
        "est_size": "1.5 GB",
        "status": "PENDING",
        "duration": "--",
        "files_xfr": "0",
        "bytes_xfr": "0 B",
    },
]

# Global State
current_job_idx = 0
current_file_name = "Initializing..."
current_speed_str = "-- MB/s"
current_eta_str = "--:--"
current_percent = 0.0
current_xfr_bytes = "0 B"
active_process = None
sudo_process = None
last_render_time = 0.0


def cleanup_handler(signum=None, frame=None):
    sys.stdout.write(SHOW_CURSOR)
    sys.stdout.flush()
    if active_process and active_process.poll() is None:
        try:
            active_process.terminate()
        except Exception:
            pass
    if sudo_process and sudo_process.poll() is None:
        try:
            sudo_process.terminate()
        except Exception:
            pass
    if os.path.exists(LOCK_FILE):
        try:
            os.remove(LOCK_FILE)
        except Exception:
            pass
    if signum:
        print(f"\n{YELLOW}[ABORT] Backup cancelled by user. Cleaned up safely.{NC}")
        sys.exit(130)


signal.signal(signal.SIGINT, cleanup_handler)
signal.signal(signal.SIGTERM, cleanup_handler)


def format_duration(seconds):
    m = int(seconds // 60)
    s = int(seconds % 60)
    return f"{m}m {s:02d}s"


def get_terminal_width():
    cols, _ = shutil.get_terminal_size((80, 24))
    return max(cols, 80)


def truncate_path(path, max_len):
    if len(path) <= max_len:
        return path
    half = max(5, (max_len - 5) // 2)
    return path[:half] + "..." + path[-half:]


def get_storage_info():
    try:
        st = os.statvfs(MOUNT_POINT)
        total = st.f_blocks * st.f_frsize
        free = st.f_bavail * st.f_frsize
        used = total - free
        used_pct = int((used / total) * 100) if total > 0 else 0

        def human(b):
            for u in ['B', 'KB', 'MB', 'GB', 'TB']:
                if b < 1024:
                    return f"{b:.1f} {u}"
                b /= 1024
            return f"{b:.1f} PB"

        return f"Total: {human(total)} | Used: {human(used)} ({used_pct}%) | Free: {human(free)}"
    except Exception:
        return "Storage metrics unavailable"


def render_tui(mode_label, force=False):
    global last_render_time
    now = time.time()
    if not force and (now - last_render_time < 0.08):
        return
    last_render_time = now

    cols = get_terminal_width()
    lines = []
    lines.append(f"{BOLD}{BLUE}┌" + "─" * (cols - 2) + f"┐{NC}")
    lines.append(f"{BOLD}{BLUE}│{NC}  {BOLD}{WHITE}🚀 RASPBERRY PI 5 — EXTERNAL HDD BACKUP MANAGER{NC}" + " " * max(0, cols - 51) + f"{BOLD}{BLUE}│{NC}")
    lines.append(f"{BOLD}{BLUE}│{NC}  {DIM}Host: rahul@192.168.1.24 | Target: /mnt/ehdd/RPI5 | Mode: {mode_label}{NC}" + " " * max(0, cols - 70 - len(mode_label)) + f"{BOLD}{BLUE}│{NC}")
    lines.append(f"{BOLD}{BLUE}├" + "─" * (cols - 2) + f"┤{NC}")

    # Dataset Progress Matrix
    lines.append(f"{BOLD}{BLUE}│{NC}  {BOLD}{CYAN}DATASET PROGRESS ({min(current_job_idx + 1, len(JOBS))}/{len(JOBS)}){NC}" + " " * max(0, cols - 27) + f"{BOLD}{BLUE}│{NC}")

    for idx, j in enumerate(JOBS):
        status_col = NC
        icon = "[ ]"
        st = j["status"]
        if st == "SUCCESS":
            icon = f"{GREEN}[✓]{NC}"
            status_col = GREEN
        elif st == "SYNCING...":
            icon = f"{CYAN}[▶]{NC}"
            status_col = CYAN
        elif st == "WARNING":
            icon = f"{YELLOW}[⚠]{NC}"
            status_col = YELLOW
        elif st == "SKIPPED":
            icon = f"{YELLOW}[-]{NC}"
            status_col = YELLOW
        elif st.startswith("FAILED"):
            icon = f"{RED}[✗]{NC}"
            status_col = RED

        name_str = f"{idx+1}. {j['name']}"
        row = f"  {icon} {name_str:<32} {j['est_size']:<9} {j['bytes_xfr']:<12} {j['duration']:<9} {status_col}{st:<12}{NC}"
        raw_len = 2 + 3 + 1 + 32 + 1 + 9 + 1 + 12 + 1 + 9 + 1 + 12
        pad = max(0, cols - 2 - raw_len)
        lines.append(f"{BOLD}{BLUE}│{NC}{row}" + " " * pad + f"{BOLD}{BLUE}│{NC}")

    lines.append(f"{BOLD}{BLUE}├" + "─" * (cols - 2) + f"┤{NC}")

    # Current Activity Panel
    active_job = JOBS[current_job_idx] if current_job_idx < len(JOBS) else JOBS[-1]
    lines.append(f"{BOLD}{BLUE}│{NC}  {BOLD}{MAGENTA}CURRENT ACTIVITY{NC}" + " " * max(0, cols - 20) + f"{BOLD}{BLUE}│{NC}")

    job_line = f"  Job  : [{min(current_job_idx + 1, len(JOBS))}/{len(JOBS)}] {active_job['name']}"
    lines.append(f"{BOLD}{BLUE}│{NC}{job_line:<{cols-2}}{BOLD}{BLUE}│{NC}")

    file_display = truncate_path(current_file_name, cols - 12)
    file_line = f"  File : {file_display}"
    lines.append(f"{BOLD}{BLUE}│{NC}{file_line:<{cols-2}}{BOLD}{BLUE}│{NC}")

    stats_line = f"  Speed: {current_speed_str} | Synced: {current_xfr_bytes} | ETA: {current_eta_str}"
    lines.append(f"{BOLD}{BLUE}│{NC}{stats_line:<{cols-2}}{BOLD}{BLUE}│{NC}")

    # Visual Progress Bar
    bar_width = max(10, cols - 16)
    filled = int(bar_width * (min(100.0, current_percent) / 100.0))
    bar = "█" * filled + "░" * (bar_width - filled)
    pbar_line = f"  [{bar}] {current_percent:5.1f}%"
    lines.append(f"{BOLD}{BLUE}│{NC}{pbar_line:<{cols-2}}{BOLD}{BLUE}│{NC}")

    lines.append(f"{BOLD}{BLUE}├" + "─" * (cols - 2) + f"┤{NC}")

    # System Status Footer
    storage_str = f"  STORAGE: {get_storage_info()}"
    lines.append(f"{BOLD}{BLUE}│{NC}{storage_str:<{cols-2}}{BOLD}{BLUE}│{NC}")

    ctrl_line = "  Driver: ntfs3 (Kernel) | USB: 5000M (UAS)  |  Press Ctrl+C to stop"
    lines.append(f"{BOLD}{BLUE}│{NC}{ctrl_line:<{cols-2}}{BOLD}{BLUE}│{NC}")

    lines.append(f"{BOLD}{BLUE}└" + "─" * (cols - 2) + f"┘{NC}")

    sys.stdout.write(CURSOR_HOME + "\n".join(lines) + "\n")
    sys.stdout.flush()


def run_job(job, mode_label, dry_run=False, delete_mode=False, checksum_mode=False, bwlimit=""):
    global active_process, current_file_name, current_speed_str
    global current_eta_str, current_percent, current_xfr_bytes

    if not os.path.exists(job["src"]):
        job["status"] = "SKIPPED"
        job["duration"] = "0s"
        return

    os.makedirs(job["dest"], exist_ok=True)
    job["status"] = "SYNCING..."
    current_percent = 0.0
    current_xfr_bytes = "0 B"
    current_speed_str = "-- MB/s"
    current_eta_str = "--:--"
    start_t = time.time()

    cmd = [
        "rsync",
        "-rltvhPW",
        "--no-owner",
        "--no-group",
        "--no-perms",
        "--modify-window=1",
        "--stats",
        "--info=progress2",
        "--exclude=*.sock",
        "--exclude=*.ctl",
    ]

    if dry_run:
        cmd.append("--dry-run")
    if delete_mode:
        cmd.append("--delete")
    if checksum_mode:
        cmd.append("--checksum")
    if bwlimit:
        cmd.append(f"--bwlimit={bwlimit}")
    if job["extra"]:
        cmd.extend(job["extra"])

    cmd.append(job["src"].rstrip("/") + "/")
    cmd.append(job["dest"].rstrip("/") + "/")

    runner = []
    if shutil.which("ionice"):
        runner.extend(["ionice", "-c2", "-n0"])

    full_cmd = []
    if not dry_run and job["sudo"] and os.geteuid() != 0:
        full_cmd.extend(["sudo"])
    full_cmd.extend(runner)
    full_cmd.extend(cmd)

    render_tui(mode_label, force=True)

    active_process = subprocess.Popen(
        full_cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )

    stats_buf = []
    prog_re = re.compile(r'(\d+(?:\.\d+)?[KMGT]?B?)\s+(\d+)%\s+(\d+(?:\.\d+)?[KMGT]?B/s)\s+(\d+:\d+(?::\d+)?)')
    raw_log = open(LOG_FILE, "a", encoding="utf-8")

    for line in active_process.stdout:
        # Test the pre-strip line: rsync progress2 bursts carry bare \r updates
        raw_line = line.rstrip("\n")
        clean = line.strip()
        if not clean:
            continue

        if "\r" not in raw_line and "to-chk=" not in raw_line:
            raw_log.write(raw_line + "\n")

        stats_buf.append(clean)

        m = prog_re.search(clean)
        if m:
            current_xfr_bytes = m.group(1)
            current_percent = float(m.group(2))
            current_speed_str = m.group(3)
            current_eta_str = m.group(4)
        else:
            if not clean.startswith("sending incremental") and not clean.startswith("Number of") and not clean.startswith("Total "):
                current_file_name = clean

        render_tui(mode_label)

    active_process.wait()
    ret = active_process.returncode
    raw_log.close()

    elapsed = time.time() - start_t
    job["duration"] = format_duration(elapsed)

    full_stats = "\n".join(stats_buf)
    m_files = re.search(r"Number of regular files transferred:\s*([\d,]+)", full_stats)
    if m_files:
        job["files_xfr"] = m_files.group(1).replace(",", "")

    m_bytes = re.search(r"Total transferred file size:\s*([^\n]+)", full_stats)
    if m_bytes:
        job["bytes_xfr"] = m_bytes.group(1).strip()

    if ret == 0:
        job["status"] = "SUCCESS"
    elif ret == 24:
        job["status"] = "WARNING"
    else:
        job["status"] = f"FAILED ({ret})"

    render_tui(mode_label, force=True)


def generate_reports(total_elapsed, mode_label):
    os.makedirs(REPORT_DIR, exist_ok=True)
    storage_after = get_storage_info()

    with open(REPORT_FILE, "w", encoding="utf-8") as f:
        f.write("# RPI5 External HDD Backup Report\n\n")
        f.write(f"- **Date / Time**: {DATE_HUMAN}\n")
        f.write(f"- **Target Location**: `{TARGET_ROOT}` (Windows NTFS `H:\\RPI5`)\n")
        f.write(f"- **Execution Mode**: {mode_label}\n")
        f.write(f"- **Total Duration**: {format_duration(total_elapsed)}\n")
        f.write(f"- **Target Storage**: `{storage_after}`\n\n")
        f.write("## Dataset Breakdown\n\n")
        f.write("| # | Dataset / Job | Status | Files Transferred | Data Synced | Duration |\n")
        f.write("|---|---------------|--------|-------------------|-------------|----------|\n")
        for i, j in enumerate(JOBS):
            f.write(f"| {i+1} | {j['name']} | {j['status']} | {j['files_xfr']} | {j['bytes_xfr']} | {j['duration']} |\n")
        f.write("\n---\n*Generated automatically by `ehdd_backup.sh`*\n")


def main():
    global current_job_idx, sudo_process, JOBS

    dry_run = "--dry-run" in sys.argv or "-n" in sys.argv
    restore_mode = "--restore" in sys.argv or "-r" in sys.argv
    delete_mode = "--delete" in sys.argv
    checksum_mode = "--checksum" in sys.argv or "-c" in sys.argv
    single_job = None
    bwlimit = ""

    for idx, arg in enumerate(sys.argv):
        if arg in ["-j", "--job"] and idx + 1 < len(sys.argv):
            single_job = sys.argv[idx + 1]
        elif arg in ["-b", "--bwlimit"] and idx + 1 < len(sys.argv):
            bwlimit = sys.argv[idx + 1]
        elif arg in ["-a", "--add"] and idx + 1 < len(sys.argv):
            custom_src = sys.argv[idx + 1]
            custom_dest = sys.argv[idx + 2] if idx + 2 < len(sys.argv) and not sys.argv[idx + 2].startswith("-") else os.path.basename(custom_src)
            JOBS = [{
                "id": "custom",
                "name": f"Custom: {os.path.basename(custom_src)}",
                "src": custom_src,
                "dest": os.path.join(TARGET_ROOT, custom_dest),
                "sudo": False,
                "extra": [],
                "est_size": "Ad-Hoc",
                "status": "PENDING",
                "duration": "--",
                "files_xfr": "0",
                "bytes_xfr": "0 B",
            }]

    if single_job and single_job != "all":
        matched = [j for j in JOBS if j["id"] == single_job]
        if matched:
            JOBS = matched
        else:
            print(f"Unknown job: {single_job}")
            sys.exit(1)

    if restore_mode:
        for j in JOBS:
            orig_src = j["src"]
            orig_dest = j["dest"]
            j["src"] = orig_dest
            j["dest"] = orig_src
            j["name"] = f"RESTORE: {j['name']}"
            if "/docker_data" in j["dest"]:
                j["sudo"] = True

    if not os.path.ismount(MOUNT_POINT):
        print(f"{RED}[ERROR] External drive not mounted at {MOUNT_POINT}. Aborting.{NC}")
        sys.exit(1)

    os.makedirs(LOG_DIR, exist_ok=True)
    os.makedirs(REPORT_DIR, exist_ok=True)

    if restore_mode:
        mode_label = "DRY-RUN (Restore)" if dry_run else "LIVE RESTORE (EHDD -> RPi5)"
    else:
        mode_label = "DRY-RUN (Simulation)" if dry_run else "LIVE INCREMENTAL"

    has_sudo_job = any(j["sudo"] for j in JOBS)
    if not dry_run and has_sudo_job and os.geteuid() != 0:
        try:
            subprocess.run(["sudo", "-v"], check=True)
            sudo_process = subprocess.Popen(["bash", "-c", "while true; do sudo -v; sleep 50; done"])
        except Exception:
            pass

    sys.stdout.write(HIDE_CURSOR + CLEAR_SCREEN)
    sys.stdout.flush()

    start_total = time.time()

    try:
        for idx, j in enumerate(JOBS):
            current_job_idx = idx
            run_job(j, mode_label, dry_run, delete_mode, checksum_mode, bwlimit)
    finally:
        # Never leave the sudo keepalive loop running after the tool exits
        if sudo_process is not None and sudo_process.poll() is None:
            sudo_process.terminate()
            try:
                sudo_process.wait(timeout=5)
            except Exception:
                sudo_process.kill()
            sudo_process = None

    total_elapsed = time.time() - start_total
    generate_reports(total_elapsed, mode_label)

    sys.stdout.write(SHOW_CURSOR)
    sys.stdout.flush()

    print("\n" + "=" * 80)
    print(f" {BOLD}{GREEN}✓ BACKUP EXECUTION COMPLETE{NC}")
    print("=" * 80)
    print(f" Total Duration : {format_duration(total_elapsed)}")
    print(f" Storage Status : {get_storage_info()}")
    print(f" Audit Report   : {CYAN}{REPORT_FILE}{NC}")
    print(f" Technical Log  : {CYAN}{LOG_FILE}{NC}")
    print("=" * 80 + "\n")


if __name__ == "__main__":
    main()
