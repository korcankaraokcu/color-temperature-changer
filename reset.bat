@echo off
rem Returns every display to normal colors (undoes "Keep after closing").
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0color-temperature-changer.ps1" -Reset
timeout /t 3 >nul
