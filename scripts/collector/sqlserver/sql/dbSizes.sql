/*
Copyright 2026 Google LLC
*/
SET NOCOUNT ON;
SET LANGUAGE us_english;

DECLARE @PKEY AS VARCHAR(256)
DECLARE @ASSESSMENT_DATABSE_NAME AS VARCHAR(256)
DECLARE @DMA_SOURCE_ID AS VARCHAR(256)
DECLARE @DMA_MANUAL_ID AS VARCHAR(256)

SELECT @PKEY = N'$(pkey)';
SELECT @ASSESSMENT_DATABSE_NAME = N'$(database)';
SELECT @DMA_SOURCE_ID = N'$(dmaSourceId)';
SELECT @DMA_MANUAL_ID = N'$(dmaManualId)';

IF @ASSESSMENT_DATABSE_NAME = 'all'
   SELECT @ASSESSMENT_DATABSE_NAME = '%'

BEGIN TRY
    DECLARE @tableCount INT, @functionCount INT, @viewCount INT, @procCount INT, @trigCount INT;

    SELECT @tableCount = COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0;
    SELECT @functionCount = COUNT(*) FROM sys.objects WHERE type IN ('FN', 'IF', 'TF') AND is_ms_shipped = 0;
    SELECT @viewCount = COUNT(*) FROM sys.views WHERE is_ms_shipped = 0;
    SELECT @procCount = COUNT(*) FROM sys.procedures WHERE is_ms_shipped = 0;
    SELECT @trigCount = COUNT(*) FROM sys.triggers WHERE is_ms_shipped = 0;

    SELECT
        '"' + @PKEY + '"' as PKEY,
        '"' + CONVERT(NVARCHAR(255), db_name()) + '"' as database_name,
        '"' + CONVERT(NVARCHAR(255), type_desc) + '"' as type_desc,
        '"' + CONVERT(NVARCHAR(255), SUM(size/128.0)) + '"' as current_size_mb,
        '"' + CONVERT(NVARCHAR(255), recovery_model_desc) + '"' as recovery_model_desc,
        '"' + CONVERT(NVARCHAR(255), @tableCount) + '"' as table_count,
        '"' + CONVERT(NVARCHAR(255), @functionCount) + '"' as function_count,
        '"' + CONVERT(NVARCHAR(255), @viewCount) + '"' as view_count,
        '"' + CONVERT(NVARCHAR(255), @procCount) + '"' as procedure_count,
        '"' + CONVERT(NVARCHAR(255), @trigCount) + '"' as trigger_count,
        '"' + @DMA_SOURCE_ID + '"' as dma_source_id,
        '"' + @DMA_MANUAL_ID + '"' as dma_manual_id
    FROM sys.database_files sm
    CROSS JOIN sys.databases d
    WHERE d.name = db_name()
      AND sm.type IN (0,1)
    GROUP BY sm.type_desc, d.recovery_model_desc;
END TRY
BEGIN CATCH
    SELECT
        '"' + @PKEY + '"' as PKEY,
        '"' + CONVERT(NVARCHAR(255), db_name()) + '"' as database_name,
        'N/A' as type_desc,
        '0' as current_size_mb,
        'N/A' as recovery_model_desc,
        '0' as table_count,
        '0' as function_count,
        '0' as view_count,
        '0' as procedure_count,
        '0' as trigger_count,
        '"' + @DMA_SOURCE_ID + '"' as dma_source_id,
        '"' + @DMA_MANUAL_ID + '"' as dma_manual_id;
END CATCH;
