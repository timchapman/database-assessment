# Author: Tim Chapman
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
<#
.SYNOPSIS
    Google Database Migration Assessment Collector for Microsoft SQL Server.
.DESCRIPTION
    Executes the necessary scripts to collect metadata, performance metrics, hardware specifications,
    and migration blockers from SQL Server and Perfmon to be uploaded to Google Database Migration Assessment.

    Uses a manifest-based collection engine with short local filenames to prevent Windows MAX_PATH limitations,
    and supports single-prompt Microsoft Entra ID MFA authentication for Azure SQL Managed Instance via ADO.NET.
.PARAMETER serverName
    Connection string in the form of [server name / ip address]\[instance name] (required)
.PARAMETER port
    Connection port (default:1433 / optional)
.PARAMETER database
    Run assessment for a single database (default:all / optional)
.PARAMETER collectionUserName
    Collection username (optional if using Windows Auth or Entra ID)
.PARAMETER collectionUserPass
    Collection username password (optional)
.PARAMETER entraIDUserName
    Microsoft Entra ID username used with Entra ID MFA authentication.
.PARAMETER ignorePerfmon
    Signals if the perfmon collection should be skipped (default:false)
.PARAMETER manualUniqueId
    Tag that can be supplied by the customer to make a collection unique. Maps to internal variable dmaManualId (optional)
.PARAMETER collectVMSpecs
    Whether to explicitly collect VM specs from the hosting VM (default:false)
.PARAMETER useWindowsAuthentication
    Specifies if logging to the database will utilize Windows Authentication (default:false)
.PARAMETER useEntraIDAuthentication
    Specifies if SQL connections will use Microsoft Entra ID interactive MFA authentication.
.PARAMETER outputDirectory
    User-specified output directory if desired to be different from the default
.NOTES
    https://googlecloudplatform.github.io/database-assessment/
#>
Param(
    [Parameter(Mandatory = $true)][string]$serverName = "",
    [Parameter(Mandatory = $false)][string]$port = "default",
    [Parameter(Mandatory = $false)][string]$database = "all",
    [Parameter(Mandatory = $false)][string]$collectionUserName,
    [Parameter(Mandatory = $false)][string]$collectionUserPass,
    [Parameter(Mandatory = $false)][string]$entraIDUserName,
    [Parameter(Mandatory = $false)][string]$ignorePerfmon = "false",
    [Parameter(Mandatory = $false)][string]$manualUniqueId = "NA",
    [Parameter(Mandatory = $false)][switch]$collectVMSpecs,
    [Parameter(Mandatory = $false)][switch]$useWindowsAuthentication = $false,
    [Parameter(Mandatory = $false)][switch]$useEntraIDAuthentication = $false,
    [Parameter(Mandatory = $false)][string]$outputDirectory = "default"
)

Import-Module $PSScriptRoot\dmaCollectorCommonFunctions.psm1

function Update-DmaManifest {
    param (
        [string]$shortName,
        [string]$longName
    )
    $manifestPath = Join-Path $foldername "dma_manifest.json"

    if (($null -eq $global:dmaManifest) -or (-not (Test-Path $manifestPath))) {
        $global:dmaManifest = [ordered]@{
            "metadata" = [ordered]@{
                "generated_at"        = (Get-Date -UFormat "%Y-%m-%dT%H:%M:%SZ")
                "db_version"          = $dbversion
                "op_version"          = $op_version
                "machine_name"        = $machinename
                "database_name"       = $dbname
                "instance_name"       = $instancename
                "service_broker_guid" = $(if ($dmaSourceId) { $dmaSourceId } else { "NA" })
                "timestamp"           = $current_ts
            }
            "files" = [ordered]@{}
        }
    }

    $global:dmaManifest.files[$shortName] = $longName
    $global:dmaManifest | ConvertTo-Json -Depth 3 | Set-Content -Path $manifestPath -Encoding utf8
}

if ($useEntraIDAuthentication -and $useWindowsAuthentication) {
    Write-Host "-useEntraIDAuthentication and -useWindowsAuthentication are mutually exclusive." -ForegroundColor Red
    Exit 1
}

if ($useEntraIDAuthentication -and ((-not [string]::IsNullOrEmpty($collectionUserName)) -or (-not [string]::IsNullOrEmpty($collectionUserPass)))) {
    Write-Host "-collectionUserName / -collectionUserPass must not be supplied with -useEntraIDAuthentication." -ForegroundColor Red
    Write-Host "Authentication identity comes from the Microsoft Entra ID interactive MFA sign-in flow." -ForegroundColor Red
    Exit 1
}

$powerShellVersion = $PSVersionTable.PSVersion.Major
$sqlcmdCommand = Get-Command sqlcmd.exe -ErrorAction SilentlyContinue
if ($null -eq $sqlcmdCommand) {
    $sqlcmdCommand = Get-Command sqlcmd -ErrorAction SilentlyContinue
}

if ($null -eq $sqlcmdCommand) {
    Write-Host "sqlcmd is required but was not found in PATH." -ForegroundColor Red
    Exit 1
}

$script:NativeSqlcmdPath = $sqlcmdCommand.Source
$sqlcmdVersion = $sqlcmdCommand.Version
$foldername = ""
$totalErrorCount = 0

# Check for Microsoft Go sqlcmd vs legacy ODBC sqlcmd
$isGoSqlcmd = $false
$sqlcmdVersionString = "$sqlcmdVersion"
$rawVersionOutput = (& $script:NativeSqlcmdPath --version 2>&1) | Out-String
if ($rawVersionOutput -match 'sqlcmd\s+(?:version\s+)?v?(\d+\.\d+\.\d+)' -or $rawVersionOutput -match 'v?(\d+\.\d+\.\d+)') {
    $isGoSqlcmd = $true
    $sqlcmdVersionString = $Matches[1]
} else {
    $helpOutput = (& $script:NativeSqlcmdPath -? 2>&1) | Out-String
    if ($helpOutput -match 'go-sqlcmd' -or $helpOutput -match 'github\.com/microsoft/go-sqlcmd') {
        $isGoSqlcmd = $true
    }
}

$windowsOSVersion = [Environment]::OSVersion.Version
$checkWindowsOSVersion = [Environment]::OSVersion.Version -ge (new-object 'Version' 6,2)

if ($ignorePerfmon -eq "true") {
    Write-Host "#############################################################"
    Write-Host "#                                                           #"
    Write-Host "#  !!!! No Windows Perfmon Data Will be Collected !!!!      #"
    Write-Host "#   A migration complexity score will be computed only ...  #"
    Write-Host "#                                                           #"
    Write-Host "#          No Right-Sizing Data will be collected           #"
    Write-Host "#                                                           #"
    Write-Host "#############################################################"
    Write-Host ""
    $ignorePerfmonAck = Read-Host -Prompt "Acknowledge with a 'Y' to Continue"

    if ([string]::IsNullOrEmpty($ignorePerfmonAck) -or ($ignorePerfmonAck.ToUpper() -ne "Y")) {
        Write-Host "Did not Acknowledge Perfmon Warning..."
        Write-Host "Exiting Collector......."
        Exit
    }
}

if (-not $useEntraIDAuthentication) {
    if ((([string]::IsNullorEmpty($collectionUserPass)) -or ([string]$collectionUserPass -eq "false")) -and (-not $useWindowsAuthentication)) {
        if ([string]($collectionUserName) -ne $(whoami)) {
            Write-Output ""
            Write-Output "Collection Username password parameter is not provided"
            $passPrompt = Read-Host 'Please enter your password' -AsSecureString
            $collectionUserPass = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($passPrompt))
            Set-Item -Path env:SQLCMDUSER -Value $collectionUserName
            Set-Item -Path env:SQLCMDPASSWORD -Value $collectionUserPass
            Write-Output ""
        }
        else {
            Write-Host ""
            Write-Host "#############################################################"
            Write-Host "#                                                           #"
            Write-Host "#   Executing Collection with Windows Authenticated User    #"
            Write-Host "#                                                           #"
            Write-Host "#############################################################"
            Write-Host ""
        }
    }
    elseif ($useWindowsAuthentication) {
        Write-Host ""
        Write-Host "#############################################################"
        Write-Host "#                                                           #"
        Write-Host "#   Executing Collection with Windows Authenticated User    #"
        Write-Host "#                                                           #"
        Write-Host "#############################################################"
        Write-Host ""
    }
    elseif (-not ([string]::IsNullOrEmpty($collectionUserPass))) {
        Set-Item -Path env:SQLCMDUSER -Value $collectionUserName
        Set-Item -Path env:SQLCMDPASSWORD -Value $collectionUserPass
        Write-Host ""
        Write-Host "#############################################################"
        Write-Host "#                                                           #"
        Write-Host "#     Executing Collection with SQL Authenticated User      #"
        Write-Host "#                                                           #"
        Write-Host "#############################################################"
        Write-Host ""
    }
    else {
        Write-Host ""
        Write-Host "#############################################################"
        Write-Host "#                                                           #"
        Write-Host "#   Executing Collection with Windows Authenticated User    #"
        Write-Host "#                                                           #"
        Write-Host "#############################################################"
        Write-Host ""
    }
}

if ($useEntraIDAuthentication) {
    if ([string]::IsNullOrEmpty($entraIDUserName)) {
        Write-Host "-entraIDUserName must be supplied with -useEntraIDAuthentication." -ForegroundColor Red
        Write-Host "Example: -useEntraIDAuthentication -entraIDUserName user@domain.com" -ForegroundColor Red
        Exit 1
    }

    Remove-Item -Path env:SQLCMDUSER -ErrorAction SilentlyContinue
    Remove-Item -Path env:SQLCMDPASSWORD -ErrorAction SilentlyContinue
    Write-Host ""
    Write-Host "#############################################################"
    Write-Host "#                                                           #"
    Write-Host "#    Executing Collection with Entra ID Authentication      #"
    Write-Host "#                                                           #"
    Write-Host "#############################################################"
    Write-Host "    No collection username or password will be passed."
    Write-Host "    Entra ID sign-in user: $entraIDUserName"
    Write-Host "    sqlcmd path: $($script:NativeSqlcmdPath)"
    Write-Host "    sqlcmd version: $sqlcmdVersionString"
    Write-Host "    Entra ID collection will use one persistent shared ADO.NET connection."
    Write-Host ""
}

# Persistent shared ADO.NET connection for Entra ID MFA (guaranteeing exactly ONE interactive prompt)
# and for executing queries when sqlcmd is wrapped.
function sqlcmd {
    if (-not $useEntraIDAuthentication) {
        & $script:NativeSqlcmdPath @args
        return
    }

    $serverInstance = $serverName
    $inputFile = ""
    $dbName = "master"
    $variables = @{}

    for ($idx = 0; $idx -lt $args.Count; $idx++) {
        $token = $args[$idx]
        if ($token -eq "-S") { $serverInstance = $args[++$idx] }
        elseif ($token -eq "-i") { $inputFile = $args[++$idx] }
        elseif ($token -eq "-d") { $dbName = $args[++$idx] }
        elseif ($token -eq "-v") {
            while ($idx + 1 -lt $args.Count -and $args[$idx+1] -notmatch "^-") {
                $assignment = $args[++$idx]
                if ($assignment -match "=") {
                    $parts = $assignment.Split('=', 2)
                    $variables[$parts[0].Trim()] = $parts[1].Trim()
                }
            }
        }
    }

    if (-not $global:persistentSqlConn) {
        Import-Module SqlServer -ErrorAction SilentlyContinue
        $connStr = "Server=$serverInstance;Database=$dbName;TrustServerCertificate=True"
        if ($useEntraIDAuthentication) {
            $connStr += ";Authentication=Active Directory Interactive"
            if ($entraIDUserName) { $connStr += ";User ID=$entraIDUserName" }
        } elseif ($env:SQLCMDUSER -and $env:SQLCMDPASSWORD) {
            $connStr += ";User ID=$env:SQLCMDUSER;Password=$env:SQLCMDPASSWORD"
        } else {
            $connStr += ";Integrated Security=True"
        }

        try {
            $global:persistentSqlConn = New-Object Microsoft.Data.SqlClient.SqlConnection($connStr)
        } catch {
            $global:persistentSqlConn = New-Object System.Data.SqlClient.SqlConnection($connStr)
        }
        $global:persistentSqlConn.Open()
    } else {
        if ($global:persistentSqlConn.Database -ne $dbName) {
            $global:persistentSqlConn.ChangeDatabase($dbName)
        }
    }

    if ($inputFile -and (Test-Path $inputFile)) {
        $query = (Get-Content $inputFile -Raw)
        foreach ($varKey in $variables.Keys) {
            $query = $query.Replace("`$($varKey)", "$($variables[$varKey])")
        }

        $cmd = $global:persistentSqlConn.CreateCommand()
        $cmd.CommandText = $query
        $cmd.CommandTimeout = 300

        try {
            $reader = $cmd.ExecuteReader()
            while ($reader.Read()) {
                $rowVals = @()
                for ($c = 0; $c -lt $reader.FieldCount; $c++) {
                    $rowVals += "$($reader.GetValue($c))"
                }
                $rowVals -join "|"
            }
            $reader.Close()
        } catch {
            Write-Error $_.Exception.Message
        }
    }
}

if (-not $useEntraIDAuthentication) {
    if ($isGoSqlcmd) {
        Write-Host "Detected Microsoft Go sqlcmd version: $sqlcmdVersionString"
    } else {
        $requiredVersion = [version]"11.0.7512.0"
        if ($sqlcmdVersion -and ($sqlcmdVersion -lt $requiredVersion)) {
            Write-Host "#############################################################"
            Write-Host "#                                                           #"
            Write-Host "#       !!!! The installed version of SQL CMD is !!!!       #"
            Write-Host "#              lower than the required version              #"
            Write-Host "#                                                           #"
            Write-Host "#          Supported Versions ODBC >= $requiredVersion      #"
            Write-Host "#               Collection Errors may Occur                 #"
            Write-Host "#############################################################"
            Write-Host ""
            $versionAck = Read-Host -Prompt "Acknowledge with a 'Y' to Continue"

            if ($versionAck.ToUpper() -ne "Y") {
                Write-Host "Did not Acknowledge SQL CMD Version Warning..."
                Write-Host "Exiting Collector......."
                Exit
            }
        }
    }
}

if ($(Get-Location).Path -ne $PSScriptRoot) {
    $currentTimestamp = "[{0:MM/dd/yy} {0:HH:mm:ss}]" -f (Get-Date)
    Write-Host "$currentTimestamp   Script Location: $PSScriptRoot"
    $currentTimestamp = "[{0:MM/dd/yy} {0:HH:mm:ss}]" -f (Get-Date)
    Write-Host "$currentTimestamp   Running script from directory: $(Get-Location)"
    $originalLocation = $(Get-Location).Path
    Push-Location -Path $PSScriptRoot
    $currentTimestamp = "[{0:MM/dd/yy} {0:HH:mm:ss}]" -f (Get-Date)
    Write-Host "$currentTimestamp   Changing Directory for script execution to $PSScriptRoot ....."
}

if ([string]::IsNullorEmpty($serverName)) {
    Write-Output "Server parameter $serverName is empty. Ensure that the parameter is provided"
    Exit 1
}
elseif ([string]::IsNullorEmpty($collectionUserName) -and (-not $useWindowsAuthentication) -and (-not $useEntraIDAuthentication)) {
    Write-Output "Collection Username parameter $collectionUserName is empty."
    Write-Output "Ensure that the parameter is provided or -useWindowsAuthentication is specified"
    Exit 1
}
elseif (((checkStringForSpecialChars -inputString $manualUniqueId) -eq "fail") -and (![string]::IsNullorEmpty($manualUniqueId))) {
    Write-Output "Manual Unique Id parameter $manualUniqueId contains spaces or special characters. Ensure that the parameter contains only letters, numbers and no spaces"
    Exit 1
}
else {
    $databaseNameFilter = '"' + $database + '"'

    $sqlcmdAuthArgs = @()

    if (([string]::IsNullorEmpty($port)) -or ($port -eq "default")) {
        $folderObjRaw = sqlcmd -S $serverName -i sql\foldername.sql -d master -C -l 30 -W -m 1 -u -h -1 -w 32768 -v database=$databaseNameFilter -s "|" @sqlcmdAuthArgs | Where-Object { $_.Trim() -ne '' -and $_ -notmatch '---' }
        $validSQLInstanceVersionCheckArray = @(sqlcmd -S $serverName -i sql\checkValidInstanceVersion.sql -d master -C -l 30 -W -m 1 -u -h -1 -w 32768 @sqlcmdAuthArgs)
        $dbNameArray = @(sqlcmd -S $serverName -i sql\getDBList.sql -d master -C -l 30 -W -m 1 -u -h -1 -w 32768 -v database=$databaseNameFilter -v hasdbaccess=1 -s "|" @sqlcmdAuthArgs)
        $dbNameNoAccessArray = @(sqlcmd -S $serverName -i sql\getDBList.sql -d master -C -l 30 -W -m 1 -u -h -1 -w 32768 -v database=$databaseNameFilter -v hasdbaccess=0 -s "|" @sqlcmdAuthArgs)
        $dmaSourceIdObj = @(sqlcmd -S $serverName -i sql\getDmaSourceId.sql -d master -C -l 30 -W -m 1 -u -h -1 -w 32768 -s "|" @sqlcmdAuthArgs)
        if ($database -ne "all") {
            $validDBObj = sqlcmd -S $serverName -i sql\checkValidDatabase.sql -C -l 30 -W -m 1 -u -h -1 -w 32768 -v database=$databaseNameFilter -s "|" @sqlcmdAuthArgs | Where-Object { $_ -notmatch '^-' }
            if ($validDBObj -eq 0) {
                Write-Output "Database $database does not exist in the SQL Server Instance $serverName"
                Write-Output "Ensure that the -database parameter provided is valid"
                Exit 1
            }
        }
    }
    else {
        $inputServerName = $serverName
        $serverName = "$serverName,$port"
        $folderObjRaw = sqlcmd -S $serverName -i sql\foldername.sql -d master -C -l 30 -W -m 1 -u -h -1 -w 32768 -v database=$databaseNameFilter -s "|" @sqlcmdAuthArgs | Where-Object { $_.Trim() -ne '' -and $_ -notmatch '---' }
        $validSQLInstanceVersionCheckArray = @(sqlcmd -S $serverName -i sql\checkValidInstanceVersion.sql -d master -C -l 30 -W -m 1 -u -h -1 -w 32768 @sqlcmdAuthArgs)
        $dbNameArray = @(sqlcmd -S $serverName -i sql\getDBList.sql -d master -C -l 30 -W -m 1 -u -h -1 -w 32768 -v database=$databaseNameFilter -v hasdbaccess=1 -s "|" @sqlcmdAuthArgs)
        $dbNameNoAccessArray = @(sqlcmd -S $serverName -i sql\getDBList.sql -d master -C -l 30 -W -m 1 -u -h -1 -w 32768 -v database=$databaseNameFilter -v hasdbaccess=0 -s "|" @sqlcmdAuthArgs)
        $dmaSourceIdObj = @(sqlcmd -S $serverName -i sql\getDmaSourceId.sql -d master -C -l 30 -W -m 1 -u -h -1 -w 32768 -s "|" @sqlcmdAuthArgs)
        if ($database -ne "all") {
            $validDBObj = sqlcmd -S $serverName -i sql\checkValidDatabase.sql -C -l 30 -W -m 1 -u -h -1 -w 32768 -v database=$databaseNameFilter -s "|" @sqlcmdAuthArgs | Where-Object { $_ -notmatch '^-' }
            if ($validDBObj -eq 0) {
                Write-Output "Database $database does not exist in the SQL Server Instance $serverName"
                Write-Output "Ensure that the -database parameter provided is valid"
                Exit 1
            }
        }
    }

    $splitValidInstanceVersionCheckObj = $validSQLInstanceVersionCheckArray[0].Split('')
    $validSQLInstanceVersionCheckValues = $splitValidInstanceVersionCheckObj | ForEach-Object { if ($_.Trim() -ne '') { $_ } }
    $isValidSQLInstanceVersion = $validSQLInstanceVersionCheckValues[0]
    $isCloudOrLinuxHost = $validSQLInstanceVersionCheckValues[1]

    if ($isValidSQLInstanceVersion -eq "0") {
        Write-Host "#############################################################"
        Write-Host "#                                                           #"
        Write-Host "#     Unsupported SQL Server Database Engine Detected       #"
        Write-Host "#                                                           #"
        Write-Host "#            Database Assessment Requires at least          #"
        Write-Host "#            SQL Server 2008 (SP4-GDR) (KB5020863)          #"
        Write-Host "#                   or greater to continue                  #"
        Write-Host "#                                                           #"
        Write-Host "#############################################################"
        Write-Host ""
        Exit 1
    }

    $folderObj = ($folderObjRaw -join "").Split('|')
    $op_version = "4.3.47"
    $dbversion = $folderObj[0].Trim()
    $machinename = $folderObj[1].Trim()
    $dbname = $folderObj[2].Trim()
    $instancename = $folderObj[3].Trim()
    $current_ts = $folderObj[4].Trim()
    $pkey = $folderObj[5].Trim()
    $dmaSourceId = if ($dmaSourceIdObj) { ($dmaSourceIdObj -join "").Trim() } else { "NotPopulated" }

    if ($instancename -eq '') {
        $instancename = "MSSQLSERVER"
    }

    if ($machinename -eq '') {
        $machinename = "UNKNOWN_HOST"
    }

    $foldername = $dbversion + '_' + $op_version + '_' + $machinename + '_' + $dbname + '_' + $instancename + '_' + $current_ts
    $folderpath = $PSScriptRoot + "\" + $foldername

    $logFileShort = 'collector_log.log'
    $logFileLong = 'opdb' + '__' + 'CollectorLog' + '__' + $foldername + '.log'
    $logFile = $logFileShort

    $sqlErrorLogFileShort = 'sql_validation_log.log'
    $sqlErrorLogFileLong = 'opdb' + '__' + 'SqlValidationLog' + '__' + $foldername + '.log'
    $sqlErrorLogFile = $sqlErrorLogFileShort

    if ([string]::IsNullorEmpty($outputDirectory) -or ($outputDirectory -eq "default")) {
        $targetExtractPath = $folderpath
    } else {
        $targetExtractPath = $outputDirectory + "\" + $foldername
    }

    if (!(Test-Path -Path $targetExtractPath)) {
        New-Item -ItemType directory -Path $targetExtractPath | Out-Null
    }

    $computerSpecsFile = 'opdb' + '__' + 'DbMachineSpecs' + '__' + $foldername + '.csv'

    if ($collectVMSpecs -or ($null -ne $collectVMSpecs.IsPresent -and $collectVMSpecs.IsPresent)) {
        .\dmaSQLServerHWSpecs.ps1 -outputDirectory $targetExtractPath -outputFileName $computerSpecsFile -pkey $pkey -dmaSourceId $dmaSourceId -dmaManualId $manualUniqueId
    }

    $outputFileSuffix = '__' + $dbversion + '_' + $op_version + '_' + $machinename + '_' + $dbname + '_' + $instancename + '_' + $current_ts + '.csv'

    $compFileNameShort = 'components.csv'
    $compFileNameLong = 'opdb' + '__' + 'CompInstalled' + $outputFileSuffix

    $srvFileNameShort = 'server_properties.csv'
    $srvFileNameLong = 'opdb' + '__' + 'ServerProps' + $outputFileSuffix

    $blockingFeaturesShort = 'blocking_features.csv'
    $blockingFeaturesLong = 'opdb' + '__' + 'BlockFeatures' + $outputFileSuffix

    $linkedServersShort = 'linked_servers.csv'
    $linkedServersLong = 'opdb' + '__' + 'LinkedSrvrs' + $outputFileSuffix

    $dbsizesShort = 'database_sizes.csv'
    $dbsizesLong = 'opdb' + '__' + 'DbSizes' + $outputFileSuffix

    $dbClusterNodesShort = 'cluster_nodes.csv'
    $dbClusterNodesLong = 'opdb' + '__' + 'DbClusterNodes' + $outputFileSuffix

    $objectListShort = 'object_list.csv'
    $objectListLong = 'opdb' + '__' + 'ObjectList' + $outputFileSuffix

    $tableListShort = 'table_list.csv'
    $tableListLong = 'opdb' + '__' + 'TableList' + $outputFileSuffix

    $indexListShort = 'index_list.csv'
    $indexListLong = 'opdb' + '__' + 'IndexList' + $outputFileSuffix

    $columnDatatypesShort = 'column_datatypes.csv'
    $columnDatatypesLong = 'opdb' + '__' + 'ColumnDatatypes' + $outputFileSuffix

    $userConnectionListShort = 'user_connections.csv'
    $userConnectionListLong = 'opdb' + '__' + 'UserConnections' + $outputFileSuffix

    $perfMonOutputShort = 'perfmon_raw.csv'
    $perfMonOutputLong = 'opdb' + '__' + 'PerfMonData' + $outputFileSuffix

    $dbccTraceFlgShort = 'dbcc_trace_flags.csv'
    $dbccTraceFlgLong = 'opdb' + '__' + 'DbccTrace' + $outputFileSuffix

    $diskVolumeInfoShort = 'disk_volume_info.csv'
    $diskVolumeInfoLong = 'opdb' + '__' + 'DiskVolInfo' + $outputFileSuffix

    $dbServerFlagsShort = 'server_flags.csv'
    $dbServerFlagsLong = 'opdb' + '__' + 'DbServerFlags' + $outputFileSuffix

    $dbServerConfigShort = 'server_config.csv'
    $dbServerConfigLong = 'opdb' + '__' + 'DbServerConfig' + $outputFileSuffix

    $manifestFile = 'integrity.csv'

    $cpuUsageFileNameShort = 'cpu_usage.csv'
    $cpuUsageFileNameLong  = 'opdb' + '__' + 'CpuUsage' + $outputFileSuffix

    $memoryUsageFileNameShort = 'memory_usage.csv'
    $memoryUsageFileNameLong  = 'opdb' + '__' + 'MemoryUsage' + $outputFileSuffix

    $batchFootprintFileNameShort = 'batch_footprint.csv'
    $batchFootprintFileNameLong  = 'opdb' + '__' + 'BatchFootprint' + $outputFileSuffix

    $waitsStatsShort = 'waits_stats.csv'
    $waitsStatsLong  = 'opdb' + '__' + 'WaitsStats' + $outputFileSuffix

    $queryOptimizerInfoShort = 'query_optimizer_info.csv'
    $queryOptimizerInfoLong  = 'opdb' + '__' + 'QueryOptimizerInfo' + $outputFileSuffix

    $fileIoLatencyShort = 'file_io_latency.csv'
    $fileIoLatencyLong  = 'opdb' + '__' + 'FileIoLatency' + $outputFileSuffix

    $instanceErrorLogShort = 'instance_error_log.csv'
    $instanceErrorLogLong  = 'opdb' + '__' + 'InstanceErrorLog' + $outputFileSuffix

    $deprecatedFeaturesShort = 'deprecated_features.csv'
    $deprecatedFeaturesLong  = 'opdb' + '__' + 'DeprecatedFeatures' + $outputFileSuffix

    $deepScannerShort = 'postgres_migration_issues.csv'
    $deepScannerLong  = 'opdb' + '__' + 'PostgresMigrationIssues' + $outputFileSuffix

    $computerSpecsFileShort = 'machine_specs.csv'
    $computerSpecsFileLong = 'opdb' + '__' + 'DbMachineSpecs' + $outputFileSuffix

    $sqlAgentJobsShort = 'sql_agent_jobs.csv'
    $sqlAgentJobsLong = 'opdb' + '__' + 'SqlAgentJobs' + $outputFileSuffix

    $tranLogBkupCountByDayByHourShort = 'tlog_bkp_count.csv'
    $tranLogBkupCountByDayByHourLong = 'opdb' + '__' + 'TranLogBkupCountByHourByDay' + $outputFileSuffix

    $tranLogBkupSizeByDayByHourShort = 'tlog_bkp_size.csv'
    $tranLogBkupSizeByDayByHourLong = 'opdb' + '__' + 'TranLogBkupSizeByHourByDay' + $outputFileSuffix

    $databaseLevelBlockingFeaturesShort = 'db_blocking_features.csv'
    $databaseLevelBlockingFeaturesLong = 'opdb' + '__' + 'DatabaseLevelBlockFeatures' + $outputFileSuffix

    $outputFileArray = @($compFileNameShort,
        $srvFileNameShort,
        $blockingFeaturesShort,
        $linkedServersShort,
        $dbsizesShort,
        $dbClusterNodesShort,
        $objectListShort,
        $tableListShort,
        $indexListShort,
        $columnDatatypesShort,
        $userConnectionListShort,
        $perfMonOutputShort,
        $dbccTraceFlgShort,
        $diskVolumeInfoShort,
        $dbServerFlagsShort,
        $dbServerConfigShort,
        $manifestFile,
        $computerSpecsFileShort,
        $sqlAgentJobsShort,
        $tranLogBkupCountByDayByHourShort,
        $tranLogBkupSizeByDayByHourShort,
        $databaseLevelBlockingFeaturesShort,
        $cpuUsageFileNameShort,
        $memoryUsageFileNameShort,
        $batchFootprintFileNameShort,
        $waitsStatsShort,
        $queryOptimizerInfoShort,
        $fileIoLatencyShort,
        $instanceErrorLogShort,
        $deprecatedFeaturesShort,
        $deepScannerShort)

    WriteLog -logLocation $foldername\$logFile -logMessage "Executing Assessment on Server $serverName Against the Following Databases:" -logOperation "BOTH"
    foreach ($dbNameList in $dbNameArray) {
        WriteLog -logLocation $foldername\$logFile -logMessage "            $dbNameList" -logOperation "BOTH"
    }

    if ($dbNameNoAccessArray.Count -gt 0) {
        WriteLog -logLocation $foldername\$logFile -logMessage "Skipping Databases Due to Permissions Issues:" -logOperation "BOTH"
        foreach ($dbNameNoAccessList in $dbNameNoAccessArray) {
            WriteLog -logLocation $foldername\$logFile -logMessage "            $dbNameNoAccessList" -logOperation "BOTH"
        }
    }

    WriteLog -logLocation $foldername\$logFile -logMessage "Retrieving SQL Server Installed Components..." -logOperation "BOTH"
    Set-Content -Path $foldername\$compFileNameShort -Encoding utf8 -Value '"PKEY"|"physical_server_name"|"sql_instance_name"|"sql_server_services"|"current_service_status"|"status_date_time"|"dma_source_id"|"dma_manual_id"'
    sqlcmd -S $serverName -i sql\componentsInstalled.sql -d master -C -l 30 -W -m 1 -u -h -1 -w 32768 -v pkey=$pkey -v dmaSourceId=$dmaSourceId -v dmaManualId=$manualUniqueId -s "|" @sqlcmdAuthArgs | Where-Object { $_ -notmatch '---' } | Add-Content -Path $foldername\$compFileNameShort -Encoding utf8
    Update-DmaManifest -shortName $compFileNameShort -longName $compFileNameLong

    WriteLog -logLocation $foldername\$logFile -logMessage "Retrieving SQL Server Properties..." -logOperation "BOTH"
    Set-Content -Path $foldername\$srvFileNameShort -Encoding utf8 -Value '"PKEY"|"property_name"|"property_value"|"dma_source_id"|"dma_manual_id"'
    sqlcmd -S $serverName -i sql\serverProperties.sql -d master -C -l 30 -W -m 1 -u -h -1 -w 32768 -v pkey=$pkey -v dmaSourceId=$dmaSourceId -v dmaManualId=$manualUniqueId -s "|" @sqlcmdAuthArgs | Where-Object { $_ -notmatch '---' } | Add-Content -Path $foldername\$srvFileNameShort -Encoding utf8
    Update-DmaManifest -shortName $srvFileNameShort -longName $srvFileNameLong

    WriteLog -logLocation $foldername\$logFile -logMessage "Retrieving SQL Server CloudSQL Unsupported Flag Info..." -logOperation "BOTH"
    Set-Content -Path $foldername\$dbServerFlagsShort -Encoding utf8 -Value '"PKEY"|"flag_name"|"value"|"value_in_use"|"description"|"dma_source_id"|"dma_manual_id"'
    sqlcmd -S $serverName -i sql\dbServerUnsupportedFlags.sql -d master -C -l 30 -W -m 1 -u -h -1 -w 32768 -v pkey=$pkey -v dmaSourceId=$dmaSourceId -v dmaManualId=$manualUniqueId -s "|" @sqlcmdAuthArgs | Where-Object { $_ -notmatch '---' } | Add-Content -Path $foldername\$dbServerFlagsShort -Encoding utf8
    Update-DmaManifest -shortName $dbServerFlagsShort -longName $dbServerFlagsLong

    WriteLog -logLocation $foldername\$logFile -logMessage "Retrieving SQL Server Blocked Features in Use..." -logOperation "BOTH"
    Set-Content -Path $foldername\$blockingFeaturesShort -Encoding utf8 -Value '"PKEY"|"Features"|"Is_EnabledOrUsed"|"Count"|"dma_source_id"|"dma_manual_id"'
    sqlcmd -S $serverName -i sql\dbServerFeatures.sql -d master -C -l 30 -W -m 1 -u -h -1 -w 32768 -v pkey=$pkey -v dmaSourceId=$dmaSourceId -v dmaManualId=$manualUniqueId -s "|" @sqlcmdAuthArgs | Where-Object { $_ -notmatch '---' } | Add-Content -Path $foldername\$blockingFeaturesShort -Encoding utf8
    Update-DmaManifest -shortName $blockingFeaturesShort -longName $blockingFeaturesLong

    WriteLog -logLocation $foldername\$logFile -logMessage "Retrieving SQL Server Linked Server Info..." -logOperation "BOTH"
    Set-Content -Path $foldername\$linkedServersShort -Encoding utf8 -Value '"pkey"|"name"|"product"|"provider"|"data_source"|"location"|"provider_string"|"catalog"|"dma_source_id"|"dma_manual_id"'
    sqlcmd -S $serverName -i sql\linkedServersDetail.sql -d master -C -l 30 -W -m 1 -u -h -1 -w 32768 -v pkey=$pkey -v dmaSourceId=$dmaSourceId -v dmaManualId=$manualUniqueId -s "|" @sqlcmdAuthArgs | Where-Object { $_ -notmatch '---' } | Add-Content -Path $foldername\$linkedServersShort -Encoding utf8
    Update-DmaManifest -shortName $linkedServersShort -longName $linkedServersLong

    WriteLog -logLocation $foldername\$logFile -logMessage "Retrieving SQL Server Cluster Node Info..." -logOperation "BOTH"
    Set-Content -Path $foldername\$dbClusterNodesShort -Encoding utf8 -Value '"pkey"|"node_name"|"status"|"status_description"|"dma_source_id"|"dma_manual_id"'
    sqlcmd -S $serverName -i sql\dbClusterNodes.sql -d master -C -l 30 -W -m 1 -u -h -1 -w 32768 -v pkey=$pkey -v dmaSourceId=$dmaSourceId -v dmaManualId=$manualUniqueId -s "|" @sqlcmdAuthArgs | Where-Object { $_ -notmatch '---' } | Add-Content -Path $foldername\$dbClusterNodesShort -Encoding utf8
    Update-DmaManifest -shortName $dbClusterNodesShort -longName $dbClusterNodesLong

    WriteLog -logLocation $foldername\$logFile -logMessage "Retrieving SQL Server DBCC Trace Info..." -logOperation "BOTH"
    Set-Content -Path $foldername\$dbccTraceFlgShort -Encoding utf8 -Value '"PKEY"|"name"|"status"|"global"|"session"|"dma_source_id"|"dma_manual_id"'
    sqlcmd -S $serverName -i sql\dbccTraceFlags.sql -d master -C -l 30 -W -m 1 -u -h -1 -w 32768 -v pkey=$pkey -v dmaSourceId=$dmaSourceId -v dmaManualId=$manualUniqueId -s "|" @sqlcmdAuthArgs | Where-Object { $_ -notmatch '---' } | Add-Content -Path $foldername\$dbccTraceFlgShort -Encoding utf8
    Update-DmaManifest -shortName $dbccTraceFlgShort -longName $dbccTraceFlgLong

    WriteLog -logLocation $foldername\$logFile -logMessage "Retrieving SQL Server CPU Usage Info (Ring Buffer)..." -logOperation "BOTH"
    Set-Content -Path $foldername\$cpuUsageFileNameShort -Encoding utf8 -Value '"PKEY"|"timestamp"|"process_utilization"|"system_idle"|"dma_source_id"|"dma_manual_id"'
    sqlcmd -S $serverName -i sql\cpuUsage.sql -d master -C -l 30 -W -m 1 -u -h -1 -w 32768 -v pkey=$pkey -v dmaSourceId=$dmaSourceId -v dmaManualId=$manualUniqueId -s "|" @sqlcmdAuthArgs | Where-Object { $_ -notmatch '---' } | Add-Content -Path $foldername\$cpuUsageFileNameShort -Encoding utf8
    Update-DmaManifest -shortName $cpuUsageFileNameShort -longName $cpuUsageFileNameLong

    WriteLog -logLocation $foldername\$logFile -logMessage "Retrieving SQL Server Memory Usage Info (Ring Buffer)..." -logOperation "BOTH"
    Set-Content -Path $foldername\$memoryUsageFileNameShort -Encoding utf8 -Value '"PKEY"|"timestamp"|"state"|"available_physical_memory_mb"|"working_set_mb"|"percent_committed_in_ws"|"system_physical_memory_high"|"system_physical_memory_low"|"process_physical_memory_low"|"process_virtual_memory_low"|"dma_source_id"|"dma_manual_id"'
    sqlcmd -S $serverName -i sql\memoryUsage.sql -d master -C -l 30 -W -m 1 -u -h -1 -w 32768 -v pkey=$pkey -v dmaSourceId=$dmaSourceId -v dmaManualId=$manualUniqueId -s "|" @sqlcmdAuthArgs | Where-Object { $_ -notmatch '---' } | Add-Content -Path $foldername\$memoryUsageFileNameShort -Encoding utf8
    Update-DmaManifest -shortName $memoryUsageFileNameShort -longName $memoryUsageFileNameLong

    WriteLog -logLocation $foldername\$logFile -logMessage "Retrieving SQL Server Batch Footprint Info..." -logOperation "BOTH"
    Set-Content -Path $foldername\$batchFootprintFileNameShort -Encoding utf8 -Value '"PKEY"|"AvgRunTimeMS"|"StatementCount"|"counter_name"|"TotalElapsedTimeMS"|"ExecutionTimePercent"|"ExecutionCountPercent"|"dma_source_id"|"dma_manual_id"'
    sqlcmd -S $serverName -i sql\batchFootprint.sql -d master -C -l 30 -W -m 1 -u -h -1 -w 32768 -v pkey=$pkey -v dmaSourceId=$dmaSourceId -v dmaManualId=$manualUniqueId -s "|" @sqlcmdAuthArgs | Where-Object { $_ -notmatch '---' } | Add-Content -Path $foldername\$batchFootprintFileNameShort -Encoding utf8
    Update-DmaManifest -shortName $batchFootprintFileNameShort -longName $batchFootprintFileNameLong

    WriteLog -logLocation $foldername\$logFile -logMessage "Retrieving SQL Server Waits Stats Info..." -logOperation "BOTH"
    Set-Content -Path $foldername\$waitsStatsShort -Encoding utf8 -Value '"PKEY"|"WaitType"|"Wait_S"|"Resource_S"|"Signal_S"|"WaitCount"|"Percentage"|"AvgWait_S"|"AvgRes_S"|"AvgSig_S"|"dma_source_id"|"dma_manual_id"'
    sqlcmd -S $serverName -i sql\waitsStats.sql -d master -C -l 30 -W -m 1 -u -h -1 -w 32768 -v pkey=$pkey -v dmaSourceId=$dmaSourceId -v dmaManualId=$manualUniqueId -s "|" @sqlcmdAuthArgs | Where-Object { $_ -notmatch '---' } | Add-Content -Path $foldername\$waitsStatsShort -Encoding utf8
    Update-DmaManifest -shortName $waitsStatsShort -longName $waitsStatsLong

    WriteLog -logLocation $foldername\$logFile -logMessage "Retrieving SQL Server Query Optimizer Info..." -logOperation "BOTH"
    Set-Content -Path $foldername\$queryOptimizerInfoShort -Encoding utf8 -Value '"PKEY"|"counter"|"value"|"occurrence"|"dma_source_id"|"dma_manual_id"'
    sqlcmd -S $serverName -i sql\queryOptimizerInfo.sql -d master -C -l 30 -W -m 1 -u -h -1 -w 32768 -v pkey=$pkey -v dmaSourceId=$dmaSourceId -v dmaManualId=$manualUniqueId -s "|" @sqlcmdAuthArgs | Where-Object { $_ -notmatch '---' } | Add-Content -Path $foldername\$queryOptimizerInfoShort -Encoding utf8
    Update-DmaManifest -shortName $queryOptimizerInfoShort -longName $queryOptimizerInfoLong

    WriteLog -logLocation $foldername\$logFile -logMessage "Retrieving SQL Server File IO Latency Info..." -logOperation "BOTH"
    Set-Content -Path $foldername\$fileIoLatencyShort -Encoding utf8 -Value '"PKEY"|"DatabaseName"|"LogicalFileName"|"FileType"|"PhysicalPath"|"TotalReads"|"DataReadMB"|"TotalReadStallMs"|"AvgReadLatencyMs"|"TotalWrites"|"DataWrittenMB"|"TotalWriteStallMs"|"AvgWriteLatencyMs"|"TotalIOStallMs"|"SizeOnDiskMB"|"dma_source_id"|"dma_manual_id"'
    sqlcmd -S $serverName -i sql\fileIoLatency.sql -d master -C -l 30 -W -m 1 -u -h -1 -w 32768 -v pkey=$pkey -v dmaSourceId=$dmaSourceId -v dmaManualId=$manualUniqueId -s "|" @sqlcmdAuthArgs | Where-Object { $_ -notmatch '---' } | Add-Content -Path $foldername\$fileIoLatencyShort -Encoding utf8
    Update-DmaManifest -shortName $fileIoLatencyShort -longName $fileIoLatencyLong

    WriteLog -logLocation $foldername\$logFile -logMessage "Retrieving SQL Server Instance Error Log Info..." -logOperation "BOTH"
    Set-Content -Path $foldername\$instanceErrorLogShort -Encoding utf8 -Value '"PKEY"|"timestamp"|"process_info"|"log_message"|"dma_source_id"|"dma_manual_id"'
    sqlcmd -S $serverName -i sql\instanceErrorLog.sql -d master -C -l 30 -W -m 1 -u -h -1 -w 32768 -v pkey=$pkey -v dmaSourceId=$dmaSourceId -v dmaManualId=$manualUniqueId -s "|" @sqlcmdAuthArgs | Where-Object { $_ -notmatch '---' } | Add-Content -Path $foldername\$instanceErrorLogShort -Encoding utf8
    Update-DmaManifest -shortName $instanceErrorLogShort -longName $instanceErrorLogLong

    WriteLog -logLocation $foldername\$logFile -logMessage "Retrieving SQL Server Deprecated Features Info..." -logOperation "BOTH"
    Set-Content -Path $foldername\$deprecatedFeaturesShort -Encoding utf8 -Value '"PKEY"|"FeatureName"|"UsageCount"|"dma_source_id"|"dma_manual_id"'
    sqlcmd -S $serverName -i sql\deprecatedFeatures.sql -d master -C -l 30 -W -m 1 -u -h -1 -w 32768 -v pkey=$pkey -v dmaSourceId=$dmaSourceId -v dmaManualId=$manualUniqueId -s "|" @sqlcmdAuthArgs | Where-Object { $_ -notmatch '---' } | Add-Content -Path $foldername\$deprecatedFeaturesShort -Encoding utf8
    Update-DmaManifest -shortName $deprecatedFeaturesShort -longName $deprecatedFeaturesLong

    WriteLog -logLocation $foldername\$logFile -logMessage "Retrieving SQL Server Disk Volume Info..." -logOperation "BOTH"
    Set-Content -Path $foldername\$diskVolumeInfoShort -Encoding utf8 -Value '"PKEY"|"volume_mount_point"|"file_system_type"|"logical_volume_name"|"total_size_gb"|"available_size_gb"|"space_free_pct"|"cluster_block_size"|"dma_source_id"|"dma_manual_id"'
    sqlcmd -S $serverName -i sql\diskVolumeInfo.sql -d master -C -l 30 -W -m 1 -u -h -1 -w 32768 -v pkey=$pkey -v dmaSourceId=$dmaSourceId -v dmaManualId=$manualUniqueId -s "|" @sqlcmdAuthArgs | Where-Object { $_ -notmatch '---' } | Add-Content -Path $foldername\$diskVolumeInfoShort -Encoding utf8
    Update-DmaManifest -shortName $diskVolumeInfoShort -longName $diskVolumeInfoLong

    WriteLog -logLocation $foldername\$logFile -logMessage "Retrieving SQL Server Configuration Info..." -logOperation "BOTH"
    Set-Content -Path $foldername\$dbServerConfigShort -Encoding utf8 -Value '"pkey"|"configuration_id"|"name"|"value"|"minimum"|"maximum"|"value_in_use"|"description"|"dma_source_id"|"dma_manual_id"'
    sqlcmd -S $serverName -i sql\dbServerConfigurationSettings.sql -d master -C -l 30 -W -m 1 -u -h -1 -w 32768 -v pkey=$pkey -v dmaSourceId=$dmaSourceId -v dmaManualId=$manualUniqueId -s "|" @sqlcmdAuthArgs | Where-Object { $_ -notmatch '---' } | Add-Content -Path $foldername\$dbServerConfigShort -Encoding utf8
    Update-DmaManifest -shortName $dbServerConfigShort -longName $dbServerConfigLong

    if ($isCloudOrLinuxHost -eq "AZURE") {
        WriteLog -logLocation $foldername\$logFile -logMessage "Skipping SQL Server Transaction Log Backup Info...Unavailable in AZURE SQL Managed Instance." -logOperation "BOTH"
        Set-Content -Path $foldername\$tranLogBkupCountByDayByHourShort -Encoding utf8 -Value '"PKEY"|"collection_date"|"day_of_month"|"total_logs_generated"|"h0_count"|"h1_count"|"h2_count"|"h3_count"|"h4_count"|"h5_count"|"h6_count"|"h7_count"|"h8_count"|"h9_count"|"h10_count"|"h11_count"|"h12_count"|"h13_count"|"h14_count"|"h15_count"|"h16_count"|"h17_count"|"h18_count"|"h19_count"|"h20_count"|"h21_count"|"h22_count"|"h23_count"|"avg_per_hour"|"dma_source_id"|"dma_manual_id"'
        Set-Content -Path $foldername\$tranLogBkupSizeByDayByHourShort -Encoding utf8 -Value '"PKEY"|"collection_date"|"day_of_month"|"total_logs_generated_in_mb"|"h0_size_in_mb"|"h1_size_in_mb"|"h2_size_in_mb"|"h3_size_in_mb"|"h4_size_in_mb"|"h5_size_in_mb"|"h6_size_in_mb"|"h7_size_in_mb"|"h8_size_in_mb"|"h9_size_in_mb"|"h10_size_in_mb"|"h11_size_in_mb"|"h12_size_in_mb"|"h13_size_in_mb"|"h14_size_in_mb"|"h15_size_in_mb"|"h16_size_in_mb"|"h17_size_in_mb"|"h18_size_in_mb"|"h19_size_in_mb"|"h20_size_in_mb"|"h21_size_in_mb"|"h22_size_in_mb"|"h23_size_in_mb"|"avg_mb_per_hour"|"dma_source_id"|"dma_manual_id"'
    }
    else {
        WriteLog -logLocation $foldername\$logFile -logMessage "Retrieving SQL Server Transaction Log Backup Info..." -logOperation "BOTH"
        Set-Content -Path $foldername\$tranLogBkupCountByDayByHourShort -Encoding utf8 -Value '"PKEY"|"collection_date"|"day_of_month"|"total_logs_generated"|"h0_count"|"h1_count"|"h2_count"|"h3_count"|"h4_count"|"h5_count"|"h6_count"|"h7_count"|"h8_count"|"h9_count"|"h10_count"|"h11_count"|"h12_count"|"h13_count"|"h14_count"|"h15_count"|"h16_count"|"h17_count"|"h18_count"|"h19_count"|"h20_count"|"h21_count"|"h22_count"|"h23_count"|"avg_per_hour"|"dma_source_id"|"dma_manual_id"'
        Set-Content -Path $foldername\$tranLogBkupSizeByDayByHourShort -Encoding utf8 -Value '"PKEY"|"collection_date"|"day_of_month"|"total_logs_generated_in_mb"|"h0_size_in_mb"|"h1_size_in_mb"|"h2_size_in_mb"|"h3_size_in_mb"|"h4_size_in_mb"|"h5_size_in_mb"|"h6_size_in_mb"|"h7_size_in_mb"|"h8_size_in_mb"|"h9_size_in_mb"|"h10_size_in_mb"|"h11_size_in_mb"|"h12_size_in_mb"|"h13_size_in_mb"|"h14_size_in_mb"|"h15_size_in_mb"|"h16_size_in_mb"|"h17_size_in_mb"|"h18_size_in_mb"|"h19_size_in_mb"|"h20_size_in_mb"|"h21_size_in_mb"|"h22_size_in_mb"|"h23_size_in_mb"|"avg_mb_per_hour"|"dma_source_id"|"dma_manual_id"'
        sqlcmd -S $serverName -i sql\dbServerTranLogBackupCountByDayByHour.sql -d msdb -C -l 30 -W -m 1 -u -h -1 -w 32768 -v pkey=$pkey -v dmaSourceId=$dmaSourceId -v dmaManualId=$manualUniqueId -s "|" @sqlcmdAuthArgs | Where-Object { $_ -notmatch '---' } | Add-Content -Path $foldername\$tranLogBkupCountByDayByHourShort -Encoding utf8
        Update-DmaManifest -shortName $tranLogBkupCountByDayByHourShort -longName $tranLogBkupCountByDayByHourLong
        sqlcmd -S $serverName -i sql\dbServerTranLogBackupSizeByDayByHour.sql -d msdb -C -l 30 -W -m 1 -u -h -1 -w 32768 -v pkey=$pkey -v dmaSourceId=$dmaSourceId -v dmaManualId=$manualUniqueId -s "|" @sqlcmdAuthArgs | Where-Object { $_ -notmatch '---' } | Add-Content -Path $foldername\$tranLogBkupSizeByDayByHourShort -Encoding utf8
        Update-DmaManifest -shortName $tranLogBkupSizeByDayByHourShort -longName $tranLogBkupSizeByDayByHourLong
    }

    WriteLog -logLocation $foldername\$logFile -logMessage "Retrieving SQL Agent Jobs Info..." -logOperation "BOTH"
    Set-Content -Path $foldername\$sqlAgentJobsShort -Encoding utf8 -Value '"pkey"|"dma_source_id"|"dma_manual_id"|"job_id"|"job_name"|"job_enabled"|"category_name"|"job_description"|"step_id"|"step_name"|"subsystem"|"command"|"database_name"|"incompatibility_category"|"incompatibility_type"|"severity"'
    sqlcmd -S $serverName -i sql\sqlAgentJobs.sql -d msdb -C -l 30 -W -m 1 -u -h -1 -w 32768 -v pkey=$pkey -v dmaSourceId=$dmaSourceId -v dmaManualId=$manualUniqueId -s "|" @sqlcmdAuthArgs | Where-Object { $_ -notmatch '---' } | Add-Content -Path $foldername\$sqlAgentJobsShort -Encoding utf8
    Update-DmaManifest -shortName $sqlAgentJobsShort -longName $sqlAgentJobsLong

    Set-Content -Path $foldername\$objectListShort -Encoding utf8 -Value '"PKEY"|"database_name"|"schema_name"|"object_name"|"object_type"|"object_type_desc"|"object_count"|"lines_of_code"|"associated_table_name"|"dma_source_id"|"dma_manual_id"'
    Set-Content -Path $foldername\$tableListShort -Encoding utf8 -Value '"PKEY"|"database_name"|"schema_name"|"table_name"|"partition_count"|"is_memory_optimized"|"temporal_type"|"is_external"|"lock_escalation"|"is_tracked_by_cdc"|"text_in_row_limit"|"is_replicated"|"row_count"|"data_compression"|"total_space_mb"|"used_space_mb"|"unused_space_mb"|"dma_source_id"|"dma_manual_id"|"partition_type"|"is_temp_table"'
    Set-Content -Path $foldername\$indexListShort -Encoding utf8 -Value '"PKEY"|"database_name"|"schema_name"|"table_name"|"index_name"|"index_type"|"is_primary_key"|"is_unique"|"fill_factor"|"allow_page_locks"|"has_filter"|"data_compression"|"data_compression_desc"|"is_partitioned"|"count_key_ordinal"|"count_partition_ordinal"|"count_is_included_column"|"total_space_mb"|"dma_source_id"|"dma_manual_id"|"is_computed_index"|"is_index_on_view"'
    Set-Content -Path $foldername\$columnDatatypesShort -Encoding utf8 -Value '"PKEY"|"database_name"|"schema_name"|"table_name"|"datatype"|"max_length"|"precision"|"scale"|"is_computed"|"is_filestream"|"is_masked"|"encryption_type"|"is_sparse"|"rule_object_id"|"column_count"|"dma_source_id"|"dma_manual_id"'
    Set-Content -Path $foldername\$userConnectionListShort -Encoding utf8 -Value '"PKEY"|"database_name"|"is_user_process"|"host_name"|"program_name"|"login_name"|"num_reads"|"num_writes"|"last_read"|"last_write"|"reads"|"logical_reads"|"writes"|"client_interface_name"|"nt_domain"|"nt_user_name"|"client_net_address"|"local_net_address"|"dma_source_id"|"dma_manual_id"|"client_version"|"protocol_type"|"protocol_version"|"protocol_hex_version"'
    Set-Content -Path $foldername\$dbsizesShort -Encoding utf8 -Value '"PKEY"|"database_name"|"type_desc"|"current_size_mb"|"recovery_model_desc"|"table_count"|"function_count"|"view_count"|"procedure_count"|"trigger_count"|"dma_source_id"|"dma_manual_id"'
    Set-Content -Path $foldername\$databaseLevelBlockingFeaturesShort -Encoding utf8 -Value '"PKEY"|"database_name"|"feature_name"|"is_enabled_or_used"|"occurance_count"|"dma_source_id"|"dma_manual_id"'
    Set-Content -Path $foldername\$deepScannerShort -Encoding utf8 -Value '"PKEY"|"database_name"|"schema_name"|"object_name"|"object_type"|"incompatibility_type"|"severity"|"violation_count"|"dma_source_id"|"dma_manual_id"'

    foreach ($databaseName in $dbNameArray) {
        $databaseName = $databaseName.Trim('"')
        if ($databaseName -inotmatch "tempdb") {
            WriteLog -logLocation $foldername\$logFile -logMessage "Retrieving SQL Server Object Info for Database $databaseName ..." -logOperation "BOTH"
            sqlcmd -S $serverName -i sql\objectList.sql -d $databaseName -C -l 30 -W -m 1 -u -h -1 -w 32768 -v pkey=$pkey -v database=$databaseName -v dmaSourceId=$dmaSourceId -v dmaManualId=$manualUniqueId -s "|" @sqlcmdAuthArgs | Where-Object { $_ -notmatch '---' } | Add-Content -Path $foldername\$objectListShort -Encoding utf8
            Update-DmaManifest -shortName $objectListShort -longName $objectListLong

            WriteLog -logLocation $foldername\$logFile -logMessage "Retrieving SQL Server Table Info for Database $databaseName ..." -logOperation "BOTH"
            sqlcmd -S $serverName -i sql\tableList.sql -d $databaseName -C -l 30 -W -m 1 -u -h -1 -w 32768 -v pkey=$pkey -v database=$databaseName -v dmaSourceId=$dmaSourceId -v dmaManualId=$manualUniqueId -s "|" @sqlcmdAuthArgs | Where-Object { $_ -notmatch '---' } | Add-Content -Path $foldername\$tableListShort -Encoding utf8
            Update-DmaManifest -shortName $tableListShort -longName $tableListLong

            WriteLog -logLocation $foldername\$logFile -logMessage "Retrieving SQL Server Index Info for Database $databaseName ..." -logOperation "BOTH"
            sqlcmd -S $serverName -i sql\indexList.sql -d $databaseName -C -l 30 -W -m 1 -u -h -1 -w 32768 -v pkey=$pkey -v database=$databaseName -v dmaSourceId=$dmaSourceId -v dmaManualId=$manualUniqueId -s "|" @sqlcmdAuthArgs | Where-Object { $_ -notmatch '---' } | Add-Content -Path $foldername\$indexListShort -Encoding utf8
            Update-DmaManifest -shortName $indexListShort -longName $indexListLong

            WriteLog -logLocation $foldername\$logFile -logMessage "Retrieving SQL Server Column Datatype Info for Database $databaseName ..." -logOperation "BOTH"
            sqlcmd -S $serverName -i sql\columnDatatypes.sql -d $databaseName -C -l 30 -W -m 1 -u -h -1 -w 32768 -v pkey=$pkey -v database=$databaseName -v dmaSourceId=$dmaSourceId -v dmaManualId=$manualUniqueId -s "|" @sqlcmdAuthArgs | Where-Object { $_ -notmatch '---' } | Add-Content -Path $foldername\$columnDatatypesShort -Encoding utf8
            Update-DmaManifest -shortName $columnDatatypesShort -longName $columnDatatypesLong

            WriteLog -logLocation $foldername\$logFile -logMessage "Retrieving SQL Server User Connection Info for Database $databaseName ..." -logOperation "BOTH"
            sqlcmd -S $serverName -i sql\userConnectionInfo.sql -d $databaseName -C -l 30 -W -m 1 -u -h -1 -w 32768 -v pkey=$pkey -v database=$databaseName -v dmaSourceId=$dmaSourceId -v dmaManualId=$manualUniqueId -s "|" @sqlcmdAuthArgs | Where-Object { $_ -notmatch '---' } | Add-Content -Path $foldername\$userConnectionListShort -Encoding utf8
            Update-DmaManifest -shortName $userConnectionListShort -longName $userConnectionListLong

            WriteLog -logLocation $foldername\$logFile -logMessage "Retrieving SQL Server Blocked Features for Database $databaseName ..." -logOperation "BOTH"
            sqlcmd -S $serverName -i sql\dbServerFeaturesDatabaseLevel.sql -d $databaseName -C -l 30 -W -m 1 -u -h -1 -w 32768 -v pkey=$pkey -v database=$databaseName -v dmaSourceId=$dmaSourceId -v dmaManualId=$manualUniqueId -s "|" @sqlcmdAuthArgs | Where-Object { $_ -notmatch '---' } | Add-Content -Path $foldername\$databaseLevelBlockingFeaturesShort -Encoding utf8
            Update-DmaManifest -shortName $databaseLevelBlockingFeaturesShort -longName $databaseLevelBlockingFeaturesLong
        }

        WriteLog -logLocation $foldername\$logFile -logMessage "Retrieving SQL Server Database Size Info for Database $databaseName ..." -logOperation "BOTH"
        sqlcmd -S $serverName -i sql\dbSizes.sql -d $databaseName -C -l 30 -W -m 1 -u -h -1 -w 32768 -v pkey=$pkey -v database=$databaseName -v dmaSourceId=$dmaSourceId -v dmaManualId=$manualUniqueId -s "|" @sqlcmdAuthArgs | Where-Object { $_ -notmatch '---' } | Add-Content -Path $foldername\$dbsizesShort -Encoding utf8
        Update-DmaManifest -shortName $dbsizesShort -longName $dbsizesLong

        WriteLog -logLocation $foldername\$logFile -logMessage "Retrieving SQL Server Deep Postgres Migration Blocker Info for Database $databaseName ..." -logOperation "BOTH"
        sqlcmd -S $serverName -i sql\tsqlPostgresDeepScanner.sql -d $databaseName -C -l 30 -W -m 1 -u -h -1 -w 32768 -v pkey=$pkey -v database=$databaseName -v dmaSourceId=$dmaSourceId -v dmaManualId=$manualUniqueId -s "|" @sqlcmdAuthArgs | Where-Object { $_ -notmatch '---' } | Add-Content -Path $foldername\$deepScannerShort -Encoding utf8
        Update-DmaManifest -shortName $deepScannerShort -longName $deepScannerLong
    }

    if ($isCloudOrLinuxHost -eq "AZURE") {
        WriteLog -logLocation $foldername\$logFile -logMessage "Skipping SQL Server Temp Table Info...Unavailable in AZURE SQL Managed Instance." -logOperation "BOTH"
    }
    else {
        WriteLog -logLocation $foldername\$logFile -logMessage "Retrieving SQL Server Temp Table Info..." -logOperation "BOTH"
        sqlcmd -S $serverName -i sql\tableList.sql -d tempdb -C -l 30 -W -m 1 -u -h -1 -w 32768 -v pkey=$pkey -v database=$databaseName -v dmaSourceId=$dmaSourceId -v dmaManualId=$manualUniqueId -s "|" @sqlcmdAuthArgs | Where-Object { $_ -notmatch '---' } | Add-Content -Path $foldername\$tableListShort -Encoding utf8
        Update-DmaManifest -shortName $tableListShort -longName $tableListLong
    }

    if ($ignorePerfmon -eq "true") {
        WriteLog -logLocation $foldername\$logFile -logMessage "Skipping Perfmon Information..." -logOperation "FILE"
        if (($instancename -eq "MSSQLSERVER") -and ([string]$env:computername.toUpper() -ne [string]$machinename.toUpper())) {
            .\dmaSQLServerPerfmonDataset.ps1 -operation createemptyfile -perfmonOutDir $foldername -perfmonOutFile $perfMonOutputShort -pkey $pkey -dmaSourceId $dmaSourceId -dmaManualId $manualUniqueId
        }
        else {
            .\dmaSQLServerPerfmonDataset.ps1 -operation createemptyfile -namedInstanceName $instancename -perfmonOutDir $foldername -perfmonOutFile $perfMonOutputShort -pkey $pkey -dmaSourceId $dmaSourceId -dmaManualId $manualUniqueId
        }
    }
    else {
        WriteLog -logLocation $foldername\$logFile -logMessage "Retrieving Perfmon Information..." -logOperation "FILE"
        if (($instancename -eq "MSSQLSERVER") -and ([string]$env:computername.toUpper() -eq [string]$machinename.toUpper())) {
            .\dmaSQLServerPerfmonDataset.ps1 -operation collect -perfmonOutDir $foldername -perfmonOutFile $perfMonOutputShort -pkey $pkey -dmaSourceId $dmaSourceId -dmaManualId $manualUniqueId
        }
        elseif (($instancename -ne "MSSQLSERVER") -and ([string]$env:computername.toUpper() -eq [string]$machinename.toUpper())) {
            .\dmaSQLServerPerfmonDataset.ps1 -operation collect -namedInstanceName $instancename -perfmonOutDir $foldername -perfmonOutFile $perfMonOutputShort -pkey $pkey -dmaSourceId $dmaSourceId -dmaManualId $manualUniqueId
        }
        elseif (($instancename -eq "MSSQLSERVER") -and ([string]$env:computername.toUpper() -ne [string]$machinename.toUpper())) {
            .\dmaSQLServerPerfmonDataset.ps1 -operation createemptyfile -perfmonOutDir $foldername -perfmonOutFile $perfMonOutputShort -pkey $pkey -dmaSourceId $dmaSourceId -dmaManualId $manualUniqueId
        }
        elseif (($instancename -ne "MSSQLSERVER") -and ([string]$env:computername.toUpper() -ne [string]$machinename.toUpper())) {
            .\dmaSQLServerPerfmonDataset.ps1 -operation createemptyfile -namedInstanceName $instancename -perfmonOutDir $foldername -perfmonOutFile $perfMonOutputShort -pkey $pkey -dmaSourceId $dmaSourceId -dmaManualId $manualUniqueId
        }
    }

    if ($isCloudOrLinuxHost -eq "AZURE") {
        WriteLog -logLocation $foldername\$logFile -logMessage "Executing Azure-Specific Compute and Governance Stats..." -logOperation "BOTH"

        $azureDbResShort = 'azure_db_resource_stats.csv'
        $azureDbResLong = 'opdb' + '__' + 'AzureDbResourceStats' + $outputFileSuffix
        Set-Content -Path $foldername\$azureDbResShort -Encoding utf8 -Value '"PKEY"|"end_time"|"avg_cpu_percent"|"avg_data_io_percent"|"avg_log_write_percent"|"max_worker_percent"|"max_session_percent"|"current_limit"|"current_storage_usage_db"|"dma_source_id"|"dma_manual_id"'
        sqlcmd -S $serverName -i sql\azureDbResourceStats.sql -d $dbname -C -l 30 -W -m 1 -u -h -1 -w 32768 -v pkey=$pkey -v dmaSourceId=$dmaSourceId -v dmaManualId=$manualUniqueId -s "|" @sqlcmdAuthArgs | Where-Object { $_ -notmatch '---' } | Add-Content -Path $foldername\$azureDbResShort -Encoding utf8
        Update-DmaManifest -shortName $azureDbResShort -longName $azureDbResLong

        $azureResShort = 'azure_historical_resource_stats.csv'
        $azureResLong = 'opdb' + '__' + 'AzureResourceStats' + $outputFileSuffix
        Set-Content -Path $foldername\$azureResShort -Encoding utf8 -Value '"PKEY"|"start_time"|"end_time"|"database_name"|"sku"|"avg_cpu_percent"|"avg_data_io_percent"|"avg_log_write_percent"|"max_worker_percent"|"max_session_percent"|"dtu_limit"|"dma_source_id"|"dma_manual_id"'
        sqlcmd -S $serverName -i sql\azureResourceStats.sql -d master -C -l 30 -W -m 1 -u -h -1 -w 32768 -v pkey=$pkey -v dmaSourceId=$dmaSourceId -v dmaManualId=$manualUniqueId -s "|" @sqlcmdAuthArgs | Where-Object { $_ -notmatch '---' } | Add-Content -Path $foldername\$azureResShort -Encoding utf8
        Update-DmaManifest -shortName $azureResShort -longName $azureResLong

        $azureGovShort = 'azure_resource_governance.csv'
        $azureGovLong = 'opdb' + '__' + 'AzureResourceGovernance' + $outputFileSuffix
        Set-Content -Path $foldername\$azureGovShort -Encoding utf8 -Value '"PKEY"|"database_id"|"logical_cpu_count"|"process_memory_limit_mb"|"max_global_index_size_mb"|"user_data_cap_gb"|"user_data_iops_cap"|"log_write_cap_mb_sec"|"dma_source_id"|"dma_manual_id"'
        sqlcmd -S $serverName -i sql\azureResourceGovernance.sql -d $dbname -C -l 30 -W -m 1 -u -h -1 -w 32768 -v pkey=$pkey -v dmaSourceId=$dmaSourceId -v dmaManualId=$manualUniqueId -s "|" @sqlcmdAuthArgs | Where-Object { $_ -notmatch '---' } | Add-Content -Path $foldername\$azureGovShort -Encoding utf8
        Update-DmaManifest -shortName $azureGovShort -longName $azureGovLong

        $azurePoolShort = 'azure_elastic_pool_stats.csv'
        $azurePoolLong = 'opdb' + '__' + 'AzureElasticPoolStats' + $outputFileSuffix
        Set-Content -Path $foldername\$azurePoolShort -Encoding utf8 -Value '"PKEY"|"end_time"|"elastic_pool_name"|"avg_cpu_percent"|"avg_data_io_percent"|"avg_log_write_percent"|"max_worker_percent"|"elastic_pool_dtu_limit"|"dma_source_id"|"dma_manual_id"'
        sqlcmd -S $serverName -i sql\azureElasticPoolStats.sql -d master -C -l 30 -W -m 1 -u -h -1 -w 32768 -v pkey=$pkey -v dmaSourceId=$dmaSourceId -v dmaManualId=$manualUniqueId -s "|" @sqlcmdAuthArgs | Where-Object { $_ -notmatch '---' } | Add-Content -Path $foldername\$azurePoolShort -Encoding utf8
        Update-DmaManifest -shortName $azurePoolShort -longName $azurePoolLong
    }

    WriteLog -logLocation $foldername\$logFile -logMessage "Retrieving SQL Server HW Shape Info for Machine $machinename via T-SQL..." -logOperation "BOTH"
    Set-Content -Path $foldername\$computerSpecsFileShort -Encoding utf8 -Value '"pkey"|"dma_source_id"|"dma_manual_id"|"MachineName"|"PhysicalCpuCount"|"LogicalCpuCount"|"TotalOSMemoryMB"'
    sqlcmd -S $serverName -i sql\machineSpecsTsql.sql -d master -C -l 30 -W -m 1 -u -h -1 -w 32768 -v pkey=$pkey -v dmaSourceId=$dmaSourceId -v dmaManualId=$manualUniqueId -s "|" @sqlcmdAuthArgs | Where-Object { $_ -notmatch '---' } | Add-Content -Path $foldername\$computerSpecsFileShort -Encoding utf8
    Update-DmaManifest -shortName $computerSpecsFileShort -longName $computerSpecsFileLong

    WriteLog -logLocation $foldername\$logFile -logMessage "Remove special characters and UTF8 BOM from extracted files..." -logOperation "BOTH"

    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    $LF = "`n"

    foreach ($file in Get-ChildItem -Path $foldername\*.csv -ErrorAction Stop) {
        $inputFile = $file.FullName
        $tempFile = "$inputFile.tmp"
        WriteLog -logLocation $foldername\$logFile -logMessage "     Processing $($file.Name)..." -logOperation "BOTH"

        $writer = $null
        try {
            $writer = New-Object System.IO.StreamWriter -ArgumentList $tempFile, $false, $utf8NoBom
            $lines = Get-Content -Path $inputFile
            $firstLine = $true
            foreach ($line in $lines) {
                $cleanLine = $line.Replace("`r", "")
                if (-not $firstLine) {
                    $writer.Write($LF)
                }
                $writer.Write($cleanLine)
                $firstLine = $false
            }
            if (-not $firstLine) {
                $writer.Write($LF)
            }
        }
        catch {
            WriteLog -logLocation $foldername\$logFile -logMessage "          Error processing file $($file.Name): $($_.Exception.Message)" -logOperation "BOTH"
            continue
        }
        finally {
            if ($writer) {
                $writer.Close()
                $writer.Dispose()
            }
        }

        try {
            Remove-Item $inputFile -Force -ErrorAction Stop
            Rename-Item $tempFile -NewName $file.Name -Force -ErrorAction Stop
            WriteLog -logLocation $foldername\$logFile -logMessage "          $($file.Name) successfully processed..." -logOperation "BOTH"
        }
        catch {
            WriteLog -logLocation $foldername\$logFile -logMessage "          Failed to replace the original file $($file.Name). Temp file may remain. Error: $($_.Exception.Message)" -logOperation "BOTH"
            Remove-Item $tempFile -ErrorAction SilentlyContinue
        }
    }

    WriteLog -logLocation $foldername\$logFile -logMessage "Creating the manifest..." -logOperation "BOTH"
    foreach ($file in Get-ChildItem -Path $foldername\*.csv) {
        $inputFile = Split-Path -Leaf $file
        createManifestFile -manifestFileLocation $foldername -manifestOutputFileName $manifestFile -manifestedFileName $inputFile
    }

    WriteLog -logLocation $foldername\$logFile -logMessage "Checking for error messages within collection files..." -logOperation "BOTH"
    foreach ($file in Get-ChildItem -Path $foldername\*.csv, $foldername\*.log) {
        $inputFile = Split-Path -Leaf $file
        $errorContentCount = 0
        [regex]$pattern = "(Msg(\s\d*)(.)(\n|\s)Level(\s\d*.)(\n|\s)State(\s\d*)(.)(\n|\s))"
        $content = Get-Content -Path $foldername\$inputFile | select-string -Pattern $pattern
        if (![string]::IsNullOrEmpty($content)) {
            $errorContentCount = 1
        }
        else {
            $errorContentCount = 0
        }
        WriteLog -logLocation $foldername\$sqlErrorLogFile -logMessage "Checking for error messages within collection $inputFile ..." -logOperation "FILE"
        if ($errorContentCount -gt 0) {
            WriteLog -logLocation $foldername\$sqlErrorLogFile -logMessage "     Errors found within collection $inputFile ..." -logOperation "FILE"
        }
        $totalErrorCount = $totalErrorCount + $errorContentCount
    }

    WriteLog -logLocation $foldername\$logFile -logMessage "Checking for the presence of all required files..." -logOperation "BOTH"
    foreach ($directory in $outputFileArray) {
        if (Test-Path -Path $PSScriptRoot\$foldername\$directory) {
            WriteLog -logLocation $foldername\$logFile -logMessage "  File $directory exists" -logOperation "FILE"
        }
        else {
            WriteLog -logLocation $foldername\$logFile -logMessage "  File $directory does not exist" -logOperation "BOTH"
            $totalErrorCount = $totalErrorCount + $errorContentCount
        }
    }

    if ($totalErrorCount -gt 0) {
        $zippedopfolder = $foldername + '_ERROR.zip'
    }
    else {
        $zippedopfolder = $foldername + '.zip'
    }

    if ($powerShellVersion -ge 5) {
        if (([string]::IsNullorEmpty($outputDirectory)) -or ($outputDirectory -eq "default")) {
            WriteLog -logLocation $foldername\$logFile -logMessage "Zipping Output to $zippedopfolder..." -logOperation "BOTH"
            Update-DmaManifest -shortName $logFileShort -longName $logFileLong
            Update-DmaManifest -shortName $sqlErrorLogFileShort -longName $sqlErrorLogFileLong
            Compress-Archive -Path $foldername\*.csv, $foldername\*.log, $foldername\*.txt, $foldername\*.json -DestinationPath $zippedopfolder
            $customOutputDir = 0
        } else {
            if ((Test-Path -Path $outputDirectory) -and ($outputDirectory -ne "default")) {
                WriteLog -logLocation $foldername\$logFile -logMessage "Zipping Output to $outputDirectory\$zippedopfolder..." -logOperation "BOTH"
                Compress-Archive -Path $foldername\*.csv, $foldername\*.log, $foldername\*.txt, $foldername\*.json -DestinationPath $outputDirectory\$zippedopfolder
                $customOutputDir = 1
            } else {
                WriteLog -logLocation $foldername\$logFile -logMessage "Specified $outputDirectory is not valid. Zipping Output to default directory $PSScriptRoot\$zippedopfolder..." -logOperation "BOTH"
                Compress-Archive -Path $foldername\*.csv, $foldername\*.log, $foldername\*.txt, $foldername\*.json -DestinationPath $zippedopfolder
                $customOutputDir = 0
            }
        }

        if (Test-Path -Path $zippedopfolder) {
            WriteLog -logLocation $foldername\$logFile -logMessage "Removing directory $foldername..." -logOperation "MESSAGE"
            Remove-Item -Path $foldername -Recurse -Force
        }
        if (Test-Path -Path $env:TEMP\tempDisk.csv) {
            WriteLog -logLocation $foldername\$logFile -logMessage "Clean up Temp File area..." -logOperation "MESSAGE"
            Remove-Item -Path $env:TEMP\tempDisk.csv
        }

        WriteLog -logLocation $foldername\$logFile -logMessage " " -logOperation "MESSAGE"
        WriteLog -logLocation $foldername\$logFile -logMessage " " -logOperation "MESSAGE"

        if ($customOutputDir -eq 0) {
            WriteLog -logLocation $foldername\$logFile -logMessage "Return file $PSScriptRoot\$zippedopfolder" -logOperation "MESSAGE"
            WriteLog -logLocation $foldername\$logFile -logMessage "to Google to complete assessment" -logOperation "MESSAGE"
        } else {
            WriteLog -logLocation $foldername\$logFile -logMessage "Return file $outputDirectory\$zippedopfolder" -logOperation "MESSAGE"
            WriteLog -logLocation $foldername\$logFile -logMessage "to Google to complete assessment" -logOperation "MESSAGE"
        }
        WriteLog -logLocation $foldername\$logFile -logMessage "Collection Complete..." -logOperation "MESSAGE"
    }
    else {
        WriteLog -logLocation $foldername\$logFile -logMessage " " -logOperation "MESSAGE"
        WriteLog -logLocation $foldername\$logFile -logMessage " " -logOperation "MESSAGE"
        WriteLog -logLocation $foldername\$logFile -logMessage "Please manually zip the files in $foldername and" -logOperation "MESSAGE"
        WriteLog -logLocation $foldername\$logFile -logMessage "return to Google to complete assessment" -logOperation "MESSAGE"
        WriteLog -logLocation $foldername\$logFile -logMessage "Collection Complete..." -logOperation "MESSAGE"
    }

    if (-not ([string]::IsNullOrEmpty($originalLocation)) -and ($originalLocation -ne $PSScriptRoot)) {
        $currentTimestamp = "[{0:MM/dd/yy} {0:HH:mm:ss}]" -f (Get-Date)
        Write-Host "$currentTimestamp Changing directory back to: $originalLocation"
        Pop-Location
    }

    if ($global:persistentSqlConn) {
        try {
            $global:persistentSqlConn.Close()
            $global:persistentSqlConn.Dispose()
        } catch { }
        $global:persistentSqlConn = $null
    }

    Exit 0
}
