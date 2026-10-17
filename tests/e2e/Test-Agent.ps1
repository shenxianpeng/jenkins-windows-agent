<#
.SYNOPSIS
Checks an agent installed by install.ps1 against the test controller.

.DESCRIPTION
Default mode checks the Windows service, the files and their permissions,
that the node is online, and that a build runs on it. -CrashRecovery then
kills the agent's java.exe and checks that Windows restarts it.
-ExpectUninstalled checks that install.ps1 -Uninstall cleaned up.

The test setup comes from E2E_* environment variables.
#>
param(
    [int] $ExpectedJava,
    [switch] $CrashRecovery,
    [switch] $ExpectUninstalled,
    [string] $ServiceId = 'jenkins-agent'
)

$ErrorActionPreference = 'Stop'
$jenkinsUrl = $env:E2E_JENKINS_URL
$agentName = $env:E2E_AGENT_NAME
$installDir = $env:E2E_INSTALL_DIR
$agentPath = 'computer/' + [Uri]::EscapeDataString($agentName)

$headers = @{}
if ($env:E2E_ADMIN_USER) {
    $pair = "$($env:E2E_ADMIN_USER):$($env:E2E_ADMIN_PASSWORD)"
    $headers.Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
}

function Invoke-JenkinsApi([string] $Path, [string] $Method = 'Get') {
    return Invoke-RestMethod -Uri ($jenkinsUrl + $Path) -Method $Method -Headers $headers -UseBasicParsing
}

function Assert-That([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "not ok - $Message" }
    Write-Host "ok - $Message"
}

function Wait-Until([scriptblock] $Condition, [int] $TimeoutSeconds, [string] $Message) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        $result = $false
        try { $result = [bool] (& $Condition) } catch { Write-Verbose $_.Exception.Message }
        if ($result) { Write-Host "ok - $Message"; return }
        if ((Get-Date) -gt $deadline) { throw "not ok - $Message (timed out after $TimeoutSeconds seconds)" }
        Start-Sleep -Seconds 3
    }
}

function Get-AgentService { Get-CimInstance -ClassName Win32_Service -Filter "Name='$ServiceId'" }

function Test-AgentOnline { -not (Invoke-JenkinsApi "$agentPath/api/json?tree=offline").offline }

function Invoke-SmokeBuild([string] $ExpectedUser) {
    $number = (Invoke-JenkinsApi 'job/smoke/api/json?tree=nextBuildNumber').nextBuildNumber
    $null = Invoke-WebRequest -Uri ($jenkinsUrl + 'job/smoke/build') -Method Post -Headers $headers -UseBasicParsing
    Wait-Until -TimeoutSeconds 300 -Message "build #$number finished" -Condition {
        (Invoke-JenkinsApi "job/smoke/$number/api/json?tree=result").result
    }
    $build = Invoke-JenkinsApi "job/smoke/$number/api/json?tree=result,builtOn"
    $console = Invoke-JenkinsApi "job/smoke/$number/consoleText"
    Write-Host $console
    Assert-That ($build.result -eq 'SUCCESS') "build #$number succeeded (result: $($build.result))"
    Assert-That ($build.builtOn -eq $agentName) "build #$number ran on '$agentName' (builtOn: '$($build.builtOn)')"
    Assert-That ($console -match "E2E-MARKER node=$([regex]::Escape($agentName))") 'build output comes from the agent'
    Assert-That ($console -match "(?m)^$([regex]::Escape($ExpectedUser))\s*$") "build runs as $ExpectedUser"
}

function Get-JavaVersionOutput([string] $JavaExe) {
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo($JavaExe, '-version')
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardOutput = $true
    $process = [System.Diagnostics.Process]::Start($startInfo)
    $text = $process.StandardError.ReadToEnd() + $process.StandardOutput.ReadToEnd()
    $process.WaitForExit()
    return $text
}

if ($ExpectUninstalled) {
    Assert-That (-not (Get-AgentService)) "service '$ServiceId' is removed"
    foreach ($item in 'jenkins-agent.exe', 'jenkins-agent.xml', 'agent.jar', 'secret-file', 'java', 'logs') {
        Assert-That (-not (Test-Path -LiteralPath (Join-Path $installDir $item))) "$item is removed"
    }
    Assert-That (Test-Path -LiteralPath (Join-Path $installDir 'remoting')) 'the work directory is kept'
    Wait-Until -TimeoutSeconds 120 -Message "agent '$agentName' is offline" -Condition { -not (Test-AgentOnline) }
    return
}

# --- Windows service ----------------------------------------------------------------
$expectedAccount = 'LocalSystem'
$expectedUser = 'nt authority\system'
if ($env:E2E_SERVICE_USER) {
    $expectedAccount = $env:E2E_SERVICE_USER
    $expectedUser = "$($env:COMPUTERNAME)\$($env:E2E_SERVICE_USER.Split('\')[-1])".ToLowerInvariant()
}
$service = Get-AgentService
Assert-That ($null -ne $service) "service '$ServiceId' exists"
Assert-That ($service.State -eq 'Running') "service is running (state: $($service.State))"
Assert-That ($service.StartMode -eq 'Auto') "service starts automatically (start mode: $($service.StartMode))"
Assert-That ([bool] $service.DelayedAutoStart) 'service uses delayed automatic start'
Assert-That ($service.StartName -eq $expectedAccount) "service runs as $expectedAccount (actual: $($service.StartName))"
$failureActions = & sc.exe qfailure $ServiceId | Out-String
Assert-That ($failureActions -match 'RESTART -- Delay = 10000') 'service restarts 10 seconds after a failure'
$failureFlag = & sc.exe qfailureflag $ServiceId | Out-String
Assert-That ($failureFlag -match 'TRUE') 'restart also applies when the agent exits with an error'

# --- Files ------------------------------------------------------------------------------
$secret = (Get-Content -LiteralPath $env:E2E_SECRET_FILE -Raw).Trim()
$configText = Get-Content -LiteralPath (Join-Path $installDir 'jenkins-agent.xml') -Raw
Assert-That (-not $configText.Contains($secret)) 'the service configuration does not contain the secret'
Assert-That ($configText -notmatch '<password>') 'the service configuration does not contain a password'
$javaExe = ([xml] $configText).service.executable
$javaOutput = Get-JavaVersionOutput $javaExe
Write-Host $javaOutput
if ($ExpectedJava) {
    $pattern = if ($ExpectedJava -eq 8) { 'version "1\.8\.' } else { "version `"$ExpectedJava[.`"]" }
    Assert-That ($javaOutput -match $pattern) "the service uses Java $ExpectedJava ($javaExe)"
}

$broad = '^(BUILTIN\\Users|NT AUTHORITY\\Authenticated Users|Everyone)$'
$writeRights = [System.Security.AccessControl.FileSystemRights] 'WriteData, AppendData, Delete, ChangePermissions, TakeOwnership'
$writable = @((Get-Acl -LiteralPath $installDir).Access | Where-Object {
        $_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -match $broad -and ($_.FileSystemRights -band $writeRights)
    })
Assert-That ($writable.Count -eq 0) 'ordinary users cannot change the install directory'
$secretAcl = Get-Acl -LiteralPath (Join-Path $installDir 'secret-file')
Assert-That $secretAcl.AreAccessRulesProtected 'the secret file does not inherit permissions'
$readers = @($secretAcl.Access | Where-Object { $_.IdentityReference.Value -match $broad })
Assert-That ($readers.Count -eq 0) 'ordinary users cannot read the secret file'

# --- Controller -------------------------------------------------------------------------
Wait-Until -TimeoutSeconds 180 -Message "agent '$agentName' is online" -Condition { Test-AgentOnline }
Invoke-SmokeBuild -ExpectedUser $expectedUser

if ($CrashRecovery) {
    $wrapperPid = [int] $service.ProcessId
    $java = @(Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId=$wrapperPid" | Where-Object { $_.Name -eq 'java.exe' })
    Assert-That ($java.Count -eq 1) "the service runs one java.exe (pid $($java.ProcessId))"
    Write-Host "Killing java.exe (pid $($java[0].ProcessId)) to simulate a crash"
    Stop-Process -Id $java[0].ProcessId -Force
    Wait-Until -TimeoutSeconds 180 -Message 'Windows restarted the service after the crash' -Condition {
        $now = Get-AgentService
        $now.State -eq 'Running' -and [int] $now.ProcessId -ne $wrapperPid
    }
    Wait-Until -TimeoutSeconds 180 -Message "agent '$agentName' reconnected" -Condition { Test-AgentOnline }
    Invoke-SmokeBuild -ExpectedUser $expectedUser
}
