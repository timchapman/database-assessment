/*
Copyright 2026 Google LLC
*/
SET NOCOUNT ON;
SET LANGUAGE us_english;

DECLARE @PKEY AS VARCHAR(256)
DECLARE @DMA_SOURCE_ID AS VARCHAR(256)
DECLARE @DMA_MANUAL_ID AS VARCHAR(256)
DECLARE @MACHINENAME AS NVARCHAR(256)

SELECT @PKEY = N'$(pkey)';
SELECT @DMA_SOURCE_ID = N'$(dmaSourceId)';
SELECT @DMA_MANUAL_ID = N'$(dmaManualId)';
SELECT @MACHINENAME = CONVERT(NVARCHAR(256), SERVERPROPERTY('MachineName'));

SELECT 
    '"' + @PKEY + '"' AS pkey,
    '"' + @DMA_SOURCE_ID + '"' AS dma_source_id,
    '"' + @DMA_MANUAL_ID + '"' AS dma_manual_id,
    '"' + @MACHINENAME + '"' AS MachineName,
    '"' + CONVERT(NVARCHAR(255), socket_count) + '"' AS PhysicalCpuCount,
    '"' + CONVERT(NVARCHAR(255), cpu_count) + '"' AS LogicalCpuCount,
    '"' + CONVERT(NVARCHAR(255), physical_memory_kb / 1024) + '"' AS TotalOSMemoryMB
FROM sys.dm_os_sys_info;
