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
    DB_NAME(vfs.database_id) AS DatabaseName,
    mf.name AS LogicalFileName,
    mf.type_desc AS FileType,
    mf.physical_name AS PhysicalPath,
    vfs.num_of_reads AS TotalReads,
    vfs.num_of_bytes_read / 1024 / 1024 AS DataReadMB,
    vfs.io_stall_read_ms AS TotalReadStallMs,
    CASE 
        WHEN vfs.num_of_reads = 0 THEN 0 
        ELSE vfs.io_stall_read_ms / vfs.num_of_reads 
    END AS AvgReadLatencyMs,
    vfs.num_of_writes AS TotalWrites,
    vfs.num_of_bytes_written / 1024 / 1024 AS DataWrittenMB,
    vfs.io_stall_write_ms AS TotalWriteStallMs,
    CASE 
        WHEN vfs.num_of_writes = 0 THEN 0 
        ELSE vfs.io_stall_write_ms / vfs.num_of_writes 
    END AS AvgWriteLatencyMs,
    vfs.io_stall AS TotalIOStallMs,
    vfs.size_on_disk_bytes / 1024 / 1024 AS SizeOnDiskMB,
    @DMA_SOURCE_ID AS dma_source_id,
    @DMA_MANUAL_ID AS dma_manual_id
FROM 
    sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs
JOIN 
    sys.master_files AS mf ON vfs.database_id = mf.database_id AND vfs.file_id = mf.file_id
ORDER BY 
    TotalIOStallMs DESC;
