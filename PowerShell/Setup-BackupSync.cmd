@echo off
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Setup-BackupSync.ps1" %*
if errorlevel 1 pause
