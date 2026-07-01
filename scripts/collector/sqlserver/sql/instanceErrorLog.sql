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

IF OBJECT_ID('tempdb..#ErrLog') IS NOT NULL 
    DROP TABLE #ErrLog;

CREATE TABLE #ErrLog (
    LogDate DATETIME,
    ProcessInfo VARCHAR(255),
    Text NVARCHAR(MAX)
);

INSERT INTO #ErrLog
EXEC master.dbo.xp_readerrorlog 0, 1, NULL, NULL, NULL, NULL, N'desc';

SELECT TOP 500
    @PKEY AS PKEY,
    LogDate AS [timestamp],
    ProcessInfo AS [process_info],
    Text AS [log_message],
    @DMA_SOURCE_ID AS dma_source_id,
    @DMA_MANUAL_ID AS dma_manual_id
FROM #ErrLog
ORDER BY LogDate DESC;

IF OBJECT_ID('tempdb..#ErrLog') IS NOT NULL 
    DROP TABLE #ErrLog;
