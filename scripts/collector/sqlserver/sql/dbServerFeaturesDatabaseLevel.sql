/*
Copyright 2026 Google LLC
*/
SET NOCOUNT ON;
SET LANGUAGE us_english;

DECLARE @PKEY AS VARCHAR(256)
DECLARE @DMA_SOURCE_ID AS VARCHAR(256)
DECLARE @DMA_MANUAL_ID AS VARCHAR(256)

SELECT @PKEY = N'$(pkey)';
SELECT @DMA_SOURCE_ID = N'$(dmaSourceId)';
SELECT @DMA_MANUAL_ID = N'$(dmaManualId)';

IF OBJECT_ID('tempdb..#FeaturesEnabledDbLevel') IS NOT NULL
   DROP TABLE #FeaturesEnabledDbLevel;

CREATE TABLE #FeaturesEnabledDbLevel
(
    database_name nvarchar(255) DEFAULT db_name(),
    feature_name NVARCHAR(255),
    is_enabled_or_used NVARCHAR(1),
    occurance_count INT
);

-- 1. Row Level Security Policies
BEGIN TRY
    exec('INSERT INTO #FeaturesEnabledDbLevel
            SELECT
                db_name(),
                ''Row Level Security Policies (RLS)'',
                CASE WHEN count(*) > 0 THEN ''1'' ELSE ''0'' END,
                CONVERT(int, count(*))
            FROM sys.security_policies
            WHERE is_enabled = 1');
END TRY
BEGIN CATCH
    INSERT INTO #FeaturesEnabledDbLevel VALUES (db_name(), 'Row Level Security Policies (RLS)', '0', 0);
END CATCH;

-- 2. FILESTREAM File Tables
BEGIN TRY
    exec('INSERT INTO #FeaturesEnabledDbLevel
            SELECT
                db_name(),
                ''FILESTREAM File Tables'',
                CASE WHEN count(*) > 0 THEN ''1'' ELSE ''0'' END,
                CONVERT(int, count(*))
            FROM sys.filetables
            WHERE is_enabled = 1');
END TRY
BEGIN CATCH
    INSERT INTO #FeaturesEnabledDbLevel VALUES (db_name(), 'FILESTREAM File Tables', '0', 0);
END CATCH;

-- 3. In-Memory OLTP Tables
BEGIN TRY
    exec('INSERT INTO #FeaturesEnabledDbLevel
            SELECT
                db_name(),
                ''In-Memory OLTP Tables'',
                CASE WHEN count(*) > 0 THEN ''1'' ELSE ''0'' END,
                CONVERT(int, count(*))
            FROM sys.tables
            WHERE is_memory_optimized = 1');
END TRY
BEGIN CATCH
    INSERT INTO #FeaturesEnabledDbLevel VALUES (db_name(), 'In-Memory OLTP Tables', '0', 0);
END CATCH;

-- 4. Temporal Tables
BEGIN TRY
    exec('INSERT INTO #FeaturesEnabledDbLevel
            SELECT
                db_name(),
                ''System-Versioned Temporal Tables'',
                CASE WHEN count(*) > 0 THEN ''1'' ELSE ''0'' END,
                CONVERT(int, count(*))
            FROM sys.tables
            WHERE temporal_type = 2');
END TRY
BEGIN CATCH
    INSERT INTO #FeaturesEnabledDbLevel VALUES (db_name(), 'System-Versioned Temporal Tables', '0', 0);
END CATCH;

-- 5. Change Data Capture (CDC) Tracked Tables
BEGIN TRY
    exec('INSERT INTO #FeaturesEnabledDbLevel
            SELECT
                db_name(),
                ''Change Data Capture (CDC) Tracked Tables'',
                CASE WHEN count(*) > 0 THEN ''1'' ELSE ''0'' END,
                CONVERT(int, count(*))
            FROM sys.tables
            WHERE is_tracked_by_cdc = 1');
END TRY
BEGIN CATCH
    INSERT INTO #FeaturesEnabledDbLevel VALUES (db_name(), 'Change Data Capture (CDC) Tracked Tables', '0', 0);
END CATCH;

-- 6. Columnstore Indexes
BEGIN TRY
    exec('INSERT INTO #FeaturesEnabledDbLevel
            SELECT
                db_name(),
                ''Columnstore Indexes (Clustered or Nonclustered)'',
                CASE WHEN count(*) > 0 THEN ''1'' ELSE ''0'' END,
                CONVERT(int, count(*))
            FROM sys.indexes
            WHERE type IN (5, 6)');
END TRY
BEGIN CATCH
    INSERT INTO #FeaturesEnabledDbLevel VALUES (db_name(), 'Columnstore Indexes (Clustered or Nonclustered)', '0', 0);
END CATCH;

-- 7. Dynamic Data Masking
BEGIN TRY
    exec('INSERT INTO #FeaturesEnabledDbLevel
            SELECT
                db_name(),
                ''Dynamic Data Masking (Masked Columns)'',
                CASE WHEN count(*) > 0 THEN ''1'' ELSE ''0'' END,
                CONVERT(int, count(*))
            FROM sys.masked_columns');
END TRY
BEGIN CATCH
    INSERT INTO #FeaturesEnabledDbLevel VALUES (db_name(), 'Dynamic Data Masking (Masked Columns)', '0', 0);
END CATCH;

-- 8. Service Broker Enabled
BEGIN TRY
    exec('INSERT INTO #FeaturesEnabledDbLevel
            SELECT
                db_name(),
                ''Service Broker Enabled'',
                CASE WHEN is_broker_enabled = 1 THEN ''1'' ELSE ''0'' END,
                CONVERT(int, is_broker_enabled)
            FROM sys.databases
            WHERE name = db_name()');
END TRY
BEGIN CATCH
    INSERT INTO #FeaturesEnabledDbLevel VALUES (db_name(), 'Service Broker Enabled', '0', 0);
END CATCH;

-- Final Payload
SELECT
    '"' + @PKEY + '"' as PKEY,
    '"' + CONVERT(NVARCHAR(MAX), f.database_name) + '"' as database_name,
    '"' + CONVERT(NVARCHAR(MAX), f.feature_name) + '"' as feature_name,
    '"' + CONVERT(NVARCHAR(MAX), f.is_enabled_or_used) + '"' as is_enabled_or_used,
    '"' + CONVERT(NVARCHAR(MAX), f.occurance_count) + '"' as occurance_count,
    '"' + @DMA_SOURCE_ID + '"' as dma_source_id,
    '"' + @DMA_MANUAL_ID + '"' as dma_manual_id
FROM #FeaturesEnabledDbLevel f;

IF OBJECT_ID('tempdb..#FeaturesEnabledDbLevel') IS NOT NULL
   DROP TABLE #FeaturesEnabledDbLevel;
