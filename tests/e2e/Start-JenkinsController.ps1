<#
.SYNOPSIS
Starts a throwaway Jenkins controller for the end-to-end tests.

.DESCRIPTION
Downloads jenkins.war and the instance-identity plugin that inbound TCP agents
need on Jenkins 2.357+ (both cached in -CacheDir, so later runs do not depend
on the Jenkins download and update sites), and starts Jenkins with
tests/e2e/setup.groovy, which creates the agent node and a smoke job.

-Https serves Jenkins only over HTTPS, with a certificate from a throwaway CA
that is added to the Windows trusted roots, like a company CA. Java does not
trust that CA unless the agent uses -UseWindowsTrustStore.

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
    [switch] $Secured,
    [switch] $Https
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$pluginManagerVersion = '2.15.0'
$pluginManagerSha256 = 'a86853ec2e2933f37a4b471ba65099b61e03c87a80c2ef8fe2315eb135672d43'

function Invoke-WithRetry([scriptblock] $Action, [string] $Description) {
    for ($attempt = 1; ; $attempt++) {
        try {
            return (& $Action)
        } catch {
            if ($attempt -ge 3) { throw "$Description failed: $($_.Exception.Message)" }
            Write-Warning "$Description failed (attempt $attempt of 3): $($_.Exception.Message)"
            Start-Sleep -Seconds (10 * $attempt)
        }
    }
}

function Save-File([string[]] $Urls, [string] $OutFile, [scriptblock] $GetSha256) {
    if (Test-Path -LiteralPath $OutFile) {
        Write-Host "Using cached $OutFile"
        return
    }
    $sha256 = Invoke-WithRetry -Description "Getting the checksum of $OutFile" -Action $GetSha256
    Invoke-WithRetry -Description "Downloading $OutFile" -Action {
        foreach ($url in $Urls) {
            try {
                Write-Host "Downloading $url"
                Invoke-WebRequest -Uri $url -OutFile "$OutFile.partial" -UseBasicParsing
                $actual = (Get-FileHash -LiteralPath "$OutFile.partial" -Algorithm SHA256).Hash
                if ($actual -ne $sha256) { throw "checksum mismatch: expected $sha256, got $actual" }
                Move-Item -LiteralPath "$OutFile.partial" -Destination $OutFile
                return
            } catch {
                Write-Warning "$url failed: $($_.Exception.Message)"
            }
        }
        throw 'no mirror worked'
    }
}

function New-TestCertificate([string] $Directory) {
    # A root CA and a localhost certificate signed by it. The CA goes into the
    # machine's trusted roots; the certificate and key into a PKCS12 file.
    $crypto = 'System.Security.Cryptography'
    $now = [DateTimeOffset]::UtcNow
    $caKey = [System.Security.Cryptography.RSA]::Create(2048)
    $caRequest = New-Object "$crypto.X509Certificates.CertificateRequest" ('CN=jenkins-windows-agent e2e CA', $caKey,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $caRequest.CertificateExtensions.Add((New-Object "$crypto.X509Certificates.X509BasicConstraintsExtension" ($true, $false, 0, $true)))
    $caRequest.CertificateExtensions.Add((New-Object "$crypto.X509Certificates.X509KeyUsageExtension" (
                [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags] 'KeyCertSign, CrlSign', $true)))
    $ca = $caRequest.CreateSelfSigned($now.AddDays(-1), $now.AddDays(7))

    $key = [System.Security.Cryptography.RSA]::Create(2048)
    $request = New-Object "$crypto.X509Certificates.CertificateRequest" ('CN=localhost', $key,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $names = New-Object "$crypto.X509Certificates.SubjectAlternativeNameBuilder"
    $names.AddDnsName('localhost')
    $names.AddIpAddress([System.Net.IPAddress]::Loopback)
    $request.CertificateExtensions.Add($names.Build())
    $serverAuth = New-Object "$crypto.OidCollection"
    $null = $serverAuth.Add((New-Object "$crypto.Oid" '1.3.6.1.5.5.7.3.1'))
    $request.CertificateExtensions.Add((New-Object "$crypto.X509Certificates.X509EnhancedKeyUsageExtension" ($serverAuth, $false)))
    $serial = New-Object byte[] 16
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($serial)
    $certificate = $request.Create($ca, $now.AddDays(-1), $now.AddDays(6), $serial)
    $withKey = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::CopyWithPrivateKey($certificate, $key)

    $keyStore = Join-Path $Directory 'jenkins.p12'
    $keyStorePassword = [guid]::NewGuid().ToString('N')
    [System.IO.File]::WriteAllBytes($keyStore, $withKey.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $keyStorePassword))
    $store = New-Object "$crypto.X509Certificates.X509Store" (
        [System.Security.Cryptography.X509Certificates.StoreName]::Root,
        [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
    $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    $store.Add((New-Object "$crypto.X509Certificates.X509Certificate2" (, $ca.Export('Cert'))))
    $store.Close()
    Write-Host "Added '$($ca.Subject)' ($($ca.Thumbprint)) to the trusted root CAs"
    return [pscustomobject]@{ Path = $keyStore; Password = $keyStorePassword }
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
$mirror = "https://get.jenkins.io/war/$Version/jenkins.war"
if ($Version -match '^\d+\.\d+\.\d+$') { $mirror = "https://get.jenkins.io/war-stable/$Version/jenkins.war" }
Save-File -Urls @($repo, $mirror) -OutFile $war -GetSha256 {
    $content = (Invoke-WebRequest -Uri "$repo.sha256" -UseBasicParsing).Content
    if ($content -is [byte[]]) { $content = [System.Text.Encoding]::ASCII.GetString($content) }
    $content.Trim().Split(' ')[0]
}

# --- instance-identity: a plugin since Jenkins 2.357, needed by TCP agents ------
$line = [int] $Version.Split('.')[1]
if ($line -ge 357) {
    # The update center only serves plugin versions for recent cores, so pin
    # the last versions that support older ones.
    $plugins = @('instance-identity')
    if ($line -lt 479) { $plugins = @('instance-identity:201.vd2a_b_5a_468a_a_6', 'bouncycastle-api:2.30.1.78.1-233.vfdcdeb_0a_08a_a_') }
    $pluginCache = Join-Path $CacheDir "plugins-$Version"
    if (Test-Path -LiteralPath (Join-Path $pluginCache 'instance-identity.jpi')) {
        Write-Host "Using cached plugins from $pluginCache"
    } else {
        $pluginManager = Join-Path $CacheDir "jenkins-plugin-manager-$pluginManagerVersion.jar"
        Save-File -Urls @("https://github.com/jenkinsci/plugin-installation-manager-tool/releases/download/$pluginManagerVersion/jenkins-plugin-manager-$pluginManagerVersion.jar") `
            -OutFile $pluginManager -GetSha256 { $pluginManagerSha256 }
        Invoke-WithRetry -Description 'Downloading plugins' -Action {
            if (Test-Path -LiteralPath $pluginCache) { Remove-Item -LiteralPath $pluginCache -Recurse -Force }
            & $java -jar $pluginManager --war $war --plugin-download-directory $pluginCache --latest false --plugins @plugins
            if ($LASTEXITCODE -ne 0) { throw "jenkins-plugin-manager exited with $LASTEXITCODE" }
        }
    }
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $JenkinsHome 'plugins')
    Copy-Item -Path (Join-Path $pluginCache '*') -Destination (Join-Path $JenkinsHome 'plugins')
}

# --- Start Jenkins ------------------------------------------------------------------
$initDir = Join-Path $JenkinsHome 'init.groovy.d'
$null = New-Item -ItemType Directory -Force -Path $initDir
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'setup.groovy') -Destination (Join-Path $initDir 'e2e.groovy')

$url = "http://localhost:$Port/"
$listen = "--httpPort=$Port"
if ($Https) {
    if (-not $PSBoundParameters.ContainsKey('Port')) { $Port = 8443 }
    $keyStore = New-TestCertificate -Directory $JenkinsHome
    $url = "https://localhost:$Port/"
    $listen = "--httpPort=-1 --httpsPort=$Port --httpsKeyStore=`"$($keyStore.Path)`" --httpsKeyStoreType=PKCS12 --httpsKeyStorePassword=$($keyStore.Password)"
}
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

# A process started from a step does not survive the step on Windows runners,
# so start Jenkins through WMI, outside the step, from a script that carries
# the environment.
$outLog = Join-Path $JenkinsHome 'jenkins.out.log'
$errLog = Join-Path $JenkinsHome 'jenkins.err.log'
$launcher = Join-Path $JenkinsHome 'start-jenkins.cmd'
$lines = @('@echo off')
foreach ($name in 'JENKINS_HOME', 'E2E_JENKINS_URL', 'E2E_AGENT_NAME', 'E2E_REMOTE_FS', 'E2E_WEBSOCKET', 'E2E_SECURED', 'E2E_ADMIN_USER', 'E2E_ADMIN_PASSWORD') {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ($value) { $lines += "set `"$name=$value`"" }
}
$lines += "`"$java`" -Djenkins.install.runSetupWizard=false " +
    '-Dhudson.security.csrf.GlobalCrumbIssuerConfiguration.DISABLE_CSRF_PROTECTION=true ' +
    "-jar `"$war`" $listen > `"$outLog`" 2> `"$errLog`""
Set-Content -LiteralPath $launcher -Value $lines -Encoding ascii

Write-Host "Starting Jenkins $Version on $url with $java"
$started = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
    CommandLine = "cmd.exe /d /c `"$launcher`""
    CurrentDirectory = $JenkinsHome
}
if ($started.ReturnValue -ne 0) { throw "Could not start Jenkins (Win32_Process.Create returned $($started.ReturnValue))" }
$launcherPid = [int] $started.ProcessId

$secretFile = Join-Path $JenkinsHome 'e2e-agent-secret.txt'
$deadline = (Get-Date).AddMinutes(5)
$ready = $false
while (-not $ready) {
    if (-not (Get-Process -Id $launcherPid -ErrorAction SilentlyContinue)) {
        Get-Content -LiteralPath $errLog -Tail 100 -ErrorAction SilentlyContinue
        throw 'Jenkins exited during startup'
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
Write-Host "Jenkins $($response.Headers['X-Jenkins']) is ready"
