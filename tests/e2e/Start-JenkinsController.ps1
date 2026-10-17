<#
.SYNOPSIS
Starts a throwaway Jenkins controller for the end-to-end tests.

.DESCRIPTION
Downloads jenkins.war (cached in -CacheDir), adds the instance-identity
plugin that inbound TCP agents need on Jenkins 2.357+, and starts Jenkins with
tests/e2e/setup.groovy, which creates the agent node and a smoke job.

Exports for later workflow steps (GITHUB_ENV): E2E_JENKINS_URL,
E2E_SECRET_FILE, E2E_JENKINS_HOME and, with -Secured, E2E_ADMIN_USER and
E2E_ADMIN_PASSWORD.

Uses the Java on JAVA_HOME (set by actions/setup-java).
#>
param(
    [Parameter(Mandatory)] [string] $Version,
    [string] $AgentName = $env:E2E_AGENT_NAME,
    [string] $RemoteFs = $env:E2E_INSTALL_DIR,
    [string] $CacheDir = (Join-Path $HOME 'jenkins-cache'),
    [string] $JenkinsHome = (Join-Path $env:RUNNER_TEMP 'jenkins-home'),
    [int] $Port = 8080,
    [switch] $WebSocket,
    [switch] $Secured
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$pluginManagerVersion = '2.15.0'
$pluginManagerSha256 = 'a86853ec2e2933f37a4b471ba65099b61e03c87a80c2ef8fe2315eb135672d43'

function Save-File([string[]] $Urls, [string] $OutFile, [string] $Sha256) {
    if (Test-Path -LiteralPath $OutFile) { return }
    foreach ($url in $Urls) {
        try {
            Write-Host "Downloading $url"
            Invoke-WebRequest -Uri $url -OutFile "$OutFile.partial" -UseBasicParsing
            $actual = (Get-FileHash -LiteralPath "$OutFile.partial" -Algorithm SHA256).Hash
            if ($Sha256 -and $actual -ne $Sha256) { throw "checksum mismatch: expected $Sha256, got $actual" }
            Move-Item -LiteralPath "$OutFile.partial" -Destination $OutFile
            return
        } catch {
            Write-Warning "$url failed: $($_.Exception.Message)"
        }
    }
    throw "Could not download $OutFile"
}

function Add-GitHubEnv([string] $Name, [string] $Value) {
    Set-Item -Path "env:$Name" -Value $Value
    if ($env:GITHUB_ENV) { Add-Content -LiteralPath $env:GITHUB_ENV -Value "$Name=$Value" }
}

$java = Join-Path $env:JAVA_HOME 'bin\java.exe'
$null = New-Item -ItemType Directory -Force -Path $CacheDir, $JenkinsHome

# --- jenkins.war ----------------------------------------------------------------
$war = Join-Path $CacheDir "jenkins-$Version.war"
$repo = "https://repo.jenkins-ci.org/releases/org/jenkins-ci/main/jenkins-war/$Version/jenkins-war-$Version.war"
$sha256 = (Invoke-RestMethod -Uri "$repo.sha256" -UseBasicParsing).ToString().Trim().Split(' ')[0]
$mirror = "https://get.jenkins.io/war/$Version/jenkins.war"
if ($Version -match '^\d+\.\d+\.\d+$') { $mirror = "https://get.jenkins.io/war-stable/$Version/jenkins.war" }
Save-File -Urls @($repo, $mirror) -OutFile $war -Sha256 $sha256

# --- instance-identity: a plugin since Jenkins 2.357, needed by TCP agents ------
$line = [int] $Version.Split('.')[1]
if ($line -ge 357) {
    $pluginManager = Join-Path $CacheDir "jenkins-plugin-manager-$pluginManagerVersion.jar"
    Save-File -Urls @("https://github.com/jenkinsci/plugin-installation-manager-tool/releases/download/$pluginManagerVersion/jenkins-plugin-manager-$pluginManagerVersion.jar") `
        -OutFile $pluginManager -Sha256 $pluginManagerSha256
    & $java -jar $pluginManager --war $war --plugin-download-directory (Join-Path $JenkinsHome 'plugins') --plugins instance-identity
    if ($LASTEXITCODE -ne 0) { throw "Plugin installation failed ($LASTEXITCODE)" }
}

# --- Start Jenkins ------------------------------------------------------------------
$initDir = Join-Path $JenkinsHome 'init.groovy.d'
$null = New-Item -ItemType Directory -Force -Path $initDir
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'setup.groovy') -Destination (Join-Path $initDir 'e2e.groovy')

$url = "http://localhost:$Port/"
$env:JENKINS_HOME = $JenkinsHome
$env:E2E_JENKINS_URL = $url
$env:E2E_AGENT_NAME = $AgentName
$env:E2E_REMOTE_FS = $RemoteFs
$env:E2E_WEBSOCKET = ([string] $WebSocket.IsPresent).ToLowerInvariant()
$env:E2E_SECURED = ([string] $Secured.IsPresent).ToLowerInvariant()
if ($Secured) {
    $password = 'E2e-' + [guid]::NewGuid().ToString('N')
    Write-Host "::add-mask::$password"
    Add-GitHubEnv 'E2E_ADMIN_USER' 'admin'
    Add-GitHubEnv 'E2E_ADMIN_PASSWORD' $password
}

$outLog = Join-Path $JenkinsHome 'jenkins.out.log'
$errLog = Join-Path $JenkinsHome 'jenkins.err.log'
$arguments = @(
    '-Djenkins.install.runSetupWizard=false'
    '-Dhudson.security.csrf.GlobalCrumbIssuerConfiguration.DISABLE_CSRF_PROTECTION=true'
    '-jar', "`"$war`"", "--httpPort=$Port"
)
Write-Host "Starting Jenkins $Version on $url with $java"
$process = Start-Process -FilePath $java -ArgumentList $arguments -RedirectStandardOutput $outLog `
    -RedirectStandardError $errLog -PassThru -WindowStyle Hidden

$secretFile = Join-Path $JenkinsHome 'e2e-agent-secret.txt'
$deadline = (Get-Date).AddMinutes(5)
$ready = $false
while (-not $ready) {
    if ($process.HasExited) {
        Get-Content -LiteralPath $errLog -Tail 100
        throw "Jenkins exited with code $($process.ExitCode)"
    }
    if ((Get-Date) -gt $deadline) {
        Get-Content -LiteralPath $errLog -Tail 100
        throw 'Jenkins did not become ready within 5 minutes'
    }
    Start-Sleep -Seconds 3
    if (Test-Path -LiteralPath $secretFile) {
        try {
            $response = Invoke-WebRequest -Uri "${url}login" -UseBasicParsing -TimeoutSec 10
            $ready = $response.StatusCode -eq 200
        } catch {
            Write-Host "Waiting for Jenkins: $($_.Exception.Message)"
        }
    }
}

Write-Host "::add-mask::$((Get-Content -LiteralPath $secretFile -Raw).Trim())"
Add-GitHubEnv 'E2E_JENKINS_URL' $url
Add-GitHubEnv 'E2E_JENKINS_HOME' $JenkinsHome
Add-GitHubEnv 'E2E_SECRET_FILE' $secretFile
Write-Host "Jenkins $($response.Headers['X-Jenkins']) is ready (pid $($process.Id))"
