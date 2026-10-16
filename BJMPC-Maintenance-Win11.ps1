#Requires -Version 5.1
<#
.SYNOPSIS
    BJMPC Informatique - Maintenance et réparation Windows 10/11 (menu interactif)
.DESCRIPTION
    Menu pas à pas : SFC, DISM, CHKDSK, services, réseau, Windows Update,
    graphique, caches, Store, nettoyage, etc.
    Chaque action est journalisée dans C:\BJMPC-Logs.
#>

$ErrorActionPreference = 'Continue'
$Script:Version = '1.0'
$Script:LogDir  = Join-Path $env:SystemDrive 'BJMPC-Logs'
$Script:LogFile = Join-Path $LogDir ("Maintenance_{0}_{1}.log" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmmss'))
$Script:RebootNeeded = $false

# ---------------------------------------------------------------- Prérequis
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host "Relance en administrateur..." -ForegroundColor Yellow
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$Host.UI.RawUI.WindowTitle = "BJMPC Informatique - Maintenance Windows v$Version"

# ---------------------------------------------------------------- Utilitaires
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $Script:LogFile -Value $line -Encoding UTF8
    switch ($Level) {
        'OK'    { Write-Host "  [OK]  $Message" -ForegroundColor Green }
        'WARN'  { Write-Host "  [!]   $Message" -ForegroundColor Yellow }
        'ERROR' { Write-Host "  [X]   $Message" -ForegroundColor Red }
        default { Write-Host "  [..]  $Message" -ForegroundColor Cyan }
    }
}

function Confirm-Action {
    param([string]$Question)
    $r = Read-Host "  $Question (O/N)"
    return ($r -match '^[oOyY]')
}

function Wait-Key {
    Write-Host ""
    Read-Host "  Appuyez sur Entrée pour revenir au menu" | Out-Null
}

function Invoke-Native {
    # Exécute une commande native et journalise la sortie
    param([string]$Exe, [string]$Arguments)
    Write-Log "Exécution : $Exe $Arguments"
    & cmd.exe /c "$Exe $Arguments 2>&1" | ForEach-Object {
        if ($_ -and $_.Trim()) { Write-Host "        $_" -ForegroundColor DarkGray; Add-Content -Path $Script:LogFile -Value "        $_" -Encoding UTF8 }
    }
    Write-Log "Code retour : $LASTEXITCODE" $(if ($LASTEXITCODE -eq 0) { 'OK' } else { 'WARN' })
}

function Show-Header {
    param([string]$Title)
    Clear-Host
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "   BJMPC INFORMATIQUE  -  Maintenance Windows  (v$Script:Version)" -ForegroundColor White
    Write-Host "   PC : $env:COMPUTERNAME   |   Utilisateur : $env:USERNAME" -ForegroundColor Gray
    Write-Host "  ============================================================" -ForegroundColor Cyan
    if ($Title) { Write-Host "   $Title" -ForegroundColor Yellow; Write-Host "" }
}

# ---------------------------------------------------------------- Actions
function Get-SystemSummary {
    Show-Header "Informations système"
    $os  = Get-CimInstance Win32_OperatingSystem
    $cs  = Get-CimInstance Win32_ComputerSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $up  = (Get-Date) - $os.LastBootUpTime
    Write-Host ("  OS            : {0} (build {1})" -f $os.Caption, $os.BuildNumber)
    Write-Host ("  Machine       : {0} {1}" -f $cs.Manufacturer, $cs.Model)
    Write-Host ("  Processeur    : {0}" -f $cpu.Name.Trim())
    Write-Host ("  RAM           : {0} Go (libre : {1} Go)" -f [math]::Round($cs.TotalPhysicalMemory/1GB,1), [math]::Round($os.FreePhysicalMemory/1MB,1))
    Write-Host ("  Uptime        : {0}j {1}h {2}m" -f $up.Days, $up.Hours, $up.Minutes)
    Write-Host ""
    Write-Host "  Disques logiques :" -ForegroundColor Yellow
    Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
        Write-Host ("    {0}  {1} Go libres / {2} Go  ({3}%)" -f $_.DeviceID, [math]::Round($_.FreeSpace/1GB,1), [math]::Round($_.Size/1GB,1), [math]::Round(100*$_.FreeSpace/$_.Size,0))
    }
    Write-Host ""
    Write-Host "  Santé des disques physiques :" -ForegroundColor Yellow
    try {
        Get-PhysicalDisk | ForEach-Object {
            $c = if ($_.HealthStatus -eq 'Healthy') { 'Green' } else { 'Red' }
            Write-Host ("    {0} [{1}] {2} - {3}" -f $_.FriendlyName, $_.MediaType, $_.HealthStatus, $_.OperationalStatus) -ForegroundColor $c
        }
    } catch { Write-Log "Lecture SMART impossible : $($_.Exception.Message)" 'WARN' }
    Write-Host ""
    $pending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
               (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
    Write-Host ("  Redémarrage en attente : {0}" -f $(if ($pending) { 'OUI' } else { 'non' })) -ForegroundColor $(if ($pending) { 'Yellow' } else { 'Green' })
    Write-Log "Résumé système affiché"
}

function New-RestorePoint {
    Write-Log "Création d'un point de restauration..."
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        # Lève la limite de 1 point / 24h
        Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Name SystemRestorePointCreationFrequency -Value 0 -Type DWord -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description "BJMPC Maintenance $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-Log "Point de restauration créé" 'OK'
    } catch {
        Write-Log "Point de restauration impossible : $($_.Exception.Message)" 'WARN'
    }
}

function Invoke-DISM {
    Write-Log "DISM - vérification de l'image Windows"
    Invoke-Native 'DISM.exe' '/Online /Cleanup-Image /CheckHealth'
    Invoke-Native 'DISM.exe' '/Online /Cleanup-Image /ScanHealth'
    if (Confirm-Action "Lancer la réparation (RestoreHealth, nécessite Internet/Windows Update) ?") {
        Invoke-Native 'DISM.exe' '/Online /Cleanup-Image /RestoreHealth'
    }
}

function Invoke-SFC {
    Write-Log "SFC - vérification des fichiers système (peut durer 10-30 min)"
    Invoke-Native 'sfc.exe' '/scannow'
    Write-Host ""
    Write-Host "  Détails CBS : $env:windir\Logs\CBS\CBS.log" -ForegroundColor DarkGray
}

function Invoke-Chkdsk {
    $drive = $env:SystemDrive
    Write-Host "  1) Analyse en ligne, lecture seule ($drive /scan)"
    Write-Host "  2) Planifier réparation complète au prochain démarrage ($drive /f /r)"
    Write-Host "  3) Autre lecteur (analyse en ligne)"
    Write-Host "  0) Annuler"
    $c = Read-Host "  Choix"
    switch ($c) {
        '1' { Invoke-Native 'chkdsk.exe' "$drive /scan" }
        '2' {
            Invoke-Native 'fsutil.exe' "dirty set $drive"
            Write-Log "CHKDSK complet ($drive) planifié au prochain redémarrage" 'OK'
            $Script:RebootNeeded = $true
        }
        '3' {
            $d = (Read-Host "  Lettre du lecteur (ex : D)").Trim().TrimEnd(':')
            if ($d -match '^[A-Za-z]$') { Invoke-Native 'chkdsk.exe' "${d}: /scan" } else { Write-Log "Lettre invalide" 'WARN' }
        }
        default { return }
    }
}

# --- Services : état par défaut de Windows 11 (liste prudente)
$Script:DefaultServices = [ordered]@{
    'EventLog'          = 'Automatic'
    'RpcSs'             = 'Automatic'
    'DcomLaunch'        = 'Automatic'
    'Winmgmt'           = 'Automatic'
    'Schedule'          = 'Automatic'
    'EventSystem'       = 'Automatic'
    'ProfSvc'           = 'Automatic'
    'Themes'            = 'Automatic'
    'ShellHWDetection'  = 'Automatic'
    'AudioEndpointBuilder' = 'Automatic'
    'Audiosrv'          = 'Automatic'
    'FontCache'         = 'Automatic'
    'Dhcp'              = 'Automatic'
    'Dnscache'          = 'Automatic'
    'NlaSvc'            = 'Automatic'
    'nsi'               = 'Automatic'
    'LanmanWorkstation' = 'Automatic'
    'mpssvc'            = 'Automatic'
    'WinDefend'         = 'Automatic'
    'CryptSvc'          = 'Automatic'
    'Spooler'           = 'Automatic'
    'wuauserv'          = 'Manual'
    'BITS'              = 'Manual'
    'TrustedInstaller'  = 'Manual'
    'msiserver'         = 'Manual'
    'netprofm'          = 'Manual'
    'PlugPlay'          = 'Manual'
}

function Reset-Services {
    Write-Log "Remise des services essentiels à leur état par défaut"
    foreach ($name in $Script:DefaultServices.Keys) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if (-not $svc) { continue }
        $target = $Script:DefaultServices[$name]
        try {
            Set-Service -Name $name -StartupType $target -ErrorAction Stop
            if ($target -eq 'Automatic' -and $svc.Status -ne 'Running') {
                Start-Service -Name $name -ErrorAction SilentlyContinue
            }
            $st = (Get-Service $name).Status
            Write-Log ("{0,-22} -> {1,-9} ({2})" -f $name, $target, $st) 'OK'
        } catch {
            Write-Log ("{0} : {1}" -f $name, $_.Exception.Message) 'WARN'
        }
    }
    Write-Log "Note : WinDefend/TrustedInstaller peuvent refuser la modification selon la protection anti-altération." 'WARN'
}

function Reset-WindowsUpdate {
    Write-Log "Réinitialisation de Windows Update"
    $svcs = 'wuauserv','bits','cryptsvc','msiserver','usosvc','dosvc'
    foreach ($s in $svcs) { Stop-Service -Name $s -Force -ErrorAction SilentlyContinue }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    foreach ($p in @("$env:windir\SoftwareDistribution", "$env:windir\System32\catroot2")) {
        if (Test-Path $p) {
            try { Rename-Item -Path $p -NewName ("{0}.bak_{1}" -f (Split-Path $p -Leaf), $stamp) -ErrorAction Stop; Write-Log "Renommé : $p" 'OK' }
            catch { Write-Log "Impossible de renommer $p : $($_.Exception.Message)" 'WARN' }
        }
    }
    # Files BITS
    Get-ChildItem "$env:ALLUSERSPROFILE\Microsoft\Network\Downloader" -Filter 'qmgr*.dat' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    # Ré-enregistrement des DLL principales
    foreach ($dll in 'atl.dll','urlmon.dll','mshtml.dll','shdocvw.dll','browseui.dll','jscript.dll','vbscript.dll','scrrun.dll','msxml3.dll','msxml6.dll','actxprxy.dll','softpub.dll','wintrust.dll','initpki.dll','wuapi.dll','wuaueng.dll','wucltux.dll','wups.dll','wups2.dll','wuweb.dll','qmgr.dll') {
        & regsvr32.exe /s "$env:windir\System32\$dll" 2>$null
    }
    Invoke-Native 'netsh.exe' 'winsock reset'
    foreach ($s in 'cryptsvc','bits','wuauserv','usosvc') { Start-Service -Name $s -ErrorAction SilentlyContinue }
    Write-Log "Windows Update réinitialisé (dossiers .bak conservés)" 'OK'
    $Script:RebootNeeded = $true
}

function Reset-Network {
    Write-Log "Réinitialisation de la pile réseau"
    Invoke-Native 'ipconfig.exe' '/flushdns'
    Invoke-Native 'ipconfig.exe' '/release'
    Invoke-Native 'netsh.exe' 'winsock reset'
    Invoke-Native 'netsh.exe' 'int ip reset'
    Invoke-Native 'netsh.exe' 'int ipv6 reset'
    Invoke-Native 'nbtstat.exe' '-R'
    Invoke-Native 'nbtstat.exe' '-RR'
    Invoke-Native 'arp.exe' '-d *'
    Invoke-Native 'ipconfig.exe' '/renew'
    Invoke-Native 'ipconfig.exe' '/registerdns'
    try { Clear-DnsClientCache } catch {}
    Write-Log "Réseau réinitialisé - redémarrage recommandé" 'OK'
    $Script:RebootNeeded = $true

    if (Confirm-Action "Réinitialiser aussi le pare-feu Windows aux valeurs par défaut ?") {
        Invoke-Native 'netsh.exe' 'advfirewall reset'
    }
    if (Confirm-Action "Réinitialisation TOTALE des adaptateurs réseau (netcfg -d) ? Les cartes seront réinstallées, IP statiques perdues") {
        Invoke-Native 'netcfg.exe' '-d'
    }
    if (Confirm-Action "Réinitialiser les paramètres proxy WinHTTP ?") {
        Invoke-Native 'netsh.exe' 'winhttp reset proxy'
    }
}

function Reset-Graphics {
    Write-Log "Réinitialisation des options graphiques"

    # 1. Préférences GPU par application (Paramètres > Affichage > Graphiques)
    $gpuKey = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
    if (Test-Path $gpuKey) {
        try {
            (Get-Item $gpuKey).GetValueNames() | ForEach-Object { Remove-ItemProperty -Path $gpuKey -Name $_ -ErrorAction SilentlyContinue }
            Write-Log "Préférences GPU par application effacées" 'OK'
        } catch { Write-Log "Préférences GPU : $($_.Exception.Message)" 'WARN' }
    } else { Write-Log "Aucune préférence GPU personnalisée" }

    # 2. Optimisations plein écran / Game DVR
    $gcs = 'HKCU:\System\GameConfigStore'
    if (Test-Path $gcs) {
        foreach ($n in 'GameDVR_FSEBehaviorMode','GameDVR_HonorUserFSEBehaviorMode','GameDVR_DXGIHonorFSEWindowsCompatible','GameDVR_EFSEFeatureFlags','GameDVR_FSEBehavior') {
            Remove-ItemProperty -Path $gcs -Name $n -ErrorAction SilentlyContinue
        }
        Write-Log "Options plein écran / GameConfigStore réinitialisées" 'OK'
    }

    # 3. Caches de shaders
    $shaderPaths = @(
        "$env:LOCALAPPDATA\D3DSCache",
        "$env:LOCALAPPDATA\NVIDIA\DXCache",
        "$env:LOCALAPPDATA\NVIDIA\GLCache",
        "$env:LOCALAPPDATA\AMD\DxCache",
        "$env:LOCALAPPDATA\AMD\GLCache",
        "$env:LOCALAPPDATA\Intel\ShaderCache"
    )
    foreach ($p in $shaderPaths) {
        if (Test-Path $p) {
            Get-ChildItem $p -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Cache vidé : $p" 'OK'
        }
    }

    # 4. Mise à l'échelle DPI (optionnel)
    if (Confirm-Action "Réinitialiser aussi la mise à l'échelle DPI (100 % au prochain redémarrage de session) ?") {
        $desk = 'HKCU:\Control Panel\Desktop'
        Remove-ItemProperty -Path $desk -Name 'LogPixels','Win8DpiScaling','DpiScalingVer' -ErrorAction SilentlyContinue
        Remove-Item -Path "$desk\PerMonitorSettings" -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "Échelle DPI réinitialisée (déconnexion nécessaire)" 'OK'
    }

    # 5. Redémarrage du pilote d'affichage (écran clignote)
    if (Confirm-Action "Redémarrer la carte graphique (désactiver/réactiver, l'écran va clignoter) ?") {
        Get-PnpDevice -Class Display -Status OK -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                Disable-PnpDevice -InstanceId $_.InstanceId -Confirm:$false -ErrorAction Stop
                Start-Sleep -Seconds 2
                Enable-PnpDevice  -InstanceId $_.InstanceId -Confirm:$false -ErrorAction Stop
                Write-Log "Adaptateur redémarré : $($_.FriendlyName)" 'OK'
            } catch { Write-Log "$($_.FriendlyName) : $($_.Exception.Message)" 'WARN' }
        }
    }

    # 6. Rescan du matériel
    Invoke-Native 'pnputil.exe' '/scan-devices'
}

function Clear-ShellCaches {
    Write-Log "Vidage des caches icônes, miniatures et polices"
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    $exp = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer"
    Get-ChildItem $exp -Include 'iconcache*','thumbcache*' -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:LOCALAPPDATA\IconCache.db" -Force -ErrorAction SilentlyContinue
    # Cache de polices
    Stop-Service FontCache -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:windir\ServiceProfiles\LocalService\AppData\Local\FontCache\*" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:windir\System32\FNTCACHE.DAT" -Force -ErrorAction SilentlyContinue
    Start-Service FontCache -ErrorAction SilentlyContinue
    Start-Process explorer.exe
    Write-Log "Caches vidés, explorateur relancé" 'OK'
}

function Reset-Store {
    Write-Log "Réinitialisation du Microsoft Store"
    Start-Process wsreset.exe -Wait -NoNewWindow -ErrorAction SilentlyContinue
    Get-AppxPackage -AllUsers Microsoft.WindowsStore -ErrorAction SilentlyContinue | ForEach-Object {
        Add-AppxPackage -DisableDevelopmentMode -Register "$($_.InstallLocation)\AppXManifest.xml" -ErrorAction SilentlyContinue
    }
    Write-Log "Store réinitialisé" 'OK'
}

function Register-AllApps {
    Write-Log "Ré-enregistrement des applications intégrées (peut durer plusieurs minutes, erreurs rouges bénignes possibles)"
    Get-AppxPackage -AllUsers | ForEach-Object {
        if ($_.InstallLocation -and (Test-Path "$($_.InstallLocation)\AppXManifest.xml")) {
            Add-AppxPackage -DisableDevelopmentMode -Register "$($_.InstallLocation)\AppXManifest.xml" -ErrorAction SilentlyContinue
        }
    }
    Write-Log "Ré-enregistrement terminé" 'OK'
}

function Repair-WMI {
    Write-Log "Vérification du dépôt WMI"
    Invoke-Native 'winmgmt.exe' '/verifyrepository'
    if (Confirm-Action "Lancer la réparation du dépôt WMI (salvagerepository) ?") {
        Invoke-Native 'winmgmt.exe' '/salvagerepository'
    }
}

function Invoke-Cleanup {
    Write-Log "Nettoyage des fichiers temporaires"
    $before = (Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':'))).Free
    foreach ($p in @("$env:TEMP", "$env:windir\Temp", "$env:LOCALAPPDATA\Temp", "$env:windir\Prefetch",
                     "$env:LOCALAPPDATA\Microsoft\Windows\INetCache", "$env:LOCALAPPDATA\CrashDumps",
                     "$env:ProgramData\Microsoft\Windows\WER\ReportQueue")) {
        if (Test-Path $p) { Get-ChildItem $p -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Clear-RecycleBin -Force -ErrorAction SilentlyContinue
    if (Confirm-Action "Nettoyer aussi le magasin de composants (DISM StartComponentCleanup) ?") {
        Invoke-Native 'DISM.exe' '/Online /Cleanup-Image /StartComponentCleanup'
    }
    $after = (Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':'))).Free
    Write-Log ("Espace libéré : {0} Mo" -f [math]::Round(($after - $before)/1MB,0)) 'OK'
}

function Invoke-DefenderScan {
    Write-Log "Mise à jour des signatures et analyse rapide Defender"
    try {
        Update-MpSignature -ErrorAction SilentlyContinue
        Start-MpScan -ScanType QuickScan -ErrorAction Stop
        Write-Log "Analyse rapide terminée" 'OK'
        Get-MpThreatDetection -ErrorAction SilentlyContinue | Select-Object -First 10 | Format-Table -AutoSize | Out-Host
    } catch { Write-Log "Defender indisponible (antivirus tiers ?) : $($_.Exception.Message)" 'WARN' }
}

function Reset-Search {
    Write-Log "Réinitialisation de l'indexation Windows Search"
    Stop-Service WSearch -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:ProgramData\Microsoft\Search\Data\Applications\Windows\Windows.edb" -Force -ErrorAction SilentlyContinue
    Start-Service WSearch -ErrorAction SilentlyContinue
    Write-Log "Index reconstruit en arrière-plan" 'OK'
}

function Reset-PowerPlan {
    Write-Log "Restauration des modes d'alimentation par défaut"
    Invoke-Native 'powercfg.exe' '-restoredefaultschemes'
}

function Invoke-FullSequence {
    Write-Log "=== SÉQUENCE COMPLÈTE RECOMMANDÉE ==="
    New-RestorePoint
    Invoke-DISM
    Invoke-SFC
    Invoke-Native 'chkdsk.exe' "$env:SystemDrive /scan"
    Reset-Services
    Reset-Network
    Invoke-Cleanup
    Write-Log "=== SÉQUENCE TERMINÉE ===" 'OK'
    $Script:RebootNeeded = $true
}

# ---------------------------------------------------------------- Menu
function Show-Menu {
    Show-Header "MENU PRINCIPAL"
    Write-Host "   DIAGNOSTIC" -ForegroundColor Magenta
    Write-Host "    1) Informations système + santé des disques"
    Write-Host "    2) Créer un point de restauration"
    Write-Host ""
    Write-Host "   RÉPARATION SYSTÈME" -ForegroundColor Magenta
    Write-Host "    3) DISM  (réparation de l'image Windows)"
    Write-Host "    4) SFC   (vérification des fichiers système)"
    Write-Host "    5) CHKDSK (vérification / réparation du disque)"
    Write-Host "    6) Réparer / vérifier WMI"
    Write-Host ""
    Write-Host "   RÉINITIALISATIONS" -ForegroundColor Magenta
    Write-Host "    7) Services Windows (état par défaut)"
    Write-Host "    8) Réseau (DNS, Winsock, TCP/IP, pare-feu...)"
    Write-Host "    9) Windows Update"
    Write-Host "   10) Options graphiques (GPU, shaders, DPI, pilote)"
    Write-Host "   11) Caches icônes / miniatures / polices"
    Write-Host "   12) Microsoft Store"
    Write-Host "   13) Ré-enregistrer les applications Windows"
    Write-Host "   14) Windows Search (index)"
    Write-Host "   15) Modes d'alimentation"
    Write-Host ""
    Write-Host "   ENTRETIEN" -ForegroundColor Magenta
    Write-Host "   16) Nettoyage (temp, corbeille, composants)"
    Write-Host "   17) Analyse antivirus Defender (rapide)"
    Write-Host ""
    Write-Host "   99) SÉQUENCE COMPLÈTE recommandée (2,3,4,5,7,8,16)" -ForegroundColor Green
    Write-Host "    R) Redémarrer le PC     L) Ouvrir le dossier des logs     0) Quitter" -ForegroundColor Yellow
    Write-Host ""
    if ($Script:RebootNeeded) { Write-Host "   >> Un redémarrage est recommandé pour finaliser certaines actions <<" -ForegroundColor Yellow; Write-Host "" }
}

Write-Log "Session démarrée sur $env:COMPUTERNAME - journal : $Script:LogFile"

do {
    Show-Menu
    $choice = (Read-Host "  Votre choix").Trim().ToUpper()
    switch ($choice) {
        '1'  { Get-SystemSummary; Wait-Key }
        '2'  { Show-Header "Point de restauration"; New-RestorePoint; Wait-Key }
        '3'  { Show-Header "DISM"; Invoke-DISM; Wait-Key }
        '4'  { Show-Header "SFC"; Invoke-SFC; Wait-Key }
        '5'  { Show-Header "CHKDSK"; Invoke-Chkdsk; Wait-Key }
        '6'  { Show-Header "WMI"; Repair-WMI; Wait-Key }
        '7'  { Show-Header "Services"; Reset-Services; Wait-Key }
        '8'  { Show-Header "Réseau"; if (Confirm-Action "La connexion Internet sera coupée brièvement. Continuer ?") { Reset-Network }; Wait-Key }
        '9'  { Show-Header "Windows Update"; Reset-WindowsUpdate; Wait-Key }
        '10' { Show-Header "Options graphiques"; Reset-Graphics; Wait-Key }
        '11' { Show-Header "Caches shell"; Clear-ShellCaches; Wait-Key }
        '12' { Show-Header "Microsoft Store"; Reset-Store; Wait-Key }
        '13' { Show-Header "Applications"; if (Confirm-Action "Opération longue. Continuer ?") { Register-AllApps }; Wait-Key }
        '14' { Show-Header "Windows Search"; Reset-Search; Wait-Key }
        '15' { Show-Header "Alimentation"; Reset-PowerPlan; Wait-Key }
        '16' { Show-Header "Nettoyage"; Invoke-Cleanup; Wait-Key }
        '17' { Show-Header "Defender"; Invoke-DefenderScan; Wait-Key }
        '99' { Show-Header "Séquence complète"; if (Confirm-Action "Lancer toute la séquence (peut durer 30 min et plus) ?") { Invoke-FullSequence }; Wait-Key }
        'L'  { Start-Process explorer.exe $Script:LogDir }
        'R'  { if (Confirm-Action "Redémarrer maintenant ?") { Write-Log "Redémarrage demandé"; Restart-Computer -Force } }
        '0'  { }
        default { Write-Host "  Choix invalide." -ForegroundColor Red; Start-Sleep -Seconds 1 }
    }
} while ($choice -ne '0')

Write-Log "Session terminée"
if ($Script:RebootNeeded) { Write-Host "`n  Pensez à redémarrer le PC pour finaliser les réparations." -ForegroundColor Yellow }
Write-Host "  Journal : $Script:LogFile" -ForegroundColor Gray
