#Requires -Version 5.1
<#
.SYNOPSIS
    BJMPC Informatique - Optimisation Gaming / Réseau / Système pour PC moderne (Windows 11)
.DESCRIPTION
    Cible : SSD NVMe, 32 Go de RAM, GPU récent (RTX 40), écran OLED, Wi-Fi 6/6E/7.
    Principe : on aligne Windows sur le matériel moderne, sans désactiver la sécurité
    (Defender, pare-feu, Windows Update restent intacts).

    SÉCURITÉ : chaque valeur modifiée (registre, service, tâche planifiée, propriété de carte réseau,
    DNS, plan d'alimentation...) est enregistrée AVANT modification dans
    C:\BJMPC-Logs\Backup\EtatOrigine_<PC>.json. L'option R annule tout et revient à l'état d'origine.
#>

$ErrorActionPreference = 'Continue'
$Script:Version      = '1.3'
$Script:LogDir       = Join-Path $env:SystemDrive 'BJMPC-Logs'
$Script:BackupDir    = Join-Path $Script:LogDir 'Backup'
$Script:LogFile      = Join-Path $Script:LogDir ("Optimisation_{0}_{1}.log" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmmss'))
$Script:StateFile    = Join-Path $Script:BackupDir ("EtatOrigine_{0}.json" -f $env:COMPUTERNAME)
$Script:RebootNeeded = $false
$Script:AssumeDefaults = $false
$Script:Orig         = [ordered]@{}

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

New-Item -ItemType Directory -Path $Script:BackupDir -Force | Out-Null
$Host.UI.RawUI.WindowTitle = "BJMPC Informatique - Optimisation Windows v$Script:Version"

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
    param([string]$Question, [bool]$Default = $false)
    if ($Script:AssumeDefaults) { return $Default }
    $hint = if ($Default) { 'O/n' } else { 'o/N' }
    $r = Read-Host "  $Question ($hint)"
    if ([string]::IsNullOrWhiteSpace($r)) { return $Default }
    return ($r -match '^[oOyY]')
}

function Confirm-Strong {
    param([string]$Question)
    if ($Script:AssumeDefaults) { return $false }
    $r = Read-Host "  $Question Tapez OUI en majuscules pour confirmer"
    return ($r -ceq 'OUI')
}

function Wait-Key {
    Write-Host ""
    Read-Host "  Appuyez sur Entrée pour revenir au menu" | Out-Null
}

function Invoke-Native {
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
    Write-Host "   BJMPC INFORMATIQUE  -  Optimisation Windows  (v$Script:Version)" -ForegroundColor White
    Write-Host "   PC : $env:COMPUTERNAME   |   Utilisateur : $env:USERNAME" -ForegroundColor Gray
    Write-Host "  ============================================================" -ForegroundColor Cyan
    if ($Title) { Write-Host "   $Title" -ForegroundColor Yellow; Write-Host "" }
}

function Get-RegValue {
    param([string]$Path, [string]$Name)
    try { (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name } catch { $null }
}

function Test-IsLaptop {
    try {
        $ch = @((Get-CimInstance Win32_SystemEnclosure -ErrorAction Stop).ChassisTypes)
        return [bool]($ch | Where-Object { $_ -in 8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32 })
    } catch { return $false }
}

# ---------------------------------------------------------------- Sauvegarde de l'état d'origine
function Save-Orig {
    $arr = @($Script:Orig.Values | ForEach-Object { $_ })
    $json = ConvertTo-Json -InputObject $arr -Depth 5
    Set-Content -Path $Script:StateFile -Value $json -Encoding UTF8
}

function Import-Orig {
    $Script:Orig = [ordered]@{}
    if (Test-Path $Script:StateFile) {
        try {
            $raw = Get-Content $Script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($r in @($raw)) {
                if ($r -and $r.Key) {
                    $h = @{}
                    foreach ($p in $r.PSObject.Properties) { $h[$p.Name] = $p.Value }
                    $Script:Orig[[string]$r.Key] = $h
                }
            }
        } catch { Write-Log "Lecture de l'état d'origine impossible : $($_.Exception.Message)" 'WARN' }
    }
}

function Add-Orig {
    # N'enregistre que la PREMIÈRE valeur vue : on revient toujours à l'état réellement d'origine.
    param([string]$Key, [hashtable]$Rec)
    if (-not $Script:Orig.Contains($Key)) {
        $Rec.Key = $Key
        $Script:Orig[$Key] = $Rec
        Save-Orig
    }
}

# ---------------------------------------------------------------- Primitives de modification (toutes réversibles)
function Set-Reg {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    $key = "reg|$Path|$Name"
    if (-not $Script:Orig.Contains($key)) {
        $existed = $false; $old = $null; $kind = $null
        try {
            $old = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name
            $kind = (Get-Item -Path $Path -ErrorAction Stop).GetValueKind($Name).ToString()
            $existed = $true
        } catch {}
        Add-Orig $key @{ Type = 'reg'; Path = $Path; Name = $Name; Existed = $existed; Value = $old; Kind = $kind }
    }
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
        Write-Log "$Path\$Name = $Value" 'OK'
    } catch {
        Write-Log "Échec $Path\$Name : $($_.Exception.Message)" 'WARN'
    }
}

function Restore-Reg {
    param($r)
    if ($r.Existed) {
        if (-not (Test-Path $r.Path)) { New-Item -Path $r.Path -Force | Out-Null }
        $val = $r.Value
        switch ($r.Kind) {
            'Binary'      { $val = [byte[]]@($val) }
            'MultiString' { $val = [string[]]@($val) }
            'DWord'       { $val = [int]$val }
            'QWord'       { $val = [long]$val }
        }
        New-ItemProperty -Path $r.Path -Name $r.Name -Value $val -PropertyType $r.Kind -Force | Out-Null
    } else {
        Remove-ItemProperty -Path $r.Path -Name $r.Name -ErrorAction SilentlyContinue
    }
}

function Get-SvcMode {
    param([string]$Name)
    $k = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    if (-not (Test-Path $k)) { return $null }
    $s = Get-RegValue $k 'Start'
    $d = Get-RegValue $k 'DelayedAutostart'
    switch ($s) {
        0 { 'boot' }
        1 { 'system' }
        2 { if ($d -eq 1) { 'delayed-auto' } else { 'auto' } }
        3 { 'demand' }
        4 { 'disabled' }
        default { $null }
    }
}

function Set-SvcMode {
    param([string]$Name, [string]$Mode, [string]$Desc = '')
    $cur = Get-SvcMode $Name
    if (-not $cur) { Write-Log "Service absent, ignoré : $Name"; return }
    if ($cur -eq $Mode) { Write-Log "Déjà en mode '$Mode' : $Name"; return }
    Add-Orig "svc|$Name" @{ Type = 'svc'; Name = $Name; Mode = $cur }
    & sc.exe config $Name start= $Mode | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Log "Impossible de modifier le service $Name (code $LASTEXITCODE)" 'WARN'; return }
    if ($Mode -eq 'disabled') { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue }
    Write-Log ("Service {0,-18} {1} -> {2}  {3}" -f $Name, $cur, $Mode, $Desc) 'OK'
}

function Disable-TaskSafe {
    param([string]$TaskPath, [string]$TaskName)
    $t = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $t) { return }
    if ($t.State -eq 'Disabled') { return }
    Add-Orig "task|$TaskPath$TaskName" @{ Type = 'task'; TaskPath = $TaskPath; TaskName = $TaskName; WasEnabled = $true }
    try {
        Disable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop | Out-Null
        Write-Log "Tâche désactivée : $TaskPath$TaskName" 'OK'
    } catch { Write-Log "Tâche non modifiable : $TaskName ($($_.Exception.Message))" 'WARN' }
}

function Set-AdvProp {
    # Modifie une propriété avancée de carte réseau trouvée par son nom affiché (regex), valeur choisie par regex.
    param([string]$Adapter, [string]$NameRegex, [string]$ValueRegex)
    $props = @(Get-NetAdapterAdvancedProperty -Name $Adapter -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match $NameRegex })
    $changed = $false
    foreach ($p in $props) {
        $disp = @($p.ValidDisplayValues); $regv = @($p.ValidRegistryValues)
        if ($disp.Count -eq 0 -or $disp.Count -ne $regv.Count) { continue }
        $idx = -1
        for ($i = 0; $i -lt $disp.Count; $i++) { if ($disp[$i] -match $ValueRegex) { $idx = $i; break } }
        if ($idx -lt 0) { continue }
        $target  = [string]$regv[$idx]
        $current = [string]($p.RegistryValue -join ',')
        if ($current -eq $target) { Write-Log "Déjà réglé : $($p.DisplayName) = $($disp[$idx])"; continue }
        Add-Orig ("adv|{0}|{1}" -f $Adapter, $p.RegistryKeyword) @{ Type = 'adv'; Adapter = $Adapter; Keyword = $p.RegistryKeyword; Value = $current; Display = $p.DisplayName }
        try {
            Set-NetAdapterAdvancedProperty -Name $Adapter -RegistryKeyword $p.RegistryKeyword -RegistryValue $target -NoRestart -ErrorAction Stop
            Write-Log ("{0} : {1} = {2}" -f $Adapter, $p.DisplayName, $disp[$idx]) 'OK'
            $changed = $true
        } catch { Write-Log "$($p.DisplayName) : $($_.Exception.Message)" 'WARN' }
    }
    return $changed
}

function Set-FsutilBehavior {
    param([string]$Name, [int]$Value)
    $o = & fsutil.exe behavior query $Name 2>$null | Out-String
    $old = $null
    if ($o -match '=\s*(\d+)') { $old = [int]$Matches[1] }
    if ($null -ne $old -and $old -eq $Value) { Write-Log "Déjà réglé : fsutil $Name = $Value"; return }
    if ($null -ne $old) { Add-Orig "fsutil|$Name" @{ Type = 'fsutil'; Name = $Name; Value = $old } }
    & fsutil.exe behavior set $Name $Value | Out-Null
    Write-Log "fsutil $Name : $old -> $Value" 'OK'
}

# ---------------------------------------------------------------- Plan d'alimentation dédié (annulable en réactivant l'ancien)
$Script:GuidRegex = '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'

function Get-ActivePlanGuid {
    $o = & powercfg.exe /getactivescheme | Out-String
    if ($o -match $Script:GuidRegex) { return $Matches[1] }
    return $null
}

function Get-BjmpcPlan {
    $key = 'power|plan'
    if ($Script:Orig.Contains($key)) {
        $g = [string]$Script:Orig[$key].NewGuid
        if ($g -and ((& powercfg.exe /list | Out-String) -match [regex]::Escape($g))) { return $g }
    }
    $orig = Get-ActivePlanGuid
    $o = & powercfg.exe -duplicatescheme $orig | Out-String
    if ($o -notmatch $Script:GuidRegex) { Write-Log "Impossible de créer le plan d'alimentation" 'WARN'; return $null }
    $new = $Matches[1]
    & powercfg.exe -changename $new "BJMPC Gaming" "Plan optimisé par BJMPC Informatique" | Out-Null
    if ($Script:Orig.Contains($key)) { $Script:Orig[$key].NewGuid = $new; Save-Orig }
    else { Add-Orig $key @{ Type = 'power'; OriginalGuid = $orig; NewGuid = $new } }
    Write-Log "Plan 'BJMPC Gaming' créé ($new), copie du plan actif" 'OK'
    return $new
}

function Set-PlanAC {
    param([string]$Guid, [string]$Sub, [string]$Setting, $Value)
    & powercfg.exe /setacvalueindex $Guid $Sub $Setting $Value 2>$null | Out-Null
}

# ---------------------------------------------------------------- Diagnostic
function Show-HardwareProfile {
    Show-Header "Profil matériel détecté"
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $cs  = Get-CimInstance Win32_ComputerSystem
    $os  = Get-CimInstance Win32_OperatingSystem
    Write-Host ("  Windows       : {0} (build {1})" -f $os.Caption, $os.BuildNumber)
    if ([int]$os.BuildNumber -lt 22000) { Write-Host "  /!\ Ce script est conçu pour Windows 11." -ForegroundColor Yellow }
    Write-Host ("  Type          : {0}" -f $(if (Test-IsLaptop) { 'Portable' } else { 'Fixe' }))
    Write-Host ("  Processeur    : {0} ({1} coeurs / {2} threads)" -f $cpu.Name.Trim(), $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors)

    $ram = @(Get-CimInstance Win32_PhysicalMemory)
    $conf = ($ram | Select-Object -First 1).ConfiguredClockSpeed
    $rate = ($ram | Select-Object -First 1).Speed
    Write-Host ("  RAM           : {0} Go, {1} barrette(s), configurée {2} MT/s (module : {3} MT/s)" -f [math]::Round($cs.TotalPhysicalMemory/1GB,0), $ram.Count, $conf, $rate)
    if ($conf -and $rate -and ([int]$conf -lt [int]$rate)) {
        Write-Host "     -> La RAM tourne sous sa vitesse nominale : vérifiez XMP/EXPO dans le BIOS." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "  Carte(s) graphique(s) :" -ForegroundColor Yellow
    foreach ($g in @(Get-CimInstance Win32_VideoController)) {
        $drv = $g.DriverVersion
        if ($g.Name -match 'NVIDIA' -and $drv) {
            $digits = ($drv -replace '\.', '')
            if ($digits.Length -ge 5) { $drv = "{0}.{1} (affichage NVIDIA)" -f $digits.Substring($digits.Length - 5, 3), $digits.Substring($digits.Length - 2) }
        }
        Write-Host ("    {0} - pilote {1} - {2}x{3} @ {4} Hz" -f $g.Name, $drv, $g.CurrentHorizontalResolution, $g.CurrentVerticalResolution, $g.CurrentRefreshRate)
    }
    try {
        $mons = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction Stop)
        foreach ($m in $mons) {
            $n = (($m.UserFriendlyName | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ }) -join '')
            if ($n) { Write-Host "    Écran : $n" }
        }
    } catch {}

    Write-Host ""
    Write-Host "  Stockage :" -ForegroundColor Yellow
    foreach ($d in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
        $rc = $d | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
        $temp = if ($rc -and $rc.Temperature) { "$($rc.Temperature) °C" } else { 'n/d' }
        $wear = if ($rc -and $null -ne $rc.Wear) { "$($rc.Wear) % usure" } else { 'usure n/d' }
        Write-Host ("    {0} [{1}/{2}] {3} Go - {4} - {5} - {6}" -f $d.FriendlyName, $d.BusType, $d.MediaType, [math]::Round($d.Size/1GB,0), $d.HealthStatus, $temp, $wear)
    }

    Write-Host ""
    Write-Host "  Réseau (cartes physiques actives) :" -ForegroundColor Yellow
    foreach ($a in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })) {
        Write-Host ("    {0} - {1} - {2}" -f $a.Name, $a.InterfaceDescription, $a.LinkSpeed)
    }
    $wl = & netsh.exe wlan show interfaces 2>$null
    if ($wl) {
        $wl | Where-Object { $_ -match '^\s*(SSID|Type de radio|Radio type|Canal|Channel|Bande|Band|Vitesse de r.ception|Receive rate|Vitesse de transmission|Transmit rate|Signal)\s*:' -and $_ -notmatch 'BSSID' } |
            ForEach-Object { Write-Host "      $($_.Trim())" -ForegroundColor Gray }
        Write-Host "      (802.11ax = Wi-Fi 6/6E, 802.11be = Wi-Fi 7)" -ForegroundColor DarkGray
    }
    Write-Log "Profil matériel affiché"
}

function Show-State {
    Show-Header "État des optimisations"
    function Row { param([string]$Label, $Value, [bool]$Good)
        $c = if ($Good) { 'Green' } else { 'Yellow' }
        Write-Host ("  {0,-44} {1}" -f $Label, $Value) -ForegroundColor $c
    }
    $hags = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode'
    Row "Planification GPU matérielle (HAGS)" $(if ($hags -eq 2) { 'activée' } else { 'non activée' }) ($hags -eq 2)
    $gm = Get-RegValue 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled'
    Row "Mode Jeu" $(if ($gm -eq 0) { 'désactivé' } else { 'actif' }) ($gm -ne 0)
    $dvr = Get-RegValue 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled'
    Row "Capture en arrière-plan (Game DVR)" $(if ($dvr -eq 0) { 'désactivée' } else { 'active' }) ($dvr -eq 0)
    $plan = (& powercfg.exe /getactivescheme | Out-String).Trim()
    Row "Plan d'alimentation actif" ($plan -replace '^.*\(|\)\s*$', '') $true
    $svc = Get-Service -Name 'DiagTrack' -ErrorAction SilentlyContinue
    if ($svc) { Row "Télémétrie (service DiagTrack)" ("{0} / {1}" -f $svc.StartType, $svc.Status) ($svc.StartType -eq 'Disabled') }
    $o = & fsutil.exe behavior query DisableDeleteNotify 2>$null | Out-String
    $trim = if ($o -match 'NTFS DisableDeleteNotify\s*=\s*(\d)') { $Matches[1] } else { '?' }
    Row "TRIM (NTFS)" $(if ($trim -eq '0') { 'actif' } else { "inactif ou inconnu ($trim)" }) ($trim -eq '0')
    $fast = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled'
    Row "Démarrage rapide" $(if ($fast -eq 0) { 'désactivé' } else { 'actif (défaut Windows)' }) $true
    # Anciens réglages (versions 1.x) : sans effet mesurable sur Windows 11, signalés pour pouvoir les défaire.
    $old = @()
    if ((Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'NetworkThrottlingIndex') -eq -1) { $old += 'MMCSS' }
    $sm = Get-Service -Name 'SysMain' -ErrorAction SilentlyContinue
    if ($sm -and $sm.StartType -eq 'Disabled') { $old += 'SysMain désactivé' }
    foreach ($a in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })) {
        if ((Get-RegValue "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($a.InterfaceGuid)" 'TCPNoDelay') -eq 1) { $old += "Nagle ($($a.Name))" }
    }
    if ($old.Count -gt 0) {
        Row "Anciens réglages encore présents" ($old -join ', ') $false
        Write-Host "     -> Sauvegarde et restauration > Restauration > « Comparer avec Windows 11 » les remet par défaut." -ForegroundColor DarkGray
    }
    try {
        $dg = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard -ErrorAction Stop
        $vbs = switch ([int]$dg.VirtualizationBasedSecurityStatus) { 0 { 'désactivé' } 1 { 'activé, non démarré' } 2 { 'en cours d''exécution' } default { 'inconnu' } }
        Row "Sécurité basée sur la virtualisation (VBS)" $vbs $true
    } catch {}
    Write-Host ""
    Write-Host ("  Modifications enregistrées pour annulation : {0}" -f $Script:Orig.Count) -ForegroundColor Cyan
    Write-Host "  (Vert = en place ou sain, jaune = à regarder)" -ForegroundColor DarkGray
}

function New-RestorePoint {
    # $Script:RestorePointOk = $true seulement si un point de moins de 10 minutes existe vraiment après l'appel : Windows peut refuser sans
    # erreur (un point par 24 h par défaut, protection du système coupée). La limite de fréquence est remise ensuite.
    Write-Log "Création d'un point de restauration..."
    $k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $Script:RestorePointOk = $false
    $old = Get-RegValue $k 'SystemRestorePointCreationFrequency'
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Set-ItemProperty $k -Name SystemRestorePointCreationFrequency -Value 0 -Type DWord -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description "BJMPC Optimisation $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop -WarningAction SilentlyContinue
        $last = Get-ComputerRestorePoint -ErrorAction Stop | Sort-Object CreationTime -Descending | Select-Object -First 1
        if ($last -and ((Get-Date) - [Management.ManagementDateTimeConverter]::ToDateTime($last.CreationTime)).TotalMinutes -le 10) { Write-Log "Point de restauration créé" 'OK'; $Script:RestorePointOk = $true; return }
        Write-Log "Windows n'a pas créé de point de restauration (aucun point récent trouvé)." 'WARN'
    } catch {
        Write-Log "Point de restauration impossible : $($_.Exception.Message)" 'WARN'
    } finally {
        if ($null -eq $old) { Remove-ItemProperty $k -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue }
        else { Set-ItemProperty $k -Name SystemRestorePointCreationFrequency -Value $old -Type DWord -ErrorAction SilentlyContinue }
    }
}

# ---------------------------------------------------------------- Gaming / GPU / affichage
function Set-GlobalDxSettings {
    param([hashtable]$Settings)
    $path = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'; $name = 'DirectXUserGlobalSettings'
    $cur = Get-RegValue $path $name
    $map = [ordered]@{}
    if ($cur) {
        foreach ($t in ($cur -split ';')) {
            if ($t -match '^\s*([^=]+)=(.*)$') { $map[$Matches[1].Trim()] = $Matches[2].Trim() }
        }
    }
    foreach ($k in $Settings.Keys) { $map[$k] = $Settings[$k] }
    $new = (($map.Keys | ForEach-Object { "$_=$($map[$_])" }) -join ';') + ';'
    Set-Reg $path $name $new 'String'
}

function Set-Hags {
    # Planification GPU à accélération matérielle (HAGS) : HwSchMode 2 = activée, 1 = désactivée.
    # C'est le même réglage que Paramètres > Système > Affichage > Graphiques > Paramètres graphiques par défaut.
    # Sans effet si le pilote graphique ne la propose pas (il faut un pilote WDDM 2.7 ou plus récent).
    param([ValidateSet('on', 'off')][string]$Mode = 'on')
    $k = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
    $cur = Get-RegValue $k 'HwSchMode'
    $state = if ($cur -eq 2) { 'activée' } elseif ($cur -eq 1) { 'désactivée' } else { 'non définie (désactivée par défaut)' }
    Write-Log "Planification GPU matérielle (HAGS) actuellement : $state"
    $want = if ($Mode -eq 'on') { 2 } else { 1 }
    if ($cur -eq $want) { Write-Log 'Déjà dans l''état demandé : rien à changer.' 'OK'; return }
    if ($Mode -eq 'on') {
        $gpu = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'NVIDIA|AMD|Radeon|Arc|Intel' -and $_.Name -notmatch 'Basic|Remote|Virtual' })
        if ($gpu.Count -eq 0) { Write-Log 'Aucune carte graphique NVIDIA, AMD ou Intel détectée : HAGS non activée.' 'WARN'; return }
    }
    Set-Reg $k 'HwSchMode' $want
    $Script:RebootNeeded = $true
    if ($Mode -eq 'on') { Write-Log 'HAGS activée. Elle prend effet au prochain redémarrage (si le pilote graphique la propose).' 'OK' }
    else { Write-Log 'HAGS désactivée. Effet au prochain redémarrage. La génération d''images DLSS 3 ne fonctionnera plus dans les jeux qui l''exigent.' 'OK' }
}

function Optimize-Gaming {
    Write-Log "=== Profil Gaming Windows ==="

    $gpu = @(Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match 'NVIDIA|AMD|Radeon|Arc' })
    if ($gpu.Count -gt 0) {
        if (Confirm-Action "Activer la planification GPU matérielle (HAGS) ? Requise pour la génération d'images DLSS 3 ; redémarrage nécessaire" $true) {
            Set-Hags -Mode on
        } else { Write-Log "HAGS laissée telle quelle (réglage dédié : Optimiser > Jeux et alimentation)" }
    } else { Write-Log "Aucun GPU dédié détecté : HAGS ignorée" 'WARN' }

    # Mode Jeu, désactivation de la capture en arrière-plan
    Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 1
    Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1
    Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'UseNexusForGameBarEnabled' 0
    Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0

    # Optimisations des jeux fenêtrés (flip model) + fréquence variable (VRR) de Windows
    Set-GlobalDxSettings @{ SwapEffectUpgradeEnable = '1'; VRROptimizeEnable = '1' }
    # Retiré en 2.0 : priorités MMCSS (NetworkThrottlingIndex, SystemResponsiveness, tâche "Games").
    # Aucun gain mesurable sur Windows 11, et des craquements audio possibles.

    if (Confirm-Action "Désactiver l'accélération de la souris (précision du pointeur) ? Prend effet à la prochaine ouverture de session") {
        Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '0' 'String'
        Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '0' 'String'
        Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '0' 'String'
    }
    if (Confirm-Action "Désactiver MPO (Multiplane Overlay) ? À réserver aux scintillements ou bugs d'affichage OLED/VRR") {
        Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' 'OverlayTestMode' 5
        $Script:RebootNeeded = $true
    }
    Write-Log "Profil Gaming appliqué" 'OK'
    Write-Host ""
    Write-Host "  Rappel : latence faible, gestion d'alimentation et G-SYNC se règlent aussi dans le" -ForegroundColor DarkGray
    Write-Host "  Panneau de configuration NVIDIA (non scriptable proprement)." -ForegroundColor DarkGray
}

function Optimize-Power {
    Write-Log "=== Plan d'alimentation Performance (BJMPC Gaming) ==="
    Write-Log "Pour un PC fixe de jeu. Sur un portable ou un PC de bureautique, le plan Équilibré de Windows reste le meilleur choix."
    $g = Get-BjmpcPlan
    if (-not $g) { return }
    $laptop = Test-IsLaptop
    if ($laptop) { Write-Log "Portable détecté : seuls les réglages sur secteur (AC) sont modifiés" 'WARN' }

    Set-PlanAC $g 'SUB_PROCESSOR' 'PROCTHROTTLEMAX' 100
    Set-PlanAC $g 'SUB_PROCESSOR' 'PERFBOOSTMODE' 2
    Set-PlanAC $g 'SUB_PROCESSOR' 'PERFEPP' 0
    Set-PlanAC $g 'SUB_PROCESSOR' 'SYSCOOLPOL' 1
    Set-PlanAC $g 'SUB_PCIEXPRESS' 'ASPM' 0
    Set-PlanAC $g '2a737441-1930-4402-8d77-b2bebba308a3' '48e6b7a6-50f5-4782-a5d4-53bb8f07e226' 0
    Set-PlanAC $g 'SUB_DISK' 'DISKIDLE' 0
    Set-PlanAC $g '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1' '12bbebe6-58d6-4636-95bb-3217ef867c1a' 0
    & powercfg.exe /setactive $g | Out-Null
    Write-Log "Plan actif : CPU boost agressif, PCIe/NVMe sans économie d'énergie, USB sans suspension, Wi-Fi performances max" 'OK'
}

# Retiré en 2.0 : "Réglages avancés" (Win32PrioritySeparation, PowerThrottlingOff, compression mémoire, HVCI).
# Les trois premiers n'apportent rien de mesurable sur Windows 11 ; désactiver HVCI retire une protection.
# Le Journal sait toujours annuler ces réglages s'ils ont été posés par une version 1.x.

# ---------------------------------------------------------------- Réseau
function Optimize-Network {
    # Ce qui reste utile en 2026 : empêcher Windows d'éteindre la carte, et quelques réglages de pilote Wi-Fi / Ethernet.
    # Retiré en 2.0 : Nagle (TcpAckFrequency / TCPNoDelay), RSC, Flow Control, Throughput Booster, options netsh
    # et réservation QoS, sans effet sur les jeux et la navigation d'aujourd'hui.
    Write-Log "=== Cartes réseau (Wi-Fi 6/7, Ethernet) ==="
    $adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
    if ($adapters.Count -eq 0) { Write-Log "Aucune carte physique active détectée" 'WARN'; return }

    $On  = '^(Enabled|Activ.*|On)$'
    $Off = '^(Disabled|D.sactiv.*|Off)$'
    $single = Confirm-Action "Le Wi-Fi passe par UN SEUL routeur/point d'accès (pas de réseau maillé) ? Réduit les recherches de roaming" $false
    if (-not (Confirm-Action "Les cartes réseau vont redémarrer, la connexion sera coupée quelques secondes. Continuer ?" $true)) { return }

    foreach ($a in $adapters) {
        $n = $a.Name
        Write-Log "--- Carte : $n ($($a.InterfaceDescription))"
        $isWifi = ($a.PhysicalMediaType -match '802\.11') -or ($a.InterfaceDescription -match 'Wi-?Fi|Wireless|802\.11|Wireless-?(AX|BE)')
        $changed = $false

        # Économie d'énergie de la carte
        try {
            $pm = Get-NetAdapterPowerManagement -Name $n -ErrorAction Stop
            if ($pm.AllowComputerToTurnOffDevice -eq 'Enabled') {
                Add-Orig "nicpm|$n" @{ Type = 'nicpm'; Adapter = $n; Value = 'Enabled' }
                Set-NetAdapterPowerManagement -Name $n -AllowComputerToTurnOffDevice Disabled -ErrorAction Stop
                Write-Log "Extinction de la carte pour économie d'énergie : désactivée" 'OK'
            }
        } catch { Write-Log "Gestion d'alimentation de la carte : $($_.Exception.Message)" 'WARN' }

        if ($isWifi) {
            if (Set-AdvProp $n 'U-?APSD' $Off) { $changed = $true }
            if (Set-AdvProp $n 'MIMO Power Save' '^(No SMPS|Pas de SMPS|Disabled|D.sactiv.*)') { $changed = $true }
            if (Set-AdvProp $n '802\.11be|11be|EHT' $On) { $changed = $true }
            if (Set-AdvProp $n '802\.11ax|11ax|HE Mode|Wireless Mode' $On) { $changed = $true }
            if (Set-AdvProp $n 'Multi-?Link|MLO' $On) { $changed = $true }
            if ($single) {
                if (Set-AdvProp $n 'Roaming Aggressiveness' '^(1\.\s*)?(Lowest|Minimum|Plus bas)') { $changed = $true }
            }
        } else {
            if (Set-AdvProp $n 'Energy.?Efficient Ethernet|^EEE|Green Ethernet|Advanced EEE' $Off) { $changed = $true }
        }

        if ($changed) {
            Write-Log "Redémarrage de la carte $n..."
            try {
                Restart-NetAdapter -Name $n -ErrorAction Stop
                $t = 0
                while ((Get-NetAdapter -Name $n -ErrorAction SilentlyContinue).Status -ne 'Up' -and $t -lt 30) { Start-Sleep -Seconds 1; $t++ }
            } catch { Write-Log "Redémarrage de $n : $($_.Exception.Message)" 'WARN' }
        }
    }

    Write-Log "Cartes réseau réglées. La pile TCP de Windows 11 est laissée à ses valeurs par défaut." 'OK'
}

# ---------------------------------------------------------------- Stockage NVMe / système
function Optimize-Storage {
    Write-Log "=== Stockage et démarrage ==="
    # TRIM : actif par défaut, on le rétablit seulement s'il a été coupé.
    $o = & fsutil.exe behavior query DisableDeleteNotify 2>$null | Out-String
    if ($o -match 'NTFS DisableDeleteNotify\s*=\s*(\d)' -and $Matches[1] -ne '0') {
        Set-FsutilBehavior 'DisableDeleteNotify' 0
    } else { Write-Log "TRIM déjà actif" 'OK' }
    # Retiré en 2.0 : "disablelastaccess" (Windows le gère seul depuis Windows 10 1803) et la désactivation de
    # SysMain (Windows adapte déjà SysMain aux SSD ; le couper ralentit le lancement des applications).

    if (Confirm-Action "Lancer un ReTrim immédiat des volumes SSD ?" $true) {
        # Seulement les volumes posés sur un SSD : un ReTrim sur un disque dur échoue (« non pris en charge »).
        $ssd = @{}
        foreach ($pd in @(Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { [string]$_.MediaType -eq 'SSD' })) { $ssd[[string]$pd.DeviceId] = $true }
        foreach ($v in @(Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.FileSystem -in 'NTFS', 'ReFS' })) {
            $dn = ''; try { $dn = [string](Get-Partition -DriveLetter $v.DriveLetter -ErrorAction Stop).DiskNumber } catch {}
            if (-not $ssd.ContainsKey($dn)) { Write-Log "ReTrim $($v.DriveLetter): ignoré (pas un SSD)"; continue }
            try { Optimize-Volume -DriveLetter $v.DriveLetter -ReTrim -ErrorAction Stop; Write-Log "ReTrim $($v.DriveLetter): OK" 'OK' } catch { Write-Log "ReTrim $($v.DriveLetter): $($_.Exception.Message)" 'WARN' }
        }
    }

    # Démarrage rapide / hibernation
    Write-Host ""
    Write-Host "  Démarrage rapide / hibernation :" -ForegroundColor Yellow
    Write-Host "   1) Désactiver le démarrage rapide seulement (arrêt complet, pilotes rechargés)"
    Write-Host "   2) Désactiver aussi l'hibernation (libère plusieurs Go : hiberfil.sys)"
    Write-Host "   3) Ne rien changer"
    $c = if ($Script:AssumeDefaults) { '3' } else { Read-Host "  Choix" }
    if ($c -eq '1' -or $c -eq '2') {
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 0
    }
    if ($c -eq '2') {
        $he = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled'
        Add-Orig 'hib|state' @{ Type = 'hib'; Enabled = [bool]($he -eq 1) }
        & powercfg.exe /h off | Out-Null
        Write-Log "Hibernation désactivée" 'OK'
    }
    Write-Log "Disque et démarrage : terminé" 'OK'
}

# ---------------------------------------------------------------- Stockage : inventaire, entretien, alimentation, NVMe natif
# Tout est réversible : chaque réglage d'alimentation garde sa valeur d'origine (type 'pwr'), les valeurs de registre
# passent par Set-Reg. Rien n'est appliqué sans un clic sur un bouton.
$Script:NvmeOverrideKey = 'HKLM:\SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides'
$Script:NvmeOverrideIds = @('1176759950', '1853569164', '156965516', '735209102')
$Script:StoragePower = @{
    usb  = @(
        @('2a737441-1930-4402-8d77-b2bebba308a3', '48e6b7a6-50f5-4782-a5d4-53bb8f07e226', 0, 'USB : suspension sélective'),
        @('2a737441-1930-4402-8d77-b2bebba308a3', 'd4e98f31-5ffe-4ce1-be31-1b38b384c009', 0, 'USB 3 : économie d''énergie de la liaison'))
    pcie = @(, @('501a4d13-42af-4429-9fd1-a8218c268e20', 'ee12f906-d277-404b-b6da-e5fa1a576df5', 0, 'PCI Express : économie d''énergie de la liaison (ASPM)'))
    sata = @(, @('0012ee47-9041-4b5d-9b77-535fba8b1442', '0b2d69d7-a2a1-449c-9680-f91c70521c60', 0, 'SATA (AHCI) : économie d''énergie de la liaison'))
    hdd  = @(, @('0012ee47-9041-4b5d-9b77-535fba8b1442', '6738e2c4-e8a5-4a42-b16a-e040e769756e', 0, 'Arrêt des disques durs après inactivité'))
}

function Get-PowerIndex {
    # Valeurs actuelles (secteur, batterie) d'un réglage du mode d'alimentation : les deux dernières valeurs 0x de powercfg.
    param([string]$Scheme, [string]$Sub, [string]$Setting)
    $o = & powercfg.exe /query $Scheme $Sub $Setting 2>$null | Out-String
    $m = [regex]::Matches($o, '0x([0-9a-fA-F]{8})')
    if ($m.Count -lt 2) { return $null }
    return @([Convert]::ToInt32($m[$m.Count - 2].Groups[1].Value, 16), [Convert]::ToInt32($m[$m.Count - 1].Groups[1].Value, 16))
}

function Set-PowerOnAc {
    # Change un réglage sur secteur seulement, dans le mode d'alimentation actif ; la batterie n'est jamais touchée.
    param([string]$Sub, [string]$Setting, [int]$Value, [string]$Label)
    $g = Get-ActivePlanGuid
    if (-not $g) { Write-Log "Mode d'alimentation actif introuvable : $Label" 'WARN'; return }
    $cur = Get-PowerIndex $g $Sub $Setting
    if ($null -eq $cur) { Write-Log "Réglage absent sur ce PC, ignoré : $Label"; return }
    if ($cur[0] -eq $Value) { Write-Log "Déjà réglé : $Label"; return }
    Add-Orig "pwr|$g|$Setting" @{ Type = 'pwr'; Scheme = $g; Sub = $Sub; Setting = $Setting; Ac = $cur[0]; Label = $Label }
    & powercfg.exe /setacvalueindex $g $Sub $Setting $Value 2>$null | Out-Null
    & powercfg.exe /setactive $g 2>$null | Out-Null
    Write-Log ("{0} (sur secteur) : {1} -> {2}" -f $Label, $cur[0], $Value) 'OK'
}

function Set-StoragePower {
    param([ValidateSet('usb', 'pcie', 'sata', 'hdd')][string]$Kind)
    if ($Kind -eq 'hdd') {
        $hdd = @(Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { [string]$_.MediaType -eq 'HDD' })
        if ($hdd.Count -eq 0) { Write-Log 'Aucun disque dur à plateaux détecté : rien à changer.' 'OK'; return }
    }
    if ($Kind -eq 'sata') {
        $sata = @(Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { [string]$_.BusType -eq 'SATA' })
        if ($sata.Count -eq 0) { Write-Log 'Aucun disque SATA détecté : rien à changer.' 'OK'; return }
    }
    foreach ($s in $Script:StoragePower[$Kind]) { Set-PowerOnAc $s[0] $s[1] $s[2] $s[3] }
}

function Get-StorageReport {
    # Lecture seule : disques, volumes, pilote NVMe, TRIM, optimisation planifiée, anomalies détectées.
    $r = [ordered]@{ Disks = @(); Volumes = @(); Notes = @(); Trim = $null; TrimRefs = $null; Task = $null }
    $phys = @(Get-PhysicalDisk -ErrorAction SilentlyContinue | Sort-Object DeviceId)
    foreach ($d in $phys) {
        $rc = $null; try { $rc = $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch {}
        $bus = [string]$d.BusType; $media = [string]$d.MediaType
        $kind = switch ($true) {
            ($bus -eq 'NVMe') { 'NVMe'; break }
            ($bus -eq 'USB') { 'USB'; break }
            ($media -eq 'SSD') { 'SSD'; break }
            ($media -eq 'HDD') { 'Disque dur'; break }
            default { 'Inconnu' }
        }
        $r.Disks += [pscustomobject]@{
            Name = ([string]$d.FriendlyName).Trim(); Kind = $kind; Bus = $bus; Media = $media
            SizeGB = [math]::Round([double]$d.Size / 1GB); Health = [string]$d.HealthStatus
            Temp = $(if ($rc -and $rc.Temperature) { [int]$rc.Temperature } else { $null })
            Wear = $(if ($rc -and $null -ne $rc.Wear) { [int]$rc.Wear } else { $null })
            Firmware = [string]$d.FirmwareVersion
        }
        if ($bus -eq 'NVMe' -and $media -ne 'SSD') { $r.Notes += "« $($d.FriendlyName) » : Windows ne le reconnaît pas comme SSD (type « $media »). L'optimisation automatique risque de le défragmenter au lieu du TRIM : faire réévaluer le disque (commande « winsat formal »)." }
        if ([string]$d.HealthStatus -ne 'Healthy') { $r.Notes += "« $($d.FriendlyName) » : santé « $($d.HealthStatus) ». Sauvegardez vos fichiers et contrôlez le disque (Réparer > Diagnostics)." }
        if ($rc -and $rc.Temperature -ge 70) { $r.Notes += "« $($d.FriendlyName) » : $($rc.Temperature) °C, température élevée (au-delà de 70 °C, les SSD ralentissent pour se protéger)." }
        if ($rc -and $rc.Wear -ge 80) { $r.Notes += "« $($d.FriendlyName) » : usure à $($rc.Wear) %. Prévoir son remplacement." }
    }
    foreach ($v in @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter } | Sort-Object DriveLetter)) {
        $r.Volumes += [pscustomobject]@{ Letter = [string]$v.DriveLetter; Label = [string]$v.FileSystemLabel; Fs = [string]$v.FileSystem; Type = [string]$v.DriveType
            SizeGB = [math]::Round([double]$v.Size / 1GB); FreePct = $(if ($v.Size) { [int](100 * $v.SizeRemaining / $v.Size) } else { $null }) }
    }
    $o = & fsutil.exe behavior query DisableDeleteNotify 2>$null | Out-String
    if ($o -match 'NTFS DisableDeleteNotify\s*=\s*(\d)') { $r.Trim = ($Matches[1] -eq '0') }
    if ($o -match 'ReFS DisableDeleteNotify\s*=\s*(\d)') { $r.TrimRefs = ($Matches[1] -eq '0') }
    if ($r.Trim -eq $false) { $r.Notes += 'Le TRIM est coupé : les SSD ralentissent avec le temps. Bouton « Entretien » pour le rétablir.' }
    try { $t = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' -ErrorAction Stop; $r.Task = ([string]$t.State -ne 'Disabled') } catch {}
    if ($r.Task -eq $false) { $r.Notes += 'L''optimisation planifiée des lecteurs est désactivée. Bouton « Entretien » pour la rétablir.' }
    $r.Nvme = Get-NvmeState
    Set-OptResult ([pscustomobject]$r)
    foreach ($d in $r.Disks) { Write-Log ("{0} · {1} · {2} Go · santé {3}{4}{5}" -f $d.Name, $d.Kind, $d.SizeGB, $d.Health, $(if ($null -ne $d.Temp) { " · $($d.Temp) °C" } else { '' }), $(if ($null -ne $d.Wear) { " · usure $($d.Wear) %" } else { '' })) 'OK' }
    foreach ($n in $r.Notes) { Write-Log $n 'WARN' }
    if ($r.Notes.Count -eq 0) { Write-Log 'Aucune anomalie de stockage détectée.' 'OK' }
}

function Invoke-StorageMaintenance {
    # Entretien sûr : TRIM rétabli s'il a été coupé (NTFS et ReFS), optimisation planifiée réactivée, puis optimisation
    # de chaque volume interne avec la méthode que Windows choisit lui-même (TRIM pour un SSD, défragmentation pour un disque dur).
    param([switch]$OptimizeNow)
    Write-Log '=== Stockage : entretien ==='
    $o = & fsutil.exe behavior query DisableDeleteNotify 2>$null | Out-String
    if ($o -match 'NTFS DisableDeleteNotify\s*=\s*(\d)' -and $Matches[1] -ne '0') { Set-FsutilBehavior 'DisableDeleteNotify' 0 } else { Write-Log 'TRIM (NTFS) déjà actif' 'OK' }
    if ($o -match 'ReFS DisableDeleteNotify\s*=\s*(\d)' -and $Matches[1] -ne '0') {
        Add-Orig 'fsutil|DisableDeleteNotifyReFS' @{ Type = 'fsutilrefs'; Value = [int]$Matches[1] }
        & fsutil.exe behavior set DisableDeleteNotify ReFS 0 | Out-Null
        Write-Log 'TRIM (ReFS) rétabli' 'OK'
    }
    try {
        $t = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' -ErrorAction Stop
        if ([string]$t.State -eq 'Disabled') {
            Add-Orig 'taskon|\Microsoft\Windows\Defrag\ScheduledDefrag' @{ Type = 'taskon'; TaskPath = '\Microsoft\Windows\Defrag\'; TaskName = 'ScheduledDefrag' }
            Enable-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' -ErrorAction Stop | Out-Null
            Write-Log 'Optimisation planifiée des lecteurs réactivée' 'OK'
        } else { Write-Log 'Optimisation planifiée des lecteurs déjà active' 'OK' }
    } catch { Write-Log "Optimisation planifiée : $($_.Exception.Message)" 'WARN' }
    if (-not $OptimizeNow) { return }
    $media = @{}
    foreach ($pd in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)) { $media[[string]$pd.DeviceId] = [string]$pd.MediaType }
    foreach ($v in @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.FileSystem -in 'NTFS', 'ReFS' })) {
        $kind = ''
        try { $dn = [string](Get-Partition -DriveLetter $v.DriveLetter -ErrorAction Stop).DiskNumber; $kind = $media[$dn] } catch {}
        try {
            if ($kind -eq 'SSD') { Optimize-Volume -DriveLetter $v.DriveLetter -ReTrim -ErrorAction Stop; Write-Log "$($v.DriveLetter): SSD, TRIM effectué" 'OK' }
            elseif ($kind -eq 'HDD') {
                $a = Optimize-Volume -DriveLetter $v.DriveLetter -Analyze -Verbose 4>&1 | Out-String
                if ($a -match '(\d+)\s*%') { Write-Log "$($v.DriveLetter): disque dur, fragmentation $($Matches[1]) %" }
                Optimize-Volume -DriveLetter $v.DriveLetter -Defrag -ErrorAction Stop; Write-Log "$($v.DriveLetter): disque dur, défragmenté" 'OK'
            } else { Optimize-Volume -DriveLetter $v.DriveLetter -ErrorAction Stop; Write-Log "$($v.DriveLetter): optimisé (méthode choisie par Windows)" 'OK' }
        } catch { Write-Log "$($v.DriveLetter): $($_.Exception.Message)" 'WARN' }
    }
}

function Restore-StorageSettings {
    # Annule les réglages de la page Stockage (alimentation sur secteur, TRIM ReFS, optimisation planifiée).
    $n = 0
    foreach ($k in @($Script:Orig.Keys | Where-Object { $_ -like 'pwr|*' -or $_ -eq 'fsutil|DisableDeleteNotifyReFS' -or $_ -like 'taskon|*' })) {
        Restore-Record $Script:Orig[$k]; $Script:Orig.Remove($k); $n++
    }
    Save-Orig
    if ($n) { Write-Log "$n réglage(s) de stockage remis à l'origine." 'OK' } else { Write-Log 'Aucun réglage de stockage à annuler.' 'OK' }
}

# Deux méthodes, posées ensemble :
#  1) les 4 valeurs de stratégie d'origine (Windows Server 2025 et premières versions de Windows 11 24H2/25H2) ;
#  2) le magasin de fonctionnalités de démarrage (comme ViVeTool /enable : priorité « User », identifiants 60786016 et
#     48433719), qui fonctionne encore après le blocage de mars 2026. Windows garde une configuration « dernière bonne
#     connue » : si le démarrage échoue après la bascule, il revient de lui-même à l'état précédent.
$Script:NvmeFeatureIds = @(60786016, 48433719)
$Script:NvmeFeatureRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides\8'

function Initialize-FeatureStoreApi {
    if ('BJ.FeatureStore' -as [type]) { return $true }
    try {
        Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace BJ {
    public static class FeatureStore {
        [DllImport("ntdll.dll")] static extern int RtlGetSystemBootStatus(int item, out int data, int len, IntPtr retLen);
        [DllImport("ntdll.dll")] static extern int RtlSetSystemBootStatus(int item, ref int data, int len, IntPtr retLen);
        [DllImport("ntdll.dll", CharSet = CharSet.Unicode)] static extern int RtlCreateBootStatusDataFile(string path);
        const int BsdFeatureConfigurationState = 17;
        static uint SwapBytes(uint x) { x = (x >> 16) | (x << 16); return ((x & 0xFF00FF00) >> 8) | ((x & 0x00FF00FF) << 8); }
        static uint RotL1(uint v) { return (v << 1) | (v >> 31); }
        static uint RotR1(uint v) { return (v >> 1) | (v << 31); }
        // Même transformation que Windows (fcon.dll) et ViVeTool pour nommer les clés du magasin.
        public static uint Obfuscate(uint id) { return RotL1(SwapBytes(id ^ 0x74161A4E) ^ 0x8FB23D4F) ^ 0x833EA8FF; }
        public static uint Deobfuscate(uint id) { return SwapBytes(RotR1(id ^ 0x833EA8FF) ^ 0x8FB23D4F) ^ 0x74161A4E; }
        // 1 = BootPending : la prochaine configuration de démarrage est à valider (retour « dernière bonne connue » si échec).
        public static int MarkBootPending() {
            int cur; int r = RtlGetSystemBootStatus(BsdFeatureConfigurationState, out cur, 4, IntPtr.Zero);
            if (r != 0 && (uint)r == 0xC0000034) { r = RtlCreateBootStatusDataFile(null); if (r != 0) return r; cur = 0; }
            if (cur == 1) return 0;
            int v = 1; return RtlSetSystemBootStatus(BsdFeatureConfigurationState, ref v, 4, IntPtr.Zero);
        }
    }
}
'@
        return $true
    } catch { Write-Log "Accès au magasin de fonctionnalités impossible : $($_.Exception.Message)" 'WARN'; return $false }
}

function Get-NvmeFeatureKeys {
    # Chemins des clés du magasin de démarrage pour les identifiants du pilote NVMe natif.
    if (-not (Initialize-FeatureStoreApi)) { return @() }
    return @($Script:NvmeFeatureIds | ForEach-Object { Join-Path $Script:NvmeFeatureRoot ([string][BJ.FeatureStore]::Obfuscate([uint32]$_)) })
}

function Get-NvmeState {
    # Lecture seule. Éligible seulement si : Windows 11 24H2 ou plus récent, pilote nvmedisk.sys présent, au moins un SSD
    # NVMe, et TOUS les contrôleurs NVMe sur le pilote Microsoft standard (stornvme). Un pilote de fabricant (Samsung, Intel
    # RST/VMD, RAID…) exclut la bascule : c'est le cas où un PC peut ne plus démarrer.
    $s = [ordered]@{ Build = 0; Ubr = 0; HasDriver = $false; Controllers = @(); NativeRunning = $false; NativeDisks = 0; ScsiNvmeDisks = 0
        Overrides = @(); FeatureSet = $false; Eligible = $false; Reason = ''; BitLocker = $false }
    try { $s.Build = [int](Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).BuildNumber } catch {}
    $s.Ubr = [int](Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'UBR')
    $s.HasDriver = Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\drivers\nvmedisk.sys')
    $pnp = @()
    try { $pnp = @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop) } catch {}
    $s.Controllers = @($pnp | Where-Object { @($_.CompatibleID) -match 'CC_010802' } | ForEach-Object { [pscustomobject]@{ Name = [string]$_.Name; Service = [string]$_.Service } })
    # Disques : pile native (service nvmedisk) ou pile SCSI (service disk) posée sur un SSD NVMe.
    $s.NativeDisks = @($pnp | Where-Object { [string]$_.Service -eq 'nvmedisk' }).Count
    $s.ScsiNvmeDisks = @($pnp | Where-Object { [string]$_.Service -eq 'disk' -and [string]$_.PNPDeviceID -match '^SCSI\\DISK&VEN_NVME|NVME' }).Count
    try { $nd = Get-CimInstance Win32_SystemDriver -Filter "Name='nvmedisk'" -ErrorAction Stop; $s.NativeRunning = ([string]$nd.State -eq 'Running') } catch {}
    foreach ($id in $Script:NvmeOverrideIds) { if ($null -ne (Get-RegValue $Script:NvmeOverrideKey $id)) { $s.Overrides += $id } }
    $fk = @(Get-NvmeFeatureKeys)
    $s.FeatureSet = ($fk.Count -gt 0 -and @($fk | Where-Object { (Get-RegValue $_ 'EnabledState') -eq 2 }).Count -eq $fk.Count)
    try { $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop; $s.BitLocker = ([string]$bl.ProtectionStatus -eq 'On') } catch {}
    $vendor = @($s.Controllers | Where-Object { $_.Service -and $_.Service -ne 'stornvme' -and $_.Service -ne 'nvmedisk' })
    if ($s.Build -lt 26100) { $s.Reason = 'Windows 11 24H2 ou plus récent requis.' }
    elseif (-not $s.HasDriver) { $s.Reason = 'Le pilote nvmedisk.sys n''existe pas sur cette version de Windows.' }
    elseif ($s.Controllers.Count -eq 0) { $s.Reason = 'Aucun SSD NVMe détecté.' }
    elseif ($vendor.Count -gt 0) { $s.Reason = 'Pilote de fabricant ou RAID/VMD en place (' + (($vendor | ForEach-Object { $_.Service }) -join ', ') + ') : bascule refusée, le PC pourrait ne plus démarrer.' }
    else { $s.Eligible = $true }
    return [pscustomobject]$s
}

function Show-NvmeState {
    $s = Get-NvmeState
    Set-OptResult $s
    Write-Log ("Windows {0}.{1} · nvmedisk.sys {2} · pile native {3} ({4} disque(s)) · disques NVMe sur la pile SCSI (disk.sys) : {5}" -f $s.Build, $s.Ubr, $(if ($s.HasDriver) { 'présent' } else { 'absent' }), $(if ($s.NativeRunning) { 'ACTIVE' } else { 'inactive' }), $s.NativeDisks, $s.ScsiNvmeDisks) 'OK'
    Write-Log ("Activation posée : stratégies {0} · magasin de démarrage {1}" -f $(if ($s.Overrides.Count) { 'oui' } else { 'non' }), $(if ($s.FeatureSet) { 'oui' } else { 'non' }))
    foreach ($c in $s.Controllers) { Write-Log ("Contrôleur : {0} (pilote {1})" -f $c.Name, $c.Service) }
    if (-not $s.Eligible) { Write-Log $s.Reason 'WARN' }
    if (($s.Overrides.Count -or $s.FeatureSet) -and -not $s.NativeRunning) { Write-Log 'Activation posée mais pile native inactive : redémarrez. Si rien ne change après redémarrage, Windows a bloqué la bascule sur cette version : revenez au pilote standard.' 'WARN' }
}

function Enable-NativeNvme {
    # Expérimental, non pris en charge par Microsoft sur Windows 11. Garde-fous : éligibilité stricte, point de restauration
    # obligatoire et vérifié, BitLocker suspendu pour deux redémarrages, valeurs d'origine mémorisées, retour automatique
    # de Windows à la dernière configuration bonne connue si le démarrage échoue.
    $s = Get-NvmeState
    if (-not $s.Eligible) { Write-Log ("Bascule refusée : " + $s.Reason) 'WARN'; return }
    if ($s.NativeRunning -and $s.ScsiNvmeDisks -eq 0) { Write-Log 'La pile NVMe native est déjà active (nvmedisk.sys), plus aucun disque NVMe sur disk.sys.' 'OK'; return }
    if (-not (Initialize-FeatureStoreApi)) { Write-Log 'Bascule annulée : magasin de fonctionnalités inaccessible.' 'WARN'; return }
    New-RestorePoint
    if (-not $Script:RestorePointOk) { Write-Log 'Bascule annulée : aucun point de restauration n''a pu être créé.' 'WARN'; return }
    if ($s.BitLocker) {
        try { Suspend-BitLocker -MountPoint $env:SystemDrive -RebootCount 2 -ErrorAction Stop | Out-Null; Write-Log 'BitLocker suspendu pour 2 redémarrages (reprise automatique ensuite).' 'OK' }
        catch { Write-Log ("Bascule annulée : BitLocker n'a pas pu être suspendu (" + $_.Exception.Message + '). Sans cela, Windows pourrait demander la clé de récupération.') 'WARN'; return }
    }
    # Méthode 1 : stratégies d'origine
    foreach ($id in $Script:NvmeOverrideIds) { Set-Reg $Script:NvmeOverrideKey $id 1 'DWord' }
    # Méthode 2 : magasin de démarrage (une clé par identifiant, créée seulement si absente, sinon valeurs mémorisées)
    foreach ($k in @(Get-NvmeFeatureKeys)) {
        if (-not (Test-Path -LiteralPath $k)) { Add-Orig "regkey|$k" @{ Type = 'regkey'; Path = $k } }
        foreach ($v in 'EnabledState', 'EnabledStateOptions', 'Variant', 'VariantPayload', 'VariantPayloadKind') {
            Set-Reg $k $v $(if ($v -eq 'EnabledState') { 2 } else { 0 }) 'DWord'
        }
    }
    $r = [BJ.FeatureStore]::MarkBootPending()
    if ($r -eq 0) { Write-Log 'Démarrage suivant marqué « à valider » : en cas d''échec, Windows revient seul à la configuration précédente.' 'OK' }
    else { Write-Log ("Marquage du démarrage à valider refusé (code 0x{0:X8}) : la bascule s'appliquera quand même au redémarrage." -f $r) 'WARN' }
    $Script:RebootNeeded = $true
    Write-Log 'Activation posée. Redémarrez, puis « Vérifier » : la pile native doit être ACTIVE et plus aucun disque NVMe sur disk.sys. Dans le Gestionnaire de périphériques, le SSD passe sous « Disques de stockage » avec nvmedisk.sys.' 'OK'
}

function Disable-NativeNvme {
    # Retire uniquement ce que la Toolbox a posé (jamais la clé Overrides entière, qui contient d'autres réglages de Windows).
    $s = Get-NvmeState
    $keys = @(Get-NvmeFeatureKeys)
    if ($s.Overrides.Count -eq 0 -and -not @($keys | Where-Object { Test-Path -LiteralPath $_ }).Count) { Write-Log 'Aucune activation du pilote natif n''est posée : rien à retirer.' 'OK'; return }
    if ($s.BitLocker) { try { Suspend-BitLocker -MountPoint $env:SystemDrive -RebootCount 2 -ErrorAction Stop | Out-Null; Write-Log 'BitLocker suspendu pour 2 redémarrages.' 'OK' } catch { Write-Log "BitLocker : $($_.Exception.Message)" 'WARN' } }
    foreach ($id in $Script:NvmeOverrideIds) {
        $k = "reg|$($Script:NvmeOverrideKey)|$id"
        if ($Script:Orig.Contains($k)) { Restore-Record $Script:Orig[$k]; $Script:Orig.Remove($k) }
        else { Remove-ItemProperty -Path $Script:NvmeOverrideKey -Name $id -ErrorAction SilentlyContinue }
    }
    foreach ($fk in $keys) {
        foreach ($v in 'EnabledState', 'EnabledStateOptions', 'Variant', 'VariantPayload', 'VariantPayloadKind') {
            $k = "reg|$fk|$v"
            if ($Script:Orig.Contains($k)) { Restore-Record $Script:Orig[$k]; $Script:Orig.Remove($k) }
        }
        $kk = "regkey|$fk"
        if ($Script:Orig.Contains($kk)) { Restore-Record $Script:Orig[$kk]; $Script:Orig.Remove($kk) }
        elseif ((Get-RegValue $fk 'EnabledState') -eq 2) { Remove-Item -LiteralPath $fk -Recurse -Force -ErrorAction SilentlyContinue }
        Write-Log "Magasin de démarrage : $(Split-Path $fk -Leaf) retiré" 'OK'
    }
    Save-Orig
    try { [void][BJ.FeatureStore]::MarkBootPending() } catch {}
    $Script:RebootNeeded = $true
    Write-Log 'Retour à la pile standard (stornvme + disk.sys) au prochain redémarrage.' 'OK'
}

# Retiré en 2.0 : désactivation de services ("niveau sûr" et "niveau avancé"). Sur Windows 11 la plupart ne
# démarrent qu'à la demande : les désactiver ne rend pas le PC plus rapide, et casse une fonction le jour où on
# en a besoin (impression, Bluetooth, partage). Les services déjà modifiés par une version 1.x se rétablissent depuis
# le Journal ou « Comparer avec Windows 11 ».

# ---------------------------------------------------------------- OLED
function Set-OledCare {
    Write-Log "=== Protection OLED (limitation du marquage) ==="
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'AppsUseLightTheme' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'SystemUsesLightTheme' 0
    $g = Get-BjmpcPlan
    if ($g) {
        Set-PlanAC $g 'SUB_VIDEO' 'VIDEOIDLE' 600
        & powercfg.exe /setactive $g | Out-Null
        Write-Log "Extinction de l'écran après 10 min d'inactivité (sur secteur)" 'OK'
    }
    Write-Host ""
    Write-Host "  À faire à la main (non scriptable de façon fiable) :" -ForegroundColor Yellow
    Write-Host "   - Masquer automatiquement la barre des tâches (Paramètres > Personnalisation > Barre des tâches)"
    Write-Host "   - Fond d'écran sombre ou changeant, éviter les icônes fixes sur le Bureau"
    Write-Host "   - Activer les cycles de rafraîchissement/pixel shift dans le menu OSD de l'écran"
    Write-Host "   - Auto HDR et HDR : Paramètres > Système > Affichage > HDR"
}

# ================================================================ ÉCHELLE D'AFFICHAGE (PPI) - DÉBUT
# Dépendances : Write-Log, Add-Orig, Set-Reg, Get-RegValue, Confirm-Action (déjà présents dans le script).
# Intégration : (1) coller ce bloc avant la section "Annulation"
#               (2) dans Restore-Record, ajouter la ligne :   'dpi' { Restore-DpiRecord $r }
#               (3) dans le menu et le switch : appeler Set-DisplayScaling (option 14)
$Script:DpiVals     = @(100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500)
$Script:DiagOverride = @{}

function Initialize-DpiApi {
    if ('BjmpcDpi' -as [type]) { return $true }
    # Source C# en tableau de lignes (pas de here-string : insensible a l'indentation lors d'un copier-coller)
    $csLines = @(
        'using System;',
        'using System.Collections.Generic;',
        'using System.Runtime.InteropServices;',
        '',
        'public static class BjmpcDpi',
        '{',
        '    const uint QDC_ONLY_ACTIVE_PATHS = 2;',
        '    const int INFO_GET_TARGET_NAME = 2;',
        '    const int INFO_GET_DPI_SCALE = -3;',
        '    const int INFO_SET_DPI_SCALE = -4;',
        '',
        '    [StructLayout(LayoutKind.Sequential)]',
        '    public struct LUID { public uint LowPart; public int HighPart; }',
        '',
        '    [StructLayout(LayoutKind.Sequential)]',
        '    public struct RATIONAL { public uint Numerator; public uint Denominator; }',
        '',
        '    [StructLayout(LayoutKind.Sequential)]',
        '    public struct PATH_SOURCE_INFO { public LUID adapterId; public uint id; public uint modeInfoIdx; public uint statusFlags; }',
        '',
        '    [StructLayout(LayoutKind.Sequential)]',
        '    public struct PATH_TARGET_INFO',
        '    {',
        '        public LUID adapterId; public uint id; public uint modeInfoIdx;',
        '        public uint outputTechnology; public uint rotation; public uint scaling;',
        '        public RATIONAL refreshRate; public uint scanLineOrdering;',
        '        public int targetAvailable; public uint statusFlags;',
        '    }',
        '',
        '    [StructLayout(LayoutKind.Sequential)]',
        '    public struct PATH_INFO { public PATH_SOURCE_INFO sourceInfo; public PATH_TARGET_INFO targetInfo; public uint flags; }',
        '',
        '    [StructLayout(LayoutKind.Explicit, Size = 64)]',
        '    public struct MODE_INFO',
        '    {',
        '        [FieldOffset(0)] public uint infoType;',
        '        [FieldOffset(4)] public uint id;',
        '        [FieldOffset(8)] public LUID adapterId;',
        '        [FieldOffset(16)] public uint width;',
        '        [FieldOffset(20)] public uint height;',
        '    }',
        '',
        '    [StructLayout(LayoutKind.Sequential)]',
        '    public struct HEADER { public int type; public uint size; public LUID adapterId; public uint id; }',
        '',
        '    [StructLayout(LayoutKind.Sequential)]',
        '    public struct DPI_GET { public HEADER header; public int minScaleRel; public int curScaleRel; public int maxScaleRel; }',
        '',
        '    [StructLayout(LayoutKind.Sequential)]',
        '    public struct DPI_SET { public HEADER header; public int scaleRel; }',
        '',
        '    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]',
        '    public struct TARGET_NAME',
        '    {',
        '        public HEADER header; public uint flags; public uint outputTechnology;',
        '        public ushort edidManufactureId; public ushort edidProductCodeId; public uint connectorInstance;',
        '        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string monitorFriendlyDeviceName;',
        '        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string monitorDevicePath;',
        '    }',
        '',
        '    public class Mon',
        '    {',
        '        public string Name; public string DevicePath;',
        '        public int Width; public int Height;',
        '        public uint AdapterLow; public int AdapterHigh; public uint SourceId;',
        '        public int Min; public int Cur; public int Max; public bool DpiOk;',
        '    }',
        '',
        '    [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint numPaths, out uint numModes);',
        '    [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint numPaths, [Out] PATH_INFO[] paths, ref uint numModes, [Out] MODE_INFO[] modes, IntPtr topologyId);',
        '    [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(IntPtr packet);',
        '    [DllImport("user32.dll")] static extern int DisplayConfigSetDeviceInfo(IntPtr packet);',
        '',
        '    static HEADER MakeHeader(int type, uint size, LUID adapter, uint id)',
        '    {',
        '        HEADER h = new HEADER();',
        '        h.type = type; h.size = size; h.adapterId = adapter; h.id = id;',
        '        return h;',
        '    }',
        '',
        '    public static List<Mon> GetMonitors()',
        '    {',
        '        uint np = 0, nm = 0;',
        '        PATH_INFO[] paths = null;',
        '        MODE_INFO[] modes = null;',
        '        int r = 0;',
        '        for (int attempt = 0; attempt < 3; attempt++)',
        '        {',
        '            r = GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, out np, out nm);',
        '            if (r != 0) throw new Exception("GetDisplayConfigBufferSizes: " + r);',
        '            paths = new PATH_INFO[np];',
        '            modes = new MODE_INFO[nm];',
        '            r = QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, ref np, paths, ref nm, modes, IntPtr.Zero);',
        '            if (r != 122) break;',
        '        }',
        '        if (r != 0) throw new Exception("QueryDisplayConfig: " + r);',
        '',
        '        List<Mon> list = new List<Mon>();',
        '        for (int i = 0; i < np; i++)',
        '        {',
        '            PATH_INFO p = paths[i];',
        '            Mon m = new Mon();',
        '            m.AdapterLow = p.sourceInfo.adapterId.LowPart;',
        '            m.AdapterHigh = p.sourceInfo.adapterId.HighPart;',
        '            m.SourceId = p.sourceInfo.id;',
        '',
        '            for (int j = 0; j < nm; j++)',
        '            {',
        '                if (modes[j].infoType == 1 && modes[j].id == p.sourceInfo.id &&',
        '                    modes[j].adapterId.LowPart == p.sourceInfo.adapterId.LowPart &&',
        '                    modes[j].adapterId.HighPart == p.sourceInfo.adapterId.HighPart)',
        '                {',
        '                    m.Width = (int)modes[j].width; m.Height = (int)modes[j].height; break;',
        '                }',
        '            }',
        '',
        '            TARGET_NAME tn = new TARGET_NAME();',
        '            uint tsize = (uint)Marshal.SizeOf(typeof(TARGET_NAME));',
        '            tn.header = MakeHeader(INFO_GET_TARGET_NAME, tsize, p.targetInfo.adapterId, p.targetInfo.id);',
        '            IntPtr tb = Marshal.AllocHGlobal((int)tsize);',
        '            try',
        '            {',
        '                Marshal.StructureToPtr(tn, tb, false);',
        '                if (DisplayConfigGetDeviceInfo(tb) == 0)',
        '                {',
        '                    tn = (TARGET_NAME)Marshal.PtrToStructure(tb, typeof(TARGET_NAME));',
        '                    m.Name = tn.monitorFriendlyDeviceName;',
        '                    m.DevicePath = tn.monitorDevicePath;',
        '                }',
        '            }',
        '            finally { Marshal.FreeHGlobal(tb); }',
        '',
        '            DPI_GET g = new DPI_GET();',
        '            uint gsize = (uint)Marshal.SizeOf(typeof(DPI_GET));',
        '            g.header = MakeHeader(INFO_GET_DPI_SCALE, gsize, p.sourceInfo.adapterId, p.sourceInfo.id);',
        '            IntPtr gb = Marshal.AllocHGlobal((int)gsize);',
        '            try',
        '            {',
        '                Marshal.StructureToPtr(g, gb, false);',
        '                if (DisplayConfigGetDeviceInfo(gb) == 0)',
        '                {',
        '                    g = (DPI_GET)Marshal.PtrToStructure(gb, typeof(DPI_GET));',
        '                    m.Min = g.minScaleRel; m.Cur = g.curScaleRel; m.Max = g.maxScaleRel; m.DpiOk = true;',
        '                }',
        '            }',
        '            finally { Marshal.FreeHGlobal(gb); }',
        '',
        '            list.Add(m);',
        '        }',
        '        return list;',
        '    }',
        '',
        '    public static int SetScaleRel(uint adapterLow, int adapterHigh, uint sourceId, int rel)',
        '    {',
        '        LUID l = new LUID();',
        '        l.LowPart = adapterLow; l.HighPart = adapterHigh;',
        '        DPI_SET s = new DPI_SET();',
        '        uint size = (uint)Marshal.SizeOf(typeof(DPI_SET));',
        '        s.header = MakeHeader(INFO_SET_DPI_SCALE, size, l, sourceId);',
        '        s.scaleRel = rel;',
        '        IntPtr buf = Marshal.AllocHGlobal((int)size);',
        '        try',
        '        {',
        '            Marshal.StructureToPtr(s, buf, false);',
        '            return DisplayConfigSetDeviceInfo(buf);',
        '        }',
        '        finally { Marshal.FreeHGlobal(buf); }',
        '    }',
        '}'
    )
    $src = $csLines -join "`r`n"
    try { Add-Type -TypeDefinition $src -Language CSharp -ErrorAction Stop; return $true }
    catch { Write-Log "API d'échelle d'affichage indisponible : $($_.Exception.Message)" 'ERROR'; return $false }
}

function Get-EdidInfo {
    # Taille physique de l'écran lue dans l'EDID (registre) : précision au mm si le descripteur de timing est valide.
    param([string]$DevicePath)
    $r = @{ Wmm = 0; Hmm = 0; Source = 'aucune donnée EDID' }
    if ($DevicePath -match 'DISPLAY#([^#]+)#([^#]+)#') {
        $key = "HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY\$($Matches[1])\$($Matches[2])\Device Parameters"
    } else { return $r }
    $edid = Get-RegValue $key 'EDID'
    if (-not $edid -or $edid.Length -lt 128) { return $r }
    if ($edid[54] -ne 0 -or $edid[55] -ne 0) {
        $w = [int]$edid[66] + (([int]$edid[68] -band 0xF0) -shl 4)
        $h = [int]$edid[67] + (([int]$edid[68] -band 0x0F) -shl 8)
        if ($w -gt 0 -and $h -gt 0) { $r.Wmm = $w; $r.Hmm = $h; $r.Source = 'EDID (au mm)'; return $r }
    }
    if ($edid[21] -gt 0 -and $edid[22] -gt 0) {
        $r.Wmm = [int]$edid[21] * 10; $r.Hmm = [int]$edid[22] * 10; $r.Source = 'EDID (au cm, approximatif)'
    }
    return $r
}

function Get-DisplayModel {
    $out = @()
    foreach ($m in @([BjmpcDpi]::GetMonitors())) {
        if (-not $m.DpiOk) { continue }
        $e = Get-EdidInfo $m.DevicePath
        $diagPx = [math]::Sqrt([math]::Pow($m.Width, 2) + [math]::Pow($m.Height, 2))
        $diagIn = 0.0; $src = $e.Source; $suspect = $false
        if ($Script:DiagOverride.ContainsKey($m.DevicePath)) {
            $diagIn = [double]$Script:DiagOverride[$m.DevicePath]; $src = 'diagonale saisie par vous'
        } elseif ($e.Wmm -gt 0 -and $e.Hmm -gt 0) {
            $diagIn = [math]::Sqrt([math]::Pow($e.Wmm, 2) + [math]::Pow($e.Hmm, 2)) / 25.4
            $aspectEdid = $e.Wmm / $e.Hmm; $aspectRes = $m.Width / [math]::Max(1, $m.Height)
            if ([math]::Abs($aspectEdid - $aspectRes) / $aspectRes -gt 0.04) { $suspect = $true }
            if (($e.Wmm % 100 -eq 0) -and ($e.Hmm % 100 -eq 0)) { $suspect = $true }
        } else { $suspect = $true }
        $ppi = if ($diagIn -gt 0 -and $diagPx -gt 0) { $diagPx / $diagIn } else { 0.0 }
        $recIdx = [math]::Abs($m.Min)
        $out += [pscustomobject]@{
            Name = $(if ($m.Name) { $m.Name } else { 'Écran (nom inconnu)' }); DevicePath = $m.DevicePath
            Width = $m.Width; Height = $m.Height; Wmm = $e.Wmm; Hmm = $e.Hmm; Source = $src; Suspect = $suspect
            DiagIn = $diagIn; Ppi = $ppi; Min = $m.Min; Cur = $m.Cur; Max = $m.Max
            RecPct = $Script:DpiVals[$recIdx]; CurPct = $Script:DpiVals[$recIdx + $m.Cur]
            MinPct = $Script:DpiVals[0]; MaxPct = $Script:DpiVals[[math]::Min($recIdx + $m.Max, $Script:DpiVals.Count - 1)]
            AdapterLow = $m.AdapterLow; AdapterHigh = $m.AdapterHigh; SourceId = $m.SourceId
        }
    }
    return $out
}

function Get-SuggestedScale {
    # 100 % = 96 PPI vu à ~71 cm (pixel de référence CSS/Windows). On conserve la taille angulaire apparente.
    param($Mon, [int]$DistCm)
    if ($Mon.Ppi -le 0) { return $Mon.RecPct }
    $raw = ($Mon.Ppi / 96.0) * ($DistCm / 71.0)
    $maxIdx = [math]::Min([math]::Abs($Mon.Min) + $Mon.Max, $Script:DpiVals.Count - 1)
    $best = 0; $bd = [double]::MaxValue
    for ($i = 0; $i -le $maxIdx; $i++) {
        $d = [math]::Abs(($Script:DpiVals[$i] / 100.0) - $raw)
        if ($d -lt $bd) { $bd = $d; $best = $i }
    }
    return $Script:DpiVals[$best]
}

function Set-MonitorScale {
    param($Mon, [int]$Pct)
    $idx = [array]::IndexOf($Script:DpiVals, $Pct)
    if ($idx -lt 0) { Write-Log "Valeur non supportée : $Pct % (pas de 25 % jusqu'à 250, puis 300, 350, 400, 450, 500)" 'WARN'; return $false }
    $rel = $idx - [math]::Abs($Mon.Min)
    if ($rel -lt $Mon.Min -or $rel -gt $Mon.Max) {
        Write-Log "$Pct % hors de la plage supportée par cet écran ($($Mon.MinPct) à $($Mon.MaxPct) %)" 'WARN'; return $false
    }
    Add-Orig ("dpi|{0}" -f $Mon.DevicePath) @{ Type = 'dpi'; DevicePath = $Mon.DevicePath; Rel = [int]$Mon.Cur; Name = $Mon.Name }
    $res = [BjmpcDpi]::SetScaleRel([uint32]$Mon.AdapterLow, [int]$Mon.AdapterHigh, [uint32]$Mon.SourceId, [int]$rel)
    if ($res -ne 0) { Write-Log "Échec de l'application de l'échelle (code $res)" 'ERROR'; return $false }
    Write-Log "$($Mon.Name) : échelle réglée à $Pct %" 'OK'
    return $true
}

function Restore-DpiRecord {
    param($r)
    if (-not (Initialize-DpiApi)) { throw "API d'échelle indisponible" }
    $m = @([BjmpcDpi]::GetMonitors()) | Where-Object { $_.DevicePath -eq [string]$r.DevicePath } | Select-Object -First 1
    if (-not $m) { throw "écran introuvable (débranché ?)" }
    $res = [BjmpcDpi]::SetScaleRel([uint32]$m.AdapterLow, [int]$m.AdapterHigh, [uint32]$m.SourceId, [int]$r.Rel)
    if ($res -ne 0) { throw "code $res" }
}

function Set-DisplayScaling {
    Write-Log "=== Échelle d'affichage selon le PPI réel de l'écran ==="
    if (-not (Initialize-DpiApi)) { return }
    Write-Host "  Windows prend 96 PPI comme référence (100 %). Il choisit une échelle recommandée d'après la taille" -ForegroundColor DarkGray
    Write-Host "  physique lue dans l'EDID de l'écran, souvent fausse sur les TV et certains OLED." -ForegroundColor DarkGray
    $dist = 70
    $d = Read-Host "  Distance yeux-écran en cm [70]"
    if ($d -match '^\d{2,3}$') { $dist = [int]$d }

    while ($true) {
        try { $mons = @(Get-DisplayModel) } catch { Write-Log "Lecture des écrans impossible : $($_.Exception.Message)" 'ERROR'; return }
        if ($mons.Count -eq 0) { Write-Log "Aucun écran actif détecté" 'WARN'; return }
        Write-Host ""
        $i = 0
        foreach ($m in $mons) {
            $i++
            $sug = Get-SuggestedScale $m $dist
            Write-Host ("  [{0}] {1}  -  {2}x{3}" -f $i, $m.Name, $m.Width, $m.Height) -ForegroundColor White
            if ($m.DiagIn -gt 0) {
                $mmTxt = if ($m.Wmm -gt 0 -and $m.Source -notmatch 'saisie') { " - {0} x {1} mm" -f $m.Wmm, $m.Hmm } else { '' }
                Write-Host ("      Taille       : {0:N1} pouces ({1}){2}" -f $m.DiagIn, $m.Source, $mmTxt)
                Write-Host ("      PPI réel     : {0:N0}" -f $m.Ppi) -ForegroundColor Cyan
            } else {
                Write-Host "      Taille       : inconnue (pas d'EDID exploitable) : saisissez la diagonale (option 3)" -ForegroundColor Yellow
            }
            if ($m.Suspect -and $m.DiagIn -gt 0 -and $m.Source -notmatch 'saisie') {
                Write-Host "      /!\ Taille EDID douteuse (arrondie ou ratio incohérent) : vérifiez la diagonale (option 3)" -ForegroundColor Yellow
            }
            Write-Host ("      Échelle      : actuelle {0} %  |  recommandée Windows {1} %  |  plage {2}-{3} %" -f $m.CurPct, $m.RecPct, $m.MinPct, $m.MaxPct)
            Write-Host ("      Suggestion   : {0} %  (à {1} cm)" -f $sug, $dist) -ForegroundColor Green
        }
        Write-Host ""
        $sel = Read-Host "  Numéro de l'écran à régler (0 = retour)"
        if ($sel -notmatch '^\d+$' -or [int]$sel -eq 0) { return }
        if ([int]$sel -gt $mons.Count) { Write-Host "  Numéro invalide." -ForegroundColor Red; continue }
        $mon = $mons[[int]$sel - 1]
        $sug = Get-SuggestedScale $mon $dist

        Write-Host "   1) Appliquer la suggestion ($sug %)"
        Write-Host "   2) Saisir un pourcentage (100, 125, 150, 175, 200, 225, 250, 300...)"
        Write-Host "   3) Corriger la diagonale réelle (pouces) puis recalculer"
        Write-Host "   4) Revenir à l'échelle recommandée par Windows ($($mon.RecPct) %)"
        Write-Host "   5) Taille du texte seule (réglage fin 100-225 %, sans flouter les applis)"
        Write-Host "   0) Retour a la liste des ecrans"
        $a = Read-Host "  Choix"
        if ([string]::IsNullOrWhiteSpace($a) -or $a -eq '0') { continue }
        switch ($a) {
            '1' { if (Set-MonitorScale $mon $sug) { Write-Host "  Appliqué. Rouvrez les applis (ou la session) si le rendu reste flou." -ForegroundColor Green } }
            '2' {
                $v = Read-Host "  Pourcentage"
                if ($v -match '^\d+$') { if (Set-MonitorScale $mon ([int]$v)) { Write-Host "  Appliqué." -ForegroundColor Green } }
                else { Write-Host "  Valeur invalide." -ForegroundColor Red }
            }
            '3' {
                $v = (Read-Host "  Diagonale réelle en pouces (ex : 27, 31.5, 42, 48)") -replace ',', '.'
                $dd = 0.0
                if ([double]::TryParse($v, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$dd) -and $dd -ge 10 -and $dd -le 100) {
                    $Script:DiagOverride[$mon.DevicePath] = $dd
                    Write-Log "Diagonale de $($mon.Name) fixée à $dd pouces pour le calcul (session)" 'OK'
                } else { Write-Host "  Valeur invalide (10 à 100)." -ForegroundColor Red }
            }
            '4' { if (Set-MonitorScale $mon $mon.RecPct) { Write-Host "  Échelle Windows rétablie." -ForegroundColor Green } }
            '5' {
                $cur = Get-RegValue 'HKCU:\Software\Microsoft\Accessibility' 'TextScaleFactor'
                if (-not $cur) { $cur = 100 }
                $v = Read-Host "  Taille du texte en % (100 à 225), actuelle $cur"
                if ($v -match '^\d+$' -and [int]$v -ge 100 -and [int]$v -le 225) {
                    Set-Reg 'HKCU:\Software\Microsoft\Accessibility' 'TextScaleFactor' ([int]$v)
                    Write-Host "  Enregistré. Fermez/rouvrez la session pour une prise en compte complète." -ForegroundColor Green
                } else { Write-Host "  Valeur invalide." -ForegroundColor Red }
            }
        }
    }
}
# ================================================================ ÉCHELLE D'AFFICHAGE (PPI) - FIN

# ---------------------------------------------------------------- Annulation
function Restore-Record {
    param($r)
    try {
        switch ($r.Type) {
            'reg'   { Restore-Reg $r }
            'svc'   { & sc.exe config $r.Name start= $r.Mode | Out-Null }
            'task'  { if ($r.WasEnabled) { Enable-ScheduledTask -TaskPath $r.TaskPath -TaskName $r.TaskName -ErrorAction Stop | Out-Null } }
            'adv'   { Set-NetAdapterAdvancedProperty -Name $r.Adapter -RegistryKeyword $r.Keyword -RegistryValue $r.Value -NoRestart -ErrorAction Stop }
            'nicpm' { Set-NetAdapterPowerManagement -Name $r.Adapter -AllowComputerToTurnOffDevice $r.Value -ErrorAction Stop }
            'rsc'   { Enable-NetAdapterRsc -Name $r.Adapter -ErrorAction Stop }
            'dns'   {
                $list = @(([string]$r.Static4 + ',' + [string]$r.Static6) -split '[,; ]' | Where-Object { $_ })
                if ($list.Count -eq 0) { Set-DnsClientServerAddress -InterfaceIndex ([int]$r.Index) -ResetServerAddresses -ErrorAction Stop }
                else { Set-DnsClientServerAddress -InterfaceIndex ([int]$r.Index) -ServerAddresses $list -ErrorAction Stop }
            }
            'power' {
                $orig = [string]$r.OriginalGuid
                & powercfg.exe /setactive $orig 2>$null | Out-Null
                if ($LASTEXITCODE -ne 0) { & powercfg.exe /setactive SCHEME_BALANCED | Out-Null }
                if ([string]$r.NewGuid) { & powercfg.exe /delete ([string]$r.NewGuid) 2>$null | Out-Null }
            }
            'fsutil' { & fsutil.exe behavior set $r.Name ([int]$r.Value) | Out-Null }
            'hib'    { if ($r.Enabled) { & powercfg.exe /h on | Out-Null } }
            'mma'    { if ($r.Enabled) { Enable-MMAgent -MemoryCompression -ErrorAction Stop } }
            'dpi'    { Restore-DpiRecord $r }
            'regkey' { if (Test-Path -LiteralPath $r.Path) { Remove-Item -LiteralPath $r.Path -Recurse -Force -ErrorAction Stop } }
            'fwgroup' { Get-NetFirewallRule -Group $r.Group -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue }
            'pwr'    { & powercfg.exe /setacvalueindex ([string]$r.Scheme) ([string]$r.Sub) ([string]$r.Setting) ([int]$r.Ac) | Out-Null; if ((Get-ActivePlanGuid) -eq [string]$r.Scheme) { & powercfg.exe /setactive ([string]$r.Scheme) | Out-Null } }
            'fsutilrefs' { & fsutil.exe behavior set DisableDeleteNotify ReFS ([int]$r.Value) | Out-Null }
            'taskon' { Disable-ScheduledTask -TaskPath $r.TaskPath -TaskName $r.TaskName -ErrorAction Stop | Out-Null }
            'feature' { Enable-WindowsOptionalFeature -Online -FeatureName $r.Name -NoRestart -ErrorAction Stop | Out-Null }
            'cap'    { Add-WindowsCapability -Online -Name $r.Name -ErrorAction Stop | Out-Null }
        }
        Write-Log "Restauré : $($r.Key)" 'OK'
    } catch {
        Write-Log "Restauration partielle de $($r.Key) : $($_.Exception.Message)" 'WARN'
    }
}

function Restore-All {
    if ($Script:Orig.Count -eq 0) { Write-Log "Aucune modification enregistrée : rien à annuler"; return }
    Write-Host ("  {0} modification(s) enregistrée(s)." -f $Script:Orig.Count)
    if (-not (Confirm-Action "Annuler TOUTES ces modifications et revenir à l'état d'origine ?")) { return }
    $recs = @($Script:Orig.Values)
    [array]::Reverse($recs)
    foreach ($r in $recs) { Restore-Record $r }
    $arch = $Script:StateFile -replace '\.json$', ("_restaure_{0}.json" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    if (Test-Path $Script:StateFile) { Move-Item -Path $Script:StateFile -Destination $arch -Force }
    $Script:Orig = [ordered]@{}
    $Script:RebootNeeded = $true
    Write-Log "Retour à l'état d'origine terminé. Redémarrage conseillé. Archive : $arch" 'OK'
}

function Invoke-FullProfile {
    # Réglages recommandés pour tout PC Windows 11 : seulement ce qui est sûr et utile partout.
    # Le plan d'alimentation, les cartes réseau, le DNS et la protection OLED dépendent du matériel et de
    # l'usage : ils restent des choix à faire dans leurs pages.
    Write-Log "=== RÉGLAGES RECOMMANDÉS (aucun choix risqué) ==="
    New-RestorePoint
    $Script:AssumeDefaults = $true
    try {
        Optimize-Gaming
        Optimize-Storage
        # Télémétrie minimale : réglage du catalogue Confidentialité (présent dans l'interface, absent de la console seule)
        if (Get-Command Set-Tweaks -ErrorAction SilentlyContinue) { Set-Tweaks -Ids @('tel_win') }
    } finally { $Script:AssumeDefaults = $false }
    $Script:RebootNeeded = $true
    Write-Log "=== RÉGLAGES RECOMMANDÉS APPLIQUÉS ===" 'OK'
}

# ---------------------------------------------------------------- Explorateur et confidentialité (réversibles)
function Optimize-Explorer {
    Write-Log "=== Explorateur Windows : confort et rapidité ==="
    $adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    Set-Reg $adv 'HideFileExt' 0
    Set-Reg $adv 'LaunchTo' 1
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'StartupDelayInMSec' 0
    Write-Log "Extensions de fichiers visibles, Explorateur ouvert sur « Ce PC », applications de démarrage sans délai artificiel" 'OK'
    Write-Log "Fermez puis rouvrez la session pour tout prendre en compte" 'WARN'
}

function Optimize-Privacy {
    Write-Log "=== Confidentialité et suggestions Windows (sans risque) ==="
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0
    Set-Reg 'HKCU:\Control Panel\International\User Profile' 'HttpAcceptLanguageOptOut' 1
    $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    foreach ($n in @('SubscribedContent-338387Enabled', 'SubscribedContent-338388Enabled', 'SubscribedContent-338389Enabled',
                     'SubscribedContent-353694Enabled', 'SubscribedContent-353696Enabled', 'SubscribedContent-310093Enabled',
                     'SystemPaneSuggestionsEnabled', 'SoftLandingEnabled', 'RotatingLockScreenOverlayEnabled',
                     'OemPreInstalledAppsEnabled', 'PreInstalledAppsEnabled', 'SilentInstalledAppsEnabled')) {
        Set-Reg $cdm $n 0
    }
    Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_IrisRecommendations' 0
    Write-Log "Identifiant publicitaire, expériences personnalisées, suggestions et publicités du menu Démarrage, résultats Bing dans la recherche : désactivés" 'OK'
}

# ---------------------------------------------------------------- Menu
function Show-Menu {
    Show-Header "MENU PRINCIPAL"
    Write-Host "   DIAGNOSTIC" -ForegroundColor Magenta
    Write-Host "    1) Profil matériel détecté (CPU, RAM, GPU, NVMe, Wi-Fi, écran)"
    Write-Host "    2) Point de restauration"
    Write-Host "   13) État des optimisations"
    Write-Host ""
    Write-Host "   GAMING" -ForegroundColor Magenta
    Write-Host "    3) Profil Gaming (HAGS, Mode Jeu, DVR off, VRR, souris)"
    Write-Host "    H) HAGS seule : activer / désactiver la planification GPU matérielle"
    Write-Host "    4) Plan d'alimentation Performance pour PC fixe de jeu (CPU, PCIe/NVMe, USB, Wi-Fi)"
    Write-Host ""
    Write-Host "   RÉSEAU" -ForegroundColor Magenta
    Write-Host "    6) Cartes réseau Wi-Fi 6/7 et Ethernet (énergie, modes, itinérance)"
    Write-Host "    7) DNS chiffré (DNS4ALL, FDN, DNS4EU…)"
    Write-Host ""
    Write-Host "   SYSTÈME" -ForegroundColor Magenta
    Write-Host "    8) Disque SSD et démarrage (TRIM, démarrage rapide, hibernation)"
    Write-Host "   11) Protection OLED"
    Write-Host "   15) Explorateur : extensions visibles, ouverture sur Ce PC, démarrage sans délai"
    Write-Host "   16) Confidentialité : publicités, suggestions, résultats Bing dans la recherche"
    Write-Host "   14) Échelle d'affichage selon le PPI réel de l'écran (OLED/HDR)"
    Write-Host ""
    Write-Host "   12) RÉGLAGES RECOMMANDÉS (2, 3, 8 et télémétrie minimale)" -ForegroundColor Green
    Write-Host "    R) ANNULER toutes les modifications (état d'origine)" -ForegroundColor Yellow
    Write-Host "    L) Dossier des logs     S) Redémarrer le PC     0) Quitter" -ForegroundColor Yellow
    Write-Host ""
    if ($Script:RebootNeeded) { Write-Host "   >> Un redémarrage est recommandé pour finaliser certaines actions <<" -ForegroundColor Yellow; Write-Host "" }
}

Import-Orig
Write-Log "Session démarrée sur $env:COMPUTERNAME - journal : $Script:LogFile (état d'origine : $($Script:Orig.Count) entrée(s))"

$emptyCount = 0
do {
    Show-Menu
    $rawChoice = Read-Host "  Votre choix"
    $choice = ("$rawChoice").Trim().ToUpper()
    if ([string]::IsNullOrWhiteSpace($choice)) {
        $emptyCount++
        if ($emptyCount -ge 5) {
            Write-Log "Aucune saisie reçue 5 fois de suite (console non interactive ?). Arrêt du script." 'ERROR'
            $choice = '0'
            continue
        }
    } else { $emptyCount = 0 }
    switch ($choice) {
        '1'  { Show-HardwareProfile; Wait-Key }
        '2'  { Show-Header "Point de restauration"; New-RestorePoint; Wait-Key }
        '3'  { Show-Header "Profil Gaming"; Optimize-Gaming; Wait-Key }
        '4'  { Show-Header "Plan d'alimentation"; Optimize-Power; Wait-Key }
        'H'  { Show-Header "Planification GPU matérielle (HAGS)"; if (Confirm-Action "Activer HAGS ? (Non = la désactiver)" $true) { Set-Hags -Mode on } else { Set-Hags -Mode off }; Wait-Key }
        '6'  { Show-Header "Réseau"; Optimize-Network; Wait-Key }
        '7'  { Show-Header "DNS chiffré"; Select-DnsPreset; Wait-Key }
        '8'  { Show-Header "Disque SSD et démarrage"; Optimize-Storage; Wait-Key }
        '11' { Show-Header "Protection OLED"; Set-OledCare; Wait-Key }
        '12' { Show-Header "Réglages recommandés"; if (Confirm-Action "Appliquer les réglages recommandés (point de restauration inclus) ?" $true) { Invoke-FullProfile }; Wait-Key }
        '13' { Show-State; Wait-Key }
        '14' { Show-Header "Échelle d'affichage (PPI)"; Set-DisplayScaling; Wait-Key }
        '15' { Show-Header "Explorateur Windows"; Optimize-Explorer; Wait-Key }
        '16' { Show-Header "Confidentialité"; Optimize-Privacy; Wait-Key }
        'R'  { Show-Header "Annulation"; Restore-All; Wait-Key }
        'L'  { Start-Process explorer.exe $Script:LogDir }
        'S'  { if (Confirm-Action "Redémarrer maintenant ?") { Write-Log "Redémarrage demandé"; Restart-Computer -Force } }
        '0'  { }
        default { Write-Host "  Choix invalide." -ForegroundColor Red; Start-Sleep -Seconds 1 }
    }
} while ($choice -ne '0')

Write-Log "Session terminée"
if ($Script:RebootNeeded) { Write-Host "`n  Pensez à redémarrer le PC pour finaliser les optimisations." -ForegroundColor Yellow }
Write-Host "  Journal : $Script:LogFile" -ForegroundColor Gray
