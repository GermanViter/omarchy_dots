import hashlib
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, call, patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import report_usage as usage  # noqa: E402


class PacingTests(unittest.TestCase):
    """The usage endpoint refuses callers that ask too often, so these rules keep its data coming."""

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        gate = patch.object(usage, "GATE", Path(folder.name) / "gate.json")
        gate.start()
        self.addCleanup(gate.stop)
        self.now = 1000.0
        clock = patch.object(usage.time, "time", lambda: self.now)
        clock.start()
        self.addCleanup(clock.stop)

    def at(self, now, forced=False):
        self.now = now
        return usage.claim(forced)

    def test_hooks_ask_once_per_interval_and_back_off_after_failures(self):
        self.assertTrue(self.at(1000))
        self.assertFalse(self.at(1000), "a parallel hook must not ask too")
        start = 1000
        for wait in (120, 240, 480, 900, 900):
            usage.settle(False)
            self.assertFalse(self.at(start + wait - 1))
            self.assertTrue(self.at(start + wait))
            start += wait
        usage.settle(True)
        self.assertTrue(self.at(start + 120), "a success goes back to the normal interval")
        usage.settle(False, retry_after=1800)
        self.assertFalse(self.at(start + 120 + 1799), "a longer Retry-After is kept")

    def test_a_click_asks_during_back_off_but_not_twice_in_30_seconds(self):
        self.at(1000)
        usage.settle(False)
        usage.settle(False)  # Hooks now wait 4 minutes.
        self.assertTrue(self.at(1030, forced=True))
        self.assertFalse(self.at(1059, forced=True))
        self.assertFalse(self.at(1150), "a click does not shorten the hooks' wait")


class LoginTests(unittest.TestCase):
    def test_keychain_name_follows_claude_codes_rule(self):
        cases = [
            ({}, Path.home() / ".claude", ""),
            ({"CLAUDE_CONFIG_DIR": "/work/claude"}, Path("/work/claude"), "/work/claude"),
            ({"CLAUDE_CONFIG_DIR": "/work/claude", "CLAUDE_SECURESTORAGE_CONFIG_DIR": ""}, Path.home() / ".claude", ""),
        ]
        for env, folder, hashed in cases:
            clean = {k: v for k, v in os.environ.items() if k not in ("CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR")}
            with patch.dict(os.environ, {**clean, **env}, clear=True):
                suffix = f"-{hashlib.sha256(hashed.encode()).hexdigest()[:8]}" if hashed else ""
                self.assertEqual(usage.claude_login(), (folder, f"Claude Code-credentials{suffix}"), env)


class TlsTests(unittest.TestCase):
    def test_system_certificates_are_used_only_when_python_has_none(self):
        for count, expected in ((0, [call(usage.SYSTEM_CAS)]), (128, [])):
            context = MagicMock()
            context.cert_store_stats.return_value = {"x509_ca": count}
            with patch("ssl.create_default_context", return_value=context), patch.object(usage.os.path, "exists", return_value=True):
                self.assertIs(usage.tls_context(), context)
            self.assertEqual(context.load_verify_locations.call_args_list, expected, count)


if __name__ == "__main__":
    unittest.main()
