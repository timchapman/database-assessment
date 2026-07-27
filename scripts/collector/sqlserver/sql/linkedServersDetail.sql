/*
Copyright 2026 Google LLC

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

DECLARE @PKEY AS VARCHAR(256)
DECLARE @CLOUDTYPE AS VARCHAR(256)
DECLARE @PRODUCT_VERSION AS INTEGER
DECLARE @DMA_SOURCE_ID AS VARCHAR(256)
DECLARE @DMA_MANUAL_ID AS VARCHAR(256)

SELECT @PKEY = N'$(pkey)';
SELECT @CLOUDTYPE = 'NONE'
SELECT @PRODUCT_VERSION = CONVERT(INTEGER, PARSENAME(CONVERT(NVARCHAR(255), SERVERPROPERTY('productversion')), 4));
SELECT @DMA_SOURCE_ID = N'$(dmaSourceId)';
SELECT @DMA_MANUAL_ID = N'$(dmaManualId)';

IF UPPER(@@VERSION) LIKE '%AZURE%'
	SELECT @CLOUDTYPE = 'AZURE'

IF OBJECT_ID('tempdb..#LinkedServers') IS NOT NULL
   DROP TABLE #LinkedServers;

CREATE TABLE #LinkedServers (
    name NVARCHAR(255),
    product NVARCHAR(255),
    provider NVARCHAR(255),
    data_source NVARCHAR(MAX),
    location NVARCHAR(255),
    provider_string NVARCHAR(MAX),
    catalog NVARCHAR(255)
);

BEGIN TRY
    INSERT INTO #LinkedServers
    SELECT
        name, product, provider, data_source, location, provider_string, catalog
    FROM sys.servers
    WHERE is_linked = 1 AND server_id <> 0;
END TRY
BEGIN CATCH
    WAITFOR DELAY '00:00:00';
END CATCH;

IF NOT EXISTS (SELECT 1 FROM #LinkedServers)
BEGIN
    INSERT INTO #LinkedServers VALUES (
        'NONE_CONFIGURED', 'N/A', 'N/A', 'N/A', 'N/A', 'N/A', 'N/A'
    );
END;

SELECT
    '"' + @PKEY + '"' AS pkey,
    '"' + CONVERT(NVARCHAR(MAX), name) + '"' as name,
    '"' + CONVERT(NVARCHAR(MAX), product) + '"' as product,
    '"' + CONVERT(NVARCHAR(MAX), provider) + '"' as provider,
    '"' + CONVERT(NVARCHAR(MAX), data_source) + '"' as data_source,
    '"' + CONVERT(NVARCHAR(MAX), location) + '"' as location,
    '"' + CONVERT(NVARCHAR(MAX), provider_string) + '"' as provider_string,
    '"' + CONVERT(NVARCHAR(MAX), catalog) + '"' as catalog,
    '"' + @DMA_SOURCE_ID + '"' as dma_source_id,
    '"' + @DMA_MANUAL_ID + '"' as dma_manual_id
FROM #LinkedServers;

IF OBJECT_ID('tempdb..#LinkedServers') IS NOT NULL
   DROP TABLE #LinkedServers;
