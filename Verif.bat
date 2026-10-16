@echo off
setlocal
cd /d "%~dp0"
echo Verification BJMPC Toolbox sur ce PC... (ne rien toucher, 1 a 2 minutes)
powershell -NoProfile -ExecutionPolicy Bypass -Command "$o=@(); $o+='PowerShell '+$PSVersionTable.PSVersion; Get-ChildItem '%~dp0' -Filter *.ps1 | ForEach-Object { $e=$null; [void][Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$null,[ref]$e); $o+=('{0} : {1} erreur(s) de syntaxe' -f $_.Name,$e.Count); $e | Select-Object -First 3 | ForEach-Object { $o+='   '+$_.Message+' (ligne '+$_.Extent.StartLineNumber+')' } }; $o | Set-Content -Encoding UTF8 '%~dp0Verif_syntaxe.txt'"
set "BJMPC_SELFTEST=%~dp0Verif_resultat.txt"
powershell -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0BJMPC-Toolbox.ps1" > "%~dp0Verif_sortie.txt" 2>&1
echo Termine. Fermez cette fenetre.
echo fini > "%~dp0Verif_fini.txt"
