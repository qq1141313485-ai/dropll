import json
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path

from match_data_audit import SHANGHAI, append_history


class MatchDataAuditHistoryTest(unittest.TestCase):
    def test_history_drops_expired_and_invalid_records(self) -> None:
        now = datetime.now(SHANGHAI)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "history.jsonl"
            path.write_text(
                "\n".join(
                    [
                        json.dumps(
                            {
                                "checkedAt": (
                                    now - timedelta(days=10)
                                ).isoformat(),
                                "ok": True,
                            }
                        ),
                        "not-json",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )

            append_history(
                path,
                {"checkedAt": now.isoformat(), "ok": True},
                retention_days=8,
            )

            records = [
                json.loads(line)
                for line in path.read_text(encoding="utf-8").splitlines()
            ]
            self.assertEqual(len(records), 1)
            self.assertEqual(records[0]["checkedAt"], now.isoformat())


if __name__ == "__main__":
    unittest.main()
