# Author: Tim Chapman
"""TDD Seam Verification for SQL Server Collector Files in database-assessment."""

from pathlib import Path
import unittest

REPO_ROOT = Path(__file__).parents[1]
SQL_DIR = REPO_ROOT / "scripts" / "collector" / "sqlserver" / "sql"
PS_DIR = REPO_ROOT / "scripts" / "collector" / "sqlserver"

NEW_SQL_FILES = [
    "azureDbResourceStats.sql",
    "azureElasticPoolStats.sql",
    "azureResourceGovernance.sql",
    "azureResourceStats.sql",
    "batchFootprint.sql",
    "cpuUsage.sql",
    "deprecatedFeatures.sql",
    "fileIoLatency.sql",
    "instanceErrorLog.sql",
    "machineSpecsTsql.sql",
    "memoryUsage.sql",
    "queryOptimizerInfo.sql",
    "sqlAgentJobs.sql",
    "tsqlPostgresDeepScanner.sql",
    "waitsStats.sql",
]


class TestSqlServerCollectorSeams(unittest.TestCase):

    def test_15_sql_files_exist_and_have_author_headers(self) -> None:
        """Verify that all 15 new SQL files exist and include author and copyright headers."""
        for filename in NEW_SQL_FILES:
            file_path = SQL_DIR / filename
            self.assertTrue(file_path.is_file(), f"Missing expected SQL query file: {filename}")
            content = file_path.read_text(encoding="utf-8")
            self.assertIn("-- Author: Tim Chapman", content, f"Missing author header in {filename}")
            self.assertIn("Google LLC", content, f"Missing copyright header in {filename}")

    def test_instance_error_log_pii_sanitization(self) -> None:
        """Verify that instanceErrorLog.sql excludes login failures and password patterns."""
        file_path = SQL_DIR / "instanceErrorLog.sql"
        self.assertTrue(file_path.is_file(), "instanceErrorLog.sql is missing")
        content = file_path.read_text(encoding="utf-8")
        self.assertIn("Login failed", content, "instanceErrorLog.sql must explicitly filter out Login failed entries")
        self.assertIn("password", content.lower(), "instanceErrorLog.sql must filter out password traces")

    def test_db_server_dmv_perfmon_deleted(self) -> None:
        """Verify that obsolete dbServerDmvPerfmon.sql has been removed from disk."""
        perfmon_path = SQL_DIR / "dbServerDmvPerfmon.sql"
        self.assertFalse(perfmon_path.exists(), "dbServerDmvPerfmon.sql must be deleted (superseded by dedicated queries)")

    def test_powershell_scripts_have_author_header(self) -> None:
        """Verify that modified PowerShell orchestrators contain author headers."""
        ps_scripts = ["instanceReview.ps1", "createUserWithSQLAuth.ps1", "createUserWithWindowsAuth.ps1"]
        for ps_name in ps_scripts:
            file_path = PS_DIR / ps_name
            self.assertTrue(file_path.is_file(), f"Missing PowerShell script: {ps_name}")
            content = file_path.read_text(encoding="utf-8")
            self.assertIn("# Author: Tim Chapman", content, f"Missing author header in {ps_name}")


if __name__ == "__main__":
    unittest.main()
