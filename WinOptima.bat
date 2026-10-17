@echo off
setlocal
cd /d "%~dp0"

:: Controllo privilegi amministratore
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Richiesta privilegi di amministratore in corso...
    powershell -NoProfile -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:: Avvio applicazione WinOptima (PowerShell nascosto, thread STA necessario per l'interfaccia)
start "" powershell -NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File "%~dp0WinOptima.ps1"
exit /b
