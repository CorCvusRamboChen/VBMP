@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0vbmp-bridge.ps1" -Role client
pause
