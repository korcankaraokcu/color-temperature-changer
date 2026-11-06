@echo off
rem Starts Color Temperature Changer without leaving a console window open.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0color-temperature-changer.ps1"
