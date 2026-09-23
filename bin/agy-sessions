#!/usr/bin/env python3
"""Antigravity Session Manager CLI (agy-sessions / agys).

Manage, inspect, search, rename, export, and resume Google Antigravity (agy) conversation sessions.
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
        clean = raw.replace("Z", "+00:00")
        parsed = dt.datetime.fromisoformat(clean)
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=dt.timezone.utc)
        return parsed
    except Exception:
        pass
    try:
        clean = raw.split(".")[0]
        parsed = dt.datetime.fromisoformat(clean)
        return parsed.replace(tzinfo=dt.timezone.utc)
    except Exception:
        return None


def ask_input(prompt_text: str) -> str:
    """Read input from user safely, returning empty string immediately if non-interactive."""
    try:
        if sys.stdin.isatty():
            return input(prompt_text)
        return ""
    except Exception:
        return ""


def is_in_workspace(ws_path_str: str, target_dir: Optional[Path] = None) -> bool:
    """Check if session workspace matches target directory (exact match or current dir is inside workspace)."""
    if not ws_path_str:
        return False
    try:
        t_dir = (target_dir or Path.cwd()).resolve()
        ws_path = Path(ws_path_str).resolve()
        if ws_path == t_dir:
            return True
        if ws_path in t_dir.parents:
            return True
        return False
    except Exception:
        return False


def sys_executable() -> str:
    return sys.executable or "/usr/bin/python3"


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
    model: Optional[str] = None

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

        lock_map: dict[str, str] = {}
        for p in self.presence_dir.glob("*.lock"):
            cid = p.stem
            lock_map[str(p)] = cid

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

        for cid in locked_cids:
            if cid not in active_map:
                active_map[cid] = 0

        return active_map

    def list_sessions(self, target_workspace: Optional[Path] = None) -> List[Session]:
        """Load all sessions sorted by last_modified_time descending, optionally filtered by workspace."""
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
            except Exception:
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

        result = list(sessions.values())

        if target_workspace:
            result = [s for s in result if is_in_workspace(s.workspace_path, target_workspace)]

        # Sort: active sessions first, then most recently modified
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

        if q.isdigit():
            idx = int(q)
            if 1 <= idx <= len(sessions):
                return sessions[idx - 1]

        for s in sessions:
            if s.conversation_id.lower() == q.lower():
                return s

        for s in sessions:
            if s.conversation_id.lower().startswith(q.lower()):
                return s

        for s in sessions:
            if q.lower() in s.title.lower():
                return s

        return None

    def rename_session(self, session: Session, new_title: str) -> bool:
        """Update conversation title in conversation_summaries.db and memory."""
        clean = sanitize_text(new_title, 200)
        if not clean:
            return False
        if self.db_path.exists():
            try:
                conn = sqlite3.connect(self.db_path, timeout=5.0)
                cur = conn.cursor()
                cur.execute(
                    "UPDATE conversation_summaries SET title = ? WHERE conversation_id = ?",
                    (clean, session.conversation_id),
                )
                conn.commit()
                conn.close()
                session.title = clean
                return True
            except Exception:
                return False
        return False

    def delete_session(self, session: Session, permanent: bool = False) -> bool:
        """Delete or archive a session's databases, transcripts, and metadata."""
        cid = session.conversation_id

        if session.is_active:
            self.kill_session(session)

        if self.db_path.exists():
            try:
                conn = sqlite3.connect(self.db_path, timeout=3.0)
                cur = conn.cursor()
                cur.execute("DELETE FROM conversation_summaries WHERE conversation_id = ?", (cid,))
                conn.commit()
                conn.close()
            except Exception:
                pass

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

        for pattern in [f"{cid}.db", f"{cid}.db-wal", f"{cid}.db-shm"]:
            p = self.conversations_dir / pattern
            if p.exists():
                try:
                    p.unlink(missing_ok=True)
                except Exception:
                    pass

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

        lock_file = self.presence_dir / f"{cid}.lock"
        if lock_file.exists():
            try:
                lock_file.unlink(missing_ok=True)
            except Exception:
                pass

        return killed


class TranscriptViewer:
    """Extract and format transcripts for live preview, full pager viewing, search, and Markdown export."""

    @staticmethod
    def get_session_model(cid: str, base_dir: Optional[Path] = None) -> Optional[str]:
        """Detect the active model used in the session from transcript logs."""
        b_dir = base_dir or get_base_dir()
        tpath = b_dir / "brain" / cid / ".system_generated" / "logs" / "transcript.jsonl"
        if not tpath.exists():
            return None

        model_name = None
        try:
            with open(tpath, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    m = re.findall(r"Model Selection\` from .*? to ([^\n<]+?)(?:\. No need|\.\s*$)", line)
                    if m:
                        model_name = m[-1].strip()
        except Exception:
            pass
        return model_name

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
        model = TranscriptViewer.get_session_model(session.conversation_id, base_dir)

        lines = [
            f"{BOLD}{CYAN}═══════════════════════════════════════════════════════════════════{RESET}",
            f"{BOLD}{session.display_title}{RESET}",
            f"{BOLD}{CYAN}═══════════════════════════════════════════════════════════════════{RESET}",
            f"{DIM}Session ID :{RESET} {WHITE}{session.conversation_id}{RESET}",
            f"{DIM}Status     :{RESET} {status_tag}",
        ]
        if model:
            lines.append(f"{DIM}Model      :{RESET} {CYAN}🔮 {model}{RESET}")
        lines.extend([
            f"{DIM}Workspace  :{RESET} {YELLOW}{session.display_workspace}{RESET}",
            f"{DIM}Turns/Steps:{RESET} {MAGENTA}{session.step_count} steps{RESET}",
            f"{DIM}Last Active:{RESET} {time_str} ({full_time})",
            "",
            f"{BOLD}{CYAN}Recent Conversation Turns:{RESET}",
            f"{DIM}───────────────────────────────────────────────────────────────────{RESET}",
        ])

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
        output = TranscriptViewer.render_preview(session, base_dir, max_turns=120)
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

    @staticmethod
    def export_markdown(session: Session, base_dir: Optional[Path] = None) -> str:
        """Generate clean GitHub-flavored Markdown from session transcript."""
        b_dir = base_dir or get_base_dir()
        tpath = b_dir / "brain" / session.conversation_id / ".system_generated" / "logs" / "transcript.jsonl"
        model = TranscriptViewer.get_session_model(session.conversation_id, base_dir)
        full_time = (
            session.last_modified_dt.astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")
            if session.last_modified_dt
            else "N/A"
        )

        lines = [
            f"# {session.display_title}",
            "",
            f"- **Session ID**: `{session.conversation_id}`",
            f"- **Workspace**: `{session.workspace_path or '~'}`",
            f"- **Last Active**: {full_time}",
            f"- **Total Steps**: {session.step_count}",
        ]
        if model:
            lines.append(f"- **Model**: `{model}`")
        lines.append("")
        lines.append("---")
        lines.append("")

        if not tpath.exists():
            lines.append("*(No detailed transcript file found)*")
            if session.preview:
                lines.append(f"\n> {session.preview}")
            return "\n".join(lines)

        turn_counter = 0
        try:
            with open(tpath, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        data = json.loads(line)
                    except Exception:
                        continue
                    tp = data.get("type", "")
                    content = data.get("content") or ""
                    tc = data.get("tool_calls") or []
                    step_idx = data.get("step_index", turn_counter)

                    if tp == "USER_INPUT" and content:
                        turn_counter += 1
                        cleaned = content.replace("<USER_REQUEST>", "").replace("</USER_REQUEST>", "")
                        cleaned = cleaned.split("<ADDITIONAL_METADATA>")[0].strip()
                        lines.append(f"## 👤 User (Step {step_idx})")
                        lines.append("")
                        lines.append(cleaned)
                        lines.append("")
                        lines.append("---")
                        lines.append("")
                    elif tp == "PLANNER_RESPONSE":
                        if content or tc:
                            turn_counter += 1
                            lines.append(f"## 🤖 Antigravity (Step {step_idx})")
                            lines.append("")
                            if content:
                                lines.append(content.strip())
                                lines.append("")
                            if tc:
                                lines.append("<details>")
                                lines.append(f"<summary>🛠️ Tool Executions ({len(tc)} calls)</summary>")
                                lines.append("")
                                for call in tc:
                                    t_name = call.get("name", "tool")
                                    args = call.get("args") or {}
                                    summary = call.get("toolSummary") or call.get("toolAction")
                                    desc = ""
                                    if summary:
                                        desc = summary
                                    elif "CommandLine" in args:
                                        cmd_str = args["CommandLine"].strip().replace("\n", " ")
                                        desc = f"run: `{cmd_str[:100]}`"
                                    elif "TargetFile" in args or "AbsolutePath" in args:
                                        f_path = args.get("TargetFile") or args.get("AbsolutePath")
                                        desc = f"file: `{Path(f_path).name}`"
                                    if desc:
                                        lines.append(f"- **`{t_name}`**: {desc}")
                                    else:
                                        lines.append(f"- **`{t_name}`**")
                                lines.append("")
                                lines.append("</details>")
                                lines.append("")
                            lines.append("---")
                            lines.append("")
        except Exception as ex:
            lines.append(f"\n*(Error reading transcript: {ex})*")

        return "\n".join(lines)

    @staticmethod
    def search_transcripts(
        store: SessionStore,
        keyword: str,
        target_workspace: Optional[Path] = None,
        limit: int = 15,
    ) -> List[Tuple[Session, List[Tuple[int, str, str]]]]:
        """Search for keyword across session transcripts.

        Returns list of (Session, [(step_index, speaker/role, snippet)]).
        """
        sessions = store.list_sessions(target_workspace=target_workspace)
        term_re = re.compile(re.escape(keyword), re.IGNORECASE)
        results: List[Tuple[Session, List[Tuple[int, str, str]]]] = []

        for s in sessions:
            tpath = store.brain_dir / s.conversation_id / ".system_generated" / "logs" / "transcript.jsonl"
            if not tpath.exists():
                continue

            matches: List[Tuple[int, str, str]] = []
            try:
                with open(tpath, "r", encoding="utf-8", errors="replace") as f:
                    for line in f:
                        if not term_re.search(line):
                            continue
                        try:
                            data = json.loads(line)
                            idx = data.get("step_index", 0)
                            tp = data.get("type", "")
                            content = data.get("content") or ""
                            tc = data.get("tool_calls") or []

                            if tp == "USER_INPUT" and content:
                                cleaned = content.replace("<USER_REQUEST>", "").replace("</USER_REQUEST>", "")
                                cleaned = cleaned.split("<ADDITIONAL_METADATA>")[0].strip()
                                for cl in cleaned.splitlines():
                                    if term_re.search(cl):
                                        matches.append((idx, "User", cl.strip()))
                                        break
                            elif tp == "PLANNER_RESPONSE":
                                found_in_content = False
                                if content:
                                    for cl in content.splitlines():
                                        if term_re.search(cl):
                                            matches.append((idx, "Antigravity", cl.strip()))
                                            found_in_content = True
                                            break
                                if not found_in_content and tc:
                                    for call in tc:
                                        t_name = call.get("name", "tool")
                                        args = call.get("args") or {}
                                        summary = call.get("toolSummary") or call.get("toolAction")
                                        args_str = json.dumps(args)
                                        if summary and term_re.search(summary):
                                            matches.append((idx, f"Tool ({t_name})", summary))
                                            break
                                        elif term_re.search(args_str):
                                            matches.append((idx, f"Tool ({t_name})", args_str[:100]))
                                            break
                        except Exception:
                            continue
            except Exception:
                continue

            if matches:
                results.append((s, matches))
                if len(results) >= limit:
                    break

        return results


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

        if ws and Path(ws).is_dir():
            try:
                os.chdir(ws)
            except Exception as ex:
                print(f"{YELLOW}Warning: Could not change directory to {ws}: {ex}{RESET}", file=sys.stderr)
        elif ws:
            print(f"{YELLOW}Notice: Workspace directory {ws} no longer exists, staying in {os.getcwd()}{RESET}", file=sys.stderr)

        agy_bin = shutil.which("agy") or shutil.which("antigravity-cli")
        if not agy_bin:
            fallback = Path.home() / ".local/bin/agy"
            if fallback.exists():
                agy_bin = str(fallback)
            else:
                print(f"{RED}Error: agy binary not found in PATH.{RESET}", file=sys.stderr)
                sys.exit(1)

        cmd = [agy_bin, "--conversation", cid]
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

    @staticmethod
    def launch_in_new_window(cmd: List[str], app_id: str, cwd: str) -> bool:
        """Spawn a command in a new Omarchy or system terminal window."""
        launch_tui = shutil.which("omarchy-launch-tui")
        if launch_tui:
            full_cmd = [launch_tui, f"--app-id={app_id}"] + cmd
            subprocess.Popen(full_cmd, cwd=cwd, start_new_session=True)
            return True
        term = shutil.which("xdg-terminal-exec") or shutil.which("x-terminal-emulator")
        if term:
            full_cmd = [term, "-e"] + cmd
            subprocess.Popen(full_cmd, cwd=cwd, start_new_session=True)
            return True
        return False

        if new_window:
            app_id = f"org.omarchy.agy-{session.short_id}"
            if Launcher.launch_in_new_window(cmd, app_id=app_id, cwd=os.getcwd()):
                print(f"{GREEN}✓ Launched session in new Omarchy window.{RESET}")
                return
            else:
                print(f"{YELLOW}Warning: No terminal window launcher found. Running inline.{RESET}", file=sys.stderr)

        # Replace current process inline
        os.execvp(cmd[0], cmd)


class MultiplexerManager:
    """Detect and launch sessions inside terminal multiplexers (tmux, zellij, screen) or fallback."""

    @staticmethod
    def detect(preferred: Optional[str] = None) -> Tuple[Optional[str], str, Optional[str]]:
        """Return (name, status, binary_path) where status is 'active', 'installed', or 'none'.

        'active' means current shell is running inside the multiplexer.
        'installed' means binary exists on the system.
        'none' means no multiplexer is found.
        """
        # 1. If currently running inside a multiplexer, prioritize the active one
        if os.environ.get("TMUX"):
            return ("tmux", "active", shutil.which("tmux"))
        if os.environ.get("ZELLIJ") or os.environ.get("ZELLIJ_SESSION_NAME"):
            return ("zellij", "active", shutil.which("zellij"))
        if os.environ.get("STY"):
            return ("screen", "active", shutil.which("screen"))

        # 2. Check user preferred multiplexer if explicitly requested
        if preferred:
            bin_path = shutil.which(preferred)
            if bin_path:
                return (preferred, "installed", bin_path)

        # 3. Check installed multiplexers in priority order: tmux -> zellij -> screen
        for name in ["tmux", "zellij", "screen"]:
            bin_path = shutil.which(name)
            if bin_path:
                return (name, "installed", bin_path)

        return (None, "none", None)

    @staticmethod
    def get_menu_label() -> str:
        name, status, _ = MultiplexerManager.detect()
        if status == "active":
            return f"m. 🪟 Multiplexer [{name}: active]   │ Open new window/tab in current {name}"
        elif status == "installed":
            return f"m. 🪟 Multiplexer [{name}]          │ Open in {name} session (agy-<id>)"
        else:
            return "m. 🪟 New Terminal Window          │ No multiplexer found; open in new window"

    @staticmethod
    def launch(
        session: Session,
        mode: str = "safe",
        preferred_mux: Optional[str] = None,
        force_new_window: bool = False,
        base_dir: Optional[Path] = None,
        dry_run: bool = False,
    ) -> None:
        """Launch session in terminal multiplexer, or fallback to new terminal window if none."""
        mux_name, mux_status, mux_bin = MultiplexerManager.detect(preferred=preferred_mux)

        agy_bin = shutil.which("agy") or shutil.which("antigravity-cli")
        if not agy_bin:
            fallback = Path.home() / ".local/bin/agy"
            if fallback.exists():
                agy_bin = str(fallback)
            else:
                print(f"{RED}Error: agy binary not found in PATH.{RESET}", file=sys.stderr)
                sys.exit(1)

        agy_cmd = [agy_bin, "--conversation", session.conversation_id]
        mode_label = "Safe Mode"
        if mode == "unsafe":
            agy_cmd.append("--dangerously-skip-permissions")
            mode_label = "⚡ Unsafe Mode (--dangerously-skip-permissions)"
        elif mode == "sandbox":
            agy_cmd.append("--sandbox")
            mode_label = "📦 Sandbox Mode (--sandbox)"
        else:
            mode_label = "🛡️  Safe Mode (Default Prompts)"

        ws = session.workspace_path or str(Path.home())
        if not Path(ws).is_dir():
            ws = str(Path.cwd())

        session_name = f"agy-{session.short_id}"

        # FALLBACK: No multiplexer found -> open in new terminal window
        if mux_status == "none" or not mux_bin:
            print(f"\n{YELLOW}Notice: No terminal multiplexer found on this system (tmux, zellij, screen).{RESET}")
            print(f"{CYAN}▶ Opening session '{session.display_title}' in new terminal window...{RESET}\n")
            Launcher.launch(session, mode=mode, new_window=True, base_dir=base_dir, dry_run=dry_run)
            return

        print(f"\n{BOLD}{CYAN}▶ Launching Antigravity Session via {mux_name.upper()}{RESET}")
        print(f"  {DIM}Session     :{RESET} {WHITE}{session.display_title}{RESET} ({session.short_id})")
        print(f"  {DIM}Multiplexer :{RESET} {MAGENTA}{mux_name}{RESET} ({mux_status})")
        print(f"  {DIM}Mode        :{RESET} {mode_label}")
        print(f"  {DIM}Workspace   :{RESET} {YELLOW}{ws}{RESET}\n")

        # CASE 1: Inside active tmux
        if mux_name == "tmux" and mux_status == "active":
            cmd_str = " ".join([f"'{c}'" if " " in c else c for c in agy_cmd])
            if dry_run:
                print(f"{BOLD}[DRY-RUN]{RESET} Multiplexer Status : Active tmux session")
                print(f"{BOLD}[DRY-RUN]{RESET} Working Directory  : {ws}")
                print(f"{BOLD}[DRY-RUN]{RESET} Target Command     : tmux new-window -n {session_name} -c {ws} {cmd_str}")
                return

            try:
                chk = subprocess.run(["tmux", "list-windows", "-F", "#{window_name}"], capture_output=True, text=True)
                if session_name in chk.stdout.splitlines():
                    subprocess.run(["tmux", "select-window", "-t", session_name])
                    print(f"{GREEN}✓ Switched to existing tmux window '{session_name}'.{RESET}")
                    return

                subprocess.Popen(["tmux", "new-window", "-n", session_name, "-c", ws, cmd_str])
                print(f"{GREEN}✓ Opened session in new tmux window '{session_name}'.{RESET}")
            except Exception as ex:
                print(f"{RED}Error opening tmux window: {ex}{RESET}", file=sys.stderr)
            return

        # CASE 2: Inside active zellij
        if mux_name == "zellij" and mux_status == "active":
            zellij_cmd = ["zellij", "action", "new-tab", "--name", session_name, "--cwd", ws, "--"] + agy_cmd
            if dry_run:
                print(f"{BOLD}[DRY-RUN]{RESET} Multiplexer Status : Active zellij session")
                print(f"{BOLD}[DRY-RUN]{RESET} Command            : {' '.join(zellij_cmd)}")
                return
            try:
                subprocess.Popen(zellij_cmd)
                print(f"{GREEN}✓ Opened session in new zellij tab '{session_name}'.{RESET}")
            except Exception as ex:
                print(f"{RED}Error opening zellij tab: {ex}{RESET}", file=sys.stderr)
            return

        # CASE 3: Inside active screen
        if mux_name == "screen" and mux_status == "active":
            screen_cmd = ["screen", "-t", session_name] + agy_cmd
            if dry_run:
                print(f"{BOLD}[DRY-RUN]{RESET} Multiplexer Status : Active screen session")
                print(f"{BOLD}[DRY-RUN]{RESET} Command            : {' '.join(screen_cmd)}")
                return
            try:
                subprocess.Popen(screen_cmd, cwd=ws)
                print(f"{GREEN}✓ Opened session in new screen window '{session_name}'.{RESET}")
            except Exception as ex:
                print(f"{RED}Error opening screen window: {ex}{RESET}", file=sys.stderr)
            return

        # CASE 4: Multiplexer installed on system (outside active multiplexer)
        if mux_name == "tmux":
            cmd_str = " ".join([f"'{c}'" if " " in c else c for c in agy_cmd])
            tmux_full = [mux_bin, "new-session", "-A", "-s", session_name, "-c", ws, cmd_str]

            if dry_run:
                print(f"{BOLD}[DRY-RUN]{RESET} Multiplexer Status : Installed binary ({mux_bin})")
                print(f"{BOLD}[DRY-RUN]{RESET} Session Name       : {session_name}")
                print(f"{BOLD}[DRY-RUN]{RESET} Target Command     : {' '.join(tmux_full)}")
                if force_new_window:
                    print(f"{BOLD}[DRY-RUN]{RESET} Window Mode        : New terminal running tmux")
                return

            if force_new_window:
                app_id = f"org.omarchy.{session_name}"
                if Launcher.launch_in_new_window(tmux_full, app_id=app_id, cwd=ws):
                    print(f"{GREEN}✓ Launched tmux session '{session_name}' in new terminal window.{RESET}")
                    return

            print(f"\n{BOLD}{CYAN}▶ Launching tmux session '{session_name}'...{RESET}")
            os.chdir(ws)
            os.execvp(tmux_full[0], tmux_full)

        elif mux_name == "zellij":
            zellij_full = [mux_bin, "--session", session_name, "options", "--default-cwd", ws, "--"] + agy_cmd
            if dry_run:
                print(f"{BOLD}[DRY-RUN]{RESET} Multiplexer Status : Installed binary ({mux_bin})")
                print(f"{BOLD}[DRY-RUN]{RESET} Command            : {' '.join(zellij_full)}")
                return
            if force_new_window:
                app_id = f"org.omarchy.{session_name}"
                if Launcher.launch_in_new_window(zellij_full, app_id=app_id, cwd=ws):
                    print(f"{GREEN}✓ Launched zellij session '{session_name}' in new terminal window.{RESET}")
                    return
            print(f"\n{BOLD}{CYAN}▶ Launching zellij session '{session_name}'...{RESET}")
            os.chdir(ws)
            os.execvp(zellij_full[0], zellij_full)

        elif mux_name == "screen":
            screen_full = [mux_bin, "-S", session_name] + agy_cmd
            if dry_run:
                print(f"{BOLD}[DRY-RUN]{RESET} Multiplexer Status : Installed binary ({mux_bin})")
                print(f"{BOLD}[DRY-RUN]{RESET} Command            : {' '.join(screen_full)}")
                return
            if force_new_window:
                app_id = f"org.omarchy.{session_name}"
                if Launcher.launch_in_new_window(screen_full, app_id=app_id, cwd=ws):
                    print(f"{GREEN}✓ Launched screen session '{session_name}' in new terminal window.{RESET}")
                    return
            print(f"\n{BOLD}{CYAN}▶ Launching screen session '{session_name}'...{RESET}")
            os.chdir(ws)
            os.execvp(screen_full[0], screen_full)


class InteractivePicker:
    """fzf-based interactive picker with live transcript preview and mode menu."""

    @staticmethod
    def run(
        store: SessionStore,
        new_window: bool = False,
        initial_filter_cwd: bool = False,
        default_mux: bool = False,
        preferred_mux: Optional[str] = None,
    ) -> None:
        if not sys.stdin.isatty():
            cmd_list(store, argparse.Namespace(limit=25, current_dir=initial_filter_cwd))
            return

        fzf_bin = shutil.which("fzf")
        if not fzf_bin:
            InteractivePicker.fallback_menu(store, new_window=new_window, default_mux=default_mux, preferred_mux=preferred_mux)
            return

        filter_cwd = initial_filter_cwd
        current_dir = Path.cwd()

        while True:
            target_ws = current_dir if filter_cwd else None
            sessions = store.list_sessions(target_workspace=target_ws)

            if not sessions:
                if filter_cwd:
                    print(f"{YELLOW}No Antigravity conversations found matching workspace: {current_dir}{RESET}")
                    choice = ask_input(f"Show all workspaces instead? [Y/n]: ").strip().lower()
                    if choice != "n":
                        filter_cwd = False
                        continue
                else:
                    print(f"{YELLOW}No Antigravity conversations found in {store.base_dir}.{RESET}")
                sys.exit(0)

            # Prepare fzf lines
            lines: List[str] = []
            for idx, s in enumerate(sessions, 1):
                status_icon = "🟢" if s.is_active else "⚪"
                t_str = relative_time(s.last_modified_dt)
                title = s.display_title.replace("\t", " ")
                ws = s.display_workspace.replace("\t", " ")
                display = f"{status_icon} {idx:2d} │ {s.short_id} │ {t_str:<7} │ {s.step_count:3d} steps │ {title:<36} │ {ws}"
                lines.append(f"{display}\t{s.conversation_id}")

            self_script = sys.argv[0]
            if not os.path.isabs(self_script):
                self_script = shutil.which(self_script) or os.path.abspath(self_script)

            preview_cmd = f"'{sys_executable()}' '{self_script}' preview {{2}}"
            ws_tag = f"[Workspace: {current_dir.name}]" if filter_cwd else "[All Workspaces]"

            mux_name = (preferred_mux or "tmux").upper() if preferred_mux else "TMUX"
            if default_mux:
                header = (
                    f"ENTER: Resume in {mux_name}  │  ^U: Unsafe ({mux_name})  │  ^A: Action Menu  │  ^S: Safe  │  ^B: Sandbox\n"
                    f"   ^W: Toggle Scope ({ws_tag})  │  ^R: Rename  │  ^T: Details  │  ^D: Delete  │  ESC: Exit"
                )
                prompt_tag = f"agys ({preferred_mux or 'tmux'}) {ws_tag} > "
            else:
                header = (
                    f"ENTER: Action Menu  │  ^U: Unsafe  │  ^S: Safe  │  ^B: Sandbox  │  ^X: Mux\n"
                    f"   ^W: Toggle Scope ({ws_tag})  │  ^R: Rename  │  ^T: Details  │  ^D: Delete  │  ESC: Exit"
                )
                prompt_tag = f"agys {ws_tag} > "

            fzf_args = [
                fzf_bin,
                "--ansi",
                "--delimiter=\t",
                "--with-nth=1",
                "--header=" + header,
                "--preview=" + preview_cmd,
                "--preview-window=right:55%:wrap",
                "--expect=ctrl-u,ctrl-s,ctrl-b,ctrl-t,ctrl-k,ctrl-d,ctrl-w,ctrl-r,ctrl-x,ctrl-a",
                "--layout=reverse",
                "--border=rounded",
                f"--prompt={prompt_tag}",
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
                sys.exit(0)

            output_lines = stdout.splitlines()
            if not output_lines:
                sys.exit(0)

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

            # Process Hotkeys
            if key_pressed == "ctrl-w":
                filter_cwd = not filter_cwd
                continue
            elif key_pressed == "ctrl-r":
                InteractivePicker.handle_rename(session, store)
                continue
            elif key_pressed == "ctrl-a":
                action_result = InteractivePicker.action_menu(session, store, new_window=new_window)
                if action_result in ("back", "refresh"):
                    continue
                break
            elif key_pressed == "ctrl-x":
                MultiplexerManager.launch(session, mode="safe", preferred_mux=preferred_mux, force_new_window=new_window, base_dir=store.base_dir)
                break
            elif key_pressed == "ctrl-u":
                if default_mux:
                    MultiplexerManager.launch(session, mode="unsafe", preferred_mux=preferred_mux, force_new_window=new_window, base_dir=store.base_dir)
                else:
                    Launcher.launch(session, mode="unsafe", new_window=new_window, base_dir=store.base_dir)
                break
            elif key_pressed == "ctrl-s":
                Launcher.launch(session, mode="safe", new_window=new_window, base_dir=store.base_dir)
                break
            elif key_pressed == "ctrl-b":
                Launcher.launch(session, mode="sandbox", new_window=new_window, base_dir=store.base_dir)
                break
            elif key_pressed == "ctrl-t":
                TranscriptViewer.show_full_info(session, store.base_dir)
                if not InteractivePicker.after_details_prompt(session, store, new_window=new_window):
                    continue
                break
            elif key_pressed == "ctrl-k":
                InteractivePicker.handle_kill(session, store)
                continue
            elif key_pressed == "ctrl-d":
                InteractivePicker.handle_delete(session, store)
                continue
            else:
                if default_mux:
                    MultiplexerManager.launch(session, mode="safe", preferred_mux=preferred_mux, force_new_window=new_window, base_dir=store.base_dir)
                    break
                else:
                    # Enter was pressed: Open action menu
                    action_result = InteractivePicker.action_menu(session, store, new_window=new_window)
                    if action_result in ("back", "refresh"):
                        continue
                    break

    @staticmethod
    def action_menu(session: Session, store: SessionStore, new_window: bool = False) -> str:
        """Display interactive submenu for the selected conversation.

        Returns 'back' or 'refresh' to loop back to picker, or exits/launches.
        """
        status_str = f"{GREEN}ACTIVE{RESET} (PID {session.pid})" if session.is_active else f"{DIM}IDLE{RESET}"
        fzf_bin = shutil.which("fzf")

        choice = ""
        mux_label = MultiplexerManager.get_menu_label()
        if fzf_bin and sys.stdin.isatty():
            menu_items = [
                "1. 🛡️  Safe Mode          │ Standard mode with tool execution prompts",
                "2. ⚡ Unsafe Mode        │ Auto-approve tools (--dangerously-skip-permissions)",
                "3. 📦 Sandbox Mode       │ Run in isolated terminal sandbox (--sandbox)",
                mux_label,
                "4. 📖 View Details       │ Inspect full dialogue transcript & steps",
                "r. ✏️  Rename Session     │ Edit session title",
                "e. 📄 Export Markdown    │ Save conversation to clean Markdown file",
            ]
            if session.is_active:
                menu_items.append(f"k. 🛑 Kill Process       │ Terminate running session process (PID {session.pid})")
            menu_items.append("d. 🗑️  Delete Session     │ Remove session from database")
            menu_items.append("0. ❌ Cancel             │ Return to session list")

            header_info = (
                f"Session  : {session.display_title} ({session.short_id})\n"
                f"Workspace: {session.display_workspace} │ Steps: {session.step_count} │ Status: {status_str}"
            )

            action_args = [
                fzf_bin,
                "--ansi",
                "--height=40%",
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
                    return "back"
                choice = out.strip()[:2].lower()
            except Exception:
                choice = ""

        if not choice:
            print("\n" + "=" * 65)
            print(f"{BOLD}{session.display_title}{RESET} ({session.short_id})")
            print(f"Workspace: {YELLOW}{session.display_workspace}{RESET} | Steps: {session.step_count} | Status: {status_str}")
            print("=" * 65)
            print("Select an action:")
            print(f"  {BOLD}[1]{RESET} 🛡️  {GREEN}Safe Mode{RESET}       - Standard mode with tool execution prompts")
            print(f"  {BOLD}[2]{RESET} ⚡ {YELLOW}Unsafe Mode{RESET}     - Auto-approve tools (--dangerously-skip-permissions)")
            print(f"  {BOLD}[3]{RESET} 📦 {CYAN}Sandbox Mode{RESET}    - Run in isolated terminal sandbox (--sandbox)")
            print(f"  {BOLD}[m]{RESET} 🪟 {MAGENTA}Multiplexer{RESET}     - Open in tmux/zellij (or new terminal window)")
            print(f"  {BOLD}[4]{RESET} 📖 {BLUE}View Details{RESET}    - Inspect full dialogue transcript & steps")
            print(f"  {BOLD}[r]{RESET} ✏️  {WHITE}Rename Session{RESET}  - Edit session title")
            print(f"  {BOLD}[e]{RESET} 📄 {MAGENTA}Export Markdown{RESET} - Save dialogue to Markdown")
            if session.is_active:
                print(f"  {BOLD}[k]{RESET} 🛑 {RED}Kill Process{RESET}    - Terminate running session process")
            print(f"  {BOLD}[d]{RESET} 🗑️  {RED}Delete Session{RESET}  - Remove session from database")
            print(f"  {BOLD}[0]{RESET} ❌ Cancel (Back to list)")
            print("=" * 65)

            try:
                choice = ask_input(f"{BOLD}Choose option [1/2/3/m/4/r/e/d/0] (default 1): {RESET}").strip().lower()
            except (KeyboardInterrupt, EOFError):
                return "back"

        if not choice or choice.startswith("1"):
            Launcher.launch(session, mode="safe", new_window=new_window, base_dir=store.base_dir)
            return "launched"
        elif choice.startswith("2"):
            Launcher.launch(session, mode="unsafe", new_window=new_window, base_dir=store.base_dir)
            return "launched"
        elif choice.startswith("3"):
            Launcher.launch(session, mode="sandbox", new_window=new_window, base_dir=store.base_dir)
            return "launched"
        elif choice.startswith("m"):
            mode_ans = ask_input(f"{BOLD}Execution mode for multiplexer [1: Safe (default) / 2: Unsafe / 3: Sandbox]: {RESET}").strip().lower()
            mux_mode = "safe"
            if mode_ans in ("2", "u", "unsafe"):
                mux_mode = "unsafe"
            elif mode_ans in ("3", "b", "sandbox"):
                mux_mode = "sandbox"
            MultiplexerManager.launch(session, mode=mux_mode, force_new_window=new_window, base_dir=store.base_dir)
            return "launched"
        elif choice.startswith("4"):
            TranscriptViewer.show_full_info(session, store.base_dir)
            if InteractivePicker.after_details_prompt(session, store, new_window=new_window):
                return "launched"
            return "back"
        elif choice.startswith("r"):
            InteractivePicker.handle_rename(session, store)
            return "refresh"
        elif choice.startswith("e"):
            InteractivePicker.handle_export(session, store)
            return "back"
        elif choice.startswith("k") and session.is_active:
            InteractivePicker.handle_kill(session, store)
            return "refresh"
        elif choice.startswith("d"):
            InteractivePicker.handle_delete(session, store)
            return "refresh"
        else:
            return "back"

    @staticmethod
    def after_details_prompt(session: Session, store: SessionStore, new_window: bool = False) -> bool:
        """Prompt user after viewing full transcript. Returns True if launched, False to return."""
        print("\n" + "─" * 65)
        print(f"{BOLD}Finished inspecting: {session.display_title}{RESET}")
        print(f"  {BOLD}[1/s]{RESET} Safe    {BOLD}[2/u]{RESET} Unsafe    {BOLD}[3/b]{RESET} Sandbox    {BOLD}[m]{RESET} Multiplexer")
        print(f"  {BOLD}[Enter/l]{RESET} Return to session list        {BOLD}[q]{RESET} Quit")
        print("─" * 65)
        try:
            ans = ask_input(f"{BOLD}Select action (default: return to list): {RESET}").strip().lower()
        except (KeyboardInterrupt, EOFError):
            return False

        if ans in ("1", "s", "safe"):
            Launcher.launch(session, mode="safe", new_window=new_window, base_dir=store.base_dir)
            return True
        elif ans in ("2", "u", "unsafe"):
            Launcher.launch(session, mode="unsafe", new_window=new_window, base_dir=store.base_dir)
            return True
        elif ans in ("3", "b", "sandbox"):
            Launcher.launch(session, mode="sandbox", new_window=new_window, base_dir=store.base_dir)
            return True
        elif ans in ("m", "mux", "tmux"):
            MultiplexerManager.launch(session, mode="safe", force_new_window=new_window, base_dir=store.base_dir)
            return True
        elif ans in ("q", "quit", "exit"):
            sys.exit(0)
        return False

    @staticmethod
    def handle_rename(session: Session, store: SessionStore) -> bool:
        print(f"\n{BOLD}Rename Session:{RESET} {WHITE}{session.display_title}{RESET} ({session.short_id})")
        new_title = ask_input(f"Enter new title (current: '{session.title}'): ").strip()
        if not new_title:
            print("Rename cancelled.")
            time.sleep(0.4)
            return False
        if store.rename_session(session, new_title):
            print(f"{GREEN}✓ Successfully renamed session to: '{new_title}'{RESET}")
            time.sleep(0.5)
            return True
        else:
            print(f"{RED}Failed to update session title.{RESET}")
            time.sleep(0.8)
            return False

    @staticmethod
    def handle_export(session: Session, store: SessionStore) -> None:
        default_slug = re.sub(r"[^a-zA-Z0-9_-]+", "_", session.display_title.lower()).strip("_") or "session"
        default_filename = f"{default_slug}-{session.short_id}.md"
        print(f"\n{BOLD}Export Session Markdown:{RESET} {session.display_title}")
        dest = ask_input(f"Enter filename (default: {default_filename}): ").strip()
        if not dest:
            dest = default_filename
        dest_path = Path(dest).resolve()
        md_text = TranscriptViewer.export_markdown(session, store.base_dir)
        try:
            dest_path.write_text(md_text, encoding="utf-8")
            print(f"{GREEN}✓ Exported session transcript to: {dest_path}{RESET}")
        except Exception as ex:
            print(f"{RED}Error writing file: {ex}{RESET}")
        ask_input(f"\n{DIM}Press Enter to return...{RESET}")

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
        time.sleep(0.5)

    @staticmethod
    def handle_delete(session: Session, store: SessionStore) -> None:
        confirm = ask_input(
            f"{RED}Are you sure you want to delete session '{session.display_title}' ({session.short_id})? [y/N]: {RESET}"
        ).strip().lower()
        if confirm == "y":
            store.delete_session(session)
            print(f"{GREEN}✓ Deleted session {session.short_id}.{RESET}")
        else:
            print("Deletion cancelled.")
        time.sleep(0.5)

    @staticmethod
    def fallback_menu(
        store: SessionStore,
        new_window: bool = False,
        default_mux: bool = False,
        preferred_mux: Optional[str] = None,
    ) -> None:
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

        if default_mux:
            MultiplexerManager.launch(session, mode="safe", preferred_mux=preferred_mux, force_new_window=new_window, base_dir=store.base_dir)
        else:
            InteractivePicker.action_menu(session, store, new_window=new_window)


def cmd_list(store: SessionStore, args: argparse.Namespace) -> None:
    target_ws = Path.cwd() if getattr(args, "current_dir", False) else None
    sessions = store.list_sessions(target_workspace=target_ws)
    if not sessions:
        if target_ws:
            print(f"No Antigravity conversations found in workspace: {target_ws}")
        else:
            print("No Antigravity conversations found.")
        return

    limit = args.limit or len(sessions)
    ws_note = f" (Workspace: {Path.cwd().name})" if target_ws else ""
    print(f"\n{BOLD}{'#':<3} {'STATUS':<8} {'ID':<10} {'UPDATED':<10} {'STEPS':<6} {'TITLE':<38} {'WORKSPACE'}{ws_note}{RESET}")
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

    if getattr(args, "mux", False) or getattr(args, "tmux", False):
        preferred = "tmux" if getattr(args, "tmux", False) else None
        MultiplexerManager.launch(
            session,
            mode=mode,
            preferred_mux=preferred,
            force_new_window=args.window,
            base_dir=store.base_dir,
            dry_run=dry_run,
        )
        return

    Launcher.launch(session, mode=mode, new_window=args.window, base_dir=store.base_dir, dry_run=dry_run)


def cmd_mux(store: SessionStore, args: argparse.Namespace) -> None:
    preferred = getattr(args, "preferred", None)
    if getattr(args, "subcommand", "") == "tmux":
        preferred = "tmux"

    query = getattr(args, "query", None)
    if not query:
        InteractivePicker.run(
            store,
            new_window=args.window,
            initial_filter_cwd=False,
            default_mux=True,
            preferred_mux=preferred,
        )
        return

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
    MultiplexerManager.launch(
        session,
        mode=mode,
        preferred_mux=preferred,
        force_new_window=args.window,
        base_dir=store.base_dir,
        dry_run=dry_run,
    )


def cmd_info(store: SessionStore, args: argparse.Namespace) -> None:
    query = args.query or "1"
    session = store.get_session(query)
    if not session:
        print(f"{RED}Error: Session matching '{query}' not found.{RESET}", file=sys.stderr)
        sys.exit(1)
    TranscriptViewer.show_full_info(session, store.base_dir)


def cmd_preview(store: SessionStore, args: argparse.Namespace) -> None:
    cid = args.cid
    session = store.get_session(cid)
    if not session:
        print(f"{DIM}Session not found: {cid}{RESET}")
        return
    print(TranscriptViewer.render_preview(session, store.base_dir, max_turns=12))


def cmd_rename(store: SessionStore, args: argparse.Namespace) -> None:
    session = store.get_session(args.query)
    if not session:
        print(f"{RED}Error: Session matching '{args.query}' not found.{RESET}", file=sys.stderr)
        sys.exit(1)

    if store.rename_session(session, args.new_title):
        print(f"{GREEN}✓ Successfully renamed session {session.short_id} to: '{args.new_title}'{RESET}")
    else:
        print(f"{RED}Error: Could not rename session {session.short_id}.{RESET}", file=sys.stderr)
        sys.exit(1)


def cmd_export(store: SessionStore, args: argparse.Namespace) -> None:
    session = store.get_session(args.query)
    if not session:
        print(f"{RED}Error: Session matching '{args.query}' not found.{RESET}", file=sys.stderr)
        sys.exit(1)

    md_text = TranscriptViewer.export_markdown(session, store.base_dir)
    if getattr(args, "stdout", False):
        sys.stdout.write(md_text + "\n")
        return

    dest = args.output
    if not dest:
        slug = re.sub(r"[^a-zA-Z0-9_-]+", "_", session.display_title.lower()).strip("_") or "session"
        dest = f"{slug}-{session.short_id}.md"

    dest_path = Path(dest).resolve()
    try:
        dest_path.write_text(md_text, encoding="utf-8")
        print(f"{GREEN}✓ Exported session transcript to: {dest_path}{RESET}")
    except Exception as ex:
        print(f"{RED}Error writing file: {ex}{RESET}", file=sys.stderr)
        sys.exit(1)


def cmd_search(store: SessionStore, args: argparse.Namespace) -> None:
    target_ws = Path.cwd() if getattr(args, "current_dir", False) else None
    results = TranscriptViewer.search_transcripts(
        store,
        keyword=args.keyword,
        target_workspace=target_ws,
        limit=args.limit,
    )

    if not results:
        ws_note = f" in workspace '{Path.cwd().name}'" if target_ws else ""
        print(f"{YELLOW}No conversation sessions found matching '{args.keyword}'{ws_note}.{RESET}")
        return

    term_re = re.compile(re.escape(args.keyword), re.IGNORECASE)
    highlight = lambda text: term_re.sub(f"{YELLOW}{BOLD}\\g<0>{RESET}", text)

    print(f"\n{BOLD}{CYAN}Found {len(results)} session(s) matching '{args.keyword}':{RESET}\n")

    indexed_sessions: List[Session] = []
    for idx, (s, matches) in enumerate(results, 1):
        indexed_sessions.append(s)
        t_str = relative_time(s.last_modified_dt)
        status = f"{GREEN}● ACTIVE{RESET}" if s.is_active else f"{DIM}○ IDLE{RESET}"
        print(f"{BOLD}[{idx}]{RESET} {CYAN}{s.short_id}{RESET} │ {BOLD}{s.display_title}{RESET} ({t_str}, {status})")
        print(f"    Workspace : {DIM}{s.display_workspace}{RESET}")
        print(f"    Matches   : {len(matches)} turn(s)")
        for turn_idx, role, snippet in matches[:3]:
            snip_clean = snippet[:90].replace("\t", " ")
            print(f"      Turn {turn_idx:3d} [{role}]: {highlight(snip_clean)}")
        if len(matches) > 3:
            print(f"      {DIM}... and {len(matches) - 3} more matching turn(s){RESET}")
        print()

    if getattr(args, "resume", False) and sys.stdin.isatty():
        try:
            choice = ask_input(f"{BOLD}Select session # to resume [1-{len(indexed_sessions)}] (or ENTER to exit): {RESET}").strip()
            if choice.isdigit():
                c_idx = int(choice)
                if 1 <= c_idx <= len(indexed_sessions):
                    target_s = indexed_sessions[c_idx - 1]
                    InteractivePicker.action_menu(target_s, store)
        except (KeyboardInterrupt, EOFError):
            pass


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
        description="Manage, search, rename, export, and resume Google Antigravity (agy) conversation sessions.",
        epilog="Run without arguments to start the interactive fuzzy session picker.",
    )
    parser.add_argument("-w", "--window", action="store_true", help="Launch session in a new Omarchy terminal window")
    parser.add_argument(
        "-c", "--current-dir", action="store_true", help="Filter sessions to current working directory workspace"
    )
    parser.add_argument("-m", "--mux", "--multiplexer", action="store_true", help="Open session in terminal multiplexer (or new window)")
    parser.add_argument("--tmux", action="store_true", help="Open session specifically in tmux")

    subparsers = parser.add_subparsers(dest="subcommand", help="Available subcommands")

    # list / ls
    p_list = subparsers.add_parser("list", aliases=["ls"], help="List conversation sessions in tabular format")
    p_list.add_argument("-n", "--limit", type=int, default=25, help="Number of sessions to display (default: 25)")
    p_list.add_argument("-c", "--current-dir", action="store_true", help="Filter to current workspace directory")

    # active
    subparsers.add_parser("active", help="Show currently running sessions and PIDs")

    # resume / open
    p_resume = subparsers.add_parser("resume", aliases=["open"], help="Resume a session directly")
    p_resume.add_argument("query", nargs="?", default="1", help="Session index, short ID, or UUID prefix (default: 1)")
    p_resume.add_argument("-u", "--unsafe", action="store_true", help="Launch in unsafe mode (--dangerously-skip-permissions)")
    p_resume.add_argument("-s", "--safe", action="store_true", help="Launch in safe mode with tool prompts (default)")
    p_resume.add_argument("-b", "--sandbox", action="store_true", help="Launch in sandbox mode (--sandbox)")
    p_resume.add_argument("-m", "--mux", "--multiplexer", action="store_true", help="Open session in terminal multiplexer (or new window)")
    p_resume.add_argument("--tmux", action="store_true", help="Open session specifically in tmux")
    p_resume.add_argument("-w", "--window", action="store_true", help="Launch in a new terminal window")
    p_resume.add_argument("--dry-run", action="store_true", help="Print command and workspace without executing")

    # mux / tmux
    p_mux = subparsers.add_parser("mux", aliases=["tmux"], help="Open session in a terminal multiplexer (or new window)")
    p_mux.add_argument("query", nargs="?", default=None, help="Session index, short ID, or UUID prefix (default: interactive picker)")
    p_mux.add_argument("-u", "--unsafe", action="store_true", help="Launch in unsafe mode (--dangerously-skip-permissions)")
    p_mux.add_argument("-s", "--safe", action="store_true", help="Launch in safe mode with tool prompts (default)")
    p_mux.add_argument("-b", "--sandbox", action="store_true", help="Launch in sandbox mode (--sandbox)")
    p_mux.add_argument("-w", "--window", action="store_true", help="Launch multiplexer in a new terminal window")
    p_mux.add_argument("--preferred", choices=["tmux", "zellij", "screen"], help="Preferred multiplexer to use")
    p_mux.add_argument("--dry-run", action="store_true", help="Print command and workspace without executing")

    # search / find
    p_search = subparsers.add_parser("search", aliases=["find"], help="Search transcripts for code, tools, or keywords")
    p_search.add_argument("keyword", help="Search term or keyword")
    p_search.add_argument("-n", "--limit", type=int, default=15, help="Maximum number of sessions to return (default: 15)")
    p_search.add_argument("-c", "--current-dir", action="store_true", help="Filter search to current workspace directory")
    p_search.add_argument("-r", "--resume", action="store_true", help="Prompt to select and resume a matching session")

    # rename
    p_rename = subparsers.add_parser("rename", help="Rename a conversation session title")
    p_rename.add_argument("query", help="Session index, short ID, or UUID prefix")
    p_rename.add_argument("new_title", help="New title for the session")

    # export
    p_export = subparsers.add_parser("export", help="Export session dialogue and tool executions to Markdown")
    p_export.add_argument("query", nargs="?", default="1", help="Session index, short ID, or UUID prefix (default: 1)")
    p_export.add_argument("output", nargs="?", help="Output Markdown filepath (default: ./<title-slug>-<id>.md)")
    p_export.add_argument("--stdout", action="store_true", help="Print Markdown directly to stdout")

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
    elif args.subcommand in ("mux", "tmux"):
        cmd_mux(store, args)
    elif args.subcommand in ("search", "find"):
        cmd_search(store, args)
    elif args.subcommand == "rename":
        cmd_rename(store, args)
    elif args.subcommand == "export":
        cmd_export(store, args)
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
        use_mux = args.mux or args.tmux
        pref = "tmux" if args.tmux else None
        InteractivePicker.run(
            store,
            new_window=args.window,
            initial_filter_cwd=args.current_dir,
            default_mux=use_mux,
            preferred_mux=pref,
        )


if __name__ == "__main__":
    main()
