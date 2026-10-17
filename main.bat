@echo off
rem Installs a Jenkins agent as a Windows service by running install.ps1 with
rem Windows PowerShell, whatever the PowerShell execution policy is.
rem Run it from an elevated ("Run as administrator") command prompt:
rem
rem   main.bat -JenkinsUrl https://jenkins.example.com/ -AgentName win-01 -Secret SECRET
rem   main.bat -Uninstall
rem
rem All options: main.bat -? or README.md
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
exit /b %ERRORLEVEL%
