@echo off
setlocal
title BJMPC Toolbox

:: Verification administrateur ("fltmc" ne depend d aucun service Windows).
fltmc >nul 2>&1 && goto :run
net session >nul 2>&1 && goto :run

:: Deja relance une fois en administrateur et toujours pas admin : on s arrete (jamais de boucle).
if /i "%~1"=="/elevated" goto :failed

powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -ArgumentList '/elevated' -Verb RunAs -WindowStyle Minimized"
exit /b

:failed
echo.
echo  Impossible d obtenir les droits administrateur.
echo  Faites un clic droit sur ce fichier ^> Executer en tant qu administrateur.
echo.
pause
exit /b 1

:run
powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0BJMPC-Toolbox.ps1"
if errorlevel 1 (
    echo.
    echo  BJMPC Toolbox ne s est pas lance correctement.
    echo  Details : %SystemDrive%\BJMPC-Logs\Toolbox_erreurs.log
    echo.
    pause
)
exit /b
