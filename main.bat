@echo off

set current_dir="%CD%"
set "openjdk_url=https://download.java.net/java/GA/jdk17.0.2/dfd4a8d0985749f896bed50d7138ee7f/8/GPL/openjdk-17.0.2_windows-x64_bin.zip"
set "jenkins_agent_url=https://github.com/winsw/winsw/releases/download/v2.11.0/WinSW-x64.exe"

:download_jdk17
rem jdk-17.0.2
curl -o "%current_dir%\openjdk-17.0.2_windows-x64_bin.zip" "%openjdk_url%"
tar -xf openjdk-17.0.2_windows-x64_bin.zip

:download_agent
curl -o "%current_dir%\jenkins-agent.exe" "%jenkins_agent_url%"

if "%1"=="agent" goto end

:install_service
jenkins-agent.exe install
:start_service
jenkins-agent.exe start

:end
