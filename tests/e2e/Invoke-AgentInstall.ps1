<#
.SYNOPSIS
Runs install.ps1 the way a user would, for the end-to-end tests.

.DESCRIPTION
-Entry picks how install.ps1 is started. All of them run in Windows
PowerShell 5.1 (powershell.exe), like on a fresh Windows machine:

  bat          main.bat with command line arguments (from cmd.exe)
  file         powershell.exe -File install.ps1 ...
  call         & .\install.ps1 @parameters inside a session (needed for -ServiceCredential)
  scriptblock  & ([scriptblock]::Create((irm .../install.ps1))) @parameters
  iex          environment variables + (irm .../install.ps1) | iex

The test setup comes from E2E_* environment variables set by the workflow
and Start-JenkinsController.ps1.
#>
param(
    [ValidateSet('bat', 'file', 'call', 'scriptblock', 'iex')]
    [string] $Entry = $env:E2E_ENTRY,
    [string] $JavaVersion = $env:E2E_AGENT_JAVA,
    [string] $Secret,
    [int] $ConnectTimeout = 180,
    [switch] $Uninstall,
    # When set, the run must fail and its output must match this regex.
    [string] $ExpectFailure
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$installScript = Join-Path $root 'install.ps1'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

$parameters = [ordered]@{}
if ($Uninstall) {
    $parameters.Uninstall = $true
    $parameters.InstallDir = $env:E2E_INSTALL_DIR
} else {
    $parameters.JenkinsUrl = $env:E2E_JENKINS_URL
    $parameters.AgentName = $env:E2E_AGENT_NAME
    if ($Secret) { $parameters.Secret = $Secret } else { $parameters.SecretFile = $env:E2E_SECRET_FILE }
    $parameters.InstallDir = $env:E2E_INSTALL_DIR
    $parameters.ConnectTimeout = $ConnectTimeout
    if ($JavaVersion -eq 'home') {
        $javaHome = $env:JAVA_HOME_21_X64
        if (-not $javaHome) { $javaHome = $env:JAVA_HOME }
        $parameters.JavaHome = $javaHome
    } elseif ($JavaVersion -and $JavaVersion -ne 'auto') {
        $parameters.JavaVersion = $JavaVersion
    }
    if ($env:E2E_JAVA_PACKAGE) { $parameters.JavaPackage = $env:E2E_JAVA_PACKAGE }
    if ($env:E2E_WEBSOCKET -eq 'true') { $parameters.WebSocket = $true }
    if ($env:E2E_WINDOWS_TRUSTSTORE -eq 'true') { $parameters.UseWindowsTrustStore = $true }
}

function ConvertTo-ArgumentList($Parameters) {
    $list = @()
    foreach ($key in $Parameters.Keys) {
        $value = $Parameters[$key]
        if ($value -is [bool]) {
            if ($value) { $list += "-$key" }
        } else {
            $list += "-$key"
            $list += [string] $value
        }
    }
    return $list
}

function ConvertTo-EncodedCommand([string] $Script) {
    return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
}

# Windows PowerShell code that rebuilds $p (the parameters) and, if the test
# runs the service as a local account, adds -ServiceCredential.
$json = ($parameters | ConvertTo-Json -Compress).Replace("'", "''")
$prologue = @"
`$ErrorActionPreference = 'Stop'
`$p = @{}
(ConvertFrom-Json '$json').PSObject.Properties | ForEach-Object { `$p[`$_.Name] = `$_.Value }
if (`$env:E2E_SERVICE_USER -and -not `$p.Contains('Uninstall')) {
    `$password = (New-Object System.Net.NetworkCredential('', `$env:E2E_SERVICE_PASSWORD)).SecurePassword
    `$p.ServiceCredential = New-Object System.Management.Automation.PSCredential(`$env:E2E_SERVICE_USER, `$password)
}
`$code = [System.IO.File]::ReadAllText('$installScript')
"@

switch ($Entry) {
    'bat' {
        $command = Join-Path $root 'main.bat'
        $arguments = ConvertTo-ArgumentList $parameters
    }
    'file' {
        $command = $powershell
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installScript) + (ConvertTo-ArgumentList $parameters)
    }
    'call' {
        $command = $powershell
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', (ConvertTo-EncodedCommand (
                    $prologue + "`n& '$installScript' @p`nexit `$LASTEXITCODE")))
    }
    'scriptblock' {
        $command = $powershell
        $arguments = @('-NoProfile', '-EncodedCommand', (ConvertTo-EncodedCommand (
                    $prologue + "`ntry { & ([scriptblock]::Create(`$code)) @p; exit 0 } catch { Write-Host `"ERROR: `$(`$_.Exception.Message)`"; exit 1 }")))
    }
    'iex' {
        # Only what environment variables can express.
        $supported = @('JenkinsUrl', 'AgentName', 'Secret', 'SecretFile', 'WebSocket', 'InstallDir', 'ConnectTimeout')
        foreach ($key in $parameters.Keys) {
            if ($supported -notcontains $key) { throw "-Entry iex cannot pass -$key" }
        }
        if ($parameters.InstallDir -ne 'C:\jenkins-agent') { throw '-Entry iex needs the default install directory C:\jenkins-agent' }
        $secretValue = $Secret
        if (-not $secretValue) { $secretValue = (Get-Content -LiteralPath $env:E2E_SECRET_FILE -Raw).Trim() }
        $env:JENKINS_URL = $parameters.JenkinsUrl
        $env:JENKINS_AGENT_NAME = $parameters.AgentName
        $env:JENKINS_SECRET = $secretValue
        $env:JENKINS_WEB_SOCKET = ([string] [bool] $parameters['WebSocket']).ToLowerInvariant()
        $command = $powershell
        $arguments = @('-NoProfile', '-EncodedCommand', (ConvertTo-EncodedCommand (
                    $prologue + "`ntry { `$code | Invoke-Expression; exit 0 } catch { Write-Host `"ERROR: `$(`$_.Exception.Message)`"; exit 1 }")))
    }
}

Write-Host "::group::install.ps1 via $Entry"
$output = New-Object System.Collections.Generic.List[string]
$ErrorActionPreference = 'Continue'
& $command @arguments 2>&1 | ForEach-Object {
    $text = "$_"
    $output.Add($text)
    Write-Host $text
}
$exitCode = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
Write-Host '::endgroup::'
foreach ($name in 'JENKINS_URL', 'JENKINS_AGENT_NAME', 'JENKINS_SECRET', 'JENKINS_WEB_SOCKET') {
    Remove-Item -Path "env:$name" -ErrorAction SilentlyContinue
}

$text = $output -join "`n"
if ($ExpectFailure) {
    if ($exitCode -eq 0) { throw "install.ps1 succeeded but was expected to fail with '$ExpectFailure'" }
    if ($text -notmatch $ExpectFailure) { throw "install.ps1 failed as expected, but its output does not match '$ExpectFailure'" }
    Write-Host "ok - install.ps1 failed as expected (exit code $exitCode, output matches '$ExpectFailure')"
} elseif ($exitCode -ne 0) {
    throw "install.ps1 failed with exit code $exitCode"
} else {
    Write-Host "ok - install.ps1 via $Entry succeeded"
}
# The workflow fails a step whose last native command failed, even when that
# failure was the expected outcome.
exit 0
