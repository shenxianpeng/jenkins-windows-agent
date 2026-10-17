<#
.SYNOPSIS
Installs a Jenkins inbound agent as a Windows service in one command.

.DESCRIPTION
install.ps1 prepares a Windows machine to run a Jenkins inbound agent
("Launch agent by connecting it to the controller") as a Windows service:

  * Downloads Eclipse Temurin Java 8, 11, 17, 21 or 25. By default it picks
    the version that matches the Jenkins controller.
  * Downloads agent.jar from the controller, so both always match.
  * Downloads WinSW v2.12.0 (checksum verified) and registers the service
    with delayed automatic start and automatic restart on failure.
  * Keeps the agent secret in a file only Administrators and SYSTEM can read.
  * Waits until the agent is connected and explains what to fix if it is not.

Run it again at any time to upgrade Java, refresh agent.jar or change
settings. Run it with -Uninstall to remove the service.

Needs Windows PowerShell 5.1 (or PowerShell 7) and an elevated
("Run as administrator") session.

.PARAMETER JenkinsUrl
Root URL of the Jenkins controller, for example https://jenkins.example.com/.
A JNLP URL such as http://host:8080/computer/win-01/jenkins-agent.jnlp also
works; the agent name is then taken from it. Default: $env:JENKINS_URL.

.PARAMETER AgentName
Name of the node on the controller. Default: $env:JENKINS_AGENT_NAME.

.PARAMETER Secret
Agent secret shown on the node page in Jenkins. Default: $env:JENKINS_SECRET.
Use -SecretFile or the environment variable to keep it out of shell history.

.PARAMETER SecretFile
File that contains the agent secret.

.PARAMETER JavaVersion
Java feature version to download: auto, 8, 11, 17, 21 or 25. "auto" (the
default) picks the version recommended for the controller's Jenkins version.

.PARAMETER JavaHome
Use an existing Java installation instead of downloading one.

.PARAMETER JavaPackage
Download a "jre" (default, smaller) or a full "jdk".

.PARAMETER InstallDir
Directory for Java, agent.jar, the service wrapper and logs.
Default: C:\jenkins-agent.

.PARAMETER WorkDir
Agent work directory. Use the same path as "Remote root directory" on the
node configuration page. Default: the install directory.

.PARAMETER WebSocket
Connect over WebSocket (HTTP/HTTPS port only) instead of the inbound TCP
port. Default: $env:JENKINS_WEB_SOCKET -eq 'true'.

.PARAMETER ServiceId
Windows service name. Default: jenkins-agent.

.PARAMETER ServiceCredential
Run the service as this account (DOMAIN\user or .\user) instead of
LocalSystem. Example: -ServiceCredential (Get-Credential)

.PARAMETER JavaOptions
Extra JVM options, for example -JavaOptions '-Xmx1g'.

.PARAMETER AgentOptions
Extra agent.jar options, for example -AgentOptions '-noReconnectAfter','1h'.

.PARAMETER UseWindowsTrustStore
Make Java trust the certificates in the Windows certificate store. Use it
when the controller uses a certificate from a company CA.

.PARAMETER ConnectTimeout
Seconds to wait for the agent to connect. 0 skips the check. Default: 120.

.PARAMETER NoStart
Install the service but do not start it.

.PARAMETER Force
Continue even if the selected Java version is too old for the controller.

.PARAMETER Uninstall
Stop and remove the service and the files this script created. The work
directory (workspaces) is left in place.

.EXAMPLE
.\install.ps1 -JenkinsUrl https://jenkins.example.com/ -AgentName win-01 -Secret <secret>

.EXAMPLE
.\install.ps1 -JenkinsUrl https://jenkins.example.com/ -AgentName win-01 -SecretFile C:\secret.txt -JavaVersion 17 -WebSocket

.EXAMPLE
.\install.ps1 -Uninstall

.LINK
https://github.com/shenxianpeng/jenkins-windows-agent
#>
[CmdletBinding()]
param(
    [string] $JenkinsUrl = $env:JENKINS_URL,
    [string] $AgentName = $env:JENKINS_AGENT_NAME,
    [string] $Secret = $env:JENKINS_SECRET,
    [string] $SecretFile,
    [ValidateSet('auto', '8', '11', '17', '21', '25')]
    [string] $JavaVersion = 'auto',
    [string] $JavaHome,
    [ValidateSet('jre', 'jdk')]
    [string] $JavaPackage = 'jre',
    [string] $InstallDir = 'C:\jenkins-agent',
    [string] $WorkDir,
    [switch] $WebSocket,
    [string] $ServiceId = 'jenkins-agent',
    [pscredential] [System.Management.Automation.Credential()]
    $ServiceCredential = [pscredential]::Empty,
    [string[]] $JavaOptions = @(),
    [string[]] $AgentOptions = @(),
    [switch] $UseWindowsTrustStore,
    [ValidateRange(0, 3600)]
    [int] $ConnectTimeout = 120,
    [switch] $NoStart,
    [switch] $Force,
    [switch] $Uninstall
)

$script:WinSWUrl = 'https://github.com/winsw/winsw/releases/download/v2.12.0/WinSW-x64.exe'
$script:WinSWSha256 = '05B82D46AD331CC16BDC00DE5C6332C1EF818DF8CEEFCD49C726553209B3A0DA'
$script:AdoptiumApi = 'https://api.adoptium.net/v3'

# Java versions supported by each Jenkins release line (the "NNN" in 2.NNN).
# The same requirements apply to agents. Source:
# https://www.jenkins.io/doc/book/platform-information/support-policy-java/
$script:JavaSupport = @(
    @{ Java = 8; First = 54; Last = 356 }
    @{ Java = 11; First = 164; Last = 462 }
    @{ Java = 17; First = 340; Last = 544 }
    @{ Java = 21; First = 463; Last = [int]::MaxValue }
    @{ Java = 25; First = 534; Last = [int]::MaxValue }
)

# File names inside the install directory.
$script:WrapperName = 'jenkins-agent'
$script:SecretFileName = 'secret-file'
$script:MarkerFileName = 'jenkins-windows-agent.txt'

#region Output

function Write-Step([string] $Message) {
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Detail([string] $Message) {
    Write-Host "    $Message"
}

#endregion

#region Pure helpers (covered by tests/install.Tests.ps1)

function ConvertTo-JenkinsLine([string] $Version) {
    # '2.580.1' -> 580. Jenkins 1.x is older than every line in the table.
    if ($Version -match '^\s*(\d+)\.(\d+)') {
        if ([int] $Matches[1] -ge 2) { return [int] $Matches[2] }
        return 0
    }
    return $null
}

function Test-JavaSupported([int] $Java, [int] $Line) {
    foreach ($entry in $script:JavaSupport) {
        if ($entry.Java -eq $Java) {
            return ($Line -ge $entry.First -and $Line -le $entry.Last)
        }
    }
    return $false
}

function Get-MinimumJavaVersion([int] $Line) {
    $candidates = @($script:JavaSupport | Where-Object { $_.Last -ge $Line } | ForEach-Object { $_.Java })
    return ($candidates | Measure-Object -Minimum).Minimum
}

function Get-RecommendedJavaVersion([int] $Line) {
    # The newest supported Java, capped at 21: Java 25 is opt-in for now.
    $candidates = @($script:JavaSupport |
        Where-Object { $Line -ge $_.First -and $Line -le $_.Last -and $_.Java -le 21 } |
        ForEach-Object { $_.Java })
    if ($candidates.Count -eq 0) { return 8 }
    return ($candidates | Measure-Object -Maximum).Maximum
}

function ConvertTo-JavaFeatureVersion([string] $VersionOutput) {
    # 'openjdk version "1.8.0_462"' -> 8, 'openjdk version "21.0.8" 2025-07-15' -> 21
    if ($VersionOutput -match 'version "1\.(\d+)') { return [int] $Matches[1] }
    if ($VersionOutput -match 'version "(\d+)') { return [int] $Matches[1] }
    throw "Cannot find the Java version in: $VersionOutput"
}

function Split-JenkinsUrl([string] $Url) {
    if ($null -eq $Url) { $Url = '' }
    $Url = $Url.Trim()
    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref] $uri) -or ($uri.Scheme -ne 'http' -and $uri.Scheme -ne 'https')) {
        throw "-JenkinsUrl must be an http:// or https:// URL, for example https://jenkins.example.com/ (got '$Url')."
    }
    $name = $null
    if ($Url -match '^(?<root>.+?/)computer/(?<name>[^/]+)/(?:jenkins|slave)-agent\.jnlp/?$') {
        $Url = $Matches['root']
        $name = [Uri]::UnescapeDataString($Matches['name'])
    }
    if (-not $Url.EndsWith('/')) { $Url += '/' }
    return [pscustomobject]@{ Url = $Url; AgentName = $name }
}

function ConvertTo-QuotedArgument([string] $Argument) {
    # Quote one argument so that Windows (CommandLineToArgvW / the MSVC runtime)
    # parses it back unchanged.
    if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') { return $Argument }
    $escaped = $Argument -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function ConvertTo-CommandLine([string[]] $ArgumentList) {
    return (@($ArgumentList) | ForEach-Object { ConvertTo-QuotedArgument $_ }) -join ' '
}

function Get-AgentArgumentList {
    param(
        [string] $AgentJar,
        [string] $JenkinsUrl,
        [string] $AgentName,
        [string] $SecretPath,
        [string] $WorkDir,
        [bool] $SupportsUrl,
        [bool] $WebSocket,
        [string[]] $JavaOptions = @(),
        [string[]] $AgentOptions = @()
    )
    $list = New-Object 'System.Collections.Generic.List[string]'
    foreach ($option in $JavaOptions) { if ($option) { $list.Add($option) } }
    $list.Add('-jar')
    $list.Add($AgentJar)
    if ($SupportsUrl) {
        $list.Add('-url'); $list.Add($JenkinsUrl)
        $list.Add('-name'); $list.Add($AgentName)
        if ($WebSocket) { $list.Add('-webSocket') }
    } else {
        # Remoting before -url/-name existed (Jenkins 2.4xx and older).
        $list.Add('-jnlpUrl')
        $list.Add($JenkinsUrl + 'computer/' + [Uri]::EscapeDataString($AgentName) + '/jenkins-agent.jnlp')
    }
    # "@file" makes agent.jar read the secret from the file, so it never
    # appears in the service configuration or the process command line.
    $list.Add('-secret'); $list.Add('@' + $SecretPath)
    $list.Add('-workDir'); $list.Add($WorkDir)
    foreach ($option in $AgentOptions) { if ($option) { $list.Add($option) } }
    return $list.ToArray()
}

function Split-AccountName([string] $UserName) {
    if ($UserName -match '^(?<domain>[^\\]+)\\(?<user>[^\\]+)$') {
        return [pscustomobject]@{ Domain = $Matches['domain']; User = $Matches['user'] }
    }
    if ($UserName -match '[\\@]') {
        throw "Use DOMAIN\user or .\user for -ServiceCredential (got '$UserName')."
    }
    return [pscustomobject]@{ Domain = '.'; User = $UserName }
}

function New-WinSWConfig {
    param(
        [string] $ServiceId,
        [string] $AgentName,
        [string] $JenkinsUrl,
        [string] $JavaExe,
        [string[]] $ArgumentList,
        [string] $WorkingDirectory,
        [string] $LogDirectory,
        [pscredential] $Credential
    )
    $e = { param($value) [System.Security.SecurityElement]::Escape([string] $value) }
    $lines = @(
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<!--'
        '  Generated by install.ps1 (https://github.com/shenxianpeng/jenkins-windows-agent).'
        '  Run install.ps1 again instead of editing this file.'
        '-->'
        '<service>'
        "  <id>$(& $e $ServiceId)</id>"
        "  <name>$(& $e "Jenkins Agent ($AgentName)")</name>"
        "  <description>$(& $e "Jenkins inbound agent '$AgentName' connected to $JenkinsUrl")</description>"
        "  <executable>$(& $e $JavaExe)</executable>"
        "  <arguments>$(& $e (ConvertTo-CommandLine $ArgumentList))</arguments>"
        "  <workingdirectory>$(& $e $WorkingDirectory)</workingdirectory>"
        '  <startmode>Automatic</startmode>'
        '  <delayedAutoStart/>'
        '  <onfailure action="restart" delay="10 sec"/>'
        '  <onfailure action="restart" delay="30 sec"/>'
        '  <onfailure action="restart" delay="60 sec"/>'
        '  <resetfailure>1 hour</resetfailure>'
        '  <stoptimeout>30 sec</stoptimeout>'
        "  <logpath>$(& $e $LogDirectory)</logpath>"
        '  <log mode="roll-by-size">'
        '    <sizeThreshold>10240</sizeThreshold>'
        '    <keepFiles>8</keepFiles>'
        '  </log>'
    )
    if ($Credential) {
        $account = Split-AccountName $Credential.UserName
        $lines += @(
            '  <serviceaccount>'
            "    <domain>$(& $e $account.Domain)</domain>"
            "    <user>$(& $e $account.User)</user>"
            "    <password>$(& $e $Credential.GetNetworkCredential().Password)</password>"
            '    <allowservicelogon>true</allowservicelogon>'
            '  </serviceaccount>'
        )
    }
    $lines += '</service>'
    return ($lines -join "`r`n") + "`r`n"
}

function Get-FailureHint([string] $Log, [string] $AgentName) {
    $rules = @(
        @{ Pattern = 'is already connected|already connected to this (controller|master)'
           Hint = "Another agent process is already connected as '$AgentName'. Stop it (an old service or a manual 'java -jar agent.jar') and run this script again." }
        @{ Pattern = 'UnsupportedClassVersionError|compiled by a more recent version'
           Hint = 'This Java version is too old for the controller. Run the script again without -JavaVersion, or with a newer one.' }
        @{ Pattern = 'PKIX path building failed|unable to find valid certification path|SSLHandshakeException'
           Hint = "Java does not trust the controller's HTTPS certificate. If the company CA is installed in Windows, run the script again with -UseWindowsTrustStore." }
        @{ Pattern = 'None of the protocols were accepted|rejected the connection|Invalid secret|HTTP response code: 403|403 Forbidden'
           Hint = 'The controller rejected the agent. Copy -AgentName and -Secret again from the node page, and check that the node uses "Launch agent by connecting it to the controller".' }
        @{ Pattern = 'Did not receive X-Remoting-Capability header|Handshake error'
           Hint = 'The controller refused the WebSocket connection. Copy -AgentName and -Secret again from the node page. If they are right, check that proxies between this machine and Jenkins allow WebSocket.' }
        @{ Pattern = 'FileNotFoundException|HTTP response code: 404|404 Not Found'
           Hint = "The controller has no inbound agent called '$AgentName'. Check -AgentName and the node's launch method." }
        @{ Pattern = 'Connection refused|connect timed out|ConnectException|NoRouteToHostException|TCP port|port is disabled'
           Hint = 'The agent cannot reach the inbound TCP port. Run the script again with -WebSocket, or enable the TCP port (Manage Jenkins > Security > Agents) and open it in the firewall.' }
        @{ Pattern = 'UnknownHostException'
           Hint = 'This machine cannot resolve the controller host name. Check DNS and proxy settings.' }
    )
    foreach ($rule in $rules) {
        if ($Log -match $rule.Pattern) { return $rule.Hint }
    }
    return $null
}

#endregion

#region System helpers

function Test-IsWindowsHost {
    if ($PSVersionTable.PSEdition -ne 'Core') { return $true }
    return [bool] (Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue)
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Prerequisite {
    if (-not (Test-IsWindowsHost)) { throw 'This script installs a Windows service and must run on Windows.' }
    if ($PSVersionTable.PSVersion -lt [version] '5.1') {
        throw "Windows PowerShell 5.1 or newer is required (this is $($PSVersionTable.PSVersion))."
    }
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'A 64-bit (x64) Windows is required.' }
    if (-not (Test-IsAdministrator)) {
        throw 'Administrator rights are required to install a service. Open PowerShell with "Run as administrator" and try again.'
    }
}

function Repair-ModulePath {
    # Windows PowerShell started from PowerShell 7 (for example main.bat run in
    # a pwsh window) inherits the PowerShell 7 module paths and then cannot
    # load some of its own cmdlets.
    if ($PSVersionTable.PSEdition -ne 'Desktop' -or -not $env:PSModulePath) { return }
    $paths = @($env:PSModulePath -split ';' | Where-Object { $_ -and $_ -notmatch '\\PowerShell\\' })
    $env:PSModulePath = $paths -join ';'
}

function Enable-Tls12 {
    # Windows PowerShell 5.1 on older Windows still defaults to TLS 1.0.
    $tls12 = [Net.SecurityProtocolType]::Tls12
    if (([Net.ServicePointManager]::SecurityProtocol -band $tls12) -ne $tls12) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor $tls12
    }
}

function Get-FullPath([string] $Path) {
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path).TrimEnd('\')
}

function Invoke-NativeCommand {
    param(
        [string] $FilePath,
        [string[]] $ArgumentList = @(),
        [int] $TimeoutSeconds = 300
    )
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = ConvertTo-CommandLine $ArgumentList
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill()
            throw "'$FilePath $($startInfo.Arguments)' did not finish within $TimeoutSeconds seconds."
        }
        $process.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Output = ($stdout.Result + $stderr.Result).Trim()
        }
    } finally {
        $process.Dispose()
    }
}

function Invoke-WithRetry([scriptblock] $Action, [string] $Description, [int] $Attempts = 3) {
    for ($attempt = 1; ; $attempt++) {
        try {
            return (& $Action)
        } catch {
            if ($attempt -ge $Attempts) { throw "$Description failed: $($_.Exception.Message)" }
            Write-Warning "$Description failed (attempt $attempt of $Attempts): $($_.Exception.Message) Retrying..."
            Start-Sleep -Seconds (5 * $attempt)
        }
    }
}

function Get-Sha256([string] $Path) {
    $stream = [System.IO.File]::OpenRead($Path)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '')
    } finally {
        $sha256.Dispose()
        $stream.Dispose()
    }
}

function Invoke-Download([string] $Url, [string] $OutFile, [string] $Sha256) {
    $partial = "$OutFile.partial"
    Invoke-WithRetry -Description "Downloading $Url" -Action {
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        Invoke-WebRequest -Uri $Url -OutFile $partial -UseBasicParsing -TimeoutSec 600
    }
    if ($Sha256) {
        $actual = Get-Sha256 $partial
        if ($actual -ne $Sha256) {
            Remove-Item -LiteralPath $partial -Force
            throw "Checksum mismatch for $Url (expected $Sha256, got $actual)."
        }
    }
    Move-Item -LiteralPath $partial -Destination $OutFile -Force
}

function Get-JenkinsVersion([string] $JenkinsUrl) {
    # Returns the X-Jenkins header, or $null when a proxy hides it.
    # Throws when the controller cannot be reached at all.
    $reachable = $false
    $failure = $null
    foreach ($path in @('login', '')) {
        try {
            $request = [System.Net.WebRequest]::Create($JenkinsUrl + $path)
            $request.Timeout = 30000
            try {
                $response = $request.GetResponse()
            } catch {
                $exception = $_.Exception
                while ($exception -and -not ($exception -is [System.Net.WebException])) { $exception = $exception.InnerException }
                if ($exception -and $exception.Response) { $response = $exception.Response } else { throw }
            }
            try {
                $reachable = $true
                $version = $response.Headers['X-Jenkins']
                if ($version) { return $version }
            } finally {
                $response.Close()
            }
        } catch {
            $failure = $_.Exception.Message
        }
    }
    if (-not $reachable) { throw "Cannot reach the Jenkins controller at $JenkinsUrl ($failure)" }
    return $null
}

function Get-TemurinRelease([int] $Java, [string] $ImageType) {
    $uri = "$script:AdoptiumApi/assets/latest/$Java/hotspot?architecture=x64&image_type=$ImageType&os=windows&vendor=eclipse"
    $assets = Invoke-WithRetry -Description "Looking up Temurin $Java" -Action {
        Invoke-RestMethod -Uri $uri -UseBasicParsing -TimeoutSec 60
    }
    foreach ($asset in @($assets)) {
        $package = $asset.binary.package
        if ($package -and $package.name -like '*.zip') {
            return [pscustomobject]@{
                Release = $asset.release_name
                FileName = $package.name
                Url = $package.link
                Sha256 = $package.checksum
            }
        }
    }
    throw "Adoptium has no Temurin $Java $ImageType zip for Windows x64."
}

function Get-JavaFeatureVersion([string] $JavaExe) {
    $result = Invoke-NativeCommand -FilePath $JavaExe -ArgumentList @('-version')
    if ($result.ExitCode -ne 0) { throw "'$JavaExe -version' failed: $($result.Output)" }
    return ConvertTo-JavaFeatureVersion $result.Output
}

function Expand-Zip([string] $ZipFile, [string] $Destination) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipFile, $Destination)
}

function Test-AgentJar([string] $JavaExe, [string] $AgentJar) {
    $version = Invoke-NativeCommand -FilePath $JavaExe -ArgumentList @('-jar', $AgentJar, '-version')
    if ($version.ExitCode -ne 0 -or $version.Output -match 'UnsupportedClassVersionError|compiled by a more recent version|Error:') {
        throw "Java at '$JavaExe' cannot run agent.jar from this controller. Use a newer -JavaVersion.`n$($version.Output)"
    }
    $help = Invoke-NativeCommand -FilePath $JavaExe -ArgumentList @('-jar', $AgentJar, '-help')
    $lines = @($version.Output -split "`r?`n" | Where-Object { $_ -match '\S' })
    return [pscustomobject]@{
        Version = $(if ($lines.Count) { $lines[-1].Trim() } else { 'unknown' })
        SupportsUrl = [bool] ($help.Output -match '(?m)^\s*-url\s')
    }
}

function Invoke-IcaclsTool([string[]] $ArgumentList) {
    $result = Invoke-NativeCommand -FilePath (Join-Path $env:SystemRoot 'System32\icacls.exe') -ArgumentList $ArgumentList -TimeoutSeconds 1800
    if ($result.ExitCode -ne 0) { throw "icacls $($ArgumentList -join ' ') failed: $($result.Output)" }
}

function Get-ServiceInfo([string] $Name) {
    return Get-CimInstance -ClassName Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
}

function Wait-ServiceState([string] $Name, [string] $State, [int] $TimeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        $service = Get-ServiceInfo $Name
        if ($State -eq 'Absent') {
            if (-not $service) { return $true }
        } elseif ($service -and $service.State -eq $State) {
            return $true
        }
        if ((Get-Date) -ge $deadline) { return $false }
        Start-Sleep -Milliseconds 500
    }
}

function Stop-ProcessTree([int] $ProcessId) {
    if ($ProcessId -le 0) { return }
    foreach ($child in @(Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId=$ProcessId" -ErrorAction SilentlyContinue)) {
        Stop-ProcessTree -ProcessId $child.ProcessId
    }
    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
}

function Remove-AgentService([string] $Name) {
    $service = Get-ServiceInfo $Name
    if (-not $service) { return }
    $sc = Join-Path $env:SystemRoot 'System32\sc.exe'
    if ($service.State -ne 'Stopped') {
        Write-Detail "Stopping service '$Name'"
        $null = Invoke-NativeCommand -FilePath $sc -ArgumentList @('stop', $Name)
        if (-not (Wait-ServiceState -Name $Name -State 'Stopped' -TimeoutSeconds 60)) {
            Write-Warning "Service '$Name' did not stop in time; ending its processes."
            Stop-ProcessTree -ProcessId ([int] $service.ProcessId)
            $null = Wait-ServiceState -Name $Name -State 'Stopped' -TimeoutSeconds 30
        }
    }
    Write-Detail "Removing service '$Name'"
    $result = Invoke-NativeCommand -FilePath $sc -ArgumentList @('delete', $Name)
    # 1072: the service is already marked for deletion.
    if ($result.ExitCode -ne 0 -and $result.ExitCode -ne 1072) {
        throw "Could not remove service '$Name': $($result.Output)"
    }
    if (-not (Wait-ServiceState -Name $Name -State 'Absent' -TimeoutSeconds 60)) {
        throw "Windows marked service '$Name' for deletion but has not removed it yet. Close the Services console (services.msc) and other tools that have it open, then run this script again."
    }
}

function Read-FileFromOffset([string] $Path, [long] $Offset) {
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare] 'ReadWrite, Delete')
    try {
        if ($Offset -gt $stream.Length) { $Offset = 0 }
        $null = $stream.Seek($Offset, [System.IO.SeekOrigin]::Begin)
        $reader = New-Object System.IO.StreamReader($stream)
        return $reader.ReadToEnd()
    } finally {
        $stream.Dispose()
    }
}

function Get-FileLength([string] $Path) {
    if (Test-Path -LiteralPath $Path) { return (Get-Item -LiteralPath $Path).Length }
    return 0
}

function Wait-AgentConnection([string] $LogFile, [long] $Offset, [int] $TimeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        $log = Read-FileFromOffset -Path $LogFile -Offset $Offset
        # "INFO: Connected" (the level name is localized by Java).
        if ($log -match '(?m)^\S+:\s+Connected\s*$') { return [pscustomobject]@{ Connected = $true; Log = $log } }
        if ((Get-Date) -ge $deadline) { return [pscustomobject]@{ Connected = $false; Log = $log } }
        Start-Sleep -Seconds 2
    }
}

function Find-OtherAgentService([string] $Name) {
    # Services, other than $Name, that look like Jenkins agents.
    return @(Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -ne $Name -and $_.PathName -and
            $_.PathName -match 'jenkins-agent|jenkins-slave|agent\.jar|slave\.jar|winsw'
        })
}

#endregion

#region Install / uninstall

function Get-JavaRuntime {
    # Decides which java.exe the service uses. When a new Temurin build is
    # needed it is downloaded and extracted into $Staging; Install-JenkinsAgent
    # moves it into place once the old service is stopped.
    param(
        [string] $JavaVersion,
        [string] $JavaHome,
        [string] $JavaPackage,
        [string] $JavaDir,
        [string] $Staging,
        $Line,
        [string] $JenkinsVersion,
        [bool] $Force
    )
    if ($JavaHome) {
        $javaExe = $JavaHome
        if ((Split-Path -Leaf $javaExe) -ne 'java.exe') { $javaExe = Join-Path $JavaHome 'bin\java.exe' }
        $javaExe = Get-FullPath $javaExe
        if (-not (Test-Path -LiteralPath $javaExe -PathType Leaf)) { throw "java.exe not found under -JavaHome: $javaExe" }
        $feature = Get-JavaFeatureVersion $javaExe
        Write-Step "Using Java $feature from $javaExe"
        if ($null -ne $Line) { Assert-JavaCompatible -Java $feature -Line $Line -JenkinsVersion $JenkinsVersion -Force:$Force }
        return [pscustomobject]@{ JavaExe = $javaExe; Feature = $feature; StagedJavaExe = $javaExe; StagedDirectory = $null; Marker = $null }
    }

    if ($JavaVersion -eq 'auto') {
        if ($null -ne $Line) { $feature = Get-RecommendedJavaVersion $Line } else { $feature = 21 }
    } else {
        $feature = [int] $JavaVersion
    }
    if ($null -ne $Line) { Assert-JavaCompatible -Java $feature -Line $Line -JenkinsVersion $JenkinsVersion -Force:$Force }

    $javaExe = Join-Path $JavaDir 'bin\java.exe'
    $markerFile = Join-Path $JavaDir $script:MarkerFileName
    $installed = $null
    if ((Test-Path -LiteralPath $javaExe) -and (Test-Path -LiteralPath $markerFile)) {
        $installed = ([System.IO.File]::ReadAllText($markerFile)).Trim()
    }
    try {
        $release = Get-TemurinRelease -Java $feature -ImageType $JavaPackage
    } catch {
        # Offline re-run: keep a matching runtime instead of failing.
        if ($installed -like "temurin $feature $JavaPackage *") {
            Write-Warning "$($_.Exception.Message) Keeping the installed Java ($installed)."
            return [pscustomobject]@{ JavaExe = $javaExe; Feature = $feature; StagedJavaExe = $javaExe; StagedDirectory = $null; Marker = $null }
        }
        throw
    }
    $marker = "temurin $feature $JavaPackage $($release.Release)"
    if ($installed -eq $marker) {
        Write-Step "Java $feature is up to date ($($release.Release), $JavaPackage)"
        return [pscustomobject]@{ JavaExe = $javaExe; Feature = $feature; StagedJavaExe = $javaExe; StagedDirectory = $null; Marker = $null }
    }

    Write-Step "Downloading Eclipse Temurin $($release.Release) ($JavaPackage)"
    $null = New-Item -ItemType Directory -Force -Path $Staging
    $zip = Join-Path $Staging $release.FileName
    Invoke-Download -Url $release.Url -OutFile $zip -Sha256 $release.Sha256
    $extracted = Join-Path $Staging 'java'
    Expand-Zip -ZipFile $zip -Destination $extracted
    Remove-Item -LiteralPath $zip -Force
    $top = @(Get-ChildItem -LiteralPath $extracted -Directory)
    if ($top.Count -ne 1 -or -not (Test-Path -LiteralPath (Join-Path $top[0].FullName 'bin\java.exe'))) {
        throw "Unexpected layout in $($release.FileName)."
    }
    return [pscustomobject]@{
        JavaExe = $javaExe
        Feature = $feature
        StagedJavaExe = Join-Path $top[0].FullName 'bin\java.exe'
        StagedDirectory = $top[0].FullName
        Marker = $marker
    }
}

function Protect-AgentDirectory([string] $InstallDir, [string] $WorkDir, [string] $SecretPath, [string] $AccountName) {
    # The service runs as LocalSystem by default, so only Administrators and
    # SYSTEM may change what it executes; other users may read. Without this,
    # a directory created under C:\ is writable by every signed-in user.
    Write-Detail "Restricting write access to $InstallDir"
    $grants = @('*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-32-545:(OI)(CI)RX')
    if ($AccountName) { $grants += "${AccountName}:(OI)(CI)M" }
    Invoke-IcaclsTool (@($InstallDir, '/inheritance:r', '/grant:r') + $grants)
    if ($AccountName -and -not ($WorkDir + '\').StartsWith($InstallDir + '\', [StringComparison]::OrdinalIgnoreCase)) {
        Invoke-IcaclsTool @($WorkDir, '/grant', "${AccountName}:(OI)(CI)M")
    }
    # Only the service may read the secret.
    $secretGrants = @('*S-1-5-18:F', '*S-1-5-32-544:F')
    if ($AccountName) { $secretGrants += "${AccountName}:R" }
    Invoke-IcaclsTool (@($SecretPath, '/inheritance:r', '/grant:r') + $secretGrants)
}

function Install-JenkinsAgent {
    param(
        [string] $JenkinsUrl,
        [string] $AgentName,
        [string] $Secret,
        [string] $SecretFile,
        [string] $JavaVersion,
        [string] $JavaHome,
        [string] $JavaPackage,
        [string] $InstallDir,
        [string] $WorkDir,
        [bool] $WebSocket,
        [string] $ServiceId,
        [pscredential] $ServiceCredential,
        [string[]] $JavaOptions,
        [string[]] $AgentOptions,
        [bool] $UseWindowsTrustStore,
        [int] $ConnectTimeout,
        [bool] $NoStart,
        [bool] $Force
    )

    # --- Validate input ----------------------------------------------------------
    if (-not $JenkinsUrl) { throw 'Missing -JenkinsUrl (or $env:JENKINS_URL), for example -JenkinsUrl https://jenkins.example.com/' }
    $parsed = Split-JenkinsUrl $JenkinsUrl
    $JenkinsUrl = $parsed.Url
    if ($parsed.AgentName) {
        if ($AgentName -and $AgentName -ne $parsed.AgentName) {
            throw "-AgentName '$AgentName' does not match the agent '$($parsed.AgentName)' in the JNLP URL."
        }
        $AgentName = $parsed.AgentName
    }
    if (-not $AgentName) { throw 'Missing -AgentName (or $env:JENKINS_AGENT_NAME): the node name on the Jenkins controller.' }

    if ($SecretFile) {
        if (-not (Test-Path -LiteralPath $SecretFile -PathType Leaf)) { throw "Secret file not found: $SecretFile" }
        $Secret = [System.IO.File]::ReadAllText((Get-FullPath $SecretFile))
    }
    if ($Secret) { $Secret = $Secret.Trim() }
    if (-not $Secret) { throw 'Missing -Secret, -SecretFile or $env:JENKINS_SECRET. Copy the secret from the node page on the controller.' }
    if ($Secret -notmatch '^[0-9a-fA-F]{64}$') {
        Write-Warning 'The secret is not the usual 64-character hex string. Check that you copied the whole value.'
    }
    if ($ServiceId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$') {
        throw "-ServiceId '$ServiceId' may only contain letters, digits, '.', '_' and '-'."
    }

    $InstallDir = Get-FullPath $InstallDir
    if (-not $WorkDir) { $WorkDir = $InstallDir }
    $WorkDir = Get-FullPath $WorkDir
    foreach ($dir in @($InstallDir, $WorkDir)) {
        if ([System.IO.Path]::GetPathRoot($dir).TrimEnd('\') -eq $dir) {
            throw "Use a dedicated directory, not a drive root: $dir"
        }
    }

    $credential = $null
    $accountName = $null
    if ($ServiceCredential -and $ServiceCredential -ne [pscredential]::Empty) {
        $credential = $ServiceCredential
        $account = Split-AccountName $credential.UserName
        $domain = $account.Domain
        if ($domain -eq '.') { $domain = $env:COMPUTERNAME }
        $accountName = "$domain\$($account.User)"
    }

    $wrapperExe = Join-Path $InstallDir "$script:WrapperName.exe"
    $wrapperXml = Join-Path $InstallDir "$script:WrapperName.xml"
    $agentJar = Join-Path $InstallDir 'agent.jar'
    $secretPath = Join-Path $InstallDir $script:SecretFileName
    $javaDir = Join-Path $InstallDir 'java'
    $logDir = Join-Path $InstallDir 'logs'
    $staging = Join-Path $InstallDir '.staging'

    # --- Controller ----------------------------------------------------------------
    Write-Step "Checking the Jenkins controller at $JenkinsUrl"
    $jenkinsVersion = Get-JenkinsVersion $JenkinsUrl
    $line = $null
    if ($jenkinsVersion) {
        $line = ConvertTo-JenkinsLine $jenkinsVersion
        Write-Detail "Jenkins $jenkinsVersion"
    } else {
        Write-Warning 'The controller did not report its version (X-Jenkins header), so the Java version cannot be checked against it.'
    }

    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    $replaced = @()
    foreach ($other in (Find-OtherAgentService -Name $ServiceId)) {
        if ($other.PathName.IndexOf($wrapperExe, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            # Installed from this directory under another -ServiceId: replace it.
            $replaced += $other.Name
        } else {
            Write-Warning "Another Jenkins agent service exists: '$($other.Name)' ($($other.PathName)). If it uses the same agent name, remove it first or the controller will reject one of them."
        }
    }

    # --- Download and check everything before touching the running service -----
    # A refused Java version (checked first) leaves the machine unchanged.
    $java = Get-JavaRuntime -JavaVersion $JavaVersion -JavaHome $JavaHome -JavaPackage $JavaPackage -JavaDir $javaDir `
        -Staging $staging -Line $line -JenkinsVersion $jenkinsVersion -Force $Force
    if ($UseWindowsTrustStore) { $JavaOptions = @('-Djavax.net.ssl.trustStoreType=Windows-ROOT') + @($JavaOptions) }

    $null = New-Item -ItemType Directory -Force -Path $staging
    $stagedWrapper = $null
    if ((Test-Path -LiteralPath $wrapperExe) -and (Get-Sha256 $wrapperExe) -eq $script:WinSWSha256) {
        Write-Step 'WinSW v2.12.0 is up to date'
    } else {
        Write-Step 'Downloading WinSW v2.12.0'
        $stagedWrapper = Join-Path $staging "$script:WrapperName.exe"
        Invoke-Download -Url $script:WinSWUrl -OutFile $stagedWrapper -Sha256 $script:WinSWSha256
    }

    Write-Step "Downloading agent.jar from $JenkinsUrl"
    $stagedJar = Join-Path $staging 'agent.jar'
    Invoke-Download -Url ($JenkinsUrl + 'jnlpJars/agent.jar') -OutFile $stagedJar
    $remoting = Test-AgentJar -JavaExe $java.StagedJavaExe -AgentJar $stagedJar
    Write-Detail "Remoting $($remoting.Version)"
    if ($WebSocket -and -not $remoting.SupportsUrl) {
        Write-Warning "This agent.jar does not take -webSocket. Enable 'Use WebSocket' on the node configuration page instead."
    }

    # --- Replace the service ---------------------------------------------------------
    Write-Step "Installing the Windows service '$ServiceId'"
    foreach ($name in $replaced) { Remove-AgentService -Name $name }
    Remove-AgentService -Name $ServiceId
    if ($java.StagedDirectory) {
        if (Test-Path -LiteralPath $javaDir) { Remove-Item -LiteralPath $javaDir -Recurse -Force }
        Move-Item -LiteralPath $java.StagedDirectory -Destination $javaDir
        [System.IO.File]::WriteAllText((Join-Path $javaDir $script:MarkerFileName), $java.Marker)
    }
    if ($stagedWrapper) { Move-Item -LiteralPath $stagedWrapper -Destination $wrapperExe -Force }
    Move-Item -LiteralPath $stagedJar -Destination $agentJar -Force
    Remove-Item -LiteralPath $staging -Recurse -Force
    foreach ($dir in @($WorkDir, $logDir)) {
        if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir }
    }
    [System.IO.File]::WriteAllText($secretPath, $Secret, [System.Text.Encoding]::ASCII)
    Protect-AgentDirectory -InstallDir $InstallDir -WorkDir $WorkDir -SecretPath $secretPath -AccountName $accountName

    $argumentList = Get-AgentArgumentList -AgentJar $agentJar -JenkinsUrl $JenkinsUrl -AgentName $AgentName `
        -SecretPath $secretPath -WorkDir $WorkDir -SupportsUrl $remoting.SupportsUrl -WebSocket $WebSocket `
        -JavaOptions $JavaOptions -AgentOptions $AgentOptions
    $configArgs = @{
        ServiceId = $ServiceId; AgentName = $AgentName; JenkinsUrl = $JenkinsUrl; JavaExe = $java.JavaExe
        ArgumentList = $argumentList; WorkingDirectory = $InstallDir; LogDirectory = $logDir
    }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    try {
        # WinSW needs the account password only while installing, so the file
        # is written again without it right after.
        [System.IO.File]::WriteAllText($wrapperXml, (New-WinSWConfig @configArgs -Credential $credential), $utf8)
        $result = Invoke-NativeCommand -FilePath $wrapperExe -ArgumentList @('install')
        if (-not (Get-ServiceInfo $ServiceId)) { throw "WinSW could not install the service:`n$($result.Output)" }
    } finally {
        [System.IO.File]::WriteAllText($wrapperXml, (New-WinSWConfig @configArgs), $utf8)
    }
    # Restart after the agent exits with an error too, not only after a crash.
    $null = Invoke-NativeCommand -FilePath (Join-Path $env:SystemRoot 'System32\sc.exe') -ArgumentList @('failureflag', $ServiceId, '1')

    $runsAs = 'LocalSystem'
    if ($accountName) { $runsAs = $accountName }
    $summary = @(
        "Service  : $ServiceId (automatic, delayed start, restarts on failure)"
        "Runs as  : $runsAs"
        "Java     : $($java.JavaExe) (Java $($java.Feature))"
        "Remoting : $($remoting.Version)"
        "Work dir : $WorkDir"
        "Logs     : $logDir"
    )

    if ($NoStart) {
        Write-Step 'Installed. The service was not started (-NoStart).'
        $summary | ForEach-Object { Write-Detail $_ }
        return
    }

    # --- Start and wait for the connection ------------------------------------------
    Write-Step 'Starting the service'
    $errLog = Join-Path $logDir "$script:WrapperName.err.log"
    $offset = Get-FileLength $errLog
    try {
        Start-Service -Name $ServiceId
    } catch {
        $wrapperLog = Read-FileFromOffset -Path (Join-Path $logDir "$script:WrapperName.wrapper.log") -Offset 0
        throw "The service did not start: $($_.Exception.Message)`n$wrapperLog"
    }

    if ($ConnectTimeout -le 0) {
        Write-Step 'Service started (connection check skipped).'
        $summary | ForEach-Object { Write-Detail $_ }
        return
    }

    Write-Step "Waiting up to $ConnectTimeout seconds for '$AgentName' to connect"
    $wait = Wait-AgentConnection -LogFile $errLog -Offset $offset -TimeoutSeconds $ConnectTimeout
    if (-not $wait.Connected) {
        $tail = (@($wait.Log -split "`r?`n") | Select-Object -Last 40) -join "`n"
        $message = "The agent did not connect within $ConnectTimeout seconds. The service stays installed and keeps retrying.`nLast lines of ${errLog}:`n$tail"
        $hint = Get-FailureHint -Log $wait.Log -AgentName $AgentName
        if ($hint) { $message += "`n`nHint: $hint" }
        throw $message
    }

    Write-Host ''
    Write-Host "Agent '$AgentName' is connected to $JenkinsUrl" -ForegroundColor Green
    $summary | ForEach-Object { Write-Detail $_ }
    Write-Detail "Manage it with: Get-Service $ServiceId | Restart-Service $ServiceId | Stop-Service $ServiceId"
}

function Assert-JavaCompatible([int] $Java, [int] $Line, [string] $JenkinsVersion, [switch] $Force) {
    $minimum = Get-MinimumJavaVersion $Line
    if ($Java -lt $minimum) {
        $message = "Jenkins $JenkinsVersion requires Java $minimum or newer on agents, but Java $Java was selected. Use -JavaVersion $(Get-RecommendedJavaVersion $Line), or leave -JavaVersion out to choose automatically."
        if (-not $Force) { throw $message }
        Write-Warning "$message Continuing because of -Force."
    } elseif (-not (Test-JavaSupported -Java $Java -Line $Line)) {
        Write-Warning "Java $Java is outside the range Jenkins $JenkinsVersion officially supports (https://www.jenkins.io/doc/book/platform-information/support-policy-java/). It may still work."
    }
}

function Uninstall-JenkinsAgent([string] $InstallDir, [string] $ServiceId, [bool] $ServiceIdGiven) {
    $InstallDir = Get-FullPath $InstallDir
    $wrapperXml = Join-Path $InstallDir "$script:WrapperName.xml"
    if (-not $ServiceIdGiven -and (Test-Path -LiteralPath $wrapperXml)) {
        $ServiceId = ([xml] (Get-Content -LiteralPath $wrapperXml -Raw)).service.id
    }
    Write-Step "Uninstalling the Windows service '$ServiceId'"
    if (Get-ServiceInfo $ServiceId) {
        Remove-AgentService -Name $ServiceId
    } else {
        Write-Detail "Service '$ServiceId' is not installed"
    }
    $owned = @("$script:WrapperName.exe", "$script:WrapperName.xml", 'agent.jar', $script:SecretFileName, 'logs', '.staging')
    if (Test-Path -LiteralPath (Join-Path $InstallDir "java\$script:MarkerFileName")) { $owned += 'java' }
    foreach ($item in $owned) {
        $path = Join-Path $InstallDir $item
        if (Test-Path -LiteralPath $path) {
            Write-Detail "Removing $path"
            Remove-Item -LiteralPath $path -Recurse -Force
        }
    }
    Write-Host ''
    Write-Host "Uninstalled. Work directory contents (workspaces, remoting) were left in place." -ForegroundColor Green
}

#endregion

function Invoke-Main([hashtable] $Options, [bool] $Uninstall, [bool] $ServiceIdGiven) {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    Set-StrictMode -Version 2.0
    Repair-ModulePath
    Assert-Prerequisite
    Enable-Tls12
    if ($Uninstall) {
        Uninstall-JenkinsAgent -InstallDir $Options.InstallDir -ServiceId $Options.ServiceId -ServiceIdGiven $ServiceIdGiven
    } else {
        Install-JenkinsAgent @Options
    }
}

# Run unless the script is dot-sourced (as the tests do).
if ($MyInvocation.InvocationName -ne '.') {
    $options = @{
        JenkinsUrl = $JenkinsUrl; AgentName = $AgentName; Secret = $Secret; SecretFile = $SecretFile
        JavaVersion = $JavaVersion; JavaHome = $JavaHome; JavaPackage = $JavaPackage
        InstallDir = $InstallDir; WorkDir = $WorkDir
        WebSocket = ($WebSocket.IsPresent -or $env:JENKINS_WEB_SOCKET -eq 'true')
        ServiceId = $ServiceId; ServiceCredential = $ServiceCredential
        JavaOptions = $JavaOptions; AgentOptions = $AgentOptions
        UseWindowsTrustStore = $UseWindowsTrustStore.IsPresent; ConnectTimeout = $ConnectTimeout
        NoStart = $NoStart.IsPresent; Force = $Force.IsPresent
    }
    try {
        Invoke-Main -Options $options -Uninstall $Uninstall.IsPresent -ServiceIdGiven $PSBoundParameters.ContainsKey('ServiceId')
        if ($PSCommandPath) { exit 0 }
    } catch {
        if ($PSCommandPath) {
            # Run as a script file: print a clean message and set the exit code.
            Write-Host ''
            Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
            exit 1
        }
        throw
    }
}
