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

SELECT 
    @PKEY AS PKEY,
    counter,
    value,
    occurrence,
    @DMA_SOURCE_ID AS dma_source_id,
    @DMA_MANUAL_ID AS dma_manual_id
FROM sys.dm_exec_query_optimizer_info;
