Param(
    [Parameter(Mandatory = $false)][string]$serverName = "sqlmi003centralus.public.8f8186726aad.database.windows.net",
    [Parameter(Mandatory = $false)][string]$port = "3342",
    [Parameter(Mandatory = $false)][string]$database = "master",
    [Parameter(Mandatory = $false)][string]$userName = "chapmantis@hotmail.com"
)

$sqlServerModule = Get-Module -ListAvailable SqlServer | Sort-Object Version -Descending | Select-Object -First 1
if ($null -eq $sqlServerModule) {
    throw "SqlServer PowerShell module is required. Run: Install-Module SqlServer -Scope CurrentUser -Force"
}

Import-Module $sqlServerModule.Path -Force

$serverInstance = "$serverName,$port"
$connectionString = "Server=$serverInstance;Database=$database;Authentication=Active Directory Interactive;User ID=$userName;Encrypt=True;TrustServerCertificate=True;Connection Timeout=30;"
$query = "SELECT @@SERVERNAME AS server_name, DB_NAME() AS database_name, SUSER_SNAME() AS login_name, SYSDATETIMEOFFSET() AS connected_at;"

Write-Host "Opening interactive MFA sign-in for $userName..."
Write-Host "Server: $serverInstance"
Write-Host "Database: $database"

Invoke-Sqlcmd -ConnectionString $connectionString -Query $query -QueryTimeout 30 -ErrorAction Stop | Format-List
