@echo off
rem Launch DesktopClock without a console window
start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0DesktopClock.ps1"
