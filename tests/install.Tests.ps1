# Unit tests for install.ps1. They need no network, no admin rights and run on
# Windows PowerShell 5.1 and PowerShell 7 (Windows, Linux, macOS).
#   Invoke-Pester -Path tests

BeforeAll {
    $script:InstallScript = (Resolve-Path "$PSScriptRoot/../install.ps1").Path
    . $script:InstallScript
}

Describe 'Repository files' {
    It '<_> is plain ASCII (Windows PowerShell 5.1 reads BOM-less files as ANSI)' -ForEach @('install.ps1', 'main.bat') {
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path "$PSScriptRoot/.." $_))
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }

    It 'install.ps1 parses without errors' {
        $tokens = $null
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($script:InstallScript, [ref] $tokens, [ref] $errors)
        $errors | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-JenkinsLine' {
    It 'reads <Version> as line <Line>' -ForEach @(
        @{ Version = '2.580.1'; Line = 580 }
        @{ Version = '2.586'; Line = 586 }
        @{ Version = '2.346.3'; Line = 346 }
        @{ Version = '2.462.3.4'; Line = 462 }
        @{ Version = '1.651.3'; Line = 0 }
    ) {
        ConvertTo-JenkinsLine $Version | Should -Be $Line
    }

    It 'returns $null for text that is not a version' {
        ConvertTo-JenkinsLine 'unknown' | Should -BeNullOrEmpty
    }
}

Describe 'Java version policy' {
    It 'recommends Java <Java> for Jenkins 2.<Line>' -ForEach @(
        @{ Line = 586; Java = 21 }
        @{ Line = 580; Java = 21 }
        @{ Line = 541; Java = 21 }
        @{ Line = 463; Java = 21 }
        @{ Line = 462; Java = 17 }
        @{ Line = 346; Java = 17 }
        @{ Line = 303; Java = 11 }
        @{ Line = 150; Java = 8 }
        @{ Line = 0; Java = 8 }
    ) {
        Get-RecommendedJavaVersion $Line | Should -Be $Java
    }

    It 'requires at least Java <Java> for Jenkins 2.<Line>' -ForEach @(
        @{ Line = 580; Java = 21 }
        @{ Line = 545; Java = 21 }
        @{ Line = 544; Java = 17 }
        @{ Line = 463; Java = 17 }
        @{ Line = 462; Java = 11 }
        @{ Line = 357; Java = 11 }
        @{ Line = 356; Java = 8 }
        @{ Line = 100; Java = 8 }
    ) {
        Get-MinimumJavaVersion $Line | Should -Be $Java
    }

    It 'knows whether Java <Java> is supported on Jenkins 2.<Line>: <Expected>' -ForEach @(
        @{ Java = 8; Line = 346; Expected = $true }
        @{ Java = 8; Line = 357; Expected = $false }
        @{ Java = 11; Line = 462; Expected = $true }
        @{ Java = 11; Line = 463; Expected = $false }
        @{ Java = 17; Line = 541; Expected = $true }
        @{ Java = 17; Line = 545; Expected = $false }
        @{ Java = 21; Line = 580; Expected = $true }
        @{ Java = 25; Line = 533; Expected = $false }
        @{ Java = 25; Line = 534; Expected = $true }
        @{ Java = 16; Line = 400; Expected = $false }
    ) {
        Test-JavaSupported -Java $Java -Line $Line | Should -Be $Expected
    }

    It 'stops when the Java version is too old for the controller' {
        { Assert-JavaCompatible -Java 17 -Line 580 -JenkinsVersion '2.580.1' } |
            Should -Throw '*requires Java 21 or newer*-JavaVersion 21*'
    }

    It 'only warns about a too old Java with -Force' {
        { Assert-JavaCompatible -Java 17 -Line 580 -JenkinsVersion '2.580.1' -Force 3>$null } |
            Should -Not -Throw
    }

    It 'only warns when the Java version is newer than officially supported' {
        { Assert-JavaCompatible -Java 25 -Line 462 -JenkinsVersion '2.462.3' 3>$null } |
            Should -Not -Throw
    }
}

Describe 'ConvertTo-JavaFeatureVersion' {
    It 'finds Java <Java> in <Text>' -ForEach @(
        @{ Text = "openjdk version `"1.8.0_462`"`nOpenJDK Runtime Environment (Temurin)(build 1.8.0_462-b08)"; Java = 8 }
        @{ Text = 'openjdk version "11.0.28" 2025-07-15'; Java = 11 }
        @{ Text = 'openjdk version "21.0.12.1" 2026-08-18 LTS'; Java = 21 }
        @{ Text = 'java version "25" 2025-09-16 LTS'; Java = 25 }
        @{ Text = 'openjdk version "17-ea" 2021-09-14'; Java = 17 }
    ) {
        ConvertTo-JavaFeatureVersion $Text | Should -Be $Java
    }

    It 'fails on unexpected output' {
        { ConvertTo-JavaFeatureVersion 'command not found' } | Should -Throw
    }
}

Describe 'Split-JenkinsUrl' {
    It 'normalizes <Url>' -ForEach @(
        @{ Url = 'https://jenkins.example.com'; Expected = 'https://jenkins.example.com/' }
        @{ Url = ' http://ci:8080/jenkins '; Expected = 'http://ci:8080/jenkins/' }
        @{ Url = 'http://ci:8080/'; Expected = 'http://ci:8080/' }
    ) {
        $result = Split-JenkinsUrl $Url
        $result.Url | Should -Be $Expected
        $result.AgentName | Should -BeNullOrEmpty
    }

    It 'takes the controller URL and agent name from a JNLP URL' {
        $result = Split-JenkinsUrl 'http://ci:8080/jenkins/computer/win%20agent%2001/jenkins-agent.jnlp'
        $result.Url | Should -Be 'http://ci:8080/jenkins/'
        $result.AgentName | Should -Be 'win agent 01'
    }

    It 'understands the old slave-agent.jnlp URL' {
        $result = Split-JenkinsUrl 'https://ci/computer/build-01/slave-agent.jnlp'
        $result.Url | Should -Be 'https://ci/'
        $result.AgentName | Should -Be 'build-01'
    }

    It 'rejects <Url>' -ForEach @(
        @{ Url = 'jenkins.example.com' }
        @{ Url = 'ftp://jenkins.example.com/' }
        @{ Url = '' }
    ) {
        { Split-JenkinsUrl $Url } | Should -Throw '*http*'
    }
}

Describe 'Command line quoting' {
    It 'quotes <Argument> as <Expected>' -ForEach @(
        @{ Argument = 'simple'; Expected = 'simple' }
        @{ Argument = 'C:\jenkins-agent\agent.jar'; Expected = 'C:\jenkins-agent\agent.jar' }
        @{ Argument = 'with space'; Expected = '"with space"' }
        @{ Argument = ''; Expected = '""' }
        @{ Argument = 'C:\my agent\'; Expected = '"C:\my agent\\"' }
        @{ Argument = 'say "hi"'; Expected = '"say \"hi\""' }
        @{ Argument = 'a\"b'; Expected = '"a\\\"b"' }
    ) {
        ConvertTo-QuotedArgument $Argument | Should -Be $Expected
    }

    It 'joins arguments' {
        ConvertTo-CommandLine @('-jar', 'C:\my agent\agent.jar', '-name', 'win-01') |
            Should -Be '-jar "C:\my agent\agent.jar" -name win-01'
    }
}

Describe 'Get-AgentArgumentList' {
    BeforeAll {
        $script:common = @{
            AgentJar = 'C:\jenkins agent\agent.jar'
            JenkinsUrl = 'https://ci.example.com/'
            AgentName = 'win agent'
            SecretPath = 'C:\jenkins agent\secret-file'
            WorkDir = 'C:\jenkins agent'
        }
    }

    It 'uses -url and -name with current remoting' {
        $list = Get-AgentArgumentList @common -SupportsUrl $true -WebSocket $true -JavaOptions @('-Xmx1g') -AgentOptions @('-noReconnectAfter', '1h')
        ($list -join '|') | Should -Be ('-Xmx1g|-jar|C:\jenkins agent\agent.jar|-url|https://ci.example.com/|-name|win agent|-webSocket|' +
            '-secret|@C:\jenkins agent\secret-file|-workDir|C:\jenkins agent|-noReconnectAfter|1h')
    }

    It 'leaves out -webSocket unless asked' {
        $list = Get-AgentArgumentList @common -SupportsUrl $true -WebSocket $false
        $list | Should -Not -Contain '-webSocket'
    }

    It 'falls back to -jnlpUrl with old remoting' {
        $list = Get-AgentArgumentList @common -SupportsUrl $false -WebSocket $true
        $list | Should -Contain '-jnlpUrl'
        $list | Should -Contain 'https://ci.example.com/computer/win%20agent/jenkins-agent.jnlp'
        $list | Should -Not -Contain '-url'
        $list | Should -Not -Contain '-name'
        $list | Should -Not -Contain '-webSocket'
    }

    It 'passes the secret as a file reference, never the value' {
        $list = Get-AgentArgumentList @common -SupportsUrl $true -WebSocket $false
        $list[$list.IndexOf('-secret') + 1] | Should -Be '@C:\jenkins agent\secret-file'
    }
}

Describe 'Split-AccountName' {
    It 'splits <Name>' -ForEach @(
        @{ Name = 'CORP\builder'; Domain = 'CORP'; User = 'builder' }
        @{ Name = '.\builder'; Domain = '.'; User = 'builder' }
        @{ Name = 'builder'; Domain = '.'; User = 'builder' }
    ) {
        $account = Split-AccountName $Name
        $account.Domain | Should -Be $Domain
        $account.User | Should -Be $User
    }

    It 'rejects user principal names' {
        { Split-AccountName 'builder@corp.example.com' } | Should -Throw '*DOMAIN\user*'
    }
}

Describe 'New-WinSWConfig' {
    BeforeAll {
        $script:configArgs = @{
            ServiceId = 'jenkins-agent'
            AgentName = 'R&D <win>'
            JenkinsUrl = 'https://ci.example.com/'
            JavaExe = 'C:\jenkins-agent\java\bin\java.exe'
            ArgumentList = @('-jar', 'C:\jenkins-agent\agent.jar', '-name', 'R&D <win>', '-secret', '@C:\jenkins-agent\secret-file')
            WorkingDirectory = 'C:\jenkins-agent'
            LogDirectory = 'C:\jenkins-agent\logs'
        }
    }

    It 'writes a valid WinSW configuration' {
        $xml = [xml] (New-WinSWConfig @configArgs)
        $xml.service.id | Should -Be 'jenkins-agent'
        $xml.service.name | Should -Be 'Jenkins Agent (R&D <win>)'
        $xml.service.executable | Should -Be 'C:\jenkins-agent\java\bin\java.exe'
        $xml.service.arguments | Should -Be '-jar C:\jenkins-agent\agent.jar -name "R&D <win>" -secret @C:\jenkins-agent\secret-file'
        $xml.service.startmode | Should -Be 'Automatic'
        $xml.service.SelectSingleNode('delayedAutoStart') | Should -Not -BeNullOrEmpty
        @($xml.service.onfailure).Count | Should -Be 3
        @($xml.service.onfailure | ForEach-Object { $_.action } | Select-Object -Unique) | Should -Be @('restart')
        $xml.service.log.mode | Should -Be 'roll-by-size'
        $xml.service.logpath | Should -Be 'C:\jenkins-agent\logs'
        $xml.service.SelectSingleNode('serviceaccount') | Should -BeNullOrEmpty
    }

    It 'adds the service account only when a credential is given' {
        $password = (New-Object System.Net.NetworkCredential('', 'p&ss<word>')).SecurePassword
        $credential = New-Object System.Management.Automation.PSCredential('.\builder', $password)
        $xml = [xml] (New-WinSWConfig @configArgs -Credential $credential)
        $xml.service.serviceaccount.domain | Should -Be '.'
        $xml.service.serviceaccount.user | Should -Be 'builder'
        $xml.service.serviceaccount.password | Should -Be 'p&ss<word>'
        $xml.service.serviceaccount.allowservicelogon | Should -Be 'true'
    }
}

Describe 'Get-FailureHint' {
    It 'explains <Log>' -ForEach @(
        @{ Log = 'SEVERE: Agent win-01 is already connected to this controller. Rejecting this connection.'; Hint = '*already connected*' }
        @{ Log = 'java.lang.UnsupportedClassVersionError: hudson/remoting/Launcher has been compiled by a more recent version'; Hint = '*too old*' }
        @{ Log = 'javax.net.ssl.SSLHandshakeException: PKIX path building failed'; Hint = '*-UseWindowsTrustStore*' }
        @{ Log = 'SEVERE: The server rejected the connection: None of the protocols were accepted'; Hint = '*rejected the agent*' }
        @{ Log = 'java.net.ConnectException: Connection refused: connect'; Hint = '*-WebSocket*' }
        @{ Log = 'java.net.UnknownHostException: jenkins.example.com'; Hint = '*resolve*' }
    ) {
        Get-FailureHint -Log $Log -AgentName 'win-01' | Should -BeLike $Hint
    }

    It 'returns nothing for an unknown problem' {
        Get-FailureHint -Log 'INFO: Locating server among [http://ci/]' -AgentName 'win-01' | Should -BeNullOrEmpty
    }
}

Describe 'Running the script' {
    BeforeAll {
        $script:shell = (Get-Process -Id $PID).Path
        $script:saved = @{}
        foreach ($name in 'JENKINS_URL', 'JENKINS_AGENT_NAME', 'JENKINS_SECRET') {
            $script:saved[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, $null)
        }
    }

    AfterAll {
        foreach ($name in $script:saved.Keys) { [Environment]::SetEnvironmentVariable($name, $script:saved[$name]) }
    }

    It 'exits with code 1 and a readable error when run as a file' {
        $output = & $script:shell -NoProfile -ExecutionPolicy Bypass -File $script:InstallScript -AgentName win-01 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 1
        $output | Should -Match 'ERROR: (Missing -JenkinsUrl|This script installs a Windows service|Administrator rights)'
    }

    It 'throws instead of exiting when run as a script block' {
        $block = [scriptblock]::Create([System.IO.File]::ReadAllText($script:InstallScript))
        { & $block -AgentName win-01 } | Should -Throw
    }
}
