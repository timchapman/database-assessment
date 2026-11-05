# Author: Tim Chapman
"""TDD Seam Verification for SQL Server Collector Files in database-assessment."""

import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).parents[1]
SQL_DIR = REPO_ROOT / "scripts" / "collector" / "sqlserver" / "sql"
PS_DIR = REPO_ROOT / "scripts" / "collector" / "sqlserver"

NEW_SQL_FILES = {
    "azureDbResourceStats.sql": "AzureDbResourceStats",
    "azureElasticPoolStats.sql": "AzureElasticPoolStats",
    "azureResourceGovernance.sql": "AzureResourceGovernance",
    "azureResourceStats.sql": "AzureResourceStats",
    "batchFootprint.sql": "BatchFootprint",
    "cpuUsage.sql": "CpuUsage",
    "deprecatedFeatures.sql": "DeprecatedFeatures",
    "fileIoLatency.sql": "FileIoLatency",
    "instanceErrorLog.sql": "InstanceErrorLog",
    "machineSpecsTsql.sql": "DbMachineSpecs",
    "memoryClerks.sql": "MemoryClerks",
    "memorySizing.sql": "MemorySizing",
    "memoryUsage.sql": "MemoryUsage",
    "queryOptimizerInfo.sql": "QueryOptimizerInfo",
    "sqlAgentJobs.sql": "SqlAgentJobs",
    "tsqlPostgresDeepScanner.sql": "PostgresMigrationIssues",
    "waitsStats.sql": "WaitsStats",
}

UPDATED_SQL_FILES = {
    "dbServerFeatures.sql": "BlockFeatures",
    "dbServerFeaturesDatabaseLevel.sql": "DatabaseLevelBlockFeatures",
    "serverProperties.sql": "ServerProps",
    "dbSizes.sql": "DbSizes",
    "userConnectionInfo.sql": "UserConnections",
    "linkedServersDetail.sql": "LinkedSrvrs",
}


class TestSqlServerCollectorSeams(unittest.TestCase):
    def test_17_new_sql_files_exist_and_have_author_headers(self) -> None:
        """Verify that all 17 new SQL files exist and include author and copyright headers."""
        for filename in NEW_SQL_FILES:
            file_path = SQL_DIR / filename
            self.assertTrue(file_path.is_file(), f"Missing expected SQL query file: {filename}")
            content = file_path.read_text(encoding="utf-8")
            self.assertIn("-- Author: Tim Chapman", content, f"Missing author header in {filename}")
            self.assertIn("Google LLC", content, f"Missing copyright header in {filename}")

    def test_instance_review_invokes_all_new_and_updated_sql_files_with_opdb_long_filenames(self) -> None:
        """Verify instanceReview.ps1 executes all 17 new and 6 updated SQL files using opdb__<Key> long filenames."""
        driver_path = PS_DIR / "instanceReview.ps1"
        content = driver_path.read_text(encoding="utf-8")

        self.assertIn('$op_version = "4.3.48"', content)
        self.assertNotIn("Update-DmaManifest", content)
        self.assertNotIn("dma_manifest.json", content)
        self.assertEqual(
            len(re.findall(r"^\s*function\s+sqlcmd\b", content, flags=re.MULTILINE)),
            1,
            "instanceReview.ps1 must define function sqlcmd exactly once",
        )

        for sql_file, key in {**NEW_SQL_FILES, **UPDATED_SQL_FILES}.items():
            self.assertIn(
                f"sql\\{sql_file}",
                content,
                f"instanceReview.ps1 must invoke sql\\{sql_file}",
            )
            self.assertIn(
                f"'opdb' + '__' + '{key}' + $outputFileSuffix",
                content,
                f"instanceReview.ps1 must define standard long filename opdb__{key}",
            )

    def test_sql_defensive_casts_and_div_by_zero_guards(self) -> None:
        """Verify XML cast and memory_model column in memorySizing.sql and NULLIF guards in waitsStats/batchFootprint."""
        memory_sizing = (SQL_DIR / "memorySizing.sql").read_text(encoding="utf-8")
        self.assertIn("CAST(r.record AS XML).value", memory_sizing)
        self.assertIn("pm.locked_page_allocations_kb", memory_sizing)
        self.assertNotIn("process_memory_model_desc", memory_sizing)

        waits_stats = (SQL_DIR / "waitsStats.sql").read_text(encoding="utf-8")
        self.assertIn("NULLIF(SUM ([wait_time_ms]) OVER(), 0)", waits_stats)

        batch_footprint = (SQL_DIR / "batchFootprint.sql").read_text(encoding="utf-8")
        self.assertIn("NULLIF(SUM(btime.cntr_value) OVER (), 0)", batch_footprint)

    def test_instance_error_log_pii_sanitization(self) -> None:
        """Verify that instanceErrorLog.sql excludes login failures and password patterns."""
        file_path = SQL_DIR / "instanceErrorLog.sql"
        self.assertTrue(file_path.is_file(), "instanceErrorLog.sql is missing")
        content = file_path.read_text(encoding="utf-8")
        self.assertIn("Login failed", content, "instanceErrorLog.sql must explicitly filter out Login failed entries")
        self.assertIn("password", content.lower(), "instanceErrorLog.sql must filter out password traces")

    def test_existing_sql_files_preserved_intact(self) -> None:
        """Verify that existing upstream SQL files (including dbServerDmvPerfmon.sql) remain present."""
        perfmon_path = SQL_DIR / "dbServerDmvPerfmon.sql"
        self.assertTrue(perfmon_path.is_file(), "dbServerDmvPerfmon.sql must remain intact as in upstream/main")
        for filename in UPDATED_SQL_FILES:
            self.assertTrue((SQL_DIR / filename).is_file(), f"Existing SQL file missing: {filename}")

    def test_powershell_driver_has_author_header(self) -> None:
        """Verify that modified instanceReview.ps1 contains the author header."""
        file_path = PS_DIR / "instanceReview.ps1"
        self.assertTrue(file_path.is_file(), "Missing PowerShell script: instanceReview.ps1")
        content = file_path.read_text(encoding="utf-8")
        self.assertIn("# Author: Tim Chapman", content, "Missing author header in instanceReview.ps1")

    def test_instance_review_csv_headers_match_downstream_column_counts(self) -> None:
        """Verify that every CSV header written by instanceReview.ps1 matches DMAUpload column counts."""
        expected_var_col_counts = {
            "compFileName": 8,
            "srvFileName": 5,
            "dbServerFlags": 7,
            "blockingFeatures": 6,
            "linkedServers": 10,
            "dbClusterNodes": 6,
            "dbccTraceFlg": 7,
            "cpuUsageFileName": 6,
            "memoryUsageFileName": 12,
            "memorySizingFileName": 14,
            "memoryClerksFileName": 6,
            "batchFootprintFileName": 9,
            "waitsStats": 12,
            "queryOptimizerInfo": 6,
            "fileIoLatency": 17,
            "instanceErrorLog": 6,
            "deprecatedFeatures": 5,
            "diskVolumeInfo": 10,
            "dbServerConfig": 10,
            "tranLogBkupCountByDayByHour": 31,
            "tranLogBkupSizeByDayByHour": 31,
            "sqlAgentJobs": 16,
            "userConnectionList": 24,
            "dbsizes": 7,
            "dbServerDmvPerfmon": 27,
            "objectList": 11,
            "tableList": 21,
            "indexList": 22,
            "columnDatatypes": 17,
            "databaseLevelBlockingFeatures": 7,
            "deepScanner": 10,
            "azureDbRes": 11,
            "azureRes": 13,
            "azureGov": 10,
            "azurePool": 10,
            "computerSpecsFile": 7,
        }
        driver_content = (PS_DIR / "instanceReview.ps1").read_text(encoding="utf-8")
        pattern = re.compile(r"Set-Content\s+-Path\s+\$foldername\\\$(\w+)\s+-Encoding\s+utf8\s+-Value\s+'([^']+)'")
        found_headers = dict(pattern.findall(driver_content))
        for var_name, expected_cols in expected_var_col_counts.items():
            self.assertIn(var_name, found_headers, f"Missing Set-Content header for ${var_name}")
            actual_cols = len(found_headers[var_name].split("|"))
            self.assertEqual(
                actual_cols,
                expected_cols,
                f"Column count mismatch for ${var_name}: expected {expected_cols}, got {actual_cols}",
            )

    def test_no_unescaped_sqlcmd_variables_in_sql_scripts(self) -> None:
        """Verify that no SQL file contains unescaped $(...) tokens that break sqlcmd variable substitution."""
        allowed_vars = {
            "$(pkey)",
            "$(dmaSourceId)",
            "$(dmaManualId)",
            "$(database)",
            "$(hasdbaccess)",
            "$(cloudtype)",
            "$(collectionUser)",
            "$(collectionPass)",
        }
        for sql_path in sorted(SQL_DIR.glob("*.sql")):
            content = sql_path.read_text(encoding="utf-8")
            for idx, line in enumerate(content.splitlines(), 1):
                for match in re.finditer(r"\$\([^)]*\)|\$\([^\s']*'", line):
                    token = match.group(0)
                    self.assertIn(
                        token,
                        allowed_vars,
                        f"Unescaped sqlcmd variable pattern {token} in {sql_path.name}:{idx}",
                    )

    def test_db_server_features_cloud_sql_blockers_and_false_positive_guards(self) -> None:
        """Verify all Cloud SQL unsupported feature/operation checks and false-positive guards in dbServerFeatures.sql and dbServerFeaturesDatabaseLevel.sql."""
        content = (SQL_DIR / "dbServerFeatures.sql").read_text(encoding="utf-8")
        for feature_name in (
            "Performance Data Collector",
            "ContainedAGCount",
            "IntegratedAccelerationEnabled",
            "AzureSQLMILinkActive",
            "AzureDevOpsServerHost",
            "ExternalLanguagesRegistered",
            "BackupsToAzureBlobStorage",
            "BackupsToObjectStorage",
            "IsTDS80Used",
            "in-memory-oltp",
            "IsDACEnabled",
            "IsDTCInUse",
            "IsPMEMEnabled",
            "IsHybridBufferPoolDirectWriteEnabled",
            "IsMultiWriteReplicationUsed",
            "UserCertificatesUsed",
            "RESTORE",
        ):
            self.assertIn(feature_name, content, f"Missing feature check {feature_name} in dbServerFeatures.sql")
        self.assertIn("WHERE ISNULL(mode, 0) > 0 OR ISNULL(config_in_use, 0) > 0", content)
        self.assertIn("WHERE el.principal_id <> 4 OR elf.content IS NOT NULL", content)
        self.assertIn("INNER JOIN sys.database_principals pr ON dp.grantee_principal_id = pr.principal_id", content)
        self.assertIn("transaction_type = 4 OR ISNULL(dtc_state, 0) > 0", content)

        db_content = (SQL_DIR / "dbServerFeaturesDatabaseLevel.sql").read_text(encoding="utf-8")
        for db_feature in (
            "RealTimeOperationalAnalyticsUsed",
            "UserCertificatesUsed",
            "RESTORE",
        ):
            self.assertIn(
                db_feature, db_content, f"Missing DB feature check {db_feature} in dbServerFeaturesDatabaseLevel.sql"
            )
        self.assertIn("INNER JOIN sys.database_principals pr ON dp.grantee_principal_id = pr.principal_id", db_content)

    def test_instance_review_error_scan_excludes_collector_logs_and_guards_trap(self) -> None:
        """Verify instanceReview.ps1 excludes collector log files from self-scanning and guards trap InvocationInfo."""
        content = (PS_DIR / "instanceReview.ps1").read_text(encoding="utf-8")
        self.assertIn("-Exclude $logFile, $sqlErrorLogFile", content)
        self.assertIn("COLLECTION_SUMMARY.txt", content)
        self.assertIn("CRASH_REPORT.txt", content)
        self.assertIn("$trappedError.InvocationInfo -and $trappedError.InvocationInfo.Line", content)

    def test_collector_logging_and_telemetry_coverage(self) -> None:
        """Verify bootstrap logging, per-step SQL telemetry, pre-flight permission audit, and sub-script logging."""
        content = (PS_DIR / "instanceReview.ps1").read_text(encoding="utf-8")
        for token in (
            "dma_collector_bootstrap.log",
            "function Write-DmaBootstrapLog",
            "function Invoke-DmaSqlStep",
            "function Invoke-DmaPermissionAudit",
            "[STEP-START]",
            "[STEP-DONE]",
            "[STEP-ERROR]",
            "[PERM-AUDIT]",
            "[PERM-WARN]",
            "STEP EXECUTION TELEMETRY",
            "CSV OUTPUT MANIFEST",
        ):
            self.assertIn(token, content, f"Missing telemetry/logging token {token} in instanceReview.ps1")

        perfmon_content = (PS_DIR / "dmaSQLServerPerfmonDataset.ps1").read_text(encoding="utf-8")
        self.assertNotIn("$foldername\\$logFile", perfmon_content)
        self.assertIn("$outputDir\\$perfmonLogFile", perfmon_content)

        hw_content = (PS_DIR / "dmaSQLServerHWSpecs.ps1").read_text(encoding="utf-8")
        self.assertIn("PhysicalCPUs=$($csvData.PhysicalCpuCount)", hw_content)
        self.assertIn("$_.Exception.GetType().FullName", hw_content)

    def test_sql_hardening_and_false_positive_guards(self) -> None:
        """Verify parameterized machineSpecsTsql, Azure view names, escaped LIKE wildcards, and safe separator filtering."""
        machine_specs = (SQL_DIR / "machineSpecsTsql.sql").read_text(encoding="utf-8")
        self.assertIn("EXEC sys.sp_executesql", machine_specs)
        self.assertNotIn("EXEC('", machine_specs)

        elastic_pool = (SQL_DIR / "azureElasticPoolStats.sql").read_text(encoding="utf-8")
        self.assertIn("sys.elastic_pool_resource_stats", elastic_pool)
        self.assertNotIn("sys.dm_elastic_pool_resource_stats", elastic_pool)

        deep_scanner = (SQL_DIR / "tsqlPostgresDeepScanner.sql").read_text(encoding="utf-8")
        self.assertIn("'%xp[_]%'", deep_scanner)
        self.assertIn("'%[^#]#[a-zA-Z_]%'", deep_scanner)
        self.assertNotIn("('%#%', 'TEMP_TABLE_LOCAL'", deep_scanner)

        agent_jobs = (SQL_DIR / "sqlAgentJobs.sql").read_text(encoding="utf-8")
        self.assertIn("LEFT JOIN msdb.dbo.syscategories", agent_jobs)
        self.assertIn("'%xp[_]%'", agent_jobs)
        self.assertIn("'%sp[_]OA%'", agent_jobs)

        waits_stats = (SQL_DIR / "waitsStats.sql").read_text(encoding="utf-8")
        self.assertIn("NULLIF(MAX ([W1].[WaitCount]), 0)", waits_stats)
        self.assertIn("'\"' + @PKEY + '\"' AS PKEY", waits_stats)

        driver = (PS_DIR / "instanceReview.ps1").read_text(encoding="utf-8")
        self.assertIn(r"if ($lineStr -match '^[\s\-|]+$')", driver)

    def test_azure_sql_database_mode_two_routed_connections(self) -> None:
        """Verify the -azureSqlDatabase mode: declared platform, one named database, two persistent connections, routed steps."""
        driver = (PS_DIR / "instanceReview.ps1").read_text(encoding="utf-8")
        # D-001 / D-002: explicit switch, mandatory single database, system databases and 'all' rejected
        self.assertIn("[switch]$azureSqlDatabase", driver)
        self.assertIn("-azureSqlDatabase requires -database [database name]", driver)
        self.assertIn("$database -match '^(master|msdb|tempdb|model)$'", driver)
        # D-003r: two SqlClient connections (master + target) opened once, every step routed by its database name
        for name in (
            "New-DmaRoutedSqlConnection",
            "Initialize-DmaAzureSqlDatabaseConnections",
            "Resolve-DmaRoutedConnection",
            "Invoke-DmaRoutedSql",
            "Close-DmaRoutedConnections",
        ):
            self.assertIn(f"function {name}", driver)
        self.assertIn("$script:DmaRoutedConnections = @{ master = $null; target = $null }", driver)
        self.assertIn("System.Data.SqlClient.SqlConnection", driver)
        self.assertNotIn(
            "ChangeDatabase", driver.split("#region Azure SQL Database routed connections")[1].split("#endregion")[0]
        )
        self.assertIn("if (-not ($script:UseEntraOdbcForSqlcmd -or $script:UseAzureSqlDatabaseConnections))", driver)
        # D-004: Entra uses the identical ODBC ActiveDirectoryInteractive connection string as the Managed Instance path
        self.assertIn("function Get-DmaEntraOdbcConnectionString", driver)
        self.assertEqual(driver.count("Get-DmaEntraOdbcConnectionString -ServerInstance"), 2)
        self.assertNotIn("DmaAzureAccessToken", driver)
        self.assertIn("System.Data.Odbc.OdbcDataAdapter($command)", driver)
        # D-005: refused master connection fails at bootstrap with the required grants named
        self.assertIn("##MS_DefinitionReader##, ##MS_SecurityDefinitionReader## and ##MS_ServerStateReader##", driver)
        # EngineEdition confirms the declaration and rejects other platforms
        self.assertIn(
            "-azureSqlDatabase was specified but $ServerInstance reports $label, not Azure SQL Database (EngineEdition 5)",
            driver,
        )
        # Routing: msdb step skipped, database-scoped telemetry on the target, master-side Azure views scoped to the target database
        self.assertIn("Skipping SQL Agent Jobs Info...msdb does not exist on Azure SQL Database", driver)
        self.assertIn('$telemetryDb = if ($azureSqlDatabase) { $databaseNameFilter } else { "master" }', driver)
        for step in (
            "CpuUsage",
            "MemoryUsage",
            "MemorySizing",
            "MemoryClerks",
            "BatchFootprint",
            "WaitsStats",
            "QueryOptimizerInfo",
            "FileIoLatency",
        ):
            self.assertRegex(driver, rf'Invoke-DmaSqlStep -StepName "{step}" [^\n]*-DatabaseName \$telemetryDb')
        self.assertRegex(
            driver,
            r'Invoke-DmaSqlStep -StepName "AzureResourceStats" [^\n]*-DatabaseName "master" [^\n]*-SqlcmdVars \$azureSqlVars',
        )
        self.assertIn("$dbNameArray = @($database)", driver)
        self.assertRegex(driver, r'Invoke-DmaSqlStep -StepName "MachineSpecsTsql" [^\n]*-DatabaseName \$telemetryDb')
        # SQL guards for objects Azure SQL Database does not expose
        self.assertIn(
            "IF CONVERT(INT, SERVERPROPERTY('EngineEdition')) = 5",
            (SQL_DIR / "fileIoLatency.sql").read_text(encoding="utf-8"),
        )
        self.assertIn(
            "sys.database_files AS mf ON vfs.file_id = mf.file_id",
            (SQL_DIR / "fileIoLatency.sql").read_text(encoding="utf-8"),
        )
        self.assertIn(
            "IF CONVERT(INT, SERVERPROPERTY('EngineEdition')) = 5",
            (SQL_DIR / "memorySizing.sql").read_text(encoding="utf-8"),
        )
        self.assertIn(
            "IF CONVERT(INT, SERVERPROPERTY('EngineEdition')) <> 5",
            (SQL_DIR / "dbccTraceFlags.sql").read_text(encoding="utf-8"),
        )
        self.assertIn(
            "WHERE (@DBNAME IN (N'all', N'master', N'') OR database_name = @DBNAME)",
            (SQL_DIR / "azureResourceStats.sql").read_text(encoding="utf-8"),
        )
        self.assertIn("AND DB_NAME() <> 'master'", (SQL_DIR / "getDmaSourceId.sql").read_text(encoding="utf-8"))
        # Column names verified against a live Azure SQL Database (2026-11-05); three-part master. xp_ references are compile errors there
        self.assertIn("used_storage_mb", (SQL_DIR / "azureDbResourceStats.sql").read_text(encoding="utf-8"))
        self.assertIn("max_db_memory / 1024", (SQL_DIR / "azureResourceGovernance.sql").read_text(encoding="utf-8"))
        self.assertIn(
            "sys.dm_user_db_resource_governance AS rg ON rg.database_id = DB_ID()",
            (SQL_DIR / "machineSpecsTsql.sql").read_text(encoding="utf-8"),
        )
        for name in ("componentsInstalled.sql", "instanceErrorLog.sql"):
            self.assertNotRegex((SQL_DIR / name).read_text(encoding="utf-8"), r"(?i)EXEC\s+master\.(sys|dbo)\.xp_")
        # Batch wrapper forwards the switch
        bat = (PS_DIR / "runAssessment.bat").read_text(encoding="utf-8")
        self.assertIn('if /i "%1" == "-azureSqlDatabase" set "azureSqlDbSwitch=-azureSqlDatabase"', bat)
        self.assertEqual(bat.count("CALL %command% %azureSqlDbSwitch%"), 2)
        self.assertEqual(bat.count("CALL %command% -collectVMSpecs %azureSqlDbSwitch%"), 2)


if __name__ == "__main__":
    unittest.main()
