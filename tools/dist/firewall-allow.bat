@echo off
rem Allow inbound TCP 27777 for the VBMP bridge (host only). Asks for admin rights.
net session >nul 2>&1 || (powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath \"%~f0\"" & exit /b)
netsh advfirewall firewall delete rule name="VBMP bridge" >nul 2>&1
netsh advfirewall firewall add rule name="VBMP bridge" dir=in action=allow protocol=TCP localport=27777 profile=any
pause
