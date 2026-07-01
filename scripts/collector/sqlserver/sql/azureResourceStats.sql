/*
Copyright 2026 Google LLC
*/
SET NOCOUNT ON;
SET LANGUAGE us_english;

DECLARE @PKEY AS VARCHAR(256)
DECLARE @DMA_SOURCE_ID AS VARCHAR(256)
DECLARE @DMA_MANUAL_ID AS VARCHAR(256)
DECLARE @CLOUDTYPE AS VARCHAR(256)

SELECT @PKEY = N'$(pkey)';
SELECT @DMA_SOURCE_ID = N'$(dmaSourceId)';
SELECT @DMA_MANUAL_ID = N'$(dmaManualId)';
SELECT @CLOUDTYPE = 'NONE';

IF UPPER(@@VERSION) LIKE '%AZURE%'
	SELECT @CLOUDTYPE = 'AZURE';

IF @CLOUDTYPE = 'AZURE'
BEGIN
    SELECT
        '"' + @PKEY + '"' AS PKEY,
        '"' + CONVERT(NVARCHAR(MAX), start_time, 121) + '"' AS start_time,
        '"' + CONVERT(NVARCHAR(MAX), end_time, 121) + '"' AS end_time,
        '"' + CONVERT(NVARCHAR(MAX), database_name) + '"' AS database_name,
        '"' + CONVERT(NVARCHAR(MAX), sku) + '"' AS sku,
        '"' + CONVERT(NVARCHAR(MAX), avg_cpu_percent) + '"' AS avg_cpu_percent,
        '"' + CONVERT(NVARCHAR(MAX), avg_data_io_percent) + '"' AS avg_data_io_percent,
        '"' + CONVERT(NVARCHAR(MAX), avg_log_write_percent) + '"' AS avg_log_write_percent,
        '"' + CONVERT(NVARCHAR(MAX), max_worker_percent) + '"' AS max_worker_percent,
        '"' + CONVERT(NVARCHAR(MAX), max_session_percent) + '"' AS max_session_percent,
        '"' + CONVERT(NVARCHAR(MAX), dtu_limit) + '"' AS dtu_limit,
        '"' + @DMA_SOURCE_ID + '"' AS dma_source_id,
        '"' + @DMA_MANUAL_ID + '"' AS dma_manual_id
    FROM sys.resource_stats
    ORDER BY end_time DESC;
END
ELSE
BEGIN
    SELECT TOP 0
        '"' + @PKEY + '"' AS PKEY,
        '' AS start_time,
        '' AS end_time,
        '' AS database_name,
        '' AS sku,
        '' AS avg_cpu_percent,
        '' AS avg_data_io_percent,
        '' AS avg_log_write_percent,
        '' AS max_worker_percent,
        '' AS max_session_percent,
        '' AS dtu_limit,
        '"' + @DMA_SOURCE_ID + '"' AS dma_source_id,
        '"' + @DMA_MANUAL_ID + '"' AS dma_manual_id
    FROM sys.objects;
END
