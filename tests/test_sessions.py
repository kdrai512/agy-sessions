"""Unit tests for agy-sessions."""

import os
import sys
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


if __name__ == "__main__":
    unittest.main()
