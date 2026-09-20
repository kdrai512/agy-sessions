#!/usr/bin/env python3
"""Antigravity Session Manager CLI (agy-sessions / agys).

Manage, inspect, search, and resume Google Antigravity (agy) conversation sessions.
Supports Safe, Unsafe, and Sandbox modes, automatic workspace navigation,
real-time process/lock tracking, and rich fzf interactive browsing.
"""

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import glob
import json
import os
import re
import shutil
import signal
import sqlite3
import subprocess
import sys
import time
import urllib.parse
from dataclasses import dataclass
from pathlib import Path
from typing import Any, List, Optional, Set, Tuple

# ANSI Colors & Styling
BOLD = "\033[1m"
DIM = "\033[2m"
ITALIC = "\033[3m"
RESET = "\033[0m"

RED = "\033[31m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
BLUE = "\033[34m"
MAGENTA = "\033[35m"
CYAN = "\033[36m"
WHITE = "\033[37m"

BG_DARK = "\033[48;5;236m"


def get_base_dir() -> Path:
    """Return root directory for Antigravity CLI data."""
    env_dir = os.environ.get("ANTIGRAVITY_DATA_DIR")
    if env_dir:
        return Path(os.path.expanduser(env_dir)).resolve()
    return Path(os.path.expanduser("~/.gemini/antigravity-cli")).resolve()


def sanitize_text(val: Any, max_len: int = 300) -> str:
    """Sanitize arbitrary strings to safe single-line plain text."""
    if val is None:
        return ""
    text = str(val)
    text = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]", "", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text[:max_len]


def relative_time(target_dt: Optional[dt.datetime]) -> str:
    """Format datetime into human-friendly relative time (e.g. '15m ago', '2h ago', '3d ago')."""
    if not target_dt or target_dt.year < 2020:
        return "never"
    now = dt.datetime.now(dt.timezone.utc)
    if target_dt.tzinfo is None:
        target_dt = target_dt.replace(tzinfo=dt.timezone.utc)
    diff = now - target_dt
    secs = int(diff.total_seconds())

    if secs <= 0:
        return "just now"
    if secs < 60:
        return f"{secs}s ago"
    mins = secs // 60
    if mins < 60:
        return f"{mins}m ago"
    hours = mins // 60
    if hours < 24:
        return f"{hours}h ago"
    days = hours // 24
    if days < 30:
        return f"{days}d ago"
    months = days // 30
    if months < 12:
        return f"{months}mo ago"
    years = days // 365
    return f"{years}y ago"


def parse_timestamp(val: Any) -> Optional[dt.datetime]:
    """Parse various timestamp formats (ISO string, epoch seconds, epoch ms)."""
    if not val:
        return None
    if isinstance(val, (int, float)):
        try:
            secs = float(val) / 1000.0 if float(val) > 10_000_000_000 else float(val)
            return dt.datetime.fromtimestamp(secs, tz=dt.timezone.utc)
        except Exception:
            return None
    raw = str(val).strip()
    if not raw:
        return None
    try:
        # Standard ISO format with Z or offset
        clean = raw.replace("Z", "+00:00")
        parsed = dt.datetime.fromisoformat(clean)
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=dt.timezone.utc)
        return parsed
    except Exception:
        pass
    try:
        # Format without microseconds or fractional seconds
        clean = raw.split(".")[0]
        parsed = dt.datetime.fromisoformat(clean)
        return parsed.replace(tzinfo=dt.timezone.utc)
    except Exception:
        return None


def ask_input(prompt_text: str) -> str:
    """Read input from user safely, falling back to /dev/tty if stdin was redirected."""
    try:
        if sys.stdin.isatty():
            return input(prompt_text)
        with open("/dev/tty", "r") as tty_in:
            sys.stdout.write(prompt_text)
            sys.stdout.flush()
            line = tty_in.readline()
            return line.strip() if line else ""
    except Exception:
        try:
            return input(prompt_text)
        except Exception:
            return ""


@dataclass
class Session:
    conversation_id: str
    title: str
    preview: str
    step_count: int
    last_modified_dt: Optional[dt.datetime]
    workspace_path: str
    parent_conversation_id: str
    is_active: bool = False
    pid: Optional[int] = None

    @property
    def short_id(self) -> str:
        return self.conversation_id[:8]

    @property
    def display_title(self) -> str:
        t = self.title.strip()
        if t:
            return t
        p = self.preview.strip()
        if p:
            return p[:60]
        return f"Session {self.short_id}"

    @property
    def display_workspace(self) -> str:
        if not self.workspace_path:
            return "~"
        home = str(Path.home())
        if self.workspace_path.startswith(home):
            return "~" + self.workspace_path[len(home):]
        return self.workspace_path


class SessionStore:
    def __init__(self, base_dir: Optional[Path] = None):
        self.base_dir = base_dir or get_base_dir()
        self.db_path = self.base_dir / "conversation_summaries.db"
        self.presence_dir = self.base_dir / "presence"
        self.conversations_dir = self.base_dir / "conversations"
        self.brain_dir = self.base_dir / "brain"

    def get_active_sessions(self) -> dict[str, int]:
        """Return a mapping of active conversation_id -> PID holding its presence lock."""
        active_map: dict[str, int] = {}
        if not self.presence_dir.exists():
            return active_map

        # Map lock paths to conversation IDs
        lock_map: dict[str, str] = {}
        for p in self.presence_dir.glob("*.lock"):
            cid = p.stem
            lock_map[str(p)] = cid

        # 1. Test presence files with non-blocking flock test
        locked_cids: Set[str] = set()
        for p in self.presence_dir.glob("*.lock"):
            try:
                with open(p, "rb") as f:
                    try:
                        fcntl.flock(f.fileno(), fcntl.LOCK_SH | fcntl.LOCK_NB)
                        fcntl.flock(f.fileno(), fcntl.LOCK_UN)
                    except (BlockingIOError, PermissionError, OSError):
                        locked_cids.add(p.stem)
            except Exception:
                pass

        # 2. Inspect /proc/*/fd to identify exact holding PIDs
        for fd_path in glob.glob("/proc/[0-9]*/fd/*"):
            try:
                target = os.readlink(fd_path)
                for lock_path, cid in lock_map.items():
                    if lock_path in target:
                        pid = int(fd_path.split("/")[2])
                        if pid != os.getpid():
                            active_map[cid] = pid
                            break
            except Exception:
                continue

        # If locked via flock but PID not found in /proc (permissions/container), still record
        for cid in locked_cids:
            if cid not in active_map:
                active_map[cid] = 0

        return active_map

    def list_sessions(self) -> List[Session]:
        """Load all sessions sorted by last_modified_time descending."""
        sessions: dict[str, Session] = {}
        active_map = self.get_active_sessions()

        # (a) Read SQLite conversation_summaries.db if present
        if self.db_path.exists():
            try:
                conn = sqlite3.connect(f"file:{self.db_path}?mode=ro", uri=True, timeout=2.0)
                cur = conn.cursor()
                cur.execute("""
                    SELECT conversation_id, title, preview, step_count, last_modified_time, workspace_uris, parent_conversation_id
                    FROM conversation_summaries
                    ORDER BY last_modified_time DESC
                """)
                for row in cur.fetchall():
                    cid, title, prev, steps, mtime_str, w_uris_raw, parent_id = row
                    cid = str(cid or "").strip()
                    if not cid:
                        continue

                    # Decode workspace URIs
                    ws_path = ""
                    if w_uris_raw:
                        try:
                            uris = json.loads(w_uris_raw)
                            if isinstance(uris, list) and uris:
                                raw_u = uris[0]
                                if raw_u.startswith("file://"):
                                    ws_path = urllib.parse.unquote(raw_u[7:])
                                else:
                                    ws_path = raw_u
                        except Exception:
                            pass

                    m_dt = parse_timestamp(mtime_str)
                    sessions[cid] = Session(
                        conversation_id=cid,
                        title=sanitize_text(title, 200),
                        preview=sanitize_text(prev, 300),
                        step_count=int(steps or 0),
                        last_modified_dt=m_dt,
                        workspace_path=ws_path,
                        parent_conversation_id=str(parent_id or "").strip(),
                        is_active=(cid in active_map),
                        pid=active_map.get(cid),
                    )
                conn.close()
            except Exception as ex:
                pass

        # (b) Discover sessions in conversations/*.db not in summaries
        if self.conversations_dir.exists():
            for db_file in self.conversations_dir.glob("*.db"):
                cid = db_file.stem
                if cid not in sessions and len(cid) >= 8:
                    mtime = db_file.stat().st_mtime
                    m_dt = dt.datetime.fromtimestamp(mtime, tz=dt.timezone.utc)
                    step_count = 0
                    try:
                        conn = sqlite3.connect(f"file:{db_file}?mode=ro", uri=True, timeout=0.3)
                        cur = conn.cursor()
                        cur.execute("SELECT count(*) FROM steps")
                        row = cur.fetchone()
                        if row:
                            step_count = int(row[0] or 0)
                        conn.close()
                    except Exception:
                        pass

                    sessions[cid] = Session(
                        conversation_id=cid,
                        title=f"Session {cid[:8]}",
                        preview="Discovered from local database",
                        step_count=step_count,
                        last_modified_dt=m_dt,
                        workspace_path="",
                        parent_conversation_id="",
                        is_active=(cid in active_map),
                        pid=active_map.get(cid),
                    )

        # Sort: active sessions first, then most recently modified
        result = list(sessions.values())
        result.sort(
            key=lambda s: (
                1 if s.is_active else 0,
                s.last_modified_dt.timestamp() if s.last_modified_dt else 0,
            ),
            reverse=True,
        )
        return result

    def get_session(self, query: str) -> Optional[Session]:
        """Find a single session by 1-based index, short ID, full UUID, or title match."""
        sessions = self.list_sessions()
        q = query.strip()

        # 1. Match by numeric 1-based index
        if q.isdigit():
            idx = int(q)
            if 1 <= idx <= len(sessions):
                return sessions[idx - 1]

        # 2. Exact conversation_id match
        for s in sessions:
            if s.conversation_id.lower() == q.lower():
                return s

        # 3. Prefix match on conversation_id
        for s in sessions:
            if s.conversation_id.lower().startswith(q.lower()):
                return s

        # 4. Case-insensitive title match
        for s in sessions:
            if q.lower() in s.title.lower():
                return s

        return None

    def delete_session(self, session: Session, permanent: bool = False) -> bool:
        """Delete or archive a session's databases, transcripts, and metadata."""
        cid = session.conversation_id

        # 1. Kill active process first if running
        if session.is_active:
            self.kill_session(session)

        # 2. Delete from conversation_summaries.db
        if self.db_path.exists():
            try:
                conn = sqlite3.connect(self.db_path, timeout=3.0)
                cur = conn.cursor()
                cur.execute("DELETE FROM conversation_summaries WHERE conversation_id = ?", (cid,))
                conn.commit()
                conn.close()
            except Exception:
                pass

        # 3. Handle brain directory
        brain_sub = self.brain_dir / cid
        if brain_sub.exists():
            if permanent:
                shutil.rmtree(brain_sub, ignore_errors=True)
            else:
                archive_dir = self.base_dir / "archive"
                archive_dir.mkdir(parents=True, exist_ok=True)
                target = archive_dir / cid
                if target.exists():
                    shutil.rmtree(target, ignore_errors=True)
                shutil.move(str(brain_sub), str(target))

        # 4. Remove conversations/<id>.db*
        for pattern in [f"{cid}.db", f"{cid}.db-wal", f"{cid}.db-shm"]:
            p = self.conversations_dir / pattern
            if p.exists():
                try:
                    p.unlink(missing_ok=True)
                except Exception:
                    pass

        # 5. Remove presence lock
        lock_file = self.presence_dir / f"{cid}.lock"
        if lock_file.exists():
            try:
                lock_file.unlink(missing_ok=True)
            except Exception:
                pass

        return True

    def kill_session(self, session: Session) -> bool:
        """Terminate any running process holding the session lock."""
        cid = session.conversation_id
        active_map = self.get_active_sessions()
        pid = active_map.get(cid) or session.pid

        killed = False
        if pid and pid > 0:
            try:
                os.kill(pid, signal.SIGTERM)
                time.sleep(0.3)
                # Check if still alive, then SIGKILL
                try:
                    os.kill(pid, 0)
                    os.kill(pid, signal.SIGKILL)
                except OSError:
                    pass
                killed = True
            except ProcessLookupError:
                killed = True
            except Exception:
                pass

        # Clean presence lock file
        lock_file = self.presence_dir / f"{cid}.lock"
        if lock_file.exists():
            try:
                lock_file.unlink(missing_ok=True)
            except Exception:
                pass

        return killed


class TranscriptViewer:
    """Extract and format transcripts for live preview and full pager viewing."""

    @staticmethod
    def get_transcript_events(cid: str, base_dir: Optional[Path] = None) -> List[Tuple[str, str, str]]:
        """Return list of (source, type, content) events from transcript.jsonl."""
        b_dir = base_dir or get_base_dir()
        tpath = b_dir / "brain" / cid / ".system_generated" / "logs" / "transcript.jsonl"
        events: List[Tuple[str, str, str]] = []

        if not tpath.exists():
            return events

        try:
            with open(tpath, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        data = json.loads(line)
                        tp = data.get("type", "")
                        src = data.get("source", "")
                        content = data.get("content") or ""
                        tool_calls = data.get("tool_calls") or []

                        if tp == "USER_INPUT" and content:
                            cleaned = content.replace("<USER_REQUEST>", "").replace("</USER_REQUEST>", "")
                            cleaned = cleaned.split("<ADDITIONAL_METADATA>")[0].strip()
                            if cleaned:
                                events.append((src, "USER_INPUT", cleaned))
                        elif tp == "PLANNER_RESPONSE":
                            if content:
                                events.append((src, "PLANNER_RESPONSE", content.strip()))
                            elif tool_calls:
                                call_summaries = []
                                for tc in tool_calls:
                                    t_name = tc.get("name", "tool")
                                    args = tc.get("args") or {}
                                    summary = tc.get("toolSummary") or tc.get("toolAction")
                                    if summary:
                                        call_summaries.append(f"{t_name}: {summary}")
                                    elif "CommandLine" in args:
                                        call_summaries.append(f"run: {args['CommandLine'][:60]}")
                                    elif "TargetFile" in args or "AbsolutePath" in args:
                                        f_path = args.get("TargetFile") or args.get("AbsolutePath")
                                        call_summaries.append(f"{t_name}: {Path(f_path).name}")
                                    else:
                                        call_summaries.append(t_name)
                                if call_summaries:
                                    events.append((src, "TOOL_CALL", " | ".join(call_summaries)))
                    except Exception:
                        continue
        except Exception:
            pass

        return events

    @staticmethod
    def render_preview(session: Session, base_dir: Optional[Path] = None, max_turns: int = 10) -> str:
        """Render a rich, ANSI-styled preview for the fzf preview window."""
        status_tag = f"{GREEN}● ACTIVE{RESET} (PID {session.pid})" if session.is_active else f"{DIM}○ IDLE{RESET}"
        time_str = relative_time(session.last_modified_dt)
        full_time = session.last_modified_dt.astimezone().strftime("%Y-%m-%d %H:%M:%S %Z") if session.last_modified_dt else "N/A"

        lines = [
            f"{BOLD}{CYAN}═══════════════════════════════════════════════════════════════════{RESET}",
            f"{BOLD}{session.display_title}{RESET}",
            f"{BOLD}{CYAN}═══════════════════════════════════════════════════════════════════{RESET}",
            f"{DIM}Session ID :{RESET} {WHITE}{session.conversation_id}{RESET}",
            f"{DIM}Status     :{RESET} {status_tag}",
            f"{DIM}Workspace  :{RESET} {YELLOW}{session.display_workspace}{RESET}",
            f"{DIM}Turns/Steps:{RESET} {MAGENTA}{session.step_count} steps{RESET}",
            f"{DIM}Last Active:{RESET} {time_str} ({full_time})",
            "",
            f"{BOLD}{CYAN}Recent Conversation Turns:{RESET}",
            f"{DIM}───────────────────────────────────────────────────────────────────{RESET}",
        ]

        events = TranscriptViewer.get_transcript_events(session.conversation_id, base_dir)
        if not events:
            lines.append(f"{DIM}(No detailed transcript available){RESET}")
            if session.preview:
                lines.append(f"\n{session.preview}")
        else:
            recent_events = events[-max_turns:]
            for src, tp, content in recent_events:
                if tp == "USER_INPUT":
                    lines.append(f"\n{BOLD}{CYAN}👤 User:{RESET}")
                    # Indent and truncate if excessive
                    for cl in content.splitlines()[:6]:
                        lines.append(f"  {cl}")
                    if len(content.splitlines()) > 6:
                        lines.append(f"  {DIM}... (truncated){RESET}")
                elif tp == "PLANNER_RESPONSE":
                    lines.append(f"\n{BOLD}{GREEN}🤖 Antigravity:{RESET}")
                    resp_lines = content.splitlines()
                    for cl in resp_lines[:8]:
                        lines.append(f"  {cl}")
                    if len(resp_lines) > 8:
                        lines.append(f"  {DIM}... (truncated){RESET}")
                elif tp == "TOOL_CALL":
                    lines.append(f"  {DIM}🛠️  {content}{RESET}")

        return "\n".join(lines)

    @staticmethod
    def show_full_info(session: Session, base_dir: Optional[Path] = None) -> None:
        """Display full transcript using system pager or bat/less."""
        output = TranscriptViewer.render_preview(session, base_dir, max_turns=100)
        pager = os.environ.get("PAGER") or shutil.which("bat") or shutil.which("less")
        if sys.stdout.isatty() and pager:
            if "bat" in str(pager):
                cmd = [pager, "--language=markdown", "--style=plain", "--paging=always"]
            elif "less" in str(pager):
                cmd = [pager, "-R"]
            else:
                cmd = [pager]
            try:
                proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, text=True)
                proc.communicate(output)
                return
            except Exception:
                pass
        print(output)


class Launcher:
    @staticmethod
    def launch(
        session: Session,
        mode: str = "safe",
        new_window: bool = False,
        base_dir: Optional[Path] = None,
        dry_run: bool = False,
    ) -> None:
        """Launch agy session with specified execution mode and optional new window."""
        cid = session.conversation_id
        ws = session.workspace_path

        # 1. Switch to the session's workspace directory if valid
        if ws and Path(ws).is_dir():
            try:
                os.chdir(ws)
            except Exception as ex:
                print(f"{YELLOW}Warning: Could not change directory to {ws}: {ex}{RESET}", file=sys.stderr)
        elif ws:
            print(f"{YELLOW}Notice: Workspace directory {ws} no longer exists, staying in {os.getcwd()}{RESET}", file=sys.stderr)

        # 2. Resolve agy binary
        agy_bin = shutil.which("agy") or shutil.which("antigravity-cli")
        if not agy_bin:
            fallback = Path.home() / ".local/bin/agy"
            if fallback.exists():
                agy_bin = str(fallback)
            else:
                print(f"{RED}Error: agy binary not found in PATH.{RESET}", file=sys.stderr)
                sys.exit(1)

        # 3. Assemble command flags
        cmd = [agy_bin, "--conversation", cid]
        mode_label = "Safe Mode"
        if mode == "unsafe":
            cmd.append("--dangerously-skip-permissions")
            mode_label = "⚡ Unsafe Mode (--dangerously-skip-permissions)"
        elif mode == "sandbox":
            cmd.append("--sandbox")
            mode_label = "📦 Sandbox Mode (--sandbox)"
        else:
            mode_label = "🛡️  Safe Mode (Default Prompts)"

        print(f"\n{BOLD}{CYAN}▶ Resuming Antigravity Session{RESET}")
        print(f"  {DIM}Session  :{RESET} {WHITE}{session.display_title}{RESET} ({session.short_id})")
        print(f"  {DIM}Mode     :{RESET} {mode_label}")
        print(f"  {DIM}Workspace:{RESET} {YELLOW}{os.getcwd()}{RESET}\n")

        if dry_run:
            print(f"{BOLD}[DRY-RUN]{RESET} Working Directory: {os.getcwd()}")
            print(f"{BOLD}[DRY-RUN]{RESET} Target Command    : {' '.join(cmd)}")
            if new_window:
                print(f"{BOLD}[DRY-RUN]{RESET} Window Mode       : omarchy-launch-tui --app-id=org.omarchy.agy-{session.short_id}")
            return

        # 4. Launch in new window or current terminal
        if new_window:
            launch_tui = shutil.which("omarchy-launch-tui")
            if launch_tui:
                app_id = f"org.omarchy.agy-{session.short_id}"
                full_cmd = [launch_tui, f"--app-id={app_id}"] + cmd
                subprocess.Popen(full_cmd, cwd=os.getcwd(), start_new_session=True)
                print(f"{GREEN}✓ Launched session in new Omarchy window.{RESET}")
                return
            else:
                # Fallback to xdg-terminal-exec or x-terminal-emulator
                term = shutil.which("xdg-terminal-exec") or shutil.which("x-terminal-emulator")
                if term:
                    full_cmd = [term, "-e"] + cmd
                    subprocess.Popen(full_cmd, cwd=os.getcwd(), start_new_session=True)
                    print(f"{GREEN}✓ Launched session in new terminal window.{RESET}")
                    return

        # Inline execution: replace current process
        os.execvp(cmd[0], cmd)


class InteractivePicker:
    """fzf-based interactive picker with live transcript preview and mode menu."""

    @staticmethod
    def run(store: SessionStore, new_window: bool = False) -> None:
        if not sys.stdin.isatty():
            cmd_list(store, argparse.Namespace(limit=25))
            return

        fzf_bin = shutil.which("fzf")
        if not fzf_bin:
            InteractivePicker.fallback_menu(store, new_window=new_window)
            return

        sessions = store.list_sessions()
        if not sessions:
            print(f"{YELLOW}No Antigravity conversations found in {store.base_dir}.{RESET}")
            sys.exit(0)

        # Prepare fzf input lines
        lines: List[str] = []
        for idx, s in enumerate(sessions, 1):
            status_icon = "🟢" if s.is_active else "⚪"
            t_str = relative_time(s.last_modified_dt)
            title = s.display_title.replace("\t", " ")
            ws = s.display_workspace.replace("\t", " ")
            # Format: Display columns \t Full Conversation ID
            display = f"{status_icon} {idx:2d} │ {s.short_id} │ {t_str:<7} │ {s.step_count:3d} steps │ {title:<36} │ {ws}"
            lines.append(f"{display}\t{s.conversation_id}")

        self_script = sys.argv[0]
        if not os.path.isabs(self_script):
            self_script = shutil.which(self_script) or os.path.abspath(self_script)

        preview_cmd = f"'{sys_executable()}' '{self_script}' preview {{2}}"

        header = (
            "ENTER: Action Menu  │  ^U: Unsafe Mode  │  ^S: Safe Mode  │  ^B: Sandbox\n"
            "   ^T: Full Transcript  │  ^K: Kill Active  │  ^D: Delete  │  ESC: Exit"
        )

        fzf_args = [
            fzf_bin,
            "--ansi",
            "--delimiter=\t",
            "--with-nth=1",
            "--header=" + header,
            "--preview=" + preview_cmd,
            "--preview-window=right:55%:wrap",
            "--expect=ctrl-u,ctrl-s,ctrl-b,ctrl-t,ctrl-k,ctrl-d",
            "--layout=reverse",
            "--border=rounded",
            "--prompt=agy-sessions > ",
        ]

        try:
            proc = subprocess.Popen(
                fzf_args,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                text=True,
            )
            stdout, _ = proc.communicate("\n".join(lines))
        except KeyboardInterrupt:
            sys.exit(0)

        if proc.returncode != 0 or not stdout:
            # Cancelled or ESC pressed
            sys.exit(0)

        output_lines = stdout.splitlines()
        if not output_lines:
            sys.exit(0)

        # When --expect is used, fzf prints:
        # Line 0: The key pressed (empty if default Enter was pressed)
        # Line 1: The selected item
        if len(output_lines) >= 2:
            key_pressed = output_lines[0].strip()
            selected_line = output_lines[1].strip()
        else:
            key_pressed = ""
            selected_line = output_lines[0].strip()

        if not selected_line:
            sys.exit(0)

        parts = selected_line.split("\t")
        if len(parts) < 2:
            sys.exit(0)

        cid = parts[1].strip()
        session = store.get_session(cid)
        if not session:
            print(f"{RED}Error: Session {cid} not found.{RESET}")
            sys.exit(1)

        # Dispatch based on hotkey or Enter menu
        if key_pressed == "ctrl-u":
            Launcher.launch(session, mode="unsafe", new_window=new_window, base_dir=store.base_dir)
        elif key_pressed == "ctrl-s":
            Launcher.launch(session, mode="safe", new_window=new_window, base_dir=store.base_dir)
        elif key_pressed == "ctrl-b":
            Launcher.launch(session, mode="sandbox", new_window=new_window, base_dir=store.base_dir)
        elif key_pressed == "ctrl-t":
            TranscriptViewer.show_full_info(session, store.base_dir)
        elif key_pressed == "ctrl-k":
            InteractivePicker.handle_kill(session, store)
        elif key_pressed == "ctrl-d":
            InteractivePicker.handle_delete(session, store)
        else:
            # Enter was pressed: Show action selection menu
            InteractivePicker.action_menu(session, store, new_window=new_window)

    @staticmethod
    def action_menu(session: Session, store: SessionStore, new_window: bool = False) -> None:
        """Display an interactive menu to choose action/mode for the selected conversation."""
        status_str = f"{GREEN}ACTIVE{RESET} (PID {session.pid})" if session.is_active else f"{DIM}IDLE{RESET}"
        fzf_bin = shutil.which("fzf")

        choice = ""
        if fzf_bin and sys.stdin.isatty():
            menu_items = [
                "1. 🛡️  Safe Mode          │ Standard mode with tool execution prompts",
                "2. ⚡ Unsafe Mode        │ Auto-approve tools (--dangerously-skip-permissions)",
                "3. 📦 Sandbox Mode       │ Run in isolated terminal sandbox (--sandbox)",
                "4. 📖 View Details       │ Inspect full dialogue transcript & steps",
            ]
            if session.is_active:
                menu_items.append(f"5. 🛑 Kill Process       │ Terminate running session process (PID {session.pid})")
            menu_items.append("d. 🗑️  Delete Session     │ Remove session from database")
            menu_items.append("0. ❌ Cancel             │ Return to terminal")

            header_info = (
                f"Session  : {session.display_title} ({session.short_id})\n"
                f"Workspace: {session.display_workspace} │ Steps: {session.step_count} │ Status: {status_str}"
            )

            action_args = [
                fzf_bin,
                "--ansi",
                "--height=35%",
                "--layout=reverse",
                "--border=rounded",
                "--header=" + header_info,
                "--prompt=Select action > ",
            ]

            try:
                proc = subprocess.Popen(
                    action_args,
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    text=True,
                )
                out, _ = proc.communicate("\n".join(menu_items))
                if proc.returncode != 0 or not out.strip():
                    sys.exit(0)
                choice = out.strip()[:2].lower()
            except Exception:
                choice = ""

        if not choice:
            # Fallback text menu
            print("\n" + "=" * 65)
            print(f"{BOLD}{session.display_title}{RESET} ({session.short_id})")
            print(f"Workspace: {YELLOW}{session.display_workspace}{RESET} | Steps: {session.step_count} | Status: {status_str}")
            print("=" * 65)
            print("Select an action:")
            print(f"  {BOLD}[1]{RESET} 🛡️  {GREEN}Safe Mode{RESET}       - Standard mode with tool execution prompts")
            print(f"  {BOLD}[2]{RESET} ⚡ {YELLOW}Unsafe Mode{RESET}     - Auto-approve tools (--dangerously-skip-permissions)")
            print(f"  {BOLD}[3]{RESET} 📦 {CYAN}Sandbox Mode{RESET}    - Run in isolated terminal sandbox (--sandbox)")
            print(f"  {BOLD}[4]{RESET} 📖 {BLUE}View Details{RESET}    - Inspect full dialogue transcript & steps")
            if session.is_active:
                print(f"  {BOLD}[5]{RESET} 🛑 {RED}Kill Process{RESET}    - Terminate running session process")
            print(f"  {BOLD}[d]{RESET} 🗑️  {RED}Delete Session{RESET}  - Remove session from database")
            print(f"  {BOLD}[0]{RESET} ❌ Cancel")
            print("=" * 65)

            try:
                choice = ask_input(f"{BOLD}Choose option [1/2/3/4/d/0] (default 1): {RESET}").strip().lower()
            except (KeyboardInterrupt, EOFError):
                print("\nCancelled.")
                sys.exit(0)

        if not choice or choice.startswith("1"):
            Launcher.launch(session, mode="safe", new_window=new_window, base_dir=store.base_dir)
        elif choice.startswith("2"):
            Launcher.launch(session, mode="unsafe", new_window=new_window, base_dir=store.base_dir)
        elif choice.startswith("3"):
            Launcher.launch(session, mode="sandbox", new_window=new_window, base_dir=store.base_dir)
        elif choice.startswith("4"):
            TranscriptViewer.show_full_info(session, store.base_dir)
        elif choice.startswith("5") and session.is_active:
            InteractivePicker.handle_kill(session, store)
        elif choice.startswith("d"):
            InteractivePicker.handle_delete(session, store)
        else:
            print("Cancelled.")
            sys.exit(0)

    @staticmethod
    def handle_kill(session: Session, store: SessionStore) -> None:
        if not session.is_active:
            print(f"{YELLOW}Session {session.short_id} is not actively running.{RESET}")
            return
        confirm = ask_input(f"Kill running session {session.short_id} (PID {session.pid})? [y/N]: ").strip().lower()
        if confirm == "y":
            if store.kill_session(session):
                print(f"{GREEN}✓ Terminated session {session.short_id}.{RESET}")
            else:
                print(f"{RED}Failed to terminate session {session.short_id}.{RESET}")

    @staticmethod
    def handle_delete(session: Session, store: SessionStore) -> None:
        confirm = ask_input(f"{RED}Are you sure you want to delete session '{session.display_title}' ({session.short_id})? [y/N]: {RESET}").strip().lower()
        if confirm == "y":
            store.delete_session(session)
            print(f"{GREEN}✓ Deleted session {session.short_id}.{RESET}")
        else:
            print("Deletion cancelled.")

    @staticmethod
    def fallback_menu(store: SessionStore, new_window: bool = False) -> None:
        """Terminal menu used when fzf is not available."""
        sessions = store.list_sessions()
        print(f"\n{BOLD}{CYAN}Antigravity Sessions ({len(sessions)} total):{RESET}\n")
        for idx, s in enumerate(sessions[:25], 1):
            status = f"{GREEN}●{RESET}" if s.is_active else f"{DIM}○{RESET}"
            t_str = relative_time(s.last_modified_dt)
            print(f"{idx:2d}. {status} {s.short_id} │ {t_str:<7} │ {s.step_count:3d} steps │ {s.display_title:<32} │ {s.display_workspace}")

        try:
            sel = ask_input(f"\n{BOLD}Select session number to open (or 'q' to quit): {RESET}").strip()
        except (KeyboardInterrupt, EOFError):
            sys.exit(0)

        if sel.lower() in ("q", "quit", "exit"):
            sys.exit(0)

        session = store.get_session(sel)
        if not session:
            print(f"{RED}Invalid selection.{RESET}")
            sys.exit(1)

        InteractivePicker.action_menu(session, store, new_window=new_window)


def sys_executable() -> str:
    return sys.executable or "/usr/bin/python3"


def cmd_list(store: SessionStore, args: argparse.Namespace) -> None:
    sessions = store.list_sessions()
    if not sessions:
        print("No Antigravity conversations found.")
        return

    limit = args.limit or len(sessions)
    print(f"\n{BOLD}{'#':<3} {'STATUS':<8} {'ID':<10} {'UPDATED':<10} {'STEPS':<6} {'TITLE':<38} {'WORKSPACE'}{RESET}")
    print(DIM + "─" * 105 + RESET)

    for idx, s in enumerate(sessions[:limit], 1):
        status = f"{GREEN}ACTIVE{RESET}  " if s.is_active else f"{DIM}IDLE{RESET}    "
        t_str = relative_time(s.last_modified_dt)
        print(f"{idx:<3} {status} {s.short_id:<10} {t_str:<10} {s.step_count:<6} {s.display_title[:36]:<38} {YELLOW}{s.display_workspace}{RESET}")
    print()


def cmd_active(store: SessionStore, args: argparse.Namespace) -> None:
    sessions = [s for s in store.list_sessions() if s.is_active]
    if not sessions:
        print(f"{DIM}No Antigravity sessions are currently active.{RESET}")
        return

    print(f"\n{BOLD}{GREEN}Active Antigravity Sessions ({len(sessions)}):{RESET}\n")
    for s in sessions:
        t_str = relative_time(s.last_modified_dt)
        print(f"  {GREEN}●{RESET} {BOLD}{s.short_id}{RESET} (PID {s.pid}) │ {t_str} │ {s.step_count} steps │ {s.display_title}")
        print(f"    Workspace: {YELLOW}{s.display_workspace}{RESET}")
    print()


def cmd_resume(store: SessionStore, args: argparse.Namespace) -> None:
    query = args.query or "1"
    session = store.get_session(query)
    if not session:
        print(f"{RED}Error: Session matching '{query}' not found.{RESET}", file=sys.stderr)
        sys.exit(1)

    mode = "safe"
    if args.unsafe:
        mode = "unsafe"
    elif args.sandbox:
        mode = "sandbox"

    dry_run = getattr(args, "dry_run", False)
    Launcher.launch(session, mode=mode, new_window=args.window, base_dir=store.base_dir, dry_run=dry_run)


def cmd_info(store: SessionStore, args: argparse.Namespace) -> None:
    query = args.query or "1"
    session = store.get_session(query)
    if not session:
        print(f"{RED}Error: Session matching '{query}' not found.{RESET}", file=sys.stderr)
        sys.exit(1)
    TranscriptViewer.show_full_info(session, store.base_dir)


def cmd_preview(store: SessionStore, args: argparse.Namespace) -> None:
    # Quick rendering for fzf preview window
    cid = args.cid
    session = store.get_session(cid)
    if not session:
        print(f"{DIM}Session not found: {cid}{RESET}")
        return
    print(TranscriptViewer.render_preview(session, store.base_dir, max_turns=12))


def cmd_kill(store: SessionStore, args: argparse.Namespace) -> None:
    session = store.get_session(args.query)
    if not session:
        print(f"{RED}Error: Session matching '{args.query}' not found.{RESET}", file=sys.stderr)
        sys.exit(1)
    InteractivePicker.handle_kill(session, store)


def cmd_delete(store: SessionStore, args: argparse.Namespace) -> None:
    session = store.get_session(args.query)
    if not session:
        print(f"{RED}Error: Session matching '{args.query}' not found.{RESET}", file=sys.stderr)
        sys.exit(1)
    InteractivePicker.handle_delete(session, store)


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="agy-sessions",
        description="Manage and resume Google Antigravity (agy) conversation sessions.",
        epilog="Run without arguments to start the interactive fuzzy session picker.",
    )
    parser.add_argument("-w", "--window", action="store_true", help="Launch session in a new Omarchy terminal window")

    subparsers = parser.add_subparsers(dest="subcommand", help="Available subcommands")

    # list / ls
    p_list = subparsers.add_parser("list", aliases=["ls"], help="List conversation sessions in tabular format")
    p_list.add_argument("-n", "--limit", type=int, default=25, help="Number of sessions to display (default: 25)")

    # active
    subparsers.add_parser("active", help="Show currently running sessions and PIDs")

    # resume / open
    p_resume = subparsers.add_parser("resume", aliases=["open"], help="Resume a session directly")
    p_resume.add_argument("query", nargs="?", default="1", help="Session index, short ID, or UUID prefix (default: 1)")
    p_resume.add_argument("-u", "--unsafe", action="store_true", help="Launch in unsafe mode (--dangerously-skip-permissions)")
    p_resume.add_argument("-s", "--safe", action="store_true", help="Launch in safe mode with tool prompts (default)")
    p_resume.add_argument("-b", "--sandbox", action="store_true", help="Launch in sandbox mode (--sandbox)")
    p_resume.add_argument("-w", "--window", action="store_true", help="Launch in a new terminal window")
    p_resume.add_argument("--dry-run", action="store_true", help="Print command and workspace without executing")

    # info / show
    p_info = subparsers.add_parser("info", aliases=["show"], help="Display session details and transcript")
    p_info.add_argument("query", nargs="?", default="1", help="Session index, short ID, or UUID prefix")

    # preview (internal for fzf)
    p_prev = subparsers.add_parser("preview", help=argparse.SUPPRESS)
    p_prev.add_argument("cid", help="Conversation ID to preview")

    # kill
    p_kill = subparsers.add_parser("kill", help="Terminate a running session process")
    p_kill.add_argument("query", help="Session index, short ID, or UUID prefix")

    # delete / rm
    p_del = subparsers.add_parser("delete", aliases=["rm"], help="Delete a conversation session")
    p_del.add_argument("query", help="Session index, short ID, or UUID prefix")

    args = parser.parse_args()
    store = SessionStore()

    if args.subcommand in ("list", "ls"):
        cmd_list(store, args)
    elif args.subcommand == "active":
        cmd_active(store, args)
    elif args.subcommand in ("resume", "open"):
        cmd_resume(store, args)
    elif args.subcommand in ("info", "show"):
        cmd_info(store, args)
    elif args.subcommand == "preview":
        cmd_preview(store, args)
    elif args.subcommand == "kill":
        cmd_kill(store, args)
    elif args.subcommand in ("delete", "rm"):
        cmd_delete(store, args)
    else:
        # Default: Interactive Picker
        InteractivePicker.run(store, new_window=args.window)


if __name__ == "__main__":
    main()
