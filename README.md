# Jenkins Windows Agent

[![Test](https://github.com/shenxianpeng/jenkins-windows-agent/actions/workflows/test.yml/badge.svg)](https://github.com/shenxianpeng/jenkins-windows-agent/actions/workflows/test.yml)

Run a Jenkins inbound agent as a Windows service with one command.

`install.ps1` downloads the right Java, gets `agent.jar` from your controller, registers a
service that starts on boot and restarts on failure, and waits until the agent is connected.
If something is wrong it tells you what to fix.

- Java 8, 11, 17, 21 and 25 (Eclipse Temurin), picked automatically to match your controller
- TCP or WebSocket connections, HTTP or HTTPS controllers, secured or not
- Runs as LocalSystem or as a domain/local account
- Safe to run again: upgrades Java and `agent.jar`, applies changed settings
- Tested end to end on Windows Server 2022 and 2025 against real Jenkins controllers, from
  2.346.3 (the last one with Java 8) to the latest weekly

## Quick start

**1. Create the node in Jenkins.** *Manage Jenkins > Nodes > New Node*, choose *Permanent Agent*:

- *Remote root directory*: `C:\jenkins-agent`
- *Launch method*: *Launch agent by connecting it to the controller*

Save, then open the node page. It shows the agent **secret**, the long hex string after `-secret`.

**2. Install the agent on Windows.** Open PowerShell with *Run as administrator* and run:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/shenxianpeng/jenkins-windows-agent/main/install.ps1))) -JenkinsUrl https://jenkins.example.com/ -AgentName win-01 -Secret <secret>
```

That's it. The output ends with:

```text
Agent 'win-01' is connected to https://jenkins.example.com/
    Service  : jenkins-agent (automatic, delayed start, restarts on failure)
    Runs as  : LocalSystem
    Java     : C:\jenkins-agent\java\bin\java.exe (Java 21)
    ...
```

Other ways to run it:

```powershell
# Settings in environment variables (also keeps the secret out of the command line)
$env:JENKINS_URL = 'https://jenkins.example.com/'
$env:JENKINS_AGENT_NAME = 'win-01'
$env:JENKINS_SECRET = '<secret>'
irm https://raw.githubusercontent.com/shenxianpeng/jenkins-windows-agent/main/install.ps1 | iex
```

```bat
:: From a clone, in an elevated Command Prompt
git clone https://github.com/shenxianpeng/jenkins-windows-agent.git
cd jenkins-windows-agent
main.bat -JenkinsUrl https://jenkins.example.com/ -AgentName win-01 -Secret <secret>
```

> [!TIP]
> To always install the same, reviewed version, replace `main` in the URLs with a release tag
> or commit SHA.

> [!NOTE]
> On Windows Server 2016 and old Windows 10 builds, enable TLS 1.2 first, or `irm` cannot
> reach GitHub: `[Net.ServicePointManager]::SecurityProtocol = 'Tls12'`

## Which Java?

The controller decides which Java its agents may use; the requirements apply to agents too
([Jenkins Java support policy](https://www.jenkins.io/doc/book/platform-information/support-policy-java/)).
`install.ps1` reads the controller version and by default (`-JavaVersion auto`) picks:

| Jenkins controller | Agent Java supported | `auto` picks |
| --- | --- | --- |
| 2.545 and newer (LTS 2.555.1 and newer) | 21, 25 | 21 |
| 2.463 – 2.544 (LTS 2.479.1 – 2.541.3) | 17, 21, 25 from 2.534 | 21 |
| 2.357 – 2.462 (LTS 2.361.1 – 2.462.3) | 11, 17 | 17 |
| 2.164 – 2.356 (LTS 2.164.1 – 2.346.3) | 8, 11, 17 from 2.340 | 11, or 17 from 2.340 |
| older | 8 | 8 |

Pass `-JavaVersion 8`, `11`, `17`, `21` or `25` to choose yourself. A version that is too old for
the controller is refused with a clear message before anything is changed, because the agent
could never connect. A version newer than officially supported only gives a warning.

> [!IMPORTANT]
> Java 17 agents only work with controllers up to 2.544 weekly / 2.541.3 LTS. Before you
> upgrade the controller past that, run the installer again with `-JavaVersion 21` (or `auto`).

## Options

| Parameter | Default | Description |
| --- | --- | --- |
| `-JenkinsUrl` | `$env:JENKINS_URL` | Controller URL. A node's `.../jenkins-agent.jnlp` URL works too. |
| `-AgentName` | `$env:JENKINS_AGENT_NAME` | Node name on the controller. |
| `-Secret` | `$env:JENKINS_SECRET` | Agent secret from the node page. |
| `-SecretFile` | | Read the secret from a file instead. |
| `-JavaVersion` | `auto` | `auto`, `8`, `11`, `17`, `21` or `25`. |
| `-JavaPackage` | `jre` | `jre`, or `jdk` if builds should use the agent's Java. |
| `-JavaHome` | | Use an installed Java instead of downloading one. |
| `-InstallDir` | `C:\jenkins-agent` | Where Java, `agent.jar`, the service wrapper and logs go. |
| `-WorkDir` | `-InstallDir` | Agent work directory. Keep it equal to the node's *Remote root directory*. |
| `-WebSocket` | `$env:JENKINS_WEB_SOCKET` | Connect over HTTP(S) WebSocket instead of the TCP agent port. |
| `-ServiceId` | `jenkins-agent` | Windows service name. |
| `-ServiceCredential` | LocalSystem | Run the service as `DOMAIN\user` or `.\user`, e.g. `(Get-Credential)`. |
| `-UseWindowsTrustStore` | | Make Java trust the CAs in the Windows certificate store. |
| `-JavaOptions` | | Extra JVM options, e.g. `'-Xmx1g'`. |
| `-AgentOptions` | | Extra `agent.jar` options. |
| `-ConnectTimeout` | `120` | Seconds to wait for the connection; `0` skips the check. |
| `-NoStart` | | Install the service without starting it. |
| `-Force` | | Use a Java version even if it is too old for the controller. |
| `-Uninstall` | | Remove the service and the files the script created. |

`Get-Help .\install.ps1 -Full` (or `main.bat -?`) shows the same in the console.

## Everyday tasks

**Upgrade** Java (to the latest patch release) and `agent.jar`, or change a setting: run the
same command again, with the changed options. It only downloads what changed, and only stops
the running agent once everything new has been downloaded and checked.

**Manage the service** like any other: `Get-Service jenkins-agent`, `Restart-Service jenkins-agent`.

**Run as a domain account**, for example to reach network shares:

```powershell
.\install.ps1 -JenkinsUrl https://jenkins.example.com/ -AgentName win-01 -SecretFile C:\secret.txt -ServiceCredential (Get-Credential CORP\jenkins)
```

Windows stores the password with the service. It is in `jenkins-agent.xml` only while the
service is being installed; the file is rewritten without it right after.

**Several agents on one machine**: give each its own `-InstallDir` and `-ServiceId`.

**No internet access**: copy [WinSW-x64.exe v2.12.0](https://github.com/winsw/winsw/releases/tag/v2.12.0)
to `<InstallDir>\jenkins-agent.exe` and pass `-JavaHome`. `agent.jar` always comes from the controller.

**Uninstall**: `.\install.ps1 -Uninstall` (add `-InstallDir` if you changed it). Workspaces in the
work directory are kept.

## Troubleshooting

When the agent does not connect within `-ConnectTimeout`, the script prints the last lines of
the agent log and a hint. The service stays installed and keeps retrying.

| Symptom | What to do |
| --- | --- |
| `requires Java 21 or newer` | Leave out `-JavaVersion`, or pick one from [Which Java?](#which-java). |
| `The controller rejected the agent` | Copy the agent name and secret again from the node page. |
| `cannot reach the inbound TCP port` | Use `-WebSocket`, or open the TCP agent port (*Manage Jenkins > Security > Agents*) in firewalls. |
| `PKIX path building failed` | The controller uses a company CA. If Windows trusts it, add `-UseWindowsTrustStore`. |
| `already connected` | Another process uses this agent name, for example a service from an older installation. |
| Not running right after a reboot | The service uses *delayed* automatic start, so it starts a minute or two after boot, once the network is up. |

Logs: `C:\jenkins-agent\logs\jenkins-agent.err.log` (agent output) and
`jenkins-agent.wrapper.log` (service wrapper), plus `C:\jenkins-agent\remoting\logs`.

## What gets installed

```text
C:\jenkins-agent\
  java\                  Eclipse Temurin (unless -JavaHome is used)
  agent.jar              from <JenkinsUrl>/jnlpJars/agent.jar
  jenkins-agent.exe      WinSW v2.12.0, the service wrapper Jenkins uses too
  jenkins-agent.xml      service configuration (generated; do not edit)
  secret-file            the agent secret
  logs\                  service and agent logs
  remoting\, workspace\  created by the agent
```

Security:

- The secret is passed to `agent.jar` as `-secret @secret-file`, so it never appears in the service
  configuration or the process list. Only SYSTEM, Administrators and the service account can read it.
- The service runs as LocalSystem by default, so the install directory is writable by
  Administrators and SYSTEM (and the service account) only. Other users can read it.
- WinSW is checked against a pinned SHA-256; Temurin downloads against Adoptium's published SHA-256.

## Upgrading from the old `main.bat` + `jenkins-agent.xml` setup

1. Remove the old service, in an elevated prompt in the old folder:
   `jenkins-agent.exe stop` and then `jenkins-agent.exe uninstall`.
2. Install with the same remote root directory as before, for example `-InstallDir C:\agent`.

`-JenkinsUrl` also accepts the old `-jnlpUrl` value, so you can copy it from the old
`jenkins-agent.xml`.

## Development

```powershell
Invoke-Pester -Path tests                                            # unit tests, no admin needed
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

The [Test workflow](.github/workflows/test.yml) runs PSScriptAnalyzer, the unit tests on
Windows PowerShell 5.1 and PowerShell 7, and end-to-end tests. Each end-to-end job starts a real
Jenkins controller on a Windows runner, installs the agent the way a user would (`main.bat`,
`-File`, script block or `irm | iex`), and checks that the node comes online and runs a build:

| Agent Java | Controller | Also covers |
| --- | --- | --- |
| 8 | 2.346.3 | old `agent.jar` (`-jnlpUrl`), spaces in agent name and path, `main.bat` |
| 11 | 2.462.3 | killing `java.exe`: Windows restarts the service and the agent reconnects |
| 17 | 2.541.3 | WebSocket only (TCP port disabled) |
| 21 | latest LTS | secured controller, local service account, upgrade to Java 25, uninstall |
| 25 (JDK) | latest LTS | WebSocket, script block one-liner |
| auto | latest weekly | `irm \| iex` one-liner, refusing a too old Java, wrong-secret diagnostics |
| existing (`-JavaHome`) | latest LTS | using a preinstalled Java |

Every job also runs the installer a second time to check that it is idempotent. The workflow
runs weekly as well, to catch new Jenkins and Java releases.

## License

[MIT](LICENSE)
