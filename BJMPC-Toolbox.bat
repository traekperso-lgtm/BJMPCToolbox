@echo off
setlocal
title BJMPC Toolbox

:: Deja administrateur ("fltmc" ne depend d aucun service Windows) : lancement direct.
fltmc >nul 2>&1 && goto :run
net session >nul 2>&1 && goto :run

:: Sinon UNE seule demande d administrateur, qui lance directement la Toolbox
:: (le fichier .bat n est pas relance : pas de second avertissement de securite).
set "BJMPC_PS1=%~dp0BJMPC-Toolbox.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "try { Start-Process -FilePath powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"' + $env:BJMPC_PS1 + '\"') -ErrorAction Stop; exit 0 } catch { exit 1 }"
if errorlevel 1 goto :failed
exit /b

:failed
echo.
echo  Impossible d obtenir les droits administrateur (demande refusee ?).
echo  Faites un clic droit sur BJMPC-Toolbox.bat ^> Executer en tant qu administrateur.
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
