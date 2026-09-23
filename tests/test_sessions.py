"""Unit tests for agy-sessions."""

import os
import shutil
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

# Add bin and src to path
REPO_ROOT = Path(__file__).parent.parent
sys.path.insert(0, str(REPO_ROOT / "src"))

import agy_sessions.cli as cli


class TestSessionManager(unittest.TestCase):
    def setUp(self):
        self.store = cli.SessionStore()

    def test_list_sessions_returns_data(self):
        sessions = self.store.list_sessions()
        self.assertIsInstance(sessions, list)
        if sessions:
            first = sessions[0]
            self.assertIsInstance(first.conversation_id, str)
            self.assertGreaterEqual(len(first.conversation_id), 8)

    def test_relative_time_formatting(self):
        import datetime as dt
        now = dt.datetime.now(dt.timezone.utc)
        self.assertEqual(cli.relative_time(now), "just now")
        self.assertEqual(cli.relative_time(now - dt.timedelta(minutes=5)), "5m ago")
        self.assertEqual(cli.relative_time(now - dt.timedelta(hours=3)), "3h ago")
        self.assertEqual(cli.relative_time(now - dt.timedelta(days=4)), "4d ago")
        self.assertEqual(cli.relative_time(None), "never")
        epoch_zero = dt.datetime.fromtimestamp(0, tz=dt.timezone.utc)
        self.assertEqual(cli.relative_time(epoch_zero), "never")

    def test_session_query_resolution(self):
        sessions = self.store.list_sessions()
        if not sessions:
            self.skipTest("No sessions found to test query resolution")

        # 1. By index 1
        s1 = self.store.get_session("1")
        self.assertIsNotNone(s1)
        self.assertEqual(s1.conversation_id, sessions[0].conversation_id)

        # 2. By short id prefix
        short_id = sessions[0].short_id
        s2 = self.store.get_session(short_id)
        self.assertIsNotNone(s2)
        self.assertEqual(s2.conversation_id, sessions[0].conversation_id)

    def test_preview_rendering(self):
        sessions = self.store.list_sessions()
        if not sessions:
            self.skipTest("No sessions found to test preview rendering")
        preview = cli.TranscriptViewer.render_preview(sessions[0], self.store.base_dir)
        self.assertIn("Session ID :", preview)
        self.assertIn("Turns/Steps:", preview)

    def test_fzf_output_parsing(self):
        # Case 1: Enter was pressed (first line empty string, second line selected item)
        stdout_enter = "\n🟢  1 │ 3ffa82ad │ just now │ 163 steps │ Session Title\t3ffa82ad-5c97-4cca-9109-70f724bb5a6b\n"
        lines = stdout_enter.splitlines()
        self.assertGreaterEqual(len(lines), 2)
        key = lines[0].strip()
        selected = lines[1].strip()
        self.assertEqual(key, "")  # Enter key
        self.assertIn("3ffa82ad-5c97-4cca-9109-70f724bb5a6b", selected)

        # Case 2: Hotkey was pressed (e.g. ctrl-u)
        stdout_hotkey = "ctrl-u\n🟢  1 │ 3ffa82ad │ just now │ 163 steps │ Session Title\t3ffa82ad-5c97-4cca-9109-70f724bb5a6b\n"
        lines_hk = stdout_hotkey.splitlines()
        self.assertGreaterEqual(len(lines_hk), 2)
        key_hk = lines_hk[0].strip()
        selected_hk = lines_hk[1].strip()
        self.assertEqual(key_hk, "ctrl-u")
        self.assertIn("3ffa82ad-5c97-4cca-9109-70f724bb5a6b", selected_hk)

    def test_workspace_matching(self):
        ws = "/home/mrworld/Work/agy-sessions"
        exact = Path("/home/mrworld/Work/agy-sessions")
        sub = Path("/home/mrworld/Work/agy-sessions/src/agy_sessions")
        other = Path("/home/mrworld/Work/omarchy")
        home = Path("/home/mrworld")

        self.assertTrue(cli.is_in_workspace(ws, exact))
        self.assertTrue(cli.is_in_workspace(ws, sub))
        self.assertFalse(cli.is_in_workspace(ws, other))
        self.assertFalse(cli.is_in_workspace(ws, home))
        self.assertFalse(cli.is_in_workspace("", exact))

    def test_rename_session_in_database(self):
        tmp_dir = Path(tempfile.mkdtemp())
        try:
            db_file = tmp_dir / "conversation_summaries.db"
            conn = sqlite3.connect(db_file)
            cur = conn.cursor()
            cur.execute("""
                CREATE TABLE conversation_summaries (
                    conversation_id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    preview TEXT NOT NULL DEFAULT '',
                    step_count INTEGER NOT NULL DEFAULT 0,
                    last_modified_time TEXT NOT NULL,
                    workspace_uris TEXT NOT NULL DEFAULT '[]',
                    parent_conversation_id TEXT NOT NULL DEFAULT ''
                )
            """)
            cur.execute("""
                INSERT INTO conversation_summaries (conversation_id, title, last_modified_time)
                VALUES ('test-1234-abcd', 'Original Title', '2026-09-20T10:00:00Z')
            """)
            conn.commit()
            conn.close()

            custom_store = cli.SessionStore(base_dir=tmp_dir)
            session = custom_store.get_session("test-1234")
            self.assertIsNotNone(session)
            self.assertEqual(session.title, "Original Title")

            success = custom_store.rename_session(session, "Brand New Name")
            self.assertTrue(success)
            self.assertEqual(session.title, "Brand New Name")

            # Verify persisted in SQLite
            conn = sqlite3.connect(db_file)
            cur = conn.cursor()
            cur.execute("SELECT title FROM conversation_summaries WHERE conversation_id = 'test-1234-abcd'")
            row = cur.fetchone()
            conn.close()
            self.assertEqual(row[0], "Brand New Name")
        finally:
            shutil.rmtree(tmp_dir, ignore_errors=True)

    def test_export_markdown_generation(self):
        sessions = self.store.list_sessions()
        if not sessions:
            self.skipTest("No sessions available for export test")
        s = sessions[0]
        md = cli.TranscriptViewer.export_markdown(s, self.store.base_dir)
        self.assertIn(f"# {s.display_title}", md)
        self.assertIn(f"- **Session ID**: `{s.conversation_id}`", md)
        self.assertIn(f"- **Workspace**:", md)

    def test_search_transcripts(self):
        results = cli.TranscriptViewer.search_transcripts(self.store, "AppLibrary", limit=5)
        self.assertIsInstance(results, list)
        if results:
            first_session, matches = results[0]
            self.assertIsInstance(first_session, cli.Session)
            self.assertGreater(len(matches), 0)
            step_idx, role, snippet = matches[0]
            self.assertIsInstance(step_idx, int)
            self.assertIsInstance(role, str)
            self.assertIsInstance(snippet, str)

    def test_multiplexer_detection_system(self):
        name, status, path = cli.MultiplexerManager.detect()
        # tmux is installed on this machine
        if shutil.which("tmux"):
            self.assertIn(name, ["tmux", "zellij", "screen"])
            self.assertIn(status, ["active", "installed"])
            self.assertIsNotNone(path)

    def test_multiplexer_detection_active_env(self):
        old_env = os.environ.copy()
        try:
            # 1. TMUX active
            os.environ["TMUX"] = "/tmp/tmux-1000/default,1234,0"
            os.environ.pop("ZELLIJ", None)
            os.environ.pop("STY", None)
            name, status, _ = cli.MultiplexerManager.detect()
            self.assertEqual(name, "tmux")
            self.assertEqual(status, "active")

            # 2. ZELLIJ active
            os.environ.pop("TMUX", None)
            os.environ["ZELLIJ"] = "0"
            name, status, _ = cli.MultiplexerManager.detect()
            self.assertEqual(name, "zellij")
            self.assertEqual(status, "active")

            # 3. SCREEN active
            os.environ.pop("ZELLIJ", None)
            os.environ["STY"] = "1234.pts-0.host"
            name, status, _ = cli.MultiplexerManager.detect()
            self.assertEqual(name, "screen")
            self.assertEqual(status, "active")
        finally:
            os.environ.clear()
            os.environ.update(old_env)

    def test_multiplexer_fallback_when_none(self):
        real_which = shutil.which
        try:
            shutil.which = lambda name: None
            old_env = os.environ.copy()
            for k in ["TMUX", "ZELLIJ", "ZELLIJ_SESSION_NAME", "STY"]:
                os.environ.pop(k, None)

            name, status, path = cli.MultiplexerManager.detect()
            self.assertIsNone(name)
            self.assertEqual(status, "none")
            self.assertIsNone(path)

            label = cli.MultiplexerManager.get_menu_label()
            self.assertIn("New Terminal Window", label)
        finally:
            shutil.which = real_which
            os.environ.clear()
            os.environ.update(old_env)

    def test_multiplexer_launch_dry_run(self):
        sessions = self.store.list_sessions()
        if not sessions:
            self.skipTest("No sessions available for multiplexer launch test")
        s = sessions[0]
        # Should not raise exception
        cli.MultiplexerManager.launch(s, mode="safe", dry_run=True)
        cli.MultiplexerManager.launch(s, mode="unsafe", dry_run=True)
        cli.MultiplexerManager.launch(s, mode="sandbox", force_new_window=True, dry_run=True)


if __name__ == "__main__":
    unittest.main()
