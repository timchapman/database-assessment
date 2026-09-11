/*
-- Author: Tim Chapman
Copyright 2024 Google LLC

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

*/

SET NOCOUNT ON;
SET LANGUAGE us_english;

DECLARE @PKEY AS VARCHAR(256);
DECLARE @DMA_SOURCE_ID AS VARCHAR(256);
DECLARE @DMA_MANUAL_ID AS VARCHAR(256);

SELECT @PKEY = N'$(pkey)';
SELECT @DMA_SOURCE_ID = N'$(dmaSourceId)';
SELECT @DMA_MANUAL_ID = N'$(dmaManualId)';

BEGIN TRY
    SELECT
        '"' + @PKEY + '"' as PKEY,
        '"' + CONVERT(NVARCHAR(255), d.name) + '"' as database_name,
        '"' + CONVERT(NVARCHAR(255), mf.type_desc) + '"' as type_desc,
        '"' + CONVERT(NVARCHAR(255), SUM(mf.size / 128.0)) + '"' as current_size_mb,
        '"' + @DMA_SOURCE_ID + '"' as dma_source_id,
        '"' + @DMA_MANUAL_ID + '"' as dma_manual_id,
        '"' + CONVERT(NVARCHAR(255), d.recovery_model_desc) + '"' as recovery_model_desc
    FROM sys.master_files mf
    INNER JOIN sys.databases d ON mf.database_id = d.database_id
    WHERE d.name NOT IN ('master', 'model', 'msdb', 'distribution', 'reportserver', 'reportservertempdb', 'resource', 'rdsadmin')
      AND d.state = 0
      AND d.is_read_only = 0
    GROUP BY d.name, mf.type_desc, d.recovery_model_desc;
END TRY
BEGIN CATCH
    SELECT
        host_name() as host_name,
        db_name() as database_name,
        'dbSizes' as module_name,
        SUBSTRING(CONVERT(NVARCHAR(255),ERROR_NUMBER()),1,254) as error_number,
        SUBSTRING(CONVERT(NVARCHAR(255),ERROR_SEVERITY()),1,254) as error_severity,
        SUBSTRING(CONVERT(NVARCHAR(255),ERROR_STATE()),1,254) as error_state,
        SUBSTRING(CONVERT(NVARCHAR(255),ERROR_MESSAGE()),1,512) as error_message;
END CATCH;
