"""Recorder redaction and private-file permission regressions."""

import stat
import tempfile
import unittest
from pathlib import Path

from record_fixtures import (
    REDACTED_CHALLENGE_ANSWER,
    REDACTED_CLIENT_ID,
    _write_private,
    redact_headers,
    redact_html,
    redact_json_body,
)


class RecorderSafetyTest(unittest.TestCase):
    def test_credential_headers_are_removed(self) -> None:
        safe = redact_headers(
            {
                "Content-Type": "application/json",
                "Cookie": "x",
                "Set-Cookie": "x",
                "Authorization": "x",
                "Location": "x",
            },
            None,
        )
        self.assertEqual(safe, {"Content-Type": "application/json"})

    def test_unknown_headers_are_not_copied(self) -> None:
        safe = redact_headers(
            {
                "Content-Type": "application/json; charset=utf-8",
                "X-Debug-Material": "must-not-be-tracked",
            },
            None,
        )
        self.assertEqual(safe, {"Content-Type": "application/json"})

    def test_html_answer_is_replaced(self) -> None:
        safe = redact_html(
            '<script>var challengeId = "cid"; var answer = 48291;</script>',
            "cid",
            None,
            48291,
        )
        self.assertNotIn("48291", safe)
        self.assertIn(f"var answer = {REDACTED_CHALLENGE_ANSWER}", safe)

    def test_response_body_is_projected_to_allowlist(self) -> None:
        self.assertEqual(
            redact_json_body(
                {"success": True, "client_id": "live-client-id"},
                "live-client-id",
            ),
            {"success": True, "client_id": REDACTED_CLIENT_ID},
        )

    def test_unknown_session_key_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            redact_json_body(
                {
                    "success": True,
                    "client_id": "live-client-id",
                    "session_key": "credential-material",
                },
                "live-client-id",
            )

    def test_unknown_answer_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            redact_json_body(
                {
                    "success": True,
                    "client_id": "live-client-id",
                    "answer": 48291,
                },
                "live-client-id",
            )

    def test_private_file_mode_is_owner_only(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "capture.txt"
            _write_private(path, "private material")
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)


if __name__ == "__main__":
    unittest.main()
