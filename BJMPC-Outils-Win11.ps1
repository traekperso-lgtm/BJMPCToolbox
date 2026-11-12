#Requires -Version 5.1
<#
.SYNOPSIS
    BJMPC Informatique - Outils de diagnostic et de dépannage (lecture seule ou sans risque)
.DESCRIPTION
    Bibliothèque de fonctions utilisée par BJMPC Toolbox (page "Outils").
    Aucune fonction ne pose de question : les confirmations sont demandées par l'interface avant l'appel.
    Rien n'est modifié durablement, sauf là où le nom de la fonction l'indique (file d'impression, horloge,
    caches de shaders, redémarrage de services) ; les rapports sont écrits dans C:\BJMPC-Logs\Rapports.
#>

$ErrorActionPreference = 'Continue'
$Script:ToolsVersion = '1.6'
$Script:LogDir       = Join-Path $env:SystemDrive 'BJMPC-Logs'
$Script:ReportDir    = Join-Path $Script:LogDir 'Rapports'
$Script:LogFile      = Join-Path $Script:LogDir ("Outils_{0}_{1}.log" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmmss'))
$Script:RebootNeeded = $false

# ---------------------------------------------------------------- Utilitaires
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try { Add-Content -Path $Script:LogFile -Value $line -Encoding UTF8 -ErrorAction Stop } catch {}
    switch ($Level) {
        'OK'    { Write-Host "  [OK]  $Message" -ForegroundColor Green }
        'WARN'  { Write-Host "  [!]   $Message" -ForegroundColor Yellow }
        'ERROR' { Write-Host "  [X]   $Message" -ForegroundColor Red }
        default { Write-Host "  [..]  $Message" -ForegroundColor Cyan }
    }
}

function Write-Row {
    # Une ligne "libellé : valeur" colorée selon l'état (ok, warn, bad ou vide).
    param([string]$Label, [string]$Value, [string]$State = '')
    $color = 'Gray'
    if ($State -eq 'ok') { $color = 'Green' } elseif ($State -eq 'warn') { $color = 'Yellow' } elseif ($State -eq 'bad') { $color = 'Red' }
    Write-Host ("  {0,-40} {1}" -f $Label, $Value) -ForegroundColor $color
}

function Get-ReportPath {
    param([string]$Name, [string]$Extension)
    try { New-Item -ItemType Directory -Path $Script:ReportDir -Force -ErrorAction Stop | Out-Null } catch {}
    return (Join-Path $Script:ReportDir ("{0}_{1}_{2}.{3}" -f $Name, $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmmss'), $Extension))
}

function Open-Path {
    param([string]$Path)
    try { Start-Process -FilePath $Path -ErrorAction Stop } catch { Write-Log "Ouverture impossible : $Path" 'WARN' }
}

function Get-RegVal {
    param([string]$Path, [string]$Name)
    try { (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name } catch { $null }
}

function Test-HasBattery {
    try { return [bool](Get-CimInstance Win32_Battery -ErrorAction Stop) } catch { return $false }
}

function Invoke-NativeLines {
    # Exécute une commande native et renvoie ses lignes de texte nettoyées (sans modifier la console).
    param([string]$Exe, [string]$Arguments)
    $res = @()
    & cmd.exe /c "$Exe $Arguments 2>&1" | ForEach-Object {
        $l = ("$_" -replace "`r", '' -replace "`0", '').TrimEnd()
        if ($l.Trim()) { $res += $l }
    }
    return $res
}

# ---------------------------------------------------------------- Matériel
function Get-StorageHealth {
    Write-Log "=== Santé des disques (SMART) ==="
    $disks = @(Get-PhysicalDisk -ErrorAction SilentlyContinue)
    if ($disks.Count -eq 0) { Write-Log "Aucun disque lisible." 'WARN'; return }
    foreach ($d in $disks) {
        $rc = $null
        try { $rc = $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch {}
        Write-Host ""
        Write-Host ("  {0}  ({1}, {2:N0} Go)" -f $d.FriendlyName, $d.MediaType, ($d.Size / 1GB)) -ForegroundColor White
        $hs = [string]$d.HealthStatus
        Write-Row "État de santé" $hs $(if ($hs -eq 'Healthy') { 'ok' } else { 'bad' })
        $op = [string]$d.OperationalStatus
        Write-Row "Fonctionnement" $op $(if ($op -eq 'OK') { 'ok' } else { 'warn' })
        if ($rc) {
            if ($null -ne $rc.Temperature -and [int]$rc.Temperature -gt 0) {
                $t = [int]$rc.Temperature
                Write-Row "Température" ("{0} °C" -f $t) $(if ($t -ge 70) { 'bad' } elseif ($t -ge 55) { 'warn' } else { 'ok' })
            }
            if ($null -ne $rc.Wear) {
                $w = [int]$rc.Wear
                Write-Row "Usure du SSD" ("{0} %" -f $w) $(if ($w -ge 80) { 'bad' } elseif ($w -ge 50) { 'warn' } else { 'ok' })
            }
            if ($null -ne $rc.PowerOnHours) { Write-Row "Heures de fonctionnement" ("{0:N0} h" -f [double]$rc.PowerOnHours) '' }
            if ($null -ne $rc.ReadErrorsTotal)  { Write-Row "Erreurs de lecture"  ([string]$rc.ReadErrorsTotal)  $(if ([double]$rc.ReadErrorsTotal -gt 0) { 'warn' } else { 'ok' }) }
            if ($null -ne $rc.WriteErrorsTotal) { Write-Row "Erreurs d'écriture" ([string]$rc.WriteErrorsTotal) $(if ([double]$rc.WriteErrorsTotal -gt 0) { 'warn' } else { 'ok' }) }
        } else {
            Write-Host "  Compteurs SMART non disponibles pour ce disque (pilote ou contrôleur)." -ForegroundColor DarkGray
        }
    }
    Write-Host ""
    Write-Host "  Seuils : orange à partir de 55 °C ou 50 % d'usure, rouge à partir de 70 °C ou 80 %." -ForegroundColor DarkGray
}

function Get-HardwareErrors {
    param([int]$Days = 7)
    Write-Log "=== Erreurs matérielles et système (derniers $Days jours) ==="
    $start = (Get-Date).AddDays(-$Days)
    $providers = @('disk', 'Ntfs', 'volmgr', 'stornvme', 'storahci', 'Microsoft-Windows-WHEA-Logger', 'Microsoft-Windows-Kernel-Power', 'nvlddmkm', 'Display', 'BugCheck')
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2; StartTime = $start } -ErrorAction SilentlyContinue |
        Where-Object { $providers -contains $_.ProviderName })
    if ($ev.Count -eq 0) { Write-Log "Aucune erreur disque, mémoire, GPU ou alimentation sur la période." 'OK'; return }
    Write-Log ("{0} événement(s) d'erreur trouvé(s)" -f $ev.Count) 'WARN'
    Write-Host ""
    foreach ($g in ($ev | Group-Object ProviderName | Sort-Object Count -Descending)) {
        Write-Row $g.Name ("{0} événement(s)" -f $g.Count) 'warn'
    }
    Write-Host ""
    Write-Host "  Les plus récents :" -ForegroundColor White
    foreach ($e in ($ev | Sort-Object TimeCreated -Descending | Select-Object -First 8)) {
        $msg = (("$($e.Message)" -split "`n")[0]).Trim()
        if ($msg.Length -gt 110) { $msg = $msg.Substring(0, 110) + '...' }
        Write-Host ("   {0}  {1}  {2}" -f $e.TimeCreated.ToString('dd/MM HH:mm'), $e.ProviderName, $msg) -ForegroundColor DarkGray
    }
    Write-Host ""
    if ($ev | Where-Object { $_.ProviderName -eq 'Microsoft-Windows-WHEA-Logger' }) {
        Write-Host "  WHEA : erreur matérielle signalée par le processeur ou la mémoire. Vérifier températures, RAM (XMP/EXPO, MemTest) et réglages d'overclock." -ForegroundColor Yellow
    }
    if ($ev | Where-Object { $_.ProviderName -in @('disk', 'Ntfs', 'volmgr', 'stornvme', 'storahci') }) {
        Write-Host "  Stockage : consulter la santé SMART, vérifier câbles et connecteurs, lancer CHKDSK (page Maintenance)." -ForegroundColor Yellow
    }
    if ($ev | Where-Object { $_.ProviderName -eq 'Microsoft-Windows-Kernel-Power' }) {
        Write-Host "  Kernel-Power : arrêt inattendu (coupure, alimentation, plantage). Vérifier l'alimentation et les températures." -ForegroundColor Yellow
    }
    if ($ev | Where-Object { $_.ProviderName -in @('nvlddmkm', 'Display') }) {
        Write-Host "  Pilote graphique : réinstaller proprement le pilote GPU ; vérifier aussi l'alimentation de la carte." -ForegroundColor Yellow
    }
}

function New-EnergyReport {
    Write-Log "=== Rapport d'efficacité énergétique (environ 20 secondes) ==="
    $path = Get-ReportPath 'Energie' 'html'
    [void](Invoke-NativeLines 'powercfg.exe' "/energy /output `"$path`" /duration 15")
    if (Test-Path $path) { Write-Log "Rapport créé : $path" 'OK'; Open-Path $path }
    else { Write-Log "Le rapport n'a pas pu être créé." 'WARN' }
}

function New-BatteryReport {
    Write-Log "=== Rapport de batterie ==="
    if (-not (Test-HasBattery)) { Write-Log "Aucune batterie détectée sur ce PC." 'WARN'; return }
    $path = Get-ReportPath 'Batterie' 'html'
    [void](Invoke-NativeLines 'powercfg.exe' "/batteryreport /output `"$path`"")
    if (Test-Path $path) { Write-Log "Rapport créé : $path" 'OK'; Open-Path $path }
    else { Write-Log "Le rapport n'a pas pu être créé." 'WARN' }
}

# ---------------------------------------------------------------- Réseau
function Test-NetworkQuality {
    Write-Log "=== Qualité de la connexion ==="
    $gw = $null
    try { $gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object RouteMetric | Select-Object -First 1).NextHop } catch {}
    $targets = @()
    if ($gw -and $gw -ne '0.0.0.0') { $targets += @{ Name = 'Passerelle (routeur)'; Host = [string]$gw } }
    $targets += @{ Name = 'Internet (1.1.1.1)'; Host = '1.1.1.1' }
    $targets += @{ Name = 'Internet (9.9.9.9)'; Host = '9.9.9.9' }
    $count = 8
    foreach ($t in $targets) {
        $r = @(Test-Connection -ComputerName $t.Host -Count $count -ErrorAction SilentlyContinue)
        if ($r.Count -eq 0) { Write-Row $t.Name "aucune réponse (le ping est peut-être bloqué)" 'warn'; continue }
        $times = @()
        foreach ($x in $r) {
            if ($null -ne $x.ResponseTime) { $times += [double]$x.ResponseTime }
            elseif ($null -ne $x.Latency) { $times += [double]$x.Latency }
        }
        if ($times.Count -eq 0) { Write-Row $t.Name "réponses sans mesure de temps" 'warn'; continue }
        $m = $times | Measure-Object -Average -Maximum -Minimum
        $loss = [math]::Round((($count - $r.Count) / $count) * 100)
        $text = "{0:N0} ms en moyenne (min {1:N0}, max {2:N0}) · perte {3} %" -f $m.Average, $m.Minimum, $m.Maximum, $loss
        $state = 'ok'
        if ($loss -gt 0 -or ($m.Maximum - $m.Minimum) -gt 60) { $state = 'warn' }
        if ($loss -ge 25 -or $m.Average -gt 150) { $state = 'bad' }
        Write-Row $t.Name $text $state
    }
    foreach ($n in @('www.wikipedia.org', 'www.mozilla.org')) {
        try {
            $ms = (Measure-Command { Resolve-DnsName -Name $n -Type A -DnsOnly -ErrorAction Stop | Out-Null }).TotalMilliseconds
            Write-Row ("Résolution DNS {0}" -f $n) ("{0:N0} ms" -f $ms) $(if ($ms -gt 300) { 'warn' } else { 'ok' })
        } catch { Write-Row ("Résolution DNS {0}" -f $n) "échec" 'bad' }
    }
    Write-Host ""
    Write-Host "  Une perte même faible ou une grande variation (gigue) gêne le jeu en ligne : tester en Ethernet pour comparer au Wi-Fi." -ForegroundColor DarkGray
}

function Get-WifiInfo {
    Write-Log "=== Connexion Wi-Fi actuelle ==="
    $lines = @(Invoke-NativeLines 'netsh.exe' 'wlan show interfaces')
    if ($lines.Count -eq 0) { Write-Log "Aucune information Wi-Fi (pas d'interface sans fil ou service WLAN arrêté)." 'WARN'; return }
    foreach ($l in $lines) { Write-Host ("  " + $l.Trim()) -ForegroundColor Gray }
}

function New-WlanReport {
    Write-Log "=== Rapport Wi-Fi des 3 derniers jours ==="
    [void](Invoke-NativeLines 'netsh.exe' 'wlan show wlanreport')
    $src = Join-Path $env:ProgramData 'Microsoft\Windows\WlanReport\wlan-report-latest.html'
    if (Test-Path $src) {
        $dst = Get-ReportPath 'Wifi' 'html'
        Copy-Item -Path $src -Destination $dst -Force -ErrorAction SilentlyContinue
        if (Test-Path $dst) { Write-Log "Rapport créé : $dst" 'OK'; Open-Path $dst } else { Open-Path $src }
    } else { Write-Log "Rapport indisponible (pas de carte Wi-Fi ?)." 'WARN' }
}

function Clear-DnsCache {
    Write-Log "Vidage du cache DNS"
    try { Clear-DnsClientCache -ErrorAction Stop; Write-Log "Cache DNS vidé" 'OK' }
    catch { [void](Invoke-NativeLines 'ipconfig.exe' '/flushdns'); Write-Log "Cache DNS vidé (ipconfig)" 'OK' }
}

# ---------------------------------------------------------------- Sécurité et mises à jour
function Get-SecurityAudit {
    Write-Log "=== Audit de sécurité (lecture seule) ==="
    Write-Host ""
    try {
        $tpm = Get-Tpm -ErrorAction Stop
        Write-Row "Puce TPM" $(if ($tpm.TpmPresent -and $tpm.TpmReady) { 'présente et prête' } elseif ($tpm.TpmPresent) { 'présente, non prête' } else { 'absente' }) $(if ($tpm.TpmPresent -and $tpm.TpmReady) { 'ok' } else { 'warn' })
    } catch { Write-Row "Puce TPM" "information indisponible" 'warn' }
    try {
        $sb = Confirm-SecureBootUEFI -ErrorAction Stop
        Write-Row "Démarrage sécurisé (Secure Boot)" $(if ($sb) { 'activé' } else { 'désactivé' }) $(if ($sb) { 'ok' } else { 'warn' })
    } catch { Write-Row "Démarrage sécurisé (Secure Boot)" "non disponible (BIOS hérité ?)" 'warn' }
    try {
        $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
        $on = ([string]$bl.ProtectionStatus -eq 'On' -or [string]$bl.ProtectionStatus -eq '1')
        Write-Row "Chiffrement BitLocker (disque système)" $(if ($on) { 'actif' } else { 'inactif' }) $(if ($on) { 'ok' } else { 'warn' })
    } catch { Write-Row "Chiffrement BitLocker (disque système)" "non disponible sur cette édition" '' }
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        Write-Row "Antivirus Defender" $(if ($mp.AntivirusEnabled) { 'activé' } else { 'désactivé' }) $(if ($mp.AntivirusEnabled) { 'ok' } else { 'bad' })
        Write-Row "Protection en temps réel" $(if ($mp.RealTimeProtectionEnabled) { 'activée' } else { 'désactivée' }) $(if ($mp.RealTimeProtectionEnabled) { 'ok' } else { 'bad' })
        $age = [int]$mp.AntivirusSignatureAge
        Write-Row "Signatures antivirus" ("{0} jour(s)" -f $age) $(if ($age -le 3) { 'ok' } elseif ($age -le 7) { 'warn' } else { 'bad' })
    } catch { Write-Row "Antivirus Defender" "information indisponible (autre antivirus installé ?)" 'warn' }
    try {
        foreach ($p in @(Get-NetFirewallProfile -ErrorAction Stop)) {
            $en = ([string]$p.Enabled -eq 'True')
            Write-Row ("Pare-feu · profil {0}" -f $p.Name) $(if ($en) { 'activé' } else { 'désactivé' }) $(if ($en) { 'ok' } else { 'bad' })
        }
    } catch { Write-Row "Pare-feu" "information indisponible" 'warn' }
    $lua = Get-RegVal 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableLUA'
    Write-Row "Contrôle de compte d'utilisateur (UAC)" $(if ($lua -eq 0) { 'désactivé' } else { 'activé' }) $(if ($lua -eq 0) { 'bad' } else { 'ok' })
    try {
        $smb = Get-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -ErrorAction Stop
        $smbOn = ([string]$smb.State -eq 'Enabled')
        Write-Row "Protocole SMBv1 (obsolète)" $(if ($smbOn) { 'activé' } else { 'désactivé' }) $(if ($smbOn) { 'bad' } else { 'ok' })
    } catch { Write-Row "Protocole SMBv1 (obsolète)" "information indisponible" '' }
    $rdp = Get-RegVal 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' 'fDenyTSConnections'
    if ($null -ne $rdp) { Write-Row "Bureau à distance (RDP)" $(if ($rdp -eq 1) { 'désactivé' } else { 'activé' }) $(if ($rdp -eq 1) { 'ok' } else { 'warn' }) }
    $pending = $false
    foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')) {
        if (Test-Path $k) { $pending = $true }
    }
    if (Get-RegVal 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' 'PendingFileRenameOperations') { $pending = $true }
    Write-Row "Redémarrage en attente" $(if ($pending) { 'oui (mises à jour ou installation)' } else { 'non' }) $(if ($pending) { 'warn' } else { 'ok' })
    try {
        $drive = $env:SystemDrive.TrimEnd(':')
        $vol = Get-Volume -DriveLetter $drive -ErrorAction Stop
        $pct = [math]::Round(($vol.SizeRemaining / $vol.Size) * 100)
        Write-Row ("Espace libre sur {0}:" -f $drive) ("{0:N0} Go libres ({1} %)" -f ($vol.SizeRemaining / 1GB), $pct) $(if ($pct -lt 10) { 'bad' } elseif ($pct -lt 20) { 'warn' } else { 'ok' })
    } catch {}
    Write-Host ""
    Write-Host "  Vert : correct. Orange : à vérifier. Rouge : à corriger. Aucune modification n'a été faite." -ForegroundColor DarkGray
}

function Get-PendingUpdates {
    Write-Log "=== Mises à jour Windows en attente (recherche, peut prendre une minute) ==="
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $res = $searcher.Search("IsInstalled=0 and IsHidden=0")
        if ($res.Updates.Count -eq 0) { Write-Log "Windows est à jour." 'OK'; return }
        Write-Log ("{0} mise(s) à jour disponible(s) :" -f $res.Updates.Count) 'WARN'
        foreach ($u in $res.Updates) { Write-Host ("   - {0}" -f $u.Title) -ForegroundColor Gray }
        Write-Host ""
        Write-Host "  Installation : Paramètres > Windows Update." -ForegroundColor DarkGray
    } catch { Write-Log "Recherche impossible : $($_.Exception.Message)" 'WARN' }
}

# ---------------------------------------------------------------- Logiciels et pilotes
function Test-Winget {
    return [bool](Get-Command winget.exe -ErrorAction SilentlyContinue)
}

function Invoke-Winget {
    param([string]$Arguments)
    $old = $null
    try { $old = [Console]::OutputEncoding; [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
    Write-Log "Exécution : winget $Arguments"
    try {
        & cmd.exe /c "winget.exe $Arguments 2>&1" | ForEach-Object {
            $l = ("$_" -replace "`r", '' -replace "`0", '').TrimEnd()
            if ($l -match '^[\s\-\\|/]*$') { return }
            Write-Host "        $l" -ForegroundColor DarkGray
        }
        $Script:LastWingetCode = $LASTEXITCODE
        Write-Log "Code retour : $LASTEXITCODE" $(if ($LASTEXITCODE -eq 0) { 'OK' } else { 'WARN' })
    } finally {
        if ($old) { try { [Console]::OutputEncoding = $old } catch {} }
    }
}

function Get-WingetUpdates {
    Write-Log "=== Applications pouvant être mises à jour (winget) ==="
    if (-not (Test-Winget)) { Write-Log "winget n'est pas installé (paquet « Programme d'installation d'application » du Microsoft Store)." 'WARN'; return }
    Invoke-Winget 'upgrade --accept-source-agreements --disable-interactivity'
}

function Update-WingetApps {
    Write-Log "=== Mise à jour de toutes les applications (winget) ==="
    if (-not (Test-Winget)) { Write-Log "winget n'est pas installé (paquet « Programme d'installation d'application » du Microsoft Store)." 'WARN'; return }
    Invoke-Winget 'upgrade --all --silent --accept-package-agreements --accept-source-agreements --disable-interactivity'
    Write-Log "Mises à jour terminées. Certaines applications demandent d'être fermées pour se mettre à jour." 'OK'
}

function Export-InstalledSoftware {
    Write-Log "=== Inventaire des logiciels installés ==="
    $paths = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')
    $apps = @(Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and -not $_.SystemComponent } |
        Select-Object @{ n = 'Nom'; e = { $_.DisplayName } }, @{ n = 'Version'; e = { $_.DisplayVersion } }, @{ n = 'Editeur'; e = { $_.Publisher } }, @{ n = 'InstalleLe'; e = { $_.InstallDate } } |
        Sort-Object Nom -Unique)
    if ($apps.Count -eq 0) { Write-Log "Aucun logiciel trouvé." 'WARN'; return }
    $path = Get-ReportPath 'Logiciels' 'csv'
    $apps | Export-Csv -Path $path -NoTypeInformation -Encoding UTF8 -Delimiter ';'
    Write-Log ("{0} logiciels exportés : {1}" -f $apps.Count, $path) 'OK'
    Start-Process explorer.exe "/select,`"$path`""
}

function Export-DriversBackup {
    Write-Log "=== Sauvegarde des pilotes tiers installés ==="
    $dest = Join-Path $Script:LogDir ("Pilotes\{0}_{1}" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    try {
        New-Item -ItemType Directory -Path $dest -Force -ErrorAction Stop | Out-Null
        $out = @(Export-WindowsDriver -Online -Destination $dest -ErrorAction Stop)
        Write-Log ("{0} pilote(s) exporté(s) dans {1}" -f $out.Count, $dest) 'OK'
        Write-Host "  Pour les réinjecter : pnputil /add-driver `"$dest\*.inf`" /subdirs /install" -ForegroundColor DarkGray
        Start-Process explorer.exe "`"$dest`""
    } catch { Write-Log "Export impossible : $($_.Exception.Message)" 'ERROR' }
}

# ---------------------------------------------------------------- Magasin de pilotes (à la manière de Driver Store Explorer)
function Set-SyncResult {
    param($Value)
    $sv = Get-Variable -Name Sync -ErrorAction SilentlyContinue
    if ($sv) { $sv.Value.Result = $Value }
}

function Get-DriverStoreList {
    # Liste les pilotes tiers du magasin Windows (oemNN.inf), avec leur taille, leur appareil, et repère
    # les anciennes versions (une version plus récente existe et celle-ci n'est pas utilisée).
    Write-Log '=== Magasin de pilotes (pilotes tiers installés) ==='
    $drv = @()
    try { $drv = @(Get-WindowsDriver -Online -All -ErrorAction Stop | Where-Object { $_.Driver -match '^oem\d+\.inf$' }) }
    catch { Write-Log ("Lecture impossible (droits administrateur requis ?) : " + $_.Exception.Message) 'WARN'; return }
    $present = @{}
    try { foreach ($d in @(Get-PnpDevice -PresentOnly -ErrorAction Stop)) { $present[[string]$d.InstanceId] = 1 } } catch {}
    $used = @{}
    try {
        foreach ($d in @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop)) {
            if (-not $d.InfName) { continue }
            if ($present.Count -gt 0 -and -not $present.ContainsKey([string]$d.DeviceID)) { continue }
            $k = ([string]$d.InfName).ToLower()
            if (-not $used.ContainsKey($k)) { $used[$k] = New-Object System.Collections.ArrayList }
            if ($d.DeviceName -and $used[$k].Count -lt 3) { [void]$used[$k].Add([string]$d.DeviceName) }
        }
    } catch { Write-Log ("Association aux appareils impossible : " + $_.Exception.Message) 'WARN' }
    $groups = @{}
    foreach ($d in $drv) {
        $leaf = ''
        try { $leaf = (Split-Path ([string]$d.OriginalFileName) -Leaf).ToLower() } catch {}
        $key = $leaf + '|' + [string]$d.ProviderName + '|' + [string]$d.ClassName
        if (-not $groups.ContainsKey($key)) { $groups[$key] = New-Object System.Collections.ArrayList }
        [void]$groups[$key].Add($d)
    }
    $rows = New-Object System.Collections.ArrayList
    foreach ($key in $groups.Keys) {
        $sorted = @($groups[$key] | Sort-Object @{ Expression = { $_.Date }; Descending = $true }, @{ Expression = { $_.Version }; Descending = $true })
        for ($i = 0; $i -lt $sorted.Count; $i++) {
            $d = $sorted[$i]
            $inf = ([string]$d.Driver).ToLower()
            $inUse = $used.ContainsKey($inf)
            $size = 0
            try { $size = Get-FolderBytes (Split-Path ([string]$d.OriginalFileName) -Parent) } catch {}
            $dateTxt = ''; try { $dateTxt = ([datetime]$d.Date).ToString('yyyy-MM-dd') } catch {}
            $dev = ''; if ($inUse) { $dev = (@($used[$inf]) -join ', ') }
            [void]$rows.Add([pscustomobject]@{
                Inf = $inf; Provider = [string]$d.ProviderName; Class = [string]$d.ClassName; Version = [string]$d.Version; Date = $dateTxt
                SizeMB = [math]::Round($size / 1MB, 1); Device = $dev; InUse = $inUse; Old = ([bool]($i -gt 0 -and -not $inUse -and $leaf -ne 'ntprint.inf')); Boot = [bool]$d.BootCritical
            })
        }
    }
    $list = @($rows | Sort-Object Class, Provider, Inf)
    $old = @($list | Where-Object { $_.Old }); $unused = @($list | Where-Object { -not $_.InUse })
    Write-Log ("{0} pilote(s) tiers : {1} utilisé(s), {2} ancienne(s) version(s) ({3} Mo), {4} sans appareil branché." -f $list.Count, @($list | Where-Object { $_.InUse }).Count, $old.Count, [math]::Round((($old | Measure-Object -Property SizeMB -Sum).Sum), 1), $unused.Count) 'OK'
    Set-SyncResult $list
}

function Remove-DriverPackages {
    # Supprime des pilotes tiers du magasin, APRÈS en avoir exporté une copie dans C:\BJMPC-Logs\Pilotes\Suppression_*.
    # Sans l'option force : Windows refuse de supprimer un pilote utilisé par un appareil.
    param([string[]]$Infs)
    $ok = @(); $ko = @()
    $dest = Join-Path $Script:LogDir ("Pilotes\Suppression_{0}_{1}" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $boot = @{}
    try { foreach ($d in @(Get-WindowsDriver -Online -All -ErrorAction Stop)) { if ($d.BootCritical) { $boot[([string]$d.Driver).ToLower()] = 1 } } } catch {}
    try { New-Item -ItemType Directory -Path $dest -Force -ErrorAction Stop | Out-Null }
    catch { Write-Log ("Dossier de sauvegarde impossible : " + $_.Exception.Message) 'ERROR'; Set-SyncResult @{ Ok = @(); Bad = @($Infs); Backup = '' }; return }
    foreach ($n in $Infs) {
        $inf = ([string]$n).ToLower()
        if ($inf -notmatch '^oem\d+\.inf$') { Write-Log "Nom refusé : $n" 'WARN'; $ko += $n; continue }
        if ($boot.ContainsKey($inf)) { Write-Log "Pilote nécessaire au démarrage, ignoré : $inf" 'WARN'; $ko += $inf; continue }
        $sub = Join-Path $dest ($inf -replace '\.inf$', '')
        New-Item -ItemType Directory -Path $sub -Force | Out-Null
        [void](Invoke-NativeLines 'pnputil.exe' ('/export-driver ' + $inf + ' "' + $sub + '"'))
        if (-not (Get-ChildItem -LiteralPath $sub -Filter *.inf -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1)) {
            Write-Log "Sauvegarde impossible, pilote conservé : $inf" 'WARN'; $ko += $inf; continue
        }
        $out = Invoke-NativeLines 'pnputil.exe' ('/delete-driver ' + $inf)
        $code = $LASTEXITCODE
        if (($code -eq 0 -or $code -eq 3010) -and -not (Test-Path -LiteralPath (Join-Path $env:windir "INF\$inf"))) {
            Write-Log "Supprimé : $inf" 'OK'; $ok += $inf
            if ($code -eq 3010) { $Script:RebootNeeded = $true }
        } else {
            Write-Log ("Refusé par Windows (pilote probablement utilisé) : {0}" -f $inf) 'WARN'
            foreach ($l in @($out | Select-Object -First 2)) { Write-Host ("   " + $l) -ForegroundColor DarkGray }
            $ko += $inf
        }
    }
    Write-Log ("{0} pilote(s) supprimé(s), {1} conservé(s) ou refusé(s)." -f $ok.Count, $ko.Count) $(if ($ko.Count -eq 0) { 'OK' } else { 'WARN' })
    if ($ok.Count -gt 0) {
        Write-Host ("  Copie de sécurité : {0}" -f $dest) -ForegroundColor DarkGray
        Write-Host "  Pour restaurer : page Pilotes > Restaurer une sauvegarde." -ForegroundColor DarkGray
    }
    Set-SyncResult @{ Ok = @($ok); Bad = @($ko); Backup = $dest }
}

function Restore-DriverBackup {
    # Réinstalle les pilotes d'un dossier de sauvegarde créé par la Toolbox (C:\BJMPC-Logs\Pilotes\<nom>).
    param([string]$Name)
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9_.\-]*$') { Write-Log "Nom de sauvegarde refusé : $Name" 'ERROR'; return }
    $root = Join-Path $Script:LogDir 'Pilotes'
    $dir = Join-Path $root $Name
    if (-not (Test-Path -LiteralPath $dir)) { Write-Log "Sauvegarde introuvable : $dir" 'ERROR'; return }
    Write-Log "=== Restauration des pilotes depuis $Name ==="
    $done = @(); $failed = @()
    # 1. Sauvegarde faite avant une mise à jour : on retire d'abord le pilote installé à ce moment-là. Sans cela,
    #    Windows garderait le plus récent des deux et « restaurer » ne changerait rien.
    $rec = Join-Path $dir 'maj.json'
    if (Test-Path -LiteralPath $rec) {
        $list = $null
        try { $list = Get-Content -LiteralPath $rec -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
        foreach ($r in @($list)) {
            $n = ([string]$r.NewInf).ToLower()
            if ($n -notmatch '^oem\d+\.inf$') { continue }
            $p = Join-Path $env:windir ("INF\" + $n)
            if (-not (Test-Path -LiteralPath $p)) { Write-Log ("Le pilote installé à l'époque ({0}) n'est déjà plus dans le magasin." -f $n); continue }
            # Windows réattribue les numéros oemNN : on ne retire le paquet que si c'est bien le même fichier.
            $h = ''; try { $h = [string](Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash } catch {}
            if (-not $r.Hash -or $h -ne [string]$r.Hash) { Write-Log ("{0} n'est plus le pilote installé à l'époque (numéro réattribué par Windows) : laissé en place." -f $n) 'WARN'; continue }
            [void](Invoke-NativeLines 'pnputil.exe' ('/delete-driver ' + $n + ' /uninstall'))
            $c = $LASTEXITCODE
            if ($c -eq 0 -or $c -eq 3010) { Write-Log ("Pilote récent retiré : {0} ({1})" -f $n, [string]$r.Device) 'OK'; $done += $n; if ($c -eq 3010) { $Script:RebootNeeded = $true } }
            else { Write-Log ("Retrait de {0} refusé par Windows (code {1})." -f $n, $c) 'WARN'; $failed += $n }
        }
    }
    # 2. Chaque pilote de la sauvegarde est recontrôlé (signature valide, architecture) avant d'être remis.
    $infs = @(Get-ChildItem -LiteralPath $dir -Filter *.inf -Recurse -ErrorAction SilentlyContinue)
    foreach ($f in $infs) {
        $t = Test-DriverPackage -Dir $f.DirectoryName -HwIds @() -InstalledVersion '' -ClassGuid '' -OnlyInf $f.FullName -Level 3
        if (-not $t.Ok) { Write-Log ("Écarté, non conforme : {0} ({1})" -f $f.Name, [string](@($t.Reasons) | Select-Object -First 1)) 'WARN'; $failed += $f.Name; continue }
        [void](Invoke-NativeLines 'pnputil.exe' ('/add-driver "' + $f.FullName + '" /install'))
        $c = $LASTEXITCODE
        if ($c -eq 0 -or $c -eq 3010) { $done += $f.Name; if ($c -eq 3010) { $Script:RebootNeeded = $true } }
        elseif ($c -eq 259) { Write-Log ("{0} : remis dans le magasin ; Windows garde le pilote en place, qu'il juge au moins aussi bon." -f $f.Name) }
        else { Write-Log ("{0} : refusé par Windows (code {1})." -f $f.Name, $c) 'WARN'; $failed += $f.Name }
    }
    if ($infs.Count -eq 0 -and (Test-Path -LiteralPath $rec)) { Write-Log 'Aucun ancien pilote à remettre : Windows reprend le pilote précédent ou son pilote générique.' }
    Write-Log ("Restauration terminée : {0} opération(s) réussie(s), {1} en échec ou écartée(s)." -f $done.Count, $failed.Count) $(if ($failed.Count -eq 0) { 'OK' } else { 'WARN' })
    Set-SyncResult @{ Ok = @($done); Bad = @($failed); Reboot = [bool]$Script:RebootNeeded }
}

function Save-DriverUpdateRecord {
    # Note, dans le dossier de sauvegarde d'une mise à jour, quel paquet vient d'être installé (avec l'empreinte de son
    # INF) : c'est ce qui permet à la restauration de le retirer.
    param([string]$Folder, [string]$Device, [string]$OldInf, [string[]]$NewInfs)
    try {
        New-Item -ItemType Directory -Path $Folder -Force -ErrorAction Stop | Out-Null
        $file = Join-Path $Folder 'maj.json'
        $old = $null
        if (Test-Path -LiteralPath $file) { try { $old = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
        $list = @($old | Where-Object { $_ })
        foreach ($n in @($NewInfs)) {
            if ([string]$n -notmatch '^oem\d+\.inf$') { continue }
            $h = ''; try { $h = [string](Get-FileHash -LiteralPath (Join-Path $env:windir ("INF\" + $n)) -Algorithm SHA256).Hash } catch {}
            $list += [pscustomobject]@{ Device = $Device; OldInf = $OldInf; NewInf = [string]$n; Hash = $h; Date = (Get-Date -Format 's') }
        }
        if ($list.Count -gt 0) { Set-Content -LiteralPath $file -Value (ConvertTo-Json -InputObject @($list) -Depth 3) -Encoding UTF8 -ErrorAction Stop }
    } catch { Write-Log ("Note de mise à jour non enregistrée : " + $_.Exception.Message) 'WARN' }
}

function Get-PresentHardwareIndex {
    # Identifiant matériel (en majuscules) -> appareils branchés qui le portent.
    $idx = @{}
    try {
        foreach ($e in @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop)) {
            if ($e.Present -eq $false) { continue }
            foreach ($h in @($e.HardwareID)) {
                if (-not $h) { continue }
                $k = ([string]$h).ToUpper()
                if (-not $idx.ContainsKey($k)) { $idx[$k] = New-Object System.Collections.ArrayList }
                [void]$idx[$k].Add([string]$e.PNPDeviceID)
            }
        }
    } catch { Write-Log ("Liste des appareils branchés : " + $_.Exception.Message) 'WARN' }
    return $idx
}

function Get-InfDeviceMatches {
    # Appareils branchés que cet INF déclare (identifiants matériels exacts lus dans le fichier).
    param([string]$InfPath, $Index)
    $txt = ''
    try { $txt = [IO.File]::ReadAllText($InfPath) } catch { return @() }
    $hit = @{}
    foreach ($line in ($txt -split "`n")) {
        $i = $line.IndexOf('=')
        if ($i -lt 0) { continue }
        foreach ($tok in ($line.Substring($i + 1) -split '[,;]')) {
            $k = $tok.Trim().Trim('"').ToUpper()
            if ($k.Length -ge 4 -and $Index.ContainsKey($k)) { foreach ($d in $Index[$k]) { $hit[[string]$d] = 1 } }
        }
    }
    return @($hit.Keys)
}

# ---------------------------------------------------------------- Contrôle des paquets de pilotes (ajout depuis un dossier, restauration)
# Seule compte la signature Microsoft du fichier .cat, vérifiée ici AVANT toute installation, puis revérifiée par
# Windows lui-même (pnputil, sans /force). Dossier de travail sous C:\BJMPC-Logs, réservé aux administrateurs.
$Script:DrvTmp = Join-Path (Join-Path $env:SystemDrive 'BJMPC-Logs') 'Travail\pilotes'

function New-DriverRestorePoint {
    # Rend $true seulement si un point de restauration de moins de 10 minutes existe réellement après l'appel :
    # Windows peut refuser sans erreur (un seul point par 24 h par défaut, protection du système désactivée).
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Name SystemRestorePointCreationFrequency -Value 0 -Type DWord -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description ("BJMPC Pilotes " + (Get-Date -Format 'yyyy-MM-dd HH:mm')) -RestorePointType MODIFY_SETTINGS -ErrorAction Stop -WarningAction SilentlyContinue
        $last = Get-ComputerRestorePoint -ErrorAction Stop | Sort-Object CreationTime -Descending | Select-Object -First 1
        if ($last -and ((Get-Date) - [Management.ManagementDateTimeConverter]::ToDateTime($last.CreationTime)).TotalMinutes -le 10) { Write-Log 'Point de restauration créé.' 'OK'; return $true }
        Write-Log 'Windows n''a pas créé de point de restauration (aucun point récent trouvé après la demande).' 'WARN'
        return $false
    } catch { Write-Log ("Point de restauration non créé (protection du système désactivée ?) : " + $_.Exception.Message) 'WARN'; return $false }
}

function ConvertTo-SafeVersion {
    param([string]$Text)
    $v = $null
    if ($Text -and [version]::TryParse(($Text.Trim()), [ref]$v)) { return $v }
    return $null
}

function Test-CandidateNewer {
    # Un paquet du Catalog est-il plus récent que le pilote installé ?
    # Même famille (même numéro majeur) : on compare les versions. Familles différentes (une même puce a souvent deux
    # pilotes aux numérotations sans rapport, par exemple 1168.x et 10.x, ou le pilote générique Microsoft 10.0.x face
    # au pilote du fabricant 6.0.x) : un numéro plus grand ne veut rien dire, on compare les dates, comme Windows.
    param($C, $InstalledVersion, $InstalledDate)
    if (-not $InstalledVersion) { return $true }
    if ($InstalledDate -and $C.V.Major -ne $InstalledVersion.Major) {
        $cd = $null; try { $cd = [datetime]$C.R.Date } catch {}
        if ($cd -and $cd -gt [datetime]'1990-01-01') { return ($cd.Date -gt ([datetime]$InstalledDate).Date) }
    }
    return ($C.V -gt $InstalledVersion)
}

function Select-BestCandidate {
    # Le plus récent d'abord (date, puis version). Le contrôle de l'INF (Test-DriverPackage) reste seul juge.
    param($Cands, $InstalledVersion, $InstalledDate = $null)
    $best = $null
    foreach ($c in @($Cands)) {
        if (-not (Test-CandidateNewer $c $InstalledVersion $InstalledDate)) { continue }
        if ($null -eq $best -or $c.R.Date -gt $best.R.Date -or ($c.R.Date -eq $best.R.Date -and $c.V -gt $best.V)) { $best = $c }
    }
    return $best
}

function Get-CandidateGuids {
    # Les résultats du Catalog sont approximatifs : plusieurs paquets différents (même titre, tailles différentes) partagent
    # le même mot-clé. On garde les meilleurs paquets distincts (plus récents que l'installé) pour les essayer l'un après l'autre.
    param($Cands, $InstalledVersion, [int]$Max = 6, $InstalledDate = $null)
    $seenKey = @{}; $g = New-Object System.Collections.ArrayList
    foreach ($c in @($Cands | Sort-Object @{ Expression = { $_.R.Date }; Descending = $true }, @{ Expression = { $_.V }; Descending = $true })) {
        if (-not (Test-CandidateNewer $c $InstalledVersion $InstalledDate)) { continue }
        $k = ([string]$c.R.Title + '|' + [string]$c.R.SizeMB + '|' + [string]$c.V)
        if ($seenKey.ContainsKey($k)) { continue }
        $seenKey[$k] = 1
        [void]$g.Add([string]$c.R.Guid)
        if ($g.Count -ge $Max) { break }
    }
    return @($g)
}

function Test-DriverPackage {
    # Contrôle strict d'un dossier de pilote. Retourne @{ Ok; Reasons; Report; Inf; Version; Date }.
    # Refus si : signature .cat absente/invalide/non Microsoft WHQL ; architecture ; identifiant matériel absent de l'INF ;
    # classe différente ; version non plus récente que celle installée.
    param([string]$Dir, [string[]]$HwIds, [string]$InstalledVersion, [string]$ClassGuid, [string]$OnlyInf, [string[]]$CompatIds = @(), [int]$Level = 1, $InstalledDate = $null)
    $rep = New-Object System.Collections.ArrayList
    $bad = New-Object System.Collections.ArrayList
    # Les identifiants de CLASSE (PCI\CC_0C0330, USB\Class_03…) sont communs à des milliers d'appareils : ils ne
    # prouvent jamais qu'un INF concerne celui-ci, même au niveau élargi.
    $CompatIds = @($CompatIds | Where-Object { $_ -and ([string]$_) -notmatch '(?i)[&\\]CC_|Class_|^[A-Za-z]+\\VEN_[0-9A-F]{4}$' })
    $instD = $null; if ($InstalledDate) { try { $instD = ([datetime]$InstalledDate).Date } catch {} }
    $result = @{ Ok = $false; Reasons = @(); Report = @(); Inf = ''; Version = ''; Date = '' }
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'ntarm64' } else { 'ntamd64' }
    $infs = @(Get-ChildItem -LiteralPath $Dir -Filter *.inf -Recurse -ErrorAction SilentlyContinue)
    if ($infs.Count -eq 0) { [void]$bad.Add('Aucun fichier .inf dans le paquet'); $result.Reasons = @($bad); return $result }
    $cands = @()
    $chip = @()
    if ($Level -ge 1) {
        # Identifiant de puce (VEN_xxxx&DEV_xxxx / VID_xxxx&PID_xxxx) : les éditeurs écrivent SUBSYS / CC_ / REV à leur
        # guise, donc ils ne sont jamais exigés. Windows reste seul juge du rang du pilote à l'installation.
        foreach ($h in @(@($HwIds) + $(if ($Level -ge 2) { @($CompatIds) } else { @() }))) { if ([string]$h -match '(VEN_[0-9A-Fa-f]{4}&DEV_[0-9A-Fa-f]{4}|VID_[0-9A-Fa-f]{4}&PID_[0-9A-Fa-f]{4})') { $chip += $Matches[1] } }
        $chip = @($chip | Select-Object -Unique)
    }
    foreach ($f in $infs) {
        if ($OnlyInf -and $f.FullName -ne $OnlyInf) { continue }
        $txt = ''
        try { $txt = [IO.File]::ReadAllText($f.FullName) } catch { continue }
        if ($txt -notmatch '(?i)\[Version\]') { continue }
        $ids = @($HwIds | Where-Object { $_ })
        if ($Level -ge 2) { $ids += @($CompatIds | Where-Object { $_ }) }
        if ($ids.Count -gt 0) {
            $hit = $false
            foreach ($h in $ids) { if ($txt -match ('(?im)(^|[\s,=])' + [regex]::Escape($h) + '(\s|,|;|$)')) { $hit = $true; break } }
            if (-not $hit -and $Level -ge 1) {
                # L'identifiant de puce (VEN_xxxx&DEV_xxxx ou VID_xxxx&PID_xxxx) suffit, même si l'INF
                # ne liste que des variantes SUBSYS/REV. Windows choisit ensuite lui-même s'il applique ce pilote.
                foreach ($h in $chip) { if ($txt -match ('(?i)' + [regex]::Escape($h) + '(?![0-9A-Fa-f])')) { $hit = $true; $result.ViaChip = $true; break } }
            }
            if (-not $hit -and $Level -lt 3) { continue }
        }
        $cands += , @($f, $txt)
    }
    if ($cands.Count -eq 0) { [void]$bad.Add('Aucun INF du paquet ne déclare l''identifiant matériel de cet appareil' + $(if ($Level -ge 2) { ' (ni ses identifiants compatibles)' } else { '' })); $result.Reasons = @($bad); return $result }
    [void]$rep.Add(("Niveau d'analyse {0} : {1}" -f $Level, $(switch ($Level) { 1 { 'strict (puce exacte VEN/DEV)' } 2 { 'élargi (identifiants compatibles admis)' } default { 'ouvert (signataire non Microsoft admis)' } })))
    [void]$rep.Add(("Correspondance d'identifiant : {0} INF" -f $cands.Count))
    $instV = ConvertTo-SafeVersion $InstalledVersion
    foreach ($c in $cands) {
        $f = $c[0]; $txt = $c[1]; $mine = New-Object System.Collections.ArrayList
        if ($txt -notmatch ('(?i)' + $arch)) { [void]$mine.Add(("{0} : architecture {1} non déclarée" -f $f.Name, $arch)) }
        if ($ClassGuid -and $txt -notmatch ('(?i)ClassGuid\s*=\s*' + [regex]::Escape($ClassGuid))) { [void]$mine.Add(("{0} : classe d'appareil différente" -f $f.Name)) }
        # Appareil sans pilote (classe inconnue) : un INF « Extension » ou « SoftwareComponent » ne fait que compléter
        # un pilote de base. L'accepter donnerait une « mise à jour » qui n'installe rien.
        if (-not $ClassGuid -and @($HwIds | Where-Object { $_ }).Count -gt 0 -and $txt -match '(?im)^\s*Class\s*=\s*"?(Extension|SoftwareComponent)\b') { [void]$mine.Add(("{0} : complément de pilote (classe {1}), pas le pilote de l'appareil" -f $f.Name, $Matches[1])) }
        $dv = $null; $dd = ''
        if ($txt -match '(?im)^\s*DriverVer\s*=\s*([\d/]+)\s*,\s*([\d\.]+)') { $dd = $Matches[1]; $dv = ConvertTo-SafeVersion $Matches[2] } else { [void]$mine.Add(("{0} : DriverVer illisible" -f $f.Name)) }
        $infD = $null
        if ($dd) { try { $infD = [datetime]::ParseExact($dd, [string[]]@('M/d/yyyy', 'MM/dd/yyyy'), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None) } catch {} }
        if ($dv -and $instV) {
            if ($infD -and $instD -and $dv.Major -ne $instV.Major) {
                # Autre famille de pilote (numérotation sans rapport) : c'est la date qui départage, comme le fait Windows.
                if ($infD -le $instD) { [void]$mine.Add(("{0} : pilote du {1:dd/MM/yyyy} (v{2}), pas plus récent que l'installé du {3:dd/MM/yyyy} (v{4})" -f $f.Name, $infD, $dv, $instD, $instV)) }
            } elseif ($dv -le $instV) { [void]$mine.Add(("{0} : version {1} pas plus récente que {2}" -f $f.Name, $dv, $instV)) }
        }
        $catName = ''
        if ($txt -match '(?im)^\s*CatalogFile(\.NT\w+)?\s*=\s*([^\s;]+)') { $catName = $Matches[2] }
        if (-not $catName) { [void]$mine.Add(("{0} : aucun fichier catalogue (non signé)" -f $f.Name)) }
        else {
            $cat = Get-ChildItem -LiteralPath $f.DirectoryName -Filter $catName -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $cat) { $cat = Get-ChildItem -LiteralPath $Dir -Filter $catName -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 }
            if (-not $cat) { [void]$mine.Add(("{0} : catalogue {1} manquant" -f $f.Name, $catName)) }
            else {
                $sig = Get-AuthenticodeSignature -LiteralPath $cat.FullName
                $subj = ''; try { $subj = [string]$sig.SignerCertificate.Subject } catch {}
                if ($sig.Status -ne 'Valid') { [void]$mine.Add(("{0} : signature du catalogue {1} invalide ({2})" -f $f.Name, $catName, $sig.Status)) }
                elseif ($subj -match 'CN=Microsoft Windows Hardware Compatibility Publisher') { [void]$mine.Add('OK'); $result.Cat = $catName }
                elseif ($Level -ge 3) { [void]$mine.Add('OK'); $result.Cat = $catName; $result.NonMs = $true; [void]$rep.Add(("ATTENTION : signature valide mais NON Microsoft WHQL ({0})" -f $subj)) }
                else { [void]$mine.Add(("{0} : catalogue non signé WHQL par Microsoft ({1})" -f $f.Name, $subj)) }
            }
        }
        $problems = @($mine | Where-Object { $_ -ne 'OK' })
        if ($problems.Count -eq 0) {
            $result.Ok = $true; $result.Inf = $f.FullName; $result.Version = [string]$dv; $result.Date = $dd
            if ($result.ViaChip) { [void]$rep.Add('Identifiant de puce (VEN/DEV) reconnu dans l''INF (SUBSYS / CC_ non exigés) ; Windows décidera s''il l''applique.') }
            [void]$rep.Add(("{0} : signature {1} valide, architecture et classe conformes, v{2} ({3})" -f $f.Name, $(if ($result.NonMs) { 'non-WHQL' } else { 'WHQL Microsoft' }), $dv, $dd))
            $result.Report = @($rep); $result.Reasons = @()
            return $result
        }
        foreach ($p in $problems) { [void]$bad.Add($p) }
    }
    $result.Reasons = @($bad); $result.Report = @($rep)
    return $result
}

function Get-DownloadsRoot {
    $p = ''
    try { $p = [string](New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path } catch {}
    if (-not $p -or -not (Test-Path -LiteralPath $p)) { $p = Join-Path $env:USERPROFILE 'Downloads' }
    return $p
}

# ---------------------------------------------------------------- Pilotes : analyse complète et mise à jour (Windows Update)
# Source unique et sûre pour l'installation automatique : Windows Update, qui propose pour CE PC le meilleur pilote
# signé selon l'identifiant exact du matériel (le même classement que Windows : correspondance, signature, date, version).
# Règles ajoutées par la Toolbox :
#   - un pilote proposé n'est jamais installé s'il est plus ancien que le pilote en place, et en particulier
#     jamais à la place d'un pilote fourni par Windows (in-box) plus récent ;
#   - carte graphique : pas de pilote Windows Update, c'est le dernier pilote du fabricant (outil officiel) qui compte ;
#   - appareil sans pilote (SMBus, Serial IO…) : paquet chipset signé (Windows Update, Intel ou AMD), jamais de pilote non signé.
# Après installation : l'ancien pilote est sauvegardé, puis retiré du magasin s'il ne sert plus et que l'appareil fonctionne.
$Script:GpuVendors = @{ '10DE' = 'nvidia'; '1002' = 'amd'; '8086' = 'intel' }

function Get-AllDeviceDrivers {
    # Tous les appareils branchés avec leur pilote actuel (lecture seule). Inbox = pilote fourni par Windows (pas oemNN.inf).
    $rows = New-Object System.Collections.ArrayList
    $sd = @{}
    foreach ($d in @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop)) { if ($d.DeviceID) { $sd[[string]$d.DeviceID] = $d } }
    foreach ($e in @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop)) {
        $id = [string]$e.DeviceID
        if (-not $id -or $e.Present -eq $false) { continue }
        if ($id -match '^(ROOT|SWD|HTREE|UMB|STORAGE\\VOLUME|DISPLAY)\\') { continue }   # appareils logiciels, volumes, écrans
        $d = $sd[$id]
        $code = 0; try { $code = [int]$e.ConfigManagerErrorCode } catch {}
        if (-not $d -and $code -eq 0) { continue }
        $inf = ''; $ver = ''; $date = $null; $prov = ''
        if ($d) {
            $inf = ([string]$d.InfName).ToLower(); $ver = [string]$d.DriverVersion; $prov = [string]$d.DriverProviderName
            try { if ($d.DriverDate) { $date = ([datetime]$d.DriverDate).Date } } catch {}
        }
        $ids = @(@($e.HardwareID) + @($e.CompatibleID) | Where-Object { $_ } | ForEach-Object { ([string]$_).ToUpper() })
        $ven = ''; if ($id -match 'VEN_([0-9A-Fa-f]{4})') { $ven = $Matches[1].ToUpper() }
        $name = [string]$e.Name; if (-not $name -and $d) { $name = [string]$d.DeviceName }; if (-not $name) { $name = $id }
        [void]$rows.Add([pscustomobject]@{
            Id = $id; Name = $name; Class = $(if ($e.PNPClass) { [string]$e.PNPClass } else { 'Autres' }); Inf = $inf; Version = $ver; Date = $date
            Provider = $prov; Inbox = [bool]($inf -and $inf -notmatch '^oem\d+\.inf$'); Problem = $code; Ids = $ids; Ven = $ven
        })
    }
    return @($rows)
}

function Get-WindowsUpdateDriverList {
    # Pilotes que Windows Update propose pour ce PC. Rend @{ Session; Updates (objets COM); Rows }.
    $session = New-Object -ComObject Microsoft.Update.Session
    $res = $session.CreateUpdateSearcher().Search("IsInstalled=0 and IsHidden=0 and Type='Driver'")
    $rows = New-Object System.Collections.ArrayList
    foreach ($u in $res.Updates) {
        $dt = $null; try { $dt = ([datetime]$u.DriverVerDate).Date } catch {}
        $ver = ''; if ([string]$u.Title -match '(\d+(?:\.\d+){2,3})\s*$') { $ver = $Matches[1] }
        $mb = 0; try { $mb = [math]::Round([double]$u.MaxDownloadSize / 1MB, 1) } catch {}
        [void]$rows.Add([pscustomobject]@{
            Id = ([string]$u.Identity.UpdateID).ToLower(); Title = [string]$u.Title; HwId = ([string]$u.DriverHardwareID).ToUpper()
            Date = $dt; Version = $ver; Provider = [string]$u.DriverProvider; Class = [string]$u.DriverClass; SizeMB = $mb
        })
    }
    return @{ Session = $session; Updates = $res.Updates; Rows = @($rows) }
}

function Compare-DriverAge {
    # 1 si le pilote proposé est plus récent que le pilote en place, 0 si identique, -1 s'il est plus ancien.
    # Comme Windows : la date d'abord, puis la version.
    param($NewDate, [string]$NewVersion, $CurDate, [string]$CurVersion)
    if ($null -eq $CurDate) { return 1 }
    if ($null -eq $NewDate) { return -1 }
    if ($NewDate -gt $CurDate) { return 1 }
    if ($NewDate -lt $CurDate) { return -1 }
    $a = ConvertTo-SafeVersion $NewVersion; $b = ConvertTo-SafeVersion $CurVersion
    if ($a -and $b) { if ($a -gt $b) { return 1 } elseif ($a -lt $b) { return -1 } }
    return 0
}

function Get-DriverDecision {
    # Décision pour un appareil et le pilote proposé par Windows Update (ou $null). Rend @{ Code; Text; Install }.
    param($Dev, $Cand)
    $gpu = ($Dev.Class -eq 'Display' -and $Script:GpuVendors.ContainsKey([string]$Dev.Ven))
    if ($gpu) { return @{ Code = 'gpu'; Text = 'Carte graphique : dernier pilote par l''outil officiel du fabricant (ci-dessous)'; Install = $false } }
    if ($Cand) {
        $cmp = Compare-DriverAge $Cand.Date $Cand.Version $Dev.Date $Dev.Version
        if ($Dev.Problem -ne 0 -and -not $Dev.Inf) { return @{ Code = 'install'; Text = 'Installer : appareil sans pilote'; Install = $true } }
        if ($cmp -gt 0) { return @{ Code = 'install'; Text = $(if ($Dev.Problem -ne 0) { 'Mettre à jour : l''appareil est en erreur' } else { 'Mettre à jour' }); Install = $true } }
        if ($Dev.Inbox) { return @{ Code = 'keep-inbox'; Text = 'Gardé : le pilote fourni par Windows est plus récent que celui proposé'; Install = $false } }
        if ($cmp -lt 0) { return @{ Code = 'keep-newer'; Text = 'Gardé : le pilote en place est plus récent que celui proposé'; Install = $false } }
        return @{ Code = 'keep-same'; Text = 'Gardé : même version'; Install = $false }
    }
    if ($Dev.Problem -ne 0) {
        if (@('8086', '1022') -contains [string]$Dev.Ven) {
            $mk = $(if ($Dev.Ven -eq '8086') { 'Intel' } else { 'AMD' })
            return @{ Code = 'chipset'; Text = ('Sans pilote : paquet chipset {0} signé requis (sert de « null driver ») : outil {0} ou du fabricant du PC, ci-dessous' -f $mk); Install = $false }
        }
        return @{ Code = 'missing'; Text = 'Sans pilote dans Windows Update : outil du fabricant du PC (ci-dessous)'; Install = $false }
    }
    return @{ Code = 'ok'; Text = 'À jour'; Install = $false }
}

function Get-DriverAnalysis {
    # Lecture seule : chaque appareil, son pilote, ce que propose Windows Update et la décision de la Toolbox.
    Write-Log '=== Analyse complète des pilotes (lecture seule) ==='
    $devs = @()
    try { $devs = @(Get-AllDeviceDrivers) } catch { Write-Log ("Lecture des appareils impossible : " + $_.Exception.Message) 'ERROR'; Set-SyncResult @{ Rows = @(); Error = $_.Exception.Message }; return }
    Write-Log ("{0} appareil(s) analysé(s). Interrogation de Windows Update (1 à 3 minutes)…" -f $devs.Count)
    $wuRows = @(); $wuErr = ''
    try { $wuRows = @((Get-WindowsUpdateDriverList).Rows) }
    catch { $wuErr = $_.Exception.Message; Write-Log ("Windows Update ne répond pas ({0}) : seules les vérifications locales sont faites." -f $wuErr) 'WARN' }
    $idx = @{}
    foreach ($u in $wuRows) { if ($u.HwId) { if (-not $idx.ContainsKey($u.HwId)) { $idx[$u.HwId] = New-Object System.Collections.ArrayList }; [void]$idx[$u.HwId].Add($u) } }
    $rows = New-Object System.Collections.ArrayList
    $okCount = 0; $gpus = @()
    foreach ($d in $devs) {
        $cand = $null
        foreach ($h in $d.Ids) { if ($idx.ContainsKey($h)) { $cand = @($idx[$h] | Sort-Object Date -Descending)[0]; break } }
        $dec = Get-DriverDecision $d $cand
        if ($dec.Code -eq 'gpu') { $gpus += [pscustomobject]@{ Name = $d.Name; Vendor = $Script:GpuVendors[[string]$d.Ven]; Version = $d.Version; Date = $(if ($d.Date) { $d.Date.ToString('yyyy-MM-dd') } else { '' }); Inbox = $d.Inbox } }
        if ($dec.Code -eq 'ok') { $okCount++; continue }
        [void]$rows.Add([pscustomobject]@{
            Device = $d.Id; Name = $d.Name; Class = $d.Class
            Current = $(if ($d.Inf) { ('{0} · {1} · {2}' -f $(if ($d.Inbox) { 'Windows' } else { $d.Provider }), $d.Version, $(if ($d.Date) { $d.Date.ToString('yyyy-MM-dd') } else { '?' })) } else { 'aucun pilote' })
            Proposed = $(if ($cand) { ('{0} · {1} · {2}' -f $cand.Provider, $(if ($cand.Version) { $cand.Version } else { '?' }), $(if ($cand.Date) { $cand.Date.ToString('yyyy-MM-dd') } else { '?' })) } else { '' })
            UpdateId = $(if ($cand) { [string]$cand.Id } else { '' }); SizeMB = $(if ($cand) { $cand.SizeMB } else { 0 })
            Code = $dec.Code; Decision = $dec.Text; Install = [bool]$dec.Install
        })
    }
    $maker = ''
    try {
        $m = [string](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).Manufacturer
        if ($m -match 'Dell') { $maker = 'dell' } elseif ($m -match 'Lenovo') { $maker = 'lenovo' } elseif ($m -match 'HP|Hewlett') { $maker = 'hp' }
    } catch {}
    $cpu = ''
    try { $c = [string](Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1).Manufacturer; if ($c -match 'Intel') { $cpu = 'intel' } elseif ($c -match 'AMD') { $cpu = 'amd' } } catch {}
    $nInst = @($rows | Where-Object { $_.Install }).Count
    Write-Log ("{0} appareil(s) à jour, {1} mise(s) à jour proposée(s), {2} autre(s) point(s) à voir." -f $okCount, $nInst, (@($rows).Count - $nInst)) $(if ($nInst -gt 0) { 'WARN' } else { 'OK' })
    $order = @{ 'install' = 0; 'chipset' = 1; 'missing' = 2; 'gpu' = 3; 'keep-inbox' = 4; 'keep-newer' = 5; 'keep-same' = 6 }
    Set-SyncResult @{
        Rows = @($rows | Sort-Object @{ Expression = { $order[[string]$_.Code] } }, Class, Name); Total = $devs.Count; UpToDate = $okCount
        WuError = $wuErr; Gpus = @($gpus); Maker = $maker; Cpu = $cpu
    }
}

function Install-DriverSelection {
    # Installe les pilotes Windows Update choisis, après point de restauration et sauvegarde des pilotes en place.
    # Puis vérifie chaque appareil et retire l'ancienne version du magasin si elle ne sert plus (sauvegarde gardée).
    param([string[]]$Ids)
    $ids = @($Ids | Where-Object { $_ -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$' } | ForEach-Object { $_.ToLower() } | Sort-Object -Unique)
    if ($ids.Count -eq 0) { Write-Log 'Aucun pilote valide à installer.' 'WARN'; Set-SyncResult @{ Ok = @(); Bad = @(); Reboot = $false }; return }
    Write-Log ("=== Installation de {0} pilote(s) (Windows Update) ===" -f $ids.Count)
    $okT = @(); $koT = @()
    try {
        $wu = Get-WindowsUpdateDriverList
        $devs = @(Get-AllDeviceDrivers)
        # 1. Garde-fou : chaque pilote choisi est revérifié contre le pilote en place, juste avant l'installation
        $coll = New-Object -ComObject Microsoft.Update.UpdateColl
        $before = @()
        foreach ($u in $wu.Updates) {
            $uid = ([string]$u.Identity.UpdateID).ToLower()
            if ($ids -notcontains $uid) { continue }
            $c = [pscustomobject]@{ HwId = ([string]$u.DriverHardwareID).ToUpper(); Date = $null; Version = '' }
            try { $c.Date = ([datetime]$u.DriverVerDate).Date } catch {}
            if ([string]$u.Title -match '(\d+(?:\.\d+){2,3})\s*$') { $c.Version = $Matches[1] }
            $targets = @($devs | Where-Object { $_.Ids -contains $c.HwId })
            if ($targets.Count -eq 0) { Write-Log ("Aucun appareil branché pour : {0}" -f $u.Title) 'WARN'; $koT += [string]$u.Title; continue }
            $refuse = ''
            foreach ($d in $targets) { $dec = Get-DriverDecision $d $c; if (-not $dec.Install) { $refuse = ('{0} : {1}' -f $d.Name, $dec.Text) } }
            if ($refuse) { Write-Log ("Refusé : {0} ({1})" -f $u.Title, $refuse) 'WARN'; $koT += [string]$u.Title; continue }
            try { if (-not $u.EulaAccepted) { $u.AcceptEula() } } catch {}
            [void]$coll.Add($u)
            foreach ($d in $targets) { $before += [pscustomobject]@{ Device = $d.Id; Name = $d.Name; OldInf = $d.Inf; Inbox = $d.Inbox; Title = [string]$u.Title } }
        }
        if ($coll.Count -eq 0) { Write-Log 'Rien à installer (pilotes plus proposés ou refusés par les règles).' 'WARN'; Set-SyncResult @{ Ok = @(); Bad = @($koT); Reboot = $false }; return }
        # 2. Point de restauration et sauvegarde des pilotes tiers en place
        [void](New-DriverRestorePoint)
        $folder = Join-Path (Join-Path $Script:LogDir 'Pilotes') ("MAJ_{0}_{1}" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmmss'))
        New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop | Out-Null
        $saved = @{}
        foreach ($inf in @($before | Where-Object { -not $_.Inbox -and $_.OldInf -match '^oem\d+\.inf$' } | ForEach-Object { $_.OldInf } | Sort-Object -Unique)) {
            $sub = Join-Path $folder ($inf -replace '\.inf$', '')
            New-Item -ItemType Directory -Path $sub -Force | Out-Null
            [void](Invoke-NativeLines 'pnputil.exe' ('/export-driver ' + $inf + ' "' + $sub + '"'))
            if (Get-ChildItem -LiteralPath $sub -Filter *.inf -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1) { $saved[$inf] = $true; Write-Log "Pilote en place sauvegardé : $inf" 'OK' }
            else { Write-Log "Sauvegarde de $inf impossible : il ne sera pas retiré après la mise à jour." 'WARN' }
        }
        # 3. Téléchargement et installation par Windows Update (signature et classement vérifiés par Windows)
        $session = $wu.Session
        Write-Log ("Téléchargement de {0} pilote(s)…" -f $coll.Count)
        $dl = $session.CreateUpdateDownloader(); $dl.Updates = $coll
        $dr = $dl.Download()
        if ($dr.ResultCode -ne 2 -and $dr.ResultCode -ne 3) { Write-Log ("Téléchargement incomplet (code {0})." -f $dr.ResultCode) 'WARN' }
        Write-Log 'Installation… (l''écran peut clignoter)'
        $inst = $session.CreateUpdateInstaller(); $inst.Updates = $coll
        $ir = $inst.Install()
        for ($i = 0; $i -lt $coll.Count; $i++) {
            $t = [string]$coll.Item($i).Title
            $rc = [int]$ir.GetUpdateResult($i).ResultCode
            if ($rc -eq 2 -or $rc -eq 3) { Write-Log "Installé : $t" 'OK'; $okT += $t } else { Write-Log ("Échec (code {0}) : {1}" -f $rc, $t) 'WARN'; $koT += $t }
        }
        $reb = [bool]$ir.RebootRequired
        if ($reb) { $Script:RebootNeeded = $true; Write-Log 'Un redémarrage est nécessaire pour terminer.' 'WARN' }
        # 4. Vérification des appareils et note pour la restauration
        $after = @{}; foreach ($d in @(Get-AllDeviceDrivers)) { $after[$d.Id] = $d }
        $inUse = @{}; foreach ($d in $after.Values) { if ($d.Inf) { $inUse[$d.Inf] = $true } }
        $broken = @{}
        foreach ($b in $before) {
            $a = $after[$b.Device]
            if (-not $a) { continue }
            if ($a.Problem -ne 0 -and $a.Problem -ne 14) { $broken[$b.OldInf] = $true; Write-Log ("{0} : appareil en erreur après la mise à jour (code {1}). Revenir en arrière : Pilotes > Sauvegardes." -f $b.Name, $a.Problem) 'WARN' }
            if ($a.Inf -and $a.Inf -ne $b.OldInf) {
                Write-Log ("{0} : {1} -> {2} ({3})" -f $b.Name, $(if ($b.OldInf) { $b.OldInf } else { 'aucun' }), $a.Inf, $a.Version) 'OK'
                Save-DriverUpdateRecord -Folder $folder -Device $b.Name -OldInf $b.OldInf -NewInfs @($a.Inf)
            }
        }
        # 5. Retrait des anciennes versions : sauvegardées, plus utilisées, appareils sans erreur, pas de redémarrage en attente
        if ($reb) { Write-Log 'Anciennes versions : retirables après le redémarrage (Pilotes > Pilotes installés > anciennes versions).' }
        else {
            foreach ($inf in @($saved.Keys)) {
                if ($inUse.ContainsKey($inf)) { Write-Log "$inf sert encore à un appareil : conservé."; continue }
                if ($broken.ContainsKey($inf)) { Write-Log "$inf conservé : l'appareil n'est pas en ordre avec le nouveau pilote."; continue }
                [void](Invoke-NativeLines 'pnputil.exe' ('/delete-driver ' + $inf))
                $c = $LASTEXITCODE
                if ($c -eq 0 -or $c -eq 3010) { Write-Log ("Ancienne version retirée du magasin : {0} (copie dans {1})" -f $inf, $folder) 'OK' }
                else { Write-Log ("Ancienne version {0} gardée par Windows (code {1})." -f $inf, $c) 'WARN' }
            }
        }
        if (@(Get-ChildItem -LiteralPath $folder -Recurse -File -ErrorAction SilentlyContinue).Count -eq 0) { Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue }
        Set-SyncResult @{ Ok = @($okT); Bad = @($koT); Reboot = $reb }
    } catch {
        Write-Log ("Installation impossible : " + $_.Exception.Message) 'ERROR'
        Set-SyncResult @{ Ok = @($okT); Bad = @($ids); Reboot = $false }
    }
}

function Find-DownloadedDrivers {
    # Lecture seule : cherche dans Téléchargements les dossiers et archives .zip qui contiennent un pilote (.inf).
    Write-Log '=== Pilotes téléchargés (dossier Téléchargements) ==='
    $root = Get-DownloadsRoot
    $rows = New-Object System.Collections.ArrayList
    $skip = '(?i)BJMPC|DriverStoreExplorer|\\\.git\\'
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $included = New-Object System.Collections.ArrayList
        foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -Recurse -Depth 3 -ErrorAction SilentlyContinue | Sort-Object { $_.FullName.Length })) {
            if ($d.FullName -match $skip) { continue }
            $under = $false; foreach ($i in $included) { if ($d.FullName.StartsWith($i + [IO.Path]::DirectorySeparatorChar)) { $under = $true; break } }
            if ($under) { continue }
            $infs = @(Get-ChildItem -LiteralPath $d.FullName -Filter *.inf -Recurse -ErrorAction SilentlyContinue | Select-Object -First 200)
            if ($infs.Count -eq 0) { continue }
            [void]$included.Add($d.FullName)
            $sz = 0; try { $sz = Get-FolderBytes $d.FullName } catch {}
            [void]$rows.Add([pscustomobject]@{ Path = $d.FullName; Kind = 'dossier'; Name = $d.Name; InfCount = $infs.Count; SizeMB = [math]::Round($sz / 1MB, 1); Date = $d.LastWriteTime.ToString('yyyy-MM-dd'); When = $d.LastWriteTime })
        }
        foreach ($z in @(Get-ChildItem -LiteralPath $root -Filter *.zip -File -Recurse -Depth 2 -ErrorAction SilentlyContinue)) {
            if ($z.FullName -match $skip) { continue }
            $n = 0
            try { $a = [IO.Compression.ZipFile]::OpenRead($z.FullName); try { $n = @($a.Entries | Where-Object { $_.FullName -like '*.inf' }).Count } finally { $a.Dispose() } } catch { continue }
            if ($n -eq 0) { continue }
            [void]$rows.Add([pscustomobject]@{ Path = $z.FullName; Kind = 'archive zip'; Name = $z.Name; InfCount = $n; SizeMB = [math]::Round($z.Length / 1MB, 1); Date = $z.LastWriteTime.ToString('yyyy-MM-dd'); When = $z.LastWriteTime })
        }
    } catch { Write-Log ("Recherche impossible : " + $_.Exception.Message) 'WARN' }
    $list = @($rows | Sort-Object When -Descending | Select-Object -First 40)
    Write-Log ("{0} pilote(s) trouvé(s) dans {1}" -f $list.Count, $root) $(if ($list.Count -gt 0) { 'OK' } else { 'WARN' })
    Set-SyncResult $list
}

function Add-DriverFromFolder {
    # Pilote téléchargé à la main (site du constructeur…) : mêmes contrôles WHQL stricts, puis ajout au magasin.
    # -Install : installe aussi sur les appareils compatibles. Sans -Install : ajout au magasin seulement.
    param([string]$Path, [switch]$Install, [int]$Level = 1)
    if ($Level -lt 1 -or $Level -gt 3) { $Level = 1 }
    $dl = Get-DownloadsRoot
    if (-not $Path -or -not ([IO.Path]::GetFullPath($Path)).StartsWith($dl + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { Write-Log 'Seuls les pilotes du dossier Téléchargements sont acceptés.' 'ERROR'; return }
    if (-not (Test-Path -LiteralPath $Path)) { Write-Log 'Pilote introuvable.' 'ERROR'; return }
    $tmpZip = ''
    if ($Path -match '(?i)\.zip$') {
        $tmpZip = Join-Path $Script:DrvTmp ('zip_' + [guid]::NewGuid().ToString('N'))
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Path $tmpZip -Force | Out-Null
            $a = [IO.Compression.ZipFile]::OpenRead($Path)
            try {
                foreach ($e in $a.Entries) {
                    if (-not $e.Name) { continue }
                    $target = [IO.Path]::GetFullPath((Join-Path $tmpZip $e.FullName))
                    if (-not $target.StartsWith($tmpZip + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Archive refusée (chemin suspect).' }
                    New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
                }
            } finally { $a.Dispose() }
            $Path = $tmpZip
        } catch { Write-Log ("Archive illisible : " + $_.Exception.Message) 'ERROR'; try { Remove-Item -LiteralPath $tmpZip -Recurse -Force -ErrorAction SilentlyContinue } catch {}; return }
    }
    Write-Log "=== Contrôle du pilote : $Path ==="
    $infs = @(Get-ChildItem -LiteralPath $Path -Filter *.inf -Recurse -ErrorAction SilentlyContinue)
    $ok = @(); $ko = @()
    foreach ($f in $infs) {
        $t = Test-DriverPackage -Dir $Path -HwIds @() -InstalledVersion '' -ClassGuid '' -OnlyInf $f.FullName -Level $Level
        $one = $null
        if ($t.Ok) { $one = $t }
        if ($one) { $ok += $f.FullName; Write-Log ("Conforme : {0} ({1}, v{2})" -f $f.Name, $(if ($one.NonMs) { 'signature valide NON Microsoft, niveau ouvert' } else { 'WHQL Microsoft' }), $one.Version) $(if ($one.NonMs) { 'WARN' } else { 'OK' }) }
        else { $ko += $f.Name; foreach ($r in @($t.Reasons | Select-Object -First 2)) { Write-Log ("Refusé : " + $r) 'WARN' } }
    }
    if ($ok.Count -eq 0) { if ($tmpZip) { try { Remove-Item -LiteralPath $tmpZip -Recurse -Force -ErrorAction SilentlyContinue } catch {} }; Write-Log 'Aucun INF conforme : rien n''est ajouté.' 'WARN'; Set-SyncResult @{ Ok = @(); Bad = @($ko); Reboot = $false }; return }
    # Installation : un dossier de constructeur contient souvent des dizaines de pilotes (un par modèle). On ne garde
    # que ceux qui déclarent un appareil réellement branché sur ce PC.
    $targets = @{}
    if ($Install) {
        $index = Get-PresentHardwareIndex
        $keep = @()
        foreach ($inf in $ok) {
            $dev = @(Get-InfDeviceMatches $inf $index)
            if ($dev.Count -eq 0) { Write-Log ("Non installé : {0} ne concerne aucun appareil branché sur ce PC." -f (Split-Path $inf -Leaf)); continue }
            $targets[$inf] = $dev; $keep += $inf
        }
        if ($keep.Count -eq 0) {
            if ($tmpZip) { try { Remove-Item -LiteralPath $tmpZip -Recurse -Force -ErrorAction SilentlyContinue } catch {} }
            Write-Log 'Aucun pilote de ce dossier ne correspond à un appareil branché : rien n''est installé. Pour le garder en réserve, utilisez « ajouter au magasin seulement ».' 'WARN'
            Set-SyncResult @{ Ok = @(); Bad = @($ko); Reboot = $false }; return
        }
        Write-Log ("{0} pilote(s) sur {1} concernent un appareil branché." -f $keep.Count, $ok.Count)
        $ok = $keep
    }
    if (-not (New-DriverRestorePoint) -and $Install) {
        if (-not (Confirm-Action "Le point de restauration n'a pas pu être créé. Installer quand même ? L'ancien pilote de chaque appareil sera tout de même copié dans C:\BJMPC-Logs\Pilotes.")) {
            if ($tmpZip) { try { Remove-Item -LiteralPath $tmpZip -Recurse -Force -ErrorAction SilentlyContinue } catch {} }
            Write-Log 'Installation annulée : pas de point de restauration.' 'WARN'
            Set-SyncResult @{ Ok = @(); Bad = @(); Reboot = $false }; return
        }
    }
    $added = @(); $rb = $false
    $top = Join-Path $Script:LogDir ("Pilotes\Avant_MAJ_{0}_{1}" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $current = @{}; $saved = @{}
    if ($Install) { try { foreach ($sd in @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop)) { $current[[string]$sd.DeviceID] = ([string]$sd.InfName).ToLower() } } catch {} }
    foreach ($inf in $ok) {
        $leaf = Split-Path $inf -Leaf
        $olds = @()
        if ($Install) {
            # Copie du pilote actuel de chaque appareil concerné, comme pour une mise à jour depuis le Catalog.
            $olds = @(@($targets[$inf]) | ForEach-Object { [string]$current[[string]$_] } | Where-Object { $_ -match '^oem\d+\.inf$' } | Sort-Object -Unique)
            $bkOk = $true
            foreach ($o in $olds) {
                if ($saved.ContainsKey($o)) { continue }
                $bk = Join-Path $top ($o -replace '\.inf$', '')
                New-Item -ItemType Directory -Path $bk -Force | Out-Null
                [void](Invoke-NativeLines 'pnputil.exe' ('/export-driver ' + $o + ' "' + $bk + '"'))
                if (Get-ChildItem -LiteralPath $bk -Filter *.inf -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1) { $saved[$o] = 1; Write-Log ("Ancien pilote sauvegardé : " + $bk) 'OK' }
                else { $bkOk = $false }
            }
            if (-not $bkOk) { $ko += $leaf; Write-Log ("{0} : sauvegarde de l'ancien pilote impossible, installation annulée pour ce pilote." -f $leaf) 'WARN'; continue }
        }
        $oemBefore = @(Get-ChildItem -LiteralPath (Join-Path $env:windir 'INF') -Filter 'oem*.inf' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name.ToLower() })
        $args2 = '/add-driver "' + $inf + '"'; if ($Install) { $args2 += ' /install' }
        [void](Invoke-NativeLines 'pnputil.exe' $args2)
        $code = $LASTEXITCODE
        if ($code -eq 0 -or $code -eq 3010) {
            $added += $leaf; if ($code -eq 3010) { $rb = $true; $Script:RebootNeeded = $true }
            if ($Install) {
                $oemAdded = @(Get-ChildItem -LiteralPath (Join-Path $env:windir 'INF') -Filter 'oem*.inf' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name.ToLower() } | Where-Object { $oemBefore -notcontains $_ })
                if ($oemAdded.Count -gt 0) { Save-DriverUpdateRecord -Folder $top -Device $leaf -OldInf ($olds -join ',') -NewInfs $oemAdded }
            }
        }
        elseif ($code -eq 259 -and $Install) { Write-Log ("{0} : ajouté au magasin, mais Windows garde le pilote en place, qu'il juge au moins aussi bon." -f $leaf) }
        else { $ko += $leaf; Write-Log ("Refusé par Windows : {0} (code {1})" -f $leaf, $code) 'WARN' }
    }
    if ($Install -and (Test-Path -LiteralPath (Join-Path $top 'maj.json'))) { Write-Log ("Retour arrière possible : Pilotes > Sauvegardes > {0}" -f (Split-Path $top -Leaf)) }
    Write-Log ("{0} pilote(s) ajouté(s){1}." -f $added.Count, $(if ($Install) { ' et installé(s)' } else { ' au magasin' })) $(if ($added.Count -gt 0) { 'OK' } else { 'WARN' })
    if ($tmpZip) { try { Remove-Item -LiteralPath $tmpZip -Recurse -Force -ErrorAction SilentlyContinue } catch {} }
    Set-SyncResult @{ Ok = @($added); Bad = @($ko); Reboot = $rb }
}

# ---------------------------------------------------------------- Appareils fantômes (non branchés depuis 15 jours ou plus)
# Classes où supprimer la trace d'un appareil absent ne fait rien perdre : rebranché, il est réinstallé à l'identique.
# Volontairement absentes : Net (adresse IP fixe et réglages de la carte), Bluetooth (appairage), Ports (numéro COM),
# Printer (file et réglages d'impression) : là, « Windows le réinstalle tout seul » serait faux.
$Script:GhostClasses = @('USB', 'USBDevice', 'WPD', 'DiskDrive', 'CDROM', 'Monitor', 'HIDClass', 'Keyboard', 'Mouse', 'Image', 'Camera', 'MEDIA', 'SmartCardReader')
$Script:GhostMinDays = 15

function Get-GhostLastSeen {
    # Dernière présence connue d'un appareil (dates d'arrivée et de retrait enregistrées par Windows), ou $null.
    param([string]$InstanceId)
    $last = $null
    foreach ($k in @('{83da6326-97a6-4088-9453-a1923f573b29} 102', '{83da6326-97a6-4088-9453-a1923f573b29} 103')) {
        try {
            $p = Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName $k -ErrorAction Stop
            if ($p.Data -is [datetime] -and ($null -eq $last -or $p.Data -gt $last)) { $last = $p.Data }
        } catch {}
    }
    return $last
}

function Get-GhostDevices {
    # Lecture seule : appareils absents, avec la date de leur dernière présence (arrivée/retrait enregistrés par Windows).
    # Seules les classes sans risque sont listées ; un appareil dont la date est inconnue n'est jamais proposé.
    param([int]$Days = 15)
    Write-Log ("=== Appareils absents (liste des fantômes, seuil {0} jours) ===" -f $Days)
    $rows = New-Object System.Collections.ArrayList
    try {
        foreach ($d in @(Get-PnpDevice -ErrorAction Stop | Where-Object { $_.Status -eq 'Unknown' -and $Script:GhostClasses -contains [string]$_.Class })) {
            $id = [string]$d.InstanceId
            if ($id -match '^(ROOT|HTREE|ACPI|SWD)\\') { continue }
            $last = Get-GhostLastSeen $id
            $age = -1; if ($last) { $age = [int]((Get-Date) - $last).TotalDays }
            [void]$rows.Add([pscustomobject]@{
                Id = $id; Name = $(if ($d.FriendlyName) { [string]$d.FriendlyName } else { [string]$d.Class }); Class = [string]$d.Class
                LastSeen = $(if ($last) { $last.ToString('yyyy-MM-dd') } else { '' }); Days = $age; Eligible = [bool]($age -ge $Days)
            })
        }
    } catch { Write-Log ("Lecture impossible : " + $_.Exception.Message) 'WARN'; return }
    $list = @($rows | Sort-Object @{ Expression = { $_.Days }; Descending = $true })
    Write-Log ("{0} appareil(s) absent(s), dont {1} depuis {2} jours ou plus." -f $list.Count, @($list | Where-Object { $_.Eligible }).Count, $Days) 'OK'
    Set-SyncResult $list
}

function Remove-GhostDevices {
    # Supprime les entrées d'appareils absents (pnputil /remove-device). La liste est enregistrée avant ; si l'appareil
    # est rebranché, Windows le réinstalle tout seul (la suppression ne touche pas au pilote du magasin).
    param([string[]]$Instances)
    $ok = @(); $ko = @()
    $present = @{}
    try { foreach ($d in @(Get-PnpDevice -PresentOnly -ErrorAction Stop)) { $present[[string]$d.InstanceId] = 1 } } catch {}
    $all = @{}
    try { foreach ($d in @(Get-PnpDevice -ErrorAction Stop)) { $all[[string]$d.InstanceId] = $d } } catch {}
    $dest = Join-Path $Script:LogDir ("Pilotes\Fantomes_{0}_{1}.json" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    try { New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null; @($Instances | ForEach-Object { $d = $all[$_]; [pscustomobject]@{ Id = $_; Name = $(if ($d) { [string]$d.FriendlyName } else { '' }); Class = $(if ($d) { [string]$d.Class } else { '' }) } }) | ConvertTo-Json | Set-Content -LiteralPath $dest -Encoding UTF8 } catch {}
    foreach ($id in @($Instances)) {
        $d = $all[$id]
        if (-not $d) { $ko += $id; continue }
        if ($present.ContainsKey($id) -or $id -match '^(ROOT|HTREE|ACPI|SWD)\\' -or $Script:GhostClasses -notcontains [string]$d.Class) { Write-Log "Ignoré (présent ou classe protégée) : $id" 'WARN'; $ko += $id; continue }
        # L'ancienneté est revérifiée ici, au moment de supprimer : la liste affichée peut dater, ou la demande venir d'ailleurs.
        $seen = Get-GhostLastSeen $id
        if (-not $seen -or ((Get-Date) - $seen).TotalDays -lt $Script:GhostMinDays) { Write-Log ("Ignoré (absent depuis moins de {0} jours, ou date inconnue) : {1}" -f $Script:GhostMinDays, $id) 'WARN'; $ko += $id; continue }
        [void](Invoke-NativeLines 'pnputil.exe' ('/remove-device "' + $id + '"'))
        $code = $LASTEXITCODE
        if ($code -eq 0 -or $code -eq 3010) { Write-Log ("Supprimé : {0} ({1})" -f $(if ($d.FriendlyName) { $d.FriendlyName } else { $id }), $d.Class) 'OK'; $ok += $id }
        else { Write-Log ("Refusé (code {0}) : {1}" -f $code, $id) 'WARN'; $ko += $id }
    }
    Write-Log ("{0} entrée(s) supprimée(s), {1} conservée(s). Liste enregistrée : {2}" -f $ok.Count, $ko.Count, $dest) $(if ($ko.Count -eq 0) { 'OK' } else { 'WARN' })
    Set-SyncResult @{ Ok = @($ok); Bad = @($ko); Backup = $dest }
}

function Get-StartupItems {
    Write-Log "=== Programmes lancés au démarrage ==="
    $items = @(Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($items.Count -eq 0) { Write-Log "Aucun programme de démarrage listé." 'OK'; return }
    foreach ($i in $items) {
        $cmd = [string]$i.Command
        if ($cmd.Length -gt 90) { $cmd = $cmd.Substring(0, 90) + '...' }
        Write-Host ("  {0,-34} {1}" -f $i.Name, $cmd) -ForegroundColor Gray
    }
    Write-Host ""
    Write-Log ("{0} programme(s). Pour en désactiver : Paramètres > Applications > Démarrage." -f $items.Count)
}

function Open-StartupSettings {
    try { Start-Process 'ms-settings:startupapps' -ErrorAction Stop } catch { Write-Log "Impossible d'ouvrir les paramètres de démarrage." 'WARN' }
}

function Get-LicenseInfo {
    Write-Log "=== Licence Windows ==="
    try {
        $p = Get-CimInstance SoftwareLicensingProduct -ErrorAction Stop |
            Where-Object { $_.PartialProductKey -and $_.ApplicationId -eq '55c92734-d682-4d71-983e-d6ec3f16059f' } | Select-Object -First 1
        if ($p) {
            Write-Row "Édition" ([string]$p.Name) ''
            Write-Row "État" $(if ($p.LicenseStatus -eq 1) { 'activé' } else { 'non activé (code {0})' -f $p.LicenseStatus }) $(if ($p.LicenseStatus -eq 1) { 'ok' } else { 'bad' })
            Write-Row "Fin de clé (5 derniers caractères)" ([string]$p.PartialProductKey) ''
        } else { Write-Log "Aucune licence Windows trouvée." 'WARN' }
    } catch { Write-Log "Lecture impossible : $($_.Exception.Message)" 'WARN' }
    try {
        $k = (Get-CimInstance SoftwareLicensingService -ErrorAction Stop).OA3xOriginalProductKey
        if ($k) { Write-Row "Clé inscrite dans le BIOS (OEM)" $k '' } else { Write-Row "Clé inscrite dans le BIOS (OEM)" "aucune" '' }
    } catch {}
}

function Export-SystemInfo {
    Write-Log "=== Export des informations système (systeminfo) ==="
    $path = Get-ReportPath 'SystemInfo' 'txt'
    $lines = @(Invoke-NativeLines 'systeminfo.exe' '')
    if ($lines.Count -eq 0) { Write-Log "systeminfo n'a rien renvoyé." 'WARN'; return }
    Set-Content -Path $path -Value $lines -Encoding UTF8
    Write-Log "Fichier créé : $path" 'OK'
    Start-Process explorer.exe "/select,`"$path`""
}

# ---------------------------------------------------------------- Dépannage rapide
function Restart-ExplorerShell {
    Write-Log "Redémarrage de l'Explorateur Windows (barre des tâches et bureau)"
    Get-Process -Name explorer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
    Write-Log "Explorateur relancé" 'OK'
}

function Restart-AudioServices {
    Write-Log "Redémarrage des services audio"
    try {
        Restart-Service -Name AudioEndpointBuilder -Force -ErrorAction Stop
        Start-Service -Name Audiosrv -ErrorAction SilentlyContinue
        Write-Log "Services audio redémarrés" 'OK'
    } catch { Write-Log "Échec : $($_.Exception.Message)" 'ERROR' }
}

function Clear-PrintQueue {
    Write-Log "Vidage de la file d'impression"
    try {
        Stop-Service -Name Spooler -Force -ErrorAction Stop
        $spool = Join-Path $env:windir 'System32\spool\PRINTERS'
        Get-ChildItem -Path $spool -File -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        Start-Service -Name Spooler -ErrorAction Stop
        Write-Log "File d'impression vidée, spouleur relancé" 'OK'
    } catch {
        Write-Log "Échec : $($_.Exception.Message)" 'ERROR'
        try { Start-Service -Name Spooler -ErrorAction SilentlyContinue } catch {}
    }
}

# ---------------------------------------------------------------- Doublons de photos
# Deux photos ne sont déclarées identiques que si leur CONTENU l'est : même taille, même empreinte SHA-256,
# puis comparaison octet par octet. Le nom, la date et la taille seuls ne suffisent jamais.
# En option, « même image » : les pixels décodés sont identiques mais les métadonnées diffèrent (date, GPS, logiciel).
# Rien n'est supprimé : les doublons choisis sont déplacés dans <disque>\BJMPC-Doublons\<date>\, et l'opération s'annule.
$Script:PhotoExt  = @('.jpg', '.jpeg', '.jpe', '.jfif', '.png', '.gif', '.bmp', '.tif', '.tiff', '.heic', '.heif', '.webp', '.avif',
                      '.dng', '.cr2', '.cr3', '.nef', '.nrw', '.arw', '.orf', '.rw2', '.raf', '.srw', '.pef')
$Script:PixelExt  = @('.jpg', '.jpeg', '.jpe', '.jfif', '.png', '.gif', '.bmp', '.tif', '.tiff')
$Script:DupRootName = 'BJMPC-Doublons'
$Script:DupLogDir = Join-Path $Script:LogDir 'Doublons'
$Script:DupMaxGroups = 1500

function Format-DupSize {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N1} Go' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N0} Mo' -f ($Bytes / 1MB)) }
    return ('{0:N0} Ko' -f ($Bytes / 1KB))
}

function Initialize-PhotoTools {
    # Comparaison rapide en C#. BJ.FileCompare : octets et SHA-256 (sans dépendance). BJ.PixelTools : pixels (System.Drawing).
    # Rend $true si la comparaison des pixels est disponible. Sans compilation possible, SHA-256 complet en PowerShell.
    if (-not ('BJ.FileCompare' -as [type])) {
        $src = @'
using System;
using System.IO;
using System.Security.Cryptography;
namespace BJ {
  public static class FileCompare {
    static int Fill(Stream s, byte[] buf) { int n = 0; while (n < buf.Length) { int r = s.Read(buf, n, buf.Length - n); if (r <= 0) break; n += r; } return n; }
    static FileStream Open(string p) { return new FileStream(p, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1 << 16); }
    public static bool SameBytes(string a, string b) {
      using (var fa = Open(a)) using (var fb = Open(b)) {
        if (fa.Length != fb.Length) return false;
        var ba = new byte[1 << 20]; var bb = new byte[1 << 20];
        while (true) {
          int na = Fill(fa, ba); int nb = Fill(fb, bb);
          if (na != nb) return false;
          if (na == 0) return true;
          for (int i = 0; i < na; i++) { if (ba[i] != bb[i]) return false; }
        }
      }
    }
    public static string Sha256(string path, long limit) {
      using (var fs = Open(path)) using (var sha = SHA256.Create()) {
        byte[] h;
        if (limit > 0) { var buf = new byte[(int)Math.Min(limit, fs.Length)]; int n = Fill(fs, buf); h = sha.ComputeHash(buf, 0, n); }
        else h = sha.ComputeHash(fs);
        return BitConverter.ToString(h).Replace("-", "");
      }
    }
  }
}
'@
        try { Add-Type -TypeDefinition $src -ErrorAction Stop }
        catch { Write-Log ("Comparateur rapide indisponible ({0}) : comparaison par SHA-256 complet." -f $_.Exception.Message) 'WARN' }
    }
    if ('BJ.PixelTools' -as [type]) { return $true }
    $px = @'
using System;
using System.IO;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
namespace BJ {
  public static class PixelTools {
    static FileStream Open(string p) { return new FileStream(p, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete); }
    public static string Dimensions(string path) {
      using (var fs = Open(path)) using (var img = Image.FromStream(fs, false, false)) { return img.Width + "x" + img.Height; }
    }
    public static string PixelHash(string path) {
      using (var fs = Open(path)) using (var img = Image.FromStream(fs, false, true)) using (var bmp = new Bitmap(img)) {
        var data = bmp.LockBits(new Rectangle(0, 0, bmp.Width, bmp.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try {
          int row = bmp.Width * 4; var line = new byte[row];
          using (var sha = SHA256.Create()) {
            var head = BitConverter.GetBytes(bmp.Width * 65536L + bmp.Height);
            sha.TransformBlock(head, 0, head.Length, null, 0);
            for (int y = 0; y < bmp.Height; y++) {
              Marshal.Copy(IntPtr.Add(data.Scan0, y * data.Stride), line, 0, row);
              sha.TransformBlock(line, 0, row, null, 0);
            }
            sha.TransformFinalBlock(new byte[0], 0, 0);
            return BitConverter.ToString(sha.Hash).Replace("-", "");
          }
        } finally { bmp.UnlockBits(data); }
      }
    }
  }
}
'@
    try { Add-Type -TypeDefinition $px -ReferencedAssemblies 'System.Drawing' -ErrorAction Stop; return $true }
    catch { return $false }
}

function Get-LongPath {
    # Préfixe \\?\ : chemins de plus de 260 caractères.
    param([string]$Path)
    if ($Path.StartsWith('\\?\')) { return $Path }
    if ($Path.StartsWith('\\')) { return '\\?\UNC\' + $Path.Substring(2) }
    return '\\?\' + $Path
}

function Get-ShortPathText {
    param([string]$Path)
    if ($Path.StartsWith('\\?\UNC\')) { return '\\' + $Path.Substring(8) }
    if ($Path.StartsWith('\\?\')) { return $Path.Substring(4) }
    return $Path
}

function Get-FileSha {
    param([string]$Path, [long]$Limit = 0)
    try {
        if ('BJ.FileCompare' -as [type]) { return [BJ.FileCompare]::Sha256($Path, $Limit) }
        $sha = [Security.Cryptography.SHA256]::Create(); $fs = $null
        try {
            $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
            if ($Limit -gt 0) {
                $buf = New-Object byte[] ([int][math]::Min($Limit, $fs.Length)); $n = 0
                while ($n -lt $buf.Length) { $r = $fs.Read($buf, $n, $buf.Length - $n); if ($r -le 0) { break }; $n += $r }
                $h = $sha.ComputeHash($buf, 0, $n)
            } else { $h = $sha.ComputeHash($fs) }
            return [BitConverter]::ToString($h).Replace('-', '')
        } finally { if ($fs) { $fs.Dispose() }; $sha.Dispose() }
    } catch { return $null }
}

function Test-SameContent {
    # Vrai seulement si les deux fichiers sont identiques. Octet par octet si possible, sinon SHA-256 complet.
    param([string]$A, [string]$B)
    try {
        if ('BJ.FileCompare' -as [type]) { return [BJ.FileCompare]::SameBytes($A, $B) }
        $ha = Get-FileSha $A; $hb = Get-FileSha $B
        return [bool]($ha -and $ha -eq $hb)
    } catch { return $false }
}

function Get-PixelSignature {
    param([string]$Path)
    try { return [BJ.PixelTools]::PixelHash($Path) } catch { return $null }
}

function Get-InteractiveUserFolders {
    # Dossiers personnels de la personne connectée (la Toolbox peut tourner sous un autre compte administrateur).
    $sid = ''
    try {
        $u = [string](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName
        if ($u) { $sid = (New-Object Security.Principal.NTAccount($u)).Translate([Security.Principal.SecurityIdentifier]).Value }
    } catch {}
    if (-not $sid) { try { $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch {} }
    $prof = ''
    try { $prof = [string](Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -ErrorAction Stop).ProfileImagePath } catch {}
    if (-not $prof) { $prof = $env:USERPROFILE }
    $map = @{
        Pictures  = @('My Pictures', 'Pictures')
        Desktop   = @('Desktop', 'Desktop')
        Documents = @('Personal', 'Documents')
        Downloads = @('{374DE290-123F-4565-9164-39C4925E467B}', 'Downloads')
    }
    $res = @{}
    foreach ($k in @($map.Keys)) {
        $p = ''
        try {
            $raw = (Get-Item -LiteralPath "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" -ErrorAction Stop).GetValue($map[$k][0], $null, 'DoNotExpandEnvironmentNames')
            if ($raw) { $p = ([string]$raw) -ireplace '%USERPROFILE%', $prof.Replace('$', '$$') }
        } catch {}
        if (-not $p -or $p -match '%') { $p = Join-Path $prof $map[$k][1] }
        $res[$k] = $p.TrimEnd('\')
    }
    return $res
}

function Find-DuplicatePhotos {
    # Lecture seule. -Known : dossiers personnels (Pictures, Desktop, Documents, Downloads) ; -Folders : autres dossiers.
    param([string[]]$Known = @('Pictures'), [string[]]$Folders = @(), [bool]$Pixels = $false)
    Write-Log '=== Doublons de photos (lecture seule) ==='
    $fast = Initialize-PhotoTools
    if ($Pixels -and -not $fast) { Write-Log 'Comparaison des pixels indisponible sur ce PC : seuls les fichiers identiques sont recherchés.' 'WARN'; $Pixels = $false }
    $cand = New-Object System.Collections.ArrayList
    if (@($Known).Count -gt 0) {
        $uf = Get-InteractiveUserFolders
        foreach ($k in @($Known)) { if ($uf.ContainsKey([string]$k)) { [void]$cand.Add([string]$uf[[string]$k]) } }
    }
    foreach ($f in @($Folders)) { if ($f) { [void]$cand.Add([string]$f) } }
    $roots = @()
    foreach ($r in @($cand | ForEach-Object { try { [IO.Path]::GetFullPath(([string]$_).Trim().Trim('"')).TrimEnd('\') } catch {} } | Where-Object { $_ } | Sort-Object Length)) {
        if ($r.Length -lt 3) { $r += '\' }
        if (-not (Test-Path -LiteralPath $r)) { Write-Log "Dossier introuvable, ignoré : $r" 'WARN'; continue }
        $inside = $false
        foreach ($x in $roots) { if (($r + '\').StartsWith($x.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { $inside = $true; break } }
        if (-not $inside) { $roots += $r }
    }
    if ($roots.Count -eq 0) { Write-Log 'Aucun dossier à analyser.' 'ERROR'; Set-SyncResult @{ Groups = @(); Scanned = 0; Roots = @() }; return }
    foreach ($r in $roots) { Write-Log "Analyse : $r" }

    # 1. Inventaire (sans suivre les jonctions, sans télécharger les fichiers OneDrive « en ligne uniquement »)
    $files = New-Object System.Collections.ArrayList
    $seenFile = @{}   # une photo atteinte par deux chemins (dossier inclus deux fois, lien) n'est comptée qu'une fois
    $online = 0
    foreach ($r in $roots) {
        $stack = New-Object 'System.Collections.Generic.Stack[string]'
        $stack.Push((Get-LongPath $r))
        while ($stack.Count -gt 0) {
            $d = $stack.Pop()
            try {
                $di = New-Object IO.DirectoryInfo $d
                if ($di.Name -ieq $Script:DupRootName) { continue }
                foreach ($fi in $di.GetFiles()) {
                    if ($Script:PhotoExt -notcontains $fi.Extension.ToLowerInvariant()) { continue }
                    if ($fi.Length -le 0) { continue }
                    # Offline (0x1000), RECALL_ON_OPEN (0x40000), RECALL_ON_DATA_ACCESS (0x400000) : fichier dans le nuage
                    if (([int64]$fi.Attributes) -band 0x441000) { $online++; continue }
                    if ($seenFile.ContainsKey($fi.FullName)) { continue }
                    $seenFile[$fi.FullName] = $true
                    [void]$files.Add($fi)
                }
                foreach ($s in $di.GetDirectories()) {
                    if (-not ($s.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $stack.Push($s.FullName) }
                }
            } catch { Write-Log ("Dossier illisible, ignoré : {0}" -f (Get-ShortPathText $d)) 'WARN' }
        }
        Write-Log ("{0} photo(s) trouvée(s) jusqu'ici" -f $files.Count)
    }
    if ($online -gt 0) { Write-Log ("{0} photo(s) présente(s) seulement dans le nuage (OneDrive) : non téléchargées, non comparées." -f $online) 'WARN' }

    # 2. Même taille -> même début (64 Ko) -> même SHA-256 complet -> identiques octet par octet
    $bySize = @{}
    foreach ($fi in $files) {
        $k = [string]$fi.Length
        if (-not $bySize.ContainsKey($k)) { $bySize[$k] = New-Object System.Collections.ArrayList }
        [void]$bySize[$k].Add($fi)
    }
    $groups = New-Object System.Collections.ArrayList
    $done = 0
    foreach ($k in @($bySize.Keys)) {
        $lst = $bySize[$k]
        if ($lst.Count -lt 2) { continue }
        $byHead = @{}
        foreach ($fi in $lst) {
            $h = Get-FileSha $fi.FullName 65536
            if (-not $h) { continue }
            if (-not $byHead.ContainsKey($h)) { $byHead[$h] = New-Object System.Collections.ArrayList }
            [void]$byHead[$h].Add($fi)
        }
        foreach ($hl in @($byHead.Values)) {
            if ($hl.Count -lt 2) { continue }
            $byFull = @{}
            foreach ($fi in $hl) {
                $h = $(if ([long]$fi.Length -le 65536) { Get-FileSha $fi.FullName 65536 } else { Get-FileSha $fi.FullName })
                if (-not $h) { continue }
                if (-not $byFull.ContainsKey($h)) { $byFull[$h] = New-Object System.Collections.ArrayList }
                [void]$byFull[$h].Add($fi)
            }
            foreach ($fl in @($byFull.Values)) {
                if ($fl.Count -lt 2) { continue }
                # Confirmation octet par octet contre le premier fichier du groupe
                $ref = $fl[0]; $same = New-Object System.Collections.ArrayList; [void]$same.Add($ref)
                for ($i = 1; $i -lt $fl.Count; $i++) {
                    if (Test-SameContent $ref.FullName $fl[$i].FullName) { [void]$same.Add($fl[$i]) }
                    else { Write-Log ("Empreinte identique mais contenu différent (écarté) : {0}" -f (Get-ShortPathText $fl[$i].FullName)) 'WARN' }
                }
                if ($same.Count -ge 2) { [void]$groups.Add(@{ Kind = 'bin'; Files = @($same) }) }
            }
        }
        $done += $lst.Count
    }
    Write-Log ("{0} groupe(s) de fichiers identiques octet par octet." -f $groups.Count) 'OK'

    # 3. Option : même image (pixels identiques), métadonnées différentes
    if ($Pixels) {
        Write-Log 'Comparaison des pixels (ignore les métadonnées) : plus lente…'
        $inBin = @{}
        foreach ($g in $groups) { foreach ($fi in $g.Files) { $inBin[$fi.FullName] = $g } }
        # un représentant par groupe binaire + les photos isolées décodables
        $reps = New-Object System.Collections.ArrayList
        foreach ($g in $groups) { [void]$reps.Add(@{ File = $g.Files[0]; Group = $g }) }
        foreach ($fi in $files) {
            if ($inBin.ContainsKey($fi.FullName)) { continue }
            if ($Script:PixelExt -contains $fi.Extension.ToLowerInvariant()) { [void]$reps.Add(@{ File = $fi; Group = $null }) }
        }
        $byDim = @{}
        foreach ($rp in $reps) {
            if ($Script:PixelExt -notcontains $rp.File.Extension.ToLowerInvariant()) { continue }
            $dim = $null; try { $dim = [BJ.PixelTools]::Dimensions($rp.File.FullName) } catch {}
            if (-not $dim) { continue }
            if (-not $byDim.ContainsKey($dim)) { $byDim[$dim] = New-Object System.Collections.ArrayList }
            [void]$byDim[$dim].Add($rp)
        }
        $pix = 0
        foreach ($dl in @($byDim.Values)) {
            if ($dl.Count -lt 2) { continue }
            $byPix = @{}
            foreach ($rp in $dl) {
                $h = Get-PixelSignature $rp.File.FullName
                if (-not $h) { continue }
                if (-not $byPix.ContainsKey($h)) { $byPix[$h] = New-Object System.Collections.ArrayList }
                [void]$byPix[$h].Add($rp)
            }
            foreach ($pl in @($byPix.Values)) {
                if ($pl.Count -lt 2) { continue }
                $all = New-Object System.Collections.ArrayList
                foreach ($rp in $pl) {
                    if ($rp.Group) { foreach ($fi in $rp.Group.Files) { [void]$all.Add($fi) }; [void]$groups.Remove($rp.Group) }
                    else { [void]$all.Add($rp.File) }
                }
                [void]$groups.Add(@{ Kind = 'pix'; Files = @($all) }); $pix++
            }
        }
        Write-Log ("{0} groupe(s) « même image, métadonnées différentes »." -f $pix) 'OK'
    }

    # 4. Résultat : dans chaque groupe, on propose de garder la plus ancienne (identiques) ou la plus lourde (métadonnées les plus complètes)
    $out = New-Object System.Collections.ArrayList
    $wasted = [long]0; $n = 0
    foreach ($g in @($groups | Sort-Object { - ([long]$_.Files[0].Length * ($_.Files.Count - 1)) })) {
        $n++
        if ($n -gt $Script:DupMaxGroups) { Write-Log ("Plus de {0} groupes : seuls les {0} plus gros sont affichés ; relancez après traitement." -f $Script:DupMaxGroups) 'WARN'; break }
        if ($g.Kind -eq 'pix') { $sorted = @($g.Files | Sort-Object @{ Expression = { - [long]$_.Length } }, @{ Expression = { $_.LastWriteTimeUtc } }, @{ Expression = { $_.FullName.Length } }) }
        else { $sorted = @($g.Files | Sort-Object @{ Expression = { $_.LastWriteTimeUtc } }, @{ Expression = { $_.FullName.Length } }) }
        $rows = @(); $first = $true
        foreach ($fi in $sorted) {
            $rows += [pscustomobject]@{ Path = (Get-ShortPathText $fi.FullName); Size = [long]$fi.Length; Date = $fi.LastWriteTime; Keep = $first }
            if (-not $first -and $g.Kind -eq 'bin') { $wasted += [long]$fi.Length }
            $first = $false
        }
        [void]$out.Add([pscustomobject]@{ Id = $n; Kind = $g.Kind; Files = $rows })
    }
    $nb = @($out | Where-Object { $_.Kind -eq 'bin' }).Count
    Write-Log ("{0} photo(s) analysée(s) : {1} groupe(s) de doublons exacts ({2} récupérables), {3} groupe(s) « même image »." -f $files.Count, $nb, (Format-DupSize $wasted), (@($out).Count - $nb)) 'OK'
    Set-SyncResult @{ Groups = @($out); Scanned = $files.Count; Roots = @($roots); Wasted = $wasted; Online = $online }
}

function Move-DuplicatePhotos {
    # -Pairs : 'bin|doublon|à garder' ou 'pix|doublon|à garder' ('|' est interdit dans un nom de fichier Windows).
    # Chaque paire est revérifiée juste avant le déplacement : si le contenu (ou l'image) n'est plus identique, rien ne bouge.
    param([string[]]$Pairs = @())
    $fast = Initialize-PhotoTools
    $session = (Get-Date -Format 'yyyyMMdd_HHmmss')
    $manifest = New-Object System.Collections.ArrayList
    $ok = @(); $ko = @(); $bytes = [long]0
    try { New-Item -ItemType Directory -Path $Script:DupLogDir -Force -ErrorAction Stop | Out-Null } catch {}
    $mfile = Join-Path $Script:DupLogDir ("Doublons_{0}.json" -f $session)
    $save = { Set-Content -LiteralPath $mfile -Value (ConvertTo-Json -InputObject @{ Session = $session; Pc = $env:COMPUTERNAME; Items = @($manifest) } -Depth 4) -Encoding UTF8 -ErrorAction SilentlyContinue }
    foreach ($pr in @($Pairs)) {
        $parts = ([string]$pr) -split '\|'
        if ($parts.Count -ne 3) { $ko += [string]$pr; continue }
        $kind = $parts[0]; $dup = $parts[1]; $keep = $parts[2]
        if ($dup -ieq $keep) { $ko += $dup; continue }
        $ld = Get-LongPath $dup; $lk = Get-LongPath $keep
        if (-not [IO.File]::Exists($ld)) { Write-Log "Déjà absent : $dup" 'WARN'; $ko += $dup; continue }
        if (-not [IO.File]::Exists($lk)) { Write-Log "Photo à garder introuvable, doublon conservé : $keep" 'WARN'; $ko += $dup; continue }
        $same = $false
        if ($kind -eq 'pix') { if ($fast) { $a = Get-PixelSignature $ld; $b = Get-PixelSignature $lk; $same = [bool]($a -and $a -eq $b) } }
        else { $same = Test-SameContent $ld $lk }
        if (-not $same) { Write-Log "Plus identique à la photo gardée, conservé : $dup" 'WARN'; $ko += $dup; continue }
        try {
            $root = [IO.Path]::GetPathRoot($dup)
            $rel = $dup.Substring($root.Length)
            $tag = $(if ($root -match '^([A-Za-z]):') { $Matches[1] } else { 'reseau' })
            $target = Join-Path (Join-Path (Join-Path (Join-Path $root $Script:DupRootName) $session) $tag) $rel
            $lt = Get-LongPath $target
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($lt))
            $len = (New-Object IO.FileInfo $ld).Length
            [IO.File]::Move($ld, $lt)
            [void]$manifest.Add(@{ From = $dup; To = $target; Keep = $keep; Kind = $kind })
            $ok += $dup; $bytes += [long]$len
            if (($manifest.Count % 50) -eq 0) { & $save }
        } catch { Write-Log ("Déplacement impossible ({0}) : {1}" -f $_.Exception.Message, $dup) 'WARN'; $ko += $dup }
    }
    & $save
    if ($manifest.Count -eq 0) { Remove-Item -LiteralPath $mfile -Force -ErrorAction SilentlyContinue }
    Write-Log ("{0} doublon(s) mis de côté ({1}), {2} conservé(s). Dossier : <disque>\{3}\{4}. Annulable : « Remettre les photos en place »." -f $ok.Count, (Format-DupSize $bytes), $ko.Count, $Script:DupRootName, $session) $(if ($ko.Count -eq 0) { 'OK' } else { 'WARN' })
    Set-SyncResult @{ Ok = @($ok); Bad = @($ko); Reboot = $false; Session = $(if ($manifest.Count -gt 0) { $session } else { '' }); Bytes = $bytes }
}

function Restore-DuplicatePhotos {
    # Remet à leur place les photos d'une mise de côté. Un fichier revenu entre-temps au même endroit n'est jamais écrasé.
    param([string]$Session)
    if ($Session -notmatch '^\d{8}_\d{6}$') { Write-Log 'Mise de côté invalide.' 'ERROR'; Set-SyncResult @{ Ok = @(); Bad = @('session'); Reboot = $false }; return }
    $mfile = Join-Path $Script:DupLogDir ("Doublons_{0}.json" -f $Session)
    if (-not (Test-Path -LiteralPath $mfile)) { Write-Log "Liste introuvable : $mfile" 'ERROR'; Set-SyncResult @{ Ok = @(); Bad = @($Session); Reboot = $false }; return }
    $m = $null
    try { $m = Get-Content -LiteralPath $mfile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Write-Log "Liste illisible : $mfile" 'ERROR'; Set-SyncResult @{ Ok = @(); Bad = @($Session); Reboot = $false }; return }
    $ok = @(); $ko = @(); $left = New-Object System.Collections.ArrayList
    foreach ($it in @($m.Items)) {
        $from = [string]$it.From; $to = [string]$it.To
        $lf = Get-LongPath $from; $lt = Get-LongPath $to
        if (-not [IO.File]::Exists($lt)) { Write-Log "Absent du dossier des doublons (déjà remis ou supprimé) : $from" 'WARN'; $ko += $from; continue }
        if ([IO.File]::Exists($lf)) { Write-Log "Un fichier existe déjà à cet endroit, rien n'est écrasé : $from" 'WARN'; $ko += $from; [void]$left.Add($it); continue }
        try {
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($lf))
            [IO.File]::Move($lt, $lf); $ok += $from
        } catch { Write-Log ("Remise en place impossible ({0}) : {1}" -f $_.Exception.Message, $from) 'WARN'; $ko += $from; [void]$left.Add($it) }
    }
    # Ménage des dossiers vides laissés dans BJMPC-Doublons\<session>
    foreach ($root in @(@($m.Items) | ForEach-Object { [IO.Path]::GetPathRoot([string]$_.To) } | Sort-Object -Unique)) {
        $sd = Join-Path (Join-Path $root $Script:DupRootName) $Session
        try {
            if (Test-Path -LiteralPath $sd) {
                foreach ($dd in @(Get-ChildItem -LiteralPath $sd -Directory -Recurse -Force -ErrorAction SilentlyContinue | Sort-Object { $_.FullName.Length } -Descending)) {
                    if (@(Get-ChildItem -LiteralPath $dd.FullName -Force -ErrorAction SilentlyContinue).Count -eq 0) { Remove-Item -LiteralPath $dd.FullName -Force -ErrorAction SilentlyContinue }
                }
                if (@(Get-ChildItem -LiteralPath $sd -Force -ErrorAction SilentlyContinue).Count -eq 0) { Remove-Item -LiteralPath $sd -Force -ErrorAction SilentlyContinue }
            }
        } catch {}
    }
    if ($left.Count -eq 0) { Remove-Item -LiteralPath $mfile -Force -ErrorAction SilentlyContinue }
    else { Set-Content -LiteralPath $mfile -Value (ConvertTo-Json -InputObject @{ Session = $Session; Pc = [string]$m.Pc; Items = @($left) } -Depth 4) -Encoding UTF8 -ErrorAction SilentlyContinue }
    Write-Log ("{0} photo(s) remise(s) en place, {1} non remise(s)." -f $ok.Count, $ko.Count) $(if ($ko.Count -eq 0) { 'OK' } else { 'WARN' })
    Set-SyncResult @{ Ok = @($ok); Bad = @($ko); Reboot = $false }
}

# ---------------------------------------------------------------- Imprimantes : blocages à l'ouverture de Word/Excel et à l'impression
# Cause fréquente : une imprimante réseau (TCP/IP, WSD, IPP) éteinte ou déplacée reste déclarée ; le spouleur attend sa réponse.
# La lecture ne modifie rien. Le nettoyage sauvegarde d'abord toutes les imprimantes (PrintBrm) et ne retire que les files
# réseau qui ne répondent plus, jamais les imprimantes USB, virtuelles (PDF, XPS, OneNote) ou partagées.
$Script:PrnDir = Join-Path $Script:LogDir 'Imprimantes'

function Test-PrinterReach {
    # Vrai si l'adresse répond sur l'un des ports ou au ping ; faux sinon ; $null si pas d'adresse à tester.
    param([string]$HostName, [int[]]$Ports, [int]$TimeoutMs = 1500)
    if (-not $HostName) { return $null }
    $ip = $null
    try {
        if (-not [System.Net.IPAddress]::TryParse($HostName, [ref]$ip)) {
            $ar = [System.Net.Dns]::BeginGetHostAddresses($HostName, $null, $null)
            if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
            $ip = @([System.Net.Dns]::EndGetHostAddresses($ar) | Where-Object { $_.AddressFamily -eq 'InterNetwork' -or $_.AddressFamily -eq 'InterNetworkV6' }) | Select-Object -First 1
            if (-not $ip) { return $false }
        }
    } catch { return $false }
    foreach ($p in @($Ports)) {
        if ([int]$p -le 0) { continue }
        $c = $null
        try {
            $c = New-Object System.Net.Sockets.TcpClient($ip.AddressFamily)
            $ar = $c.BeginConnect($ip, [int]$p, $null, $null)
            if ($ar.AsyncWaitHandle.WaitOne($TimeoutMs)) { $c.EndConnect($ar); if ($c.Connected) { return $true } }
        } catch {} finally { if ($c) { try { $c.Close() } catch {} } }
    }
    # Une imprimante en veille profonde répond souvent au ping sans ouvrir son port : on ne la déclare pas absente.
    try {
        $pg = New-Object System.Net.NetworkInformation.Ping
        try { if ($pg.Send($ip, $TimeoutMs).Status -eq 'Success') { return $true } } finally { $pg.Dispose() }
    } catch {}
    return $false
}

function Get-PrinterKind {
    param([string]$Name, [string]$PortName, [string]$Driver, $Port)
    if ($Driver -match 'Print To PDF|XPS Document Writer|OneNote|Microsoft Shared Fax|Software Printer' -or $PortName -match '^(PORTPROMPT:|nul:?|FILE:|XPSPort:|SHRFAX:)') { return 'Virtuelle' }
    if ($Name.StartsWith('\\')) { return 'Partagée' }
    if ($PortName -match '^(USB|DOT4|BTH|LPT|COM|TS\d)') { return 'USB / locale' }
    if ($PortName -match '^WSD-') { return 'WSD' }
    if ($PortName -match '^(https?|ipps?)://') { return 'IPP' }
    if ($Port -and [string]$Port.PrinterHostAddress) { return 'TCP/IP' }
    return 'Autre'
}

function Get-PrinterRows {
    # Imprimantes et ports d'impression, avec la joignabilité des adresses réseau. Renvoie $null si la lecture échoue.
    $rows = New-Object System.Collections.ArrayList
    $ports = @{}
    try { foreach ($p in @(Get-PrinterPort -ErrorAction Stop)) { $ports[[string]$p.Name] = $p } }
    catch { Write-Log ("Lecture des ports d'impression impossible : " + $_.Exception.Message) 'WARN' }
    $printers = @()
    try { $printers = @(Get-CimInstance -ClassName Win32_Printer -ErrorAction Stop) }
    catch { Write-Log ("Lecture des imprimantes impossible : " + $_.Exception.Message) 'ERROR'; return $null }
    $used = @{}; $cache = @{}
    foreach ($pr in $printers) {
        $name = [string]$pr.Name; $portName = [string]$pr.PortName
        $port = $ports[$portName]
        if ($portName) { $used[$portName] = $true }
        $kind = Get-PrinterKind $name $portName ([string]$pr.DriverName) $port
        $hostName = ''; $tests = @()
        switch ($kind) {
            'TCP/IP' { $hostName = [string]$port.PrinterHostAddress; $pn = 0; try { $pn = [int]$port.PortNumber } catch {}; if ($pn -le 0) { $pn = 9100 }; $tests = @($pn) }
            'IPP' {
                try {
                    $u = [uri]$portName; $hostName = [string]$u.Host
                    if ($portName -match '^[A-Za-z]+://[^/]+:(\d+)') { $tests = @([int]$Matches[1]) } else { $tests = @(631, [int]$u.Port) }
                } catch {}
            }
            'WSD' { if ($port -and [string]$port.PrinterHostAddress) { $hostName = [string]$port.PrinterHostAddress; $tests = @(80, 443, 9100) } }
        }
        $reach = $null
        if ($hostName) {
            $ck = $hostName + '|' + ($tests -join ',')
            if (-not $cache.ContainsKey($ck)) { $cache[$ck] = Test-PrinterReach $hostName $tests }
            $reach = $cache[$ck]
        }
        $offline = $false; try { $offline = [bool]$pr.WorkOffline } catch {}
        $dead = $false; $state = ''; $why = ''
        switch ($kind) {
            'Virtuelle' { $state = 'Virtuelle (jamais touchée)' }
            'Partagée'  { $state = 'Partagée (non testée)' }
            'USB / locale' { $state = 'Locale (jamais touchée)' }
            'Autre'     { $state = 'Non vérifiable' }
            default {
                if ($reach -eq $true) { $state = 'Répond' }
                elseif ($reach -eq $false) { $state = 'Ne répond pas'; $dead = $true; $why = "L'adresse $hostName ne répond ni au ping ni sur le port d'impression." }
                elseif ($offline) { $state = 'Hors ligne (selon Windows)'; $dead = $true; $why = "Windows la marque hors ligne et son adresse n'est pas connue." }
                else { $state = 'Non vérifiable' }
            }
        }
        $isDef = $false; try { $isDef = [bool]$pr.Default } catch {}
        [void]$rows.Add([pscustomobject]@{
            Id = $name; IsPort = $false; Name = $name; Kind = $kind; Port = $portName; Target = $(if ($hostName) { $hostName } else { $portName })
            State = $state; Reach = $reach; Dead = $dead; Default = $isDef; Why = $why
        })
    }
    # Ports réseau qui n'appartiennent plus à aucune imprimante (restes d'imprimantes supprimées)
    foreach ($k in @($ports.Keys | Sort-Object)) {
        if ($used.ContainsKey($k)) { continue }
        $p = $ports[$k]
        $isNet = ($k -match '^(WSD-|https?://|ipps?://)') -or [bool]([string]$p.PrinterHostAddress)
        if (-not $isNet) { continue }
        $h = [string]$p.PrinterHostAddress
        [void]$rows.Add([pscustomobject]@{
            Id = $k; IsPort = $true; Name = $k; Kind = 'Port orphelin'; Port = $k; Target = $(if ($h) { $h } else { $k })
            State = 'Aucune imprimante ne l''utilise'; Reach = $null; Dead = $true; Default = $false; Why = 'Port réseau resté après la suppression de son imprimante.'
        })
    }
    return @($rows)
}

function Get-PrinterDiagnostic {
    Write-Log '=== Imprimantes et ports d''impression (lecture seule) ==='
    $svc = Get-Service -Name Spooler -ErrorAction SilentlyContinue
    if ($svc) { Write-Row 'Spouleur d''impression' ("{0} · démarrage {1}" -f $svc.Status, $svc.StartType) $(if ($svc.Status -eq 'Running') { 'ok' } else { 'bad' }) }
    $jobs = 0; try { $jobs = @(Get-CimInstance -ClassName Win32_PrintJob -ErrorAction Stop).Count } catch {}
    Write-Row 'Travaux en attente' ([string]$jobs) $(if ($jobs -gt 0) { 'warn' } else { 'ok' })
    $rows = Get-PrinterRows
    if ($null -eq $rows) { return }
    $rows = @($rows)
    foreach ($r in $rows) {
        $lvl = $(if ($r.Dead) { 'bad' } elseif ($r.State -eq 'Répond') { 'ok' } else { '' })
        Write-Row ("{0}{1}  [{2}]" -f $r.Name, $(if ($r.Default) { ' (par défaut)' } else { '' }), $r.Kind) ("{0} · {1}" -f $r.Target, $r.State) $lvl
    }
    $def = @($rows | Where-Object { $_.Default }) | Select-Object -First 1
    $defDead = [bool]($def -and $def.Dead)
    if ($defDead) { Write-Log ("L'imprimante par défaut « {0} » ne répond pas : c'est la cause la plus probable du blocage de Word et d'Excel au démarrage." -f $def.Name) 'WARN' }
    try {
        $mon = @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Print\Monitors' -ErrorAction Stop | ForEach-Object { $_.PSChildName })
        if ($mon.Count -gt 0) { Write-Log ("Moniteurs de ports installés : " + ($mon -join ', ')) }
    } catch {}
    foreach ($n in 'FDResPub', 'fdPHost', 'SSDPSRV') {
        $s = Get-Service -Name $n -ErrorAction SilentlyContinue
        if ($s) { Write-Log ("Service de découverte {0} ({1}) : {2}" -f $s.DisplayName, $n, $s.Status) }
    }
    $nDead = @($rows | Where-Object { $_.Dead }).Count
    if ($nDead -gt 0) { Write-Log ("{0} imprimante(s) ou port(s) réseau qui ne répondent plus : cochez-les pour les retirer (une sauvegarde est faite avant)." -f $nDead) 'WARN' }
    else { Write-Log 'Aucune imprimante ou port réseau mort détecté.' 'OK' }
    Set-SyncResult @{ Rows = @($rows); DefaultName = $(if ($def) { [string]$def.Name } else { '' }); DefaultDead = $defDead; Spooler = $(if ($svc) { [string]$svc.Status } else { '' }); Jobs = $jobs }
}

function Export-PrintersBackup {
    # Sauvegarde toutes les imprimantes : liste lisible (JSON) + export complet PrintBrm (files, pilotes, ports) pour restaurer.
    # Renvoie @{ Base; Json; Export; ExportOk } ou $null si même la liste n'a pas pu être écrite.
    New-Item -ItemType Directory -Path $Script:PrnDir -Force -ErrorAction SilentlyContinue | Out-Null
    $base = "Imprimantes_{0}_{1}" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmmss')
    $json = Join-Path $Script:PrnDir ($base + '.json'); $exp = Join-Path $Script:PrnDir ($base + '.printerExport')
    try {
        $pr = @(Get-CimInstance -ClassName Win32_Printer -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Name = [string]$_.Name; Driver = [string]$_.DriverName; Port = [string]$_.PortName; Default = [bool]$_.Default; Shared = [bool]$_.Shared; ShareName = [string]$_.ShareName; Location = [string]$_.Location; Comment = [string]$_.Comment } })
        $po = @(); try { $po = @(Get-PrinterPort -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Name = [string]$_.Name; Host = [string]$_.PrinterHostAddress; PortNumber = [string]$_.PortNumber; Description = [string]$_.Description } }) } catch {}
        Set-Content -LiteralPath $json -Value (ConvertTo-Json -InputObject ([ordered]@{ Date = (Get-Date).ToString('s'); Pc = $env:COMPUTERNAME; Printers = $pr; Ports = $po }) -Depth 4) -Encoding UTF8 -ErrorAction Stop
    } catch { Write-Log ("Sauvegarde de la liste impossible : " + $_.Exception.Message) 'ERROR'; return $null }
    $exe = Join-Path $env:windir 'System32\spool\tools\PrintBrm.exe'
    $ok = $false
    if (Test-Path -LiteralPath $exe) {
        try {
            $proc = Start-Process -FilePath $exe -ArgumentList @('-B', '-F', ('"' + $exp + '"')) -PassThru -WindowStyle Hidden -ErrorAction Stop
            if (-not $proc.WaitForExit(240000)) { try { $proc.Kill() } catch {}; Write-Log 'Export PrintBrm trop long : abandonné.' 'WARN' }
            elseif ($proc.ExitCode -eq 0 -and (Test-Path -LiteralPath $exp)) { $ok = $true }
            else { Write-Log ("Export PrintBrm refusé (code {0})." -f $proc.ExitCode) 'WARN' }
        } catch { Write-Log ("Export PrintBrm impossible : " + $_.Exception.Message) 'WARN' }
    } else { Write-Log 'PrintBrm absent sur ce PC : seule la liste lisible est sauvegardée.' 'WARN' }
    return @{ Base = $base; Json = $json; Export = $exp; ExportOk = $ok; ExportAvailable = (Test-Path -LiteralPath $exe) }
}

function Remove-DeadPrinters {
    # Retire les imprimantes réseau et ports orphelins demandés, SI ils sont toujours morts maintenant (revérifié ici).
    # Sauvegarde obligatoire avant : sans export PrintBrm réussi (quand l'outil existe), rien n'est supprimé.
    param([string[]]$Names = @(), [string[]]$Ports = @())
    $ok = @(); $ko = @()
    $svc = Get-Service -Name Spooler -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Running') { try { Start-Service -Name Spooler -ErrorAction Stop } catch { Write-Log 'Spouleur arrêté et impossible à démarrer.' 'ERROR'; Set-SyncResult @{ Ok = @(); Bad = @($Names + $Ports); Backup = '' }; return } }
    $rows = Get-PrinterRows
    if ($null -eq $rows) { Set-SyncResult @{ Ok = @(); Bad = @($Names + $Ports); Backup = '' }; return }
    $dead = @{}; foreach ($r in @($rows)) { if ($r.Dead) { $dead[[string]$r.Kind + '|' + [string]$r.Id] = $r } }
    $todoP = @(); $todoPo = @()
    foreach ($n in @($Names)) {
        $r = @($rows | Where-Object { -not $_.IsPort -and [string]$_.Name -eq $n }) | Select-Object -First 1
        if (-not $r) { Write-Log "Imprimante introuvable (déjà retirée ?) : $n" 'WARN'; $ko += $n; continue }
        if (-not $r.Dead) { Write-Log ("Conservée ({0}, {1}) : {2}" -f $r.Kind, $r.State, $n) 'WARN'; $ko += $n; continue }
        $todoP += $r
    }
    foreach ($n in @($Ports)) {
        $r = @($rows | Where-Object { $_.IsPort -and [string]$_.Name -eq $n }) | Select-Object -First 1
        if (-not $r) { Write-Log "Port introuvable ou utilisé par une imprimante : $n" 'WARN'; $ko += $n; continue }
        $todoPo += $r
    }
    if (($todoP.Count + $todoPo.Count) -eq 0) { Write-Log 'Rien à retirer.' 'WARN'; Set-SyncResult @{ Ok = @(); Bad = @($ko); Backup = '' }; return }
    $bk = Export-PrintersBackup
    if (-not $bk -or ($bk.ExportAvailable -and -not $bk.ExportOk)) {
        Write-Log 'Sauvegarde des imprimantes incomplète : rien n''a été supprimé.' 'ERROR'
        Set-SyncResult @{ Ok = @(); Bad = @($Names + $Ports); Backup = $(if ($bk) { $bk.Json } else { '' }) }; return
    }
    Write-Log ("Sauvegarde faite : {0}" -f $bk.Base) 'OK'
    $portsAfter = @()
    foreach ($r in $todoP) {
        try {
            Remove-Printer -Name ([string]$r.Name) -ErrorAction Stop
            Write-Log ("Imprimante retirée : {0} ({1})" -f $r.Name, $r.Kind) 'OK'; $ok += [string]$r.Name
            if ($r.Port) { $portsAfter += [string]$r.Port }
        } catch { Write-Log ("Refusé : {0} ({1})" -f $r.Name, $_.Exception.Message) 'WARN'; $ko += [string]$r.Name }
    }
    # Ports : ceux demandés (orphelins) et ceux des imprimantes retirées, seulement s'ils ne servent plus à personne
    $inUse = @{}
    try { foreach ($p in @(Get-CimInstance -ClassName Win32_Printer -ErrorAction Stop)) { $inUse[[string]$p.PortName] = $true } } catch {}
    $netPorts = @{}
    foreach ($r in @($rows)) { if ($r.Kind -match '^(TCP/IP|IPP|WSD|Port orphelin)$') { $netPorts[[string]$r.Port] = $true } }
    foreach ($pn in @(@($todoPo | ForEach-Object { [string]$_.Name }) + $portsAfter | Sort-Object -Unique)) {
        if (-not $netPorts.ContainsKey($pn) -or $inUse.ContainsKey($pn)) { continue }
        try { Remove-PrinterPort -Name $pn -ErrorAction Stop; Write-Log ("Port retiré : $pn") 'OK'; if ($Ports -contains $pn) { $ok += $pn } }
        catch { Write-Log ("Port conservé ($pn) : " + $_.Exception.Message) 'WARN'; if ($Ports -contains $pn) { $ko += $pn } }
    }
    Write-Log ("{0} élément(s) retiré(s), {1} conservé(s). Pour revenir en arrière : Restaurer une sauvegarde d'imprimantes ({2})." -f $ok.Count, $ko.Count, $bk.Base) $(if ($ko.Count -eq 0) { 'OK' } else { 'WARN' })
    Set-SyncResult @{ Ok = @($ok); Bad = @($ko); Backup = $bk.Base }
}

function Restore-PrintersBackup {
    # Réimporte une sauvegarde faite avant un nettoyage (imprimantes, pilotes et ports). Les files du même nom sont remplacées.
    param([string]$Name)
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9_.\-]*$') { Write-Log 'Nom de sauvegarde invalide.' 'ERROR'; Set-SyncResult @{ Ok = @(); Bad = @('nom'); Backup = '' }; return }
    $exp = Join-Path $Script:PrnDir ($Name + '.printerExport')
    $exe = Join-Path $env:windir 'System32\spool\tools\PrintBrm.exe'
    if (-not (Test-Path -LiteralPath $exp)) { Write-Log "Export introuvable : $exp (seule la liste lisible existe)" 'ERROR'; Set-SyncResult @{ Ok = @(); Bad = @($Name); Backup = '' }; return }
    if (-not (Test-Path -LiteralPath $exe)) { Write-Log 'PrintBrm absent : restauration impossible sur ce PC.' 'ERROR'; Set-SyncResult @{ Ok = @(); Bad = @($Name); Backup = '' }; return }
    Write-Log "Restauration des imprimantes : $Name"
    $good = $false
    try {
        $proc = Start-Process -FilePath $exe -ArgumentList @('-R', '-F', ('"' + $exp + '"'), '-O', 'FORCE') -PassThru -WindowStyle Hidden -ErrorAction Stop
        if (-not $proc.WaitForExit(300000)) { try { $proc.Kill() } catch {}; Write-Log 'Restauration trop longue : abandonnée.' 'ERROR' }
        elseif ($proc.ExitCode -eq 0) { $good = $true } else { Write-Log ("PrintBrm a refusé (code {0})." -f $proc.ExitCode) 'ERROR' }
    } catch { Write-Log ("Restauration impossible : " + $_.Exception.Message) 'ERROR' }
    try { Restart-Service -Name Spooler -Force -ErrorAction SilentlyContinue } catch {}
    if ($good) { Write-Log 'Imprimantes restaurées.' 'OK'; Set-SyncResult @{ Ok = @($Name); Bad = @(); Backup = $Name } }
    else { Set-SyncResult @{ Ok = @(); Bad = @($Name); Backup = $Name } }
}

function Sync-Clock {
    Write-Log "Synchronisation de l'horloge"
    try {
        $svc = Get-Service -Name w32time -ErrorAction Stop
        if ($svc.Status -ne 'Running') { Start-Service -Name w32time -ErrorAction Stop }
        foreach ($l in @(Invoke-NativeLines 'w32tm.exe' '/resync')) { Write-Host "        $l" -ForegroundColor DarkGray }
        Write-Log ("Heure actuelle : {0}" -f (Get-Date -Format 'dd/MM/yyyy HH:mm:ss')) 'OK'
    } catch { Write-Log "Échec : $($_.Exception.Message)" 'ERROR' }
}

function Start-MemoryDiagnostic {
    Write-Log "Ouverture du Diagnostic de mémoire Windows (il propose de redémarrer le PC)"
    try { Start-Process mdsched.exe -ErrorAction Stop } catch { Write-Log "Lancement impossible : $($_.Exception.Message)" 'ERROR' }
}

function Clear-ShaderCache {
    Write-Log "=== Vidage des caches de shaders (DirectX, NVIDIA, AMD) ==="
    $dirs = @(
        (Join-Path $env:LOCALAPPDATA 'D3DSCache'),
        (Join-Path $env:LOCALAPPDATA 'NVIDIA\DXCache'),
        (Join-Path $env:LOCALAPPDATA 'NVIDIA\GLCache'),
        (Join-Path $env:LOCALAPPDATA 'AMD\DxCache'),
        (Join-Path $env:LOCALAPPDATA 'AMD\GLCache')
    )
    $freed = 0.0
    foreach ($d in $dirs) {
        if (-not (Test-Path $d)) { continue }
        $size = (Get-ChildItem -Path $d -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        if ($size) { $freed += $size }
        Get-ChildItem -Path $d -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log ("Vidé : {0}" -f $d) 'OK'
    }
    Write-Log ("{0:N0} Mo libérés. Les shaders sont recompilés au prochain lancement des jeux (premier démarrage un peu plus long)." -f ($freed / 1MB)) 'OK'
}


# ================================================================ APPLICATIONS (winget, applications préinstallées, OneDrive)
# Catalogue d'applications installables avec winget : Catégorie, Nom, Identifiant.
# Source : liste du projet WinScript, nettoyée (voir LISEZMOI : entrées obsolètes retirées).
$Script:AppCatalog = @(
    @('Pilotes', 'Intel Driver and Support Assistant', 'Intel.IntelDriverAndSupportAssistant'),
    @('Pilotes', 'NVIDIA (NVCleanstall)', 'TechPowerUp.NVCleanstall'),
    @('Navigateurs', 'Brave', 'Brave.Brave'),
    @('Navigateurs', 'Chrome', 'Google.Chrome'),
    @('Navigateurs', 'Edge', 'Microsoft.Edge'),
    @('Navigateurs', 'Falkon', 'KDE.Falkon'),
    @('Navigateurs', 'Firefox', 'Mozilla.Firefox'),
    @('Navigateurs', 'FirefoxESR', 'Mozilla.Firefox.ESR'),
    @('Navigateurs', 'Floorp', 'Ablaze.Floorp'),
    @('Navigateurs', 'Helium', 'ImputNet.Helium'),
    @('Navigateurs', 'LibreWolf', 'LibreWolf.LibreWolf'),
    @('Navigateurs', 'Opera', 'Opera.Opera'),
    @('Navigateurs', 'Palemoon', 'MoonchildProductions.PaleMoon'),
    @('Navigateurs', 'Thorium', 'Alex313031.Thorium'),
    @('Navigateurs', 'Tor', 'TorProject.TorBrowser'),
    @('Navigateurs', 'Ungoogled', 'eloston.ungoogled-chromium'),
    @('Navigateurs', 'Vivaldi', 'Vivaldi.Vivaldi'),
    @('Navigateurs', 'Waterfox', 'Waterfox.Waterfox'),
    @('Navigateurs', 'ZenBrowser', 'Zen-Team.Zen-Browser'),
    @('Compression', '7Zip', '7zip.7zip'),
    @('Compression', 'Bandizip', 'Bandisoft.Bandizip'),
    @('Compression', 'NanaZip', 'M2Team.NanaZip'),
    @('Compression', 'PeaZip', 'Giorgiotani.Peazip'),
    @('Compression', 'WinRAR', 'RARLab.WinRAR'),
    @('Jeux', 'Cemu', 'Cemu.Cemu'),
    @('Jeux', 'DS4Windows', 'Ryochan7.DS4Windows'),
    @('Jeux', 'EAApp', 'ElectronicArts.EADesktop'),
    @('Jeux', 'EpicGames', 'EpicGames.EpicGamesLauncher'),
    @('Jeux', 'FaceIT', 'FACEITLTD.FACEITClient'),
    @('Jeux', 'GeforceNOW', 'Nvidia.GeForceNow'),
    @('Jeux', 'GOGGalaxy', 'GOG.Galaxy'),
    @('Jeux', 'Heroic', 'HeroicGamesLauncher.HeroicGamesLauncher'),
    @('Jeux', 'ItchIo', 'ItchIo.Itch'),
    @('Jeux', 'LGHub', 'Logitech.GHUB'),
    @('Jeux', 'Minecraft', 'Mojang.MinecraftLauncher'),
    @('Jeux', 'Modrinth', 'Modrinth.ModrinthApp'),
    @('Jeux', 'Moonlight', 'MoonlightGameStreamingProject.Moonlight'),
    @('Jeux', 'Parsec', 'Parsec.Parsec'),
    @('Jeux', 'PCSX2', 'PCSX2Team.PCSX2'),
    @('Jeux', 'PlayNite', 'Playnite.Playnite'),
    @('Jeux', 'PrismLauncher', 'PrismLauncher.PrismLauncher'),
    @('Jeux', 'RetroArch', 'Libretro.RetroArch'),
    @('Jeux', 'Steam', 'Valve.Steam'),
    @('Jeux', 'Sunshine', 'LizardByte.Sunshine'),
    @('Jeux', 'UbisoftConnect', 'Ubisoft.Connect'),
    @('Utilitaires', '1Password', 'AgileBits.1Password'),
    @('Utilitaires', 'ABDownloadManager', 'amir1376.ABDownloadManager'),
    @('Utilitaires', 'Afterburner', 'Guru3D.Afterburner'),
    @('Utilitaires', 'AnyDesk', 'AnyDesk.AnyDesk'),
    @('Utilitaires', 'AutoClicker', 'OPAutoClicker.OPAutoClicker'),
    @('Utilitaires', 'AutoHotkey', 'AutoHotkey.AutoHotkey'),
    @('Utilitaires', 'BitDefender', 'Bitdefender.Bitdefender'),
    @('Utilitaires', 'BitWarden', 'Bitwarden.Bitwarden'),
    @('Utilitaires', 'BulkCrapUninstaller', 'Klocman.BulkCrapUninstaller'),
    @('Utilitaires', 'BulkRename', 'TGRMNSoftware.BulkRenameUtility'),
    @('Utilitaires', 'CCleaner', 'Piriform.CCleaner'),
    @('Utilitaires', 'CoreTemp', 'ALCPU.CoreTemp'),
    @('Utilitaires', 'CPU-Z', 'CPUID.CPU-Z'),
    @('Utilitaires', 'CrystalDiskInfo', 'CrystalDewWorld.CrystalDiskInfo'),
    @('Utilitaires', 'CrystalDiskMark', 'CrystalDewWorld.CrystalDiskMark'),
    @('Utilitaires', 'DDU', 'Wagnardsoft.DisplayDriverUninstaller'),
    @('Utilitaires', 'Driver Store Explorer', 'lostindark.DriverStoreExplorer'),
    @('Utilitaires', 'Deskflow', 'Deskflow.Deskflow'),
    @('Utilitaires', 'DISMTools', 'CodingWondersSoftware.DISMTools.Stable'),
    @('Utilitaires', 'DropBox', 'Dropbox.Dropbox'),
    @('Utilitaires', 'EnteAuth', 'ente-io.auth-desktop'),
    @('Utilitaires', 'Etcher', 'Balena.Etcher'),
    @('Utilitaires', 'Everything', 'voidtools.Everything'),
    @('Utilitaires', 'FileConverter', 'AdrienAllard.FileConverter'),
    @('Utilitaires', 'FilesApp', 'FilesCommunity.Files'),
    @('Utilitaires', 'FlowLauncher', 'Flow-Launcher.Flow-Launcher'),
    @('Utilitaires', 'Flux', 'flux.flux'),
    @('Utilitaires', 'FXSound', 'FxSound.FxSound'),
    @('Utilitaires', 'GlazeWM', 'glzr-io.glazewm'),
    @('Utilitaires', 'GoogleDrive', 'Google.GoogleDrive'),
    @('Utilitaires', 'GPU-Z', 'TechPowerUp.GPU-Z'),
    @('Utilitaires', 'gsudo', 'gerardog.gsudo'),
    @('Utilitaires', 'HWInfo', 'REALiX.HWiNFO'),
    @('Utilitaires', 'HWMonitor', 'CPUID.HWMonitor'),
    @('Utilitaires', 'IDM', 'Tonec.InternetDownloadManager'),
    @('Utilitaires', 'ImgBurn', 'LIGHTNINGUK.ImgBurn'),
    @('Utilitaires', 'JDownloader', 'AppWork.JDownloader'),
    @('Utilitaires', 'KeePass', 'DominikReichl.KeePass'),
    @('Utilitaires', 'KeePassXC', 'KeePassXCTeam.KeePassXC'),
    @('Utilitaires', 'LocalSend', 'LocalSend.LocalSend'),
    @('Utilitaires', 'MEGASync', 'Mega.MEGASync'),
    @('Utilitaires', 'ModernFlyouts', 'ModernFlyouts.ModernFlyouts'),
    @('Utilitaires', 'MSEdgeRedirect', 'rcmaehl.MSEdgeRedirect'),
    @('Utilitaires', 'NextcloudClient', 'Nextcloud.NextcloudDesktop'),
    @('Utilitaires', 'NTLite', 'Nlitesoft.NTLite'),
    @('Utilitaires', 'OFGB', 'xM4ddy.OFGB'),
    @('Utilitaires', 'OpenRGB', 'OpenRGB.OpenRGB'),
    @('Utilitaires', 'PartitionWizard', 'MiniTool.PartitionWizard.Free'),
    @('Utilitaires', 'ProcessLasso', 'BitSum.ProcessLasso'),
    @('Utilitaires', 'ProtonAuth', 'Proton.ProtonAuthenticator'),
    @('Utilitaires', 'ProtonDrive', 'Proton.ProtonDrive'),
    @('Utilitaires', 'ProtonMail', 'Proton.ProtonMail'),
    @('Utilitaires', 'ProtonPass', 'Proton.ProtonPass'),
    @('Utilitaires', 'qBitTorrent', 'qBittorrent.qBittorrent'),
    @('Utilitaires', 'QuickLook', 'QL-Win.QuickLook'),
    @('Utilitaires', 'Rainmeter', 'Rainmeter.Rainmeter'),
    @('Utilitaires', 'Recuva', 'Piriform.Recuva'),
    @('Utilitaires', 'Revo', 'RevoUninstaller.RevoUninstaller'),
    @('Utilitaires', 'Rufus', 'Rufus.Rufus'),
    @('Utilitaires', 'SDIO', 'GlennDelahoy.SnappyDriverInstallerOrigin'),
    @('Utilitaires', 'Shell', 'Nilesoft.Shell'),
    @('Utilitaires', 'StartAllBack', 'StartIsBack.StartAllBack'),
    @('Utilitaires', 'Syncthing', 'Syncthing.Syncthing'),
    @('Utilitaires', 'SyncTrayzor', 'GermanCoding.SyncTrayzor'),
    @('Utilitaires', 'SystemInformer', 'WinsiderSS.SystemInformer'),
    @('Utilitaires', 'TeamViewer', 'TeamViewer.TeamViewer'),
    @('Utilitaires', 'TotalCommander', 'Ghisler.TotalCommander'),
    @('Utilitaires', 'TransluscentTB', 'CharlesMilette.TranslucentTB'),
    @('Utilitaires', 'TreeSize', 'JAMSoftware.TreeSize.Free'),
    @('Utilitaires', 'TwinkleTray', 'xanderfrangos.twinkletray'),
    @('Utilitaires', 'UniGetUI', 'Devolutions.UniGetUI'),
    @('Utilitaires', 'Ventoy', 'Ventoy.Ventoy'),
    @('Utilitaires', 'VirtualBox', 'Oracle.VirtualBox'),
    @('Utilitaires', 'WinDirStat', 'WinDirStat.WinDirStat'),
    @('Utilitaires', 'WindHawk', 'RamenSoftware.Windhawk'),
    @('Utilitaires', 'WizTree', 'AntibodySoftware.WizTree'),
    @('Réseau et outils pro', 'AdvancedIpScanner', 'Famatech.AdvancedIPScanner'),
    @('Réseau et outils pro', 'AngryIpScanner', 'angryziber.AngryIPScanner'),
    @('Réseau et outils pro', 'MobaXterm', 'Mobatek.MobaXterm'),
    @('Réseau et outils pro', 'MullvadVPN', 'MullvadVPN.MullvadVPN'),
    @('Réseau et outils pro', 'NetBird', 'Netbird.Netbird'),
    @('Réseau et outils pro', 'Nmap', 'Insecure.Nmap'),
    @('Réseau et outils pro', 'NordVPN', 'NordSecurity.NordVPN'),
    @('Réseau et outils pro', 'OpenVPN', 'OpenVPNTechnologies.OpenVPN'),
    @('Réseau et outils pro', 'ProtonVPN', 'Proton.ProtonVPN'),
    @('Réseau et outils pro', 'PuTTY', 'PuTTY.PuTTY'),
    @('Réseau et outils pro', 'SimpleWall', 'Henry++.simplewall'),
    @('Réseau et outils pro', 'Tailscale', 'Tailscale.Tailscale'),
    @('Réseau et outils pro', 'Termius', 'Termius.Termius'),
    @('Réseau et outils pro', 'TightVNC', 'GlavSoft.TightVNC'),
    @('Réseau et outils pro', 'WinSCP', 'WinSCP.WinSCP'),
    @('Réseau et outils pro', 'WireGuard', 'WireGuard.WireGuard'),
    @('Réseau et outils pro', 'WireShark', 'WiresharkFoundation.Wireshark'),
    @('Outils Microsoft', 'Autoruns', 'Microsoft.Sysinternals.Autoruns'),
    @('Outils Microsoft', 'NET10Runtime', 'Microsoft.DotNet.DesktopRuntime.10'),
    @('Outils Microsoft', 'NET6Runtime', 'Microsoft.DotNet.DesktopRuntime.6'),
    @('Outils Microsoft', 'NET9Runtime', 'Microsoft.DotNet.DesktopRuntime.9'),
    @('Outils Microsoft', 'Nuget', 'Microsoft.NuGet'),
    @('Outils Microsoft', 'OneDrive', 'Microsoft.OneDrive'),
    @('Outils Microsoft', 'PowerBI', 'Microsoft.PowerBI'),
    @('Outils Microsoft', 'PowerShell', 'Microsoft.PowerShell'),
    @('Outils Microsoft', 'PowerToys', 'Microsoft.PowerToys'),
    @('Outils Microsoft', 'ProcessExplorer', 'Microsoft.Sysinternals.ProcessExplorer'),
    @('Outils Microsoft', 'ProcessMonitor', 'Microsoft.Sysinternals.ProcessMonitor'),
    @('Outils Microsoft', 'TCPView', 'Microsoft.Sysinternals.TCPView'),
    @('Outils Microsoft', 'Visual C++ 2015-2022 (x64)', 'Microsoft.VCRedist.2015+.x64'),
    @('Outils Microsoft', 'Visual C++ 2015-2022 (x86)', 'Microsoft.VCRedist.2015+.x86'),
    @('Outils Microsoft', 'WinTerminal', 'Microsoft.WindowsTerminal'),
    @('Multimédia', 'AIMP', 'AIMP.AIMP'),
    @('Multimédia', 'Audacity', 'Audacity.Audacity'),
    @('Multimédia', 'Clementine', 'Clementine.Clementine'),
    @('Multimédia', 'DarkTable', 'darktable.darktable'),
    @('Multimédia', 'digiKam', 'KDE.digiKam'),
    @('Multimédia', 'EarTrumpet', 'File-New-Project.EarTrumpet'),
    @('Multimédia', 'FFmpeg', 'Gyan.FFmpeg'),
    @('Multimédia', 'Flameshot', 'Flameshot.Flameshot'),
    @('Multimédia', 'foobar2000', 'PeterPawlowski.foobar2000'),
    @('Multimédia', 'FreeCAD', 'FreeCAD.FreeCAD'),
    @('Multimédia', 'HandBrake', 'HandBrake.HandBrake'),
    @('Multimédia', 'Harmonoid', 'Harmonoid.Harmonoid'),
    @('Multimédia', 'ImageGlass', 'DuongDieuPhap.ImageGlass'),
    @('Multimédia', 'IrfanView', 'IrfanSkiljan.IrfanView'),
    @('Multimédia', 'iTunes', 'Apple.iTunes'),
    @('Multimédia', 'Jellyfin', 'Jellyfin.Server'),
    @('Multimédia', 'JellyfinMediaPlayer', 'Jellyfin.JellyfinMediaPlayer'),
    @('Multimédia', 'JPEGView', 'sylikc.JPEGView'),
    @('Multimédia', 'KLite', 'CodecGuide.K-LiteCodecPack.Basic'),
    @('Multimédia', 'KLiteStandard', 'CodecGuide.K-LiteCodecPack.Standard'),
    @('Multimédia', 'Kodi', 'XBMCFoundation.Kodi'),
    @('Multimédia', 'LMMS', 'LMMS.LMMS'),
    @('Multimédia', 'MediaInfo', 'MediaArea.MediaInfo.GUI'),
    @('Multimédia', 'MediaMonkey', 'VentisMedia.MediaMonkey.5'),
    @('Multimédia', 'Mp3tag', 'FlorianHeidenreich.Mp3tag'),
    @('Multimédia', 'MPCHC', 'clsid2.mpc-hc'),
    @('Multimédia', 'MuseScore', 'Musescore.Musescore'),
    @('Multimédia', 'Nomacs', 'nomacs.nomacs'),
    @('Multimédia', 'OBS', 'OBSProject.OBSStudio'),
    @('Multimédia', 'OpenShot', 'OpenShot.OpenShot'),
    @('Multimédia', 'PaintNET', 'dotPDN.PaintDotNet'),
    @('Multimédia', 'Plex', 'Plex.Plex'),
    @('Multimédia', 'PotPlayer', 'Daum.PotPlayer'),
    @('Multimédia', 'Reaper', 'Cockos.REAPER'),
    @('Multimédia', 'ScreenToGif', 'NickeManarin.ScreenToGif'),
    @('Multimédia', 'Shotcut', 'Meltytech.Shotcut'),
    @('Multimédia', 'Spicetify', 'Spicetify.Spicetify'),
    @('Multimédia', 'Spotify', 'Spotify.Spotify'),
    @('Multimédia', 'Stremio', 'Stremio.Stremio'),
    @('Multimédia', 'TagScanner', 'SergeySerkov.TagScanner'),
    @('Multimédia', 'Tidal', 'TIDALMusicAS.TIDAL'),
    @('Multimédia', 'VLC', 'VideoLAN.VLC'),
    @('Multimédia', 'VoiceMeeter', 'VB-Audio.Voicemeeter'),
    @('Multimédia', 'XnViewMP', 'XnSoft.XnViewMP'),
    @('Multimédia', 'yt-dlp', 'yt-dlp.yt-dlp'),
    @('Communication', 'Beeper', 'Beeper.Beeper'),
    @('Communication', 'BetterBird', 'Betterbird.Betterbird'),
    @('Communication', 'Chatterino', 'ChatterinoTeam.Chatterino'),
    @('Communication', 'Discord', 'Discord.Discord'),
    @('Communication', 'Dorion', 'SpikeHD.Dorion'),
    @('Communication', 'Element', 'Element.Element'),
    @('Communication', 'eMClient', 'eMClient.eMClient'),
    @('Communication', 'Ferdium', 'Ferdium.Ferdium'),
    @('Communication', 'Hexchat', 'HexChat.HexChat'),
    @('Communication', 'Jami', 'SFLinux.Jami'),
    @('Communication', 'Line', 'LINE.LINE'),
    @('Communication', 'Linphone', 'BelledonneCommunications.Linphone'),
    @('Communication', 'Mumble', 'Mumble.Mumble.Client'),
    @('Communication', 'Pidgin', 'Pidgin.Pidgin'),
    @('Communication', 'qTox', 'Tox.qTox'),
    @('Communication', 'Signal', 'OpenWhisperSystems.Signal'),
    @('Communication', 'Slack', 'SlackTechnologies.Slack'),
    @('Communication', 'Teams', 'Microsoft.Teams'),
    @('Communication', 'TeamSpeak', 'TeamSpeakSystems.TeamSpeakClient'),
    @('Communication', 'Telegram', 'Telegram.TelegramDesktop'),
    @('Communication', 'Thunderbird', 'Mozilla.Thunderbird'),
    @('Communication', 'Viber', 'Rakuten.Viber'),
    @('Communication', 'Webex', 'Cisco.Webex'),
    @('Communication', 'Zoom', 'Zoom.Zoom'),
    @('Communication', 'Zulip', 'Zulip.Zulip'),
    @('Image et capture', 'Blender', 'BlenderFoundation.Blender'),
    @('Image et capture', 'Figma', 'Figma.Figma'),
    @('Image et capture', 'GIMP', 'GIMP.GIMP'),
    @('Image et capture', 'Greenshot', 'Greenshot.Greenshot'),
    @('Image et capture', 'inkScape', 'Inkscape.Inkscape'),
    @('Image et capture', 'KdenLive', 'KDE.Kdenlive'),
    @('Image et capture', 'Krita', 'KDE.Krita'),
    @('Image et capture', 'LightShot', 'Skillbrains.Lightshot'),
    @('Image et capture', 'ShareX', 'ShareX.ShareX'),
    @('Documents', 'AdobeReader', 'Adobe.Acrobat.Reader.64-bit'),
    @('Documents', 'AFFiNE', 'ToEverything.AFFiNE'),
    @('Documents', 'Anki', 'Anki.Anki'),
    @('Documents', 'Calibre', 'calibre.calibre'),
    @('Documents', 'DrawIO', 'JGraph.Draw'),
    @('Documents', 'FoxItReader', 'Foxit.FoxitReader'),
    @('Documents', 'Joplin', 'Joplin.Joplin'),
    @('Documents', 'LibreOffice', 'TheDocumentFoundation.LibreOffice'),
    @('Documents', 'LogSeq', 'Logseq.Logseq'),
    @('Documents', 'NAPS2', 'Cyanfish.NAPS2'),
    @('Documents', 'Notion', 'Notion.Notion'),
    @('Documents', 'Obsidian', 'Obsidian.Obsidian'),
    @('Documents', 'Okular', 'KDE.Okular'),
    @('Documents', 'OnlyOffice', 'ONLYOFFICE.DesktopEditors'),
    @('Documents', 'OpenOffice', 'Apache.OpenOffice'),
    @('Documents', 'PDF24', 'geeksoftwareGmbH.PDF24Creator'),
    @('Documents', 'PDFGear', 'PDFgear.PDFgear'),
    @('Documents', 'PDFSam', 'PDFsam.PDFsam'),
    @('Documents', 'PDFXChangeEditor', 'TrackerSoftware.PDF-XChangeEditor'),
    @('Documents', 'QOwnNotes', 'pbek.QOwnNotes'),
    @('Documents', 'simplenote', 'Automattic.Simplenote'),
    @('Documents', 'SumatraPDF', 'SumatraPDF.SumatraPDF'),
    @('Documents', 'WinMerge', 'WinMerge.WinMerge'),
    @('Documents', 'Xournal', 'Xournal++.Xournal++'),
    @('Documents', 'Zotero', 'DigitalScholar.Zotero'),
    @('Sécurité', 'ClamAV', 'Cisco.ClamAV'),
    @('Sécurité', 'Cryptomator', 'Cryptomator.Cryptomator'),
    @('Sécurité', 'ESET', 'ESET.Nod32'),
    @('Sécurité', 'MalwareBytes', 'Malwarebytes.Malwarebytes'),
    @('Sécurité', 'VeraCrypt', 'IDRIX.VeraCrypt'),
    @('Développement', 'Aegisub', 'Aegisub.Aegisub'),
    @('Développement', 'Alacritty', 'Alacritty.Alacritty'),
    @('Développement', 'Anaconda3', 'Anaconda.Anaconda3'),
    @('Développement', 'AndroidStudio', 'Google.AndroidStudio'),
    @('Développement', 'AWSCLI', 'Amazon.AWSCLI'),
    @('Développement', 'AzureCLI', 'Microsoft.AzureCLI'),
    @('Développement', 'Bat', 'sharkdp.bat'),
    @('Développement', 'Bruno', 'Bruno.Bruno'),
    @('Développement', 'Bun', 'Oven-sh.Bun'),
    @('Développement', 'Claude', 'Anthropic.Claude'),
    @('Développement', 'ClaudeCode', 'Anthropic.ClaudeCode'),
    @('Développement', 'Clink', 'chrisant996.Clink'),
    @('Développement', 'CloudflareWarp', 'Cloudflare.Warp'),
    @('Développement', 'CMake', 'Kitware.CMake'),
    @('Développement', 'Codex', 'OpenAI.Codex'),
    @('Développement', 'Corretto25', 'Amazon.Corretto.25.JDK'),
    @('Développement', 'Corretto8', 'Amazon.Corretto.8.JDK'),
    @('Développement', 'Cursor', 'Anysphere.Cursor'),
    @('Développement', 'DBeaver', 'DBeaver.DBeaver.Community'),
    @('Développement', 'Deno', 'DenoLand.Deno'),
    @('Développement', 'Docker', 'Docker.DockerDesktop'),
    @('Développement', 'Fd', 'sharkdp.fd'),
    @('Développement', 'FNM', 'Schniz.fnm'),
    @('Développement', 'Fzf', 'junegunn.fzf'),
    @('Développement', 'Git', 'Git.Git'),
    @('Développement', 'GitExtensions', 'GitExtensionsTeam.GitExtensions'),
    @('Développement', 'GitHub', 'GitHub.GitHubDesktop'),
    @('Développement', 'GitHubCLI', 'GitHub.cli'),
    @('Développement', 'GitKraken', 'Axosoft.GitKraken'),
    @('Développement', 'Go', 'GoLang.Go'),
    @('Développement', 'Godot', 'GodotEngine.GodotEngine'),
    @('Développement', 'HeidiSQL', 'HeidiSQL.HeidiSQL'),
    @('Développement', 'Helm', 'Helm.Helm'),
    @('Développement', 'HugoExtended', 'Hugo.Hugo.Extended'),
    @('Développement', 'HxD', 'MHNexus.HxD'),
    @('Développement', 'IntelliJ', 'JetBrains.IntelliJIDEA.Community'),
    @('Développement', 'JetBrainsToolbox', 'JetBrains.Toolbox'),
    @('Développement', 'Jq', 'jqlang.jq'),
    @('Développement', 'Kubectl', 'Kubernetes.kubectl'),
    @('Développement', 'Lazygit', 'JesseDuffield.lazygit'),
    @('Développement', 'LLVM', 'LLVM.LLVM'),
    @('Développement', 'Lua', 'rjpcomputing.luaforwindows'),
    @('Développement', 'Miniconda', 'Anaconda.Miniconda3'),
    @('Développement', 'MSYS2', 'MSYS2.MSYS2'),
    @('Développement', 'Neovim', 'Neovim.Neovim'),
    @('Développement', 'NET48', 'Microsoft.DotNet.Framework.DeveloperPack_4'),
    @('Développement', 'NET8', 'Microsoft.DotNet.DesktopRuntime.8'),
    @('Développement', 'NodeJS', 'OpenJS.NodeJS'),
    @('Développement', 'NodeJSLTS', 'OpenJS.NodeJS.LTS'),
    @('Développement', 'Notepad++', 'Notepad++.Notepad++'),
    @('Développement', 'OhMyPosh', 'JanDeDobbeleer.OhMyPosh'),
    @('Développement', 'Ollama', 'Ollama.Ollama'),
    @('Développement', 'Pnpm', 'pnpm.pnpm'),
    @('Développement', 'PodmanDesktop', 'RedHat.Podman-Desktop'),
    @('Développement', 'Postman', 'Postman.Postman'),
    @('Développement', 'Pulsar', 'Pulsar-Edit.Pulsar'),
    @('Développement', 'PyCharm', 'JetBrains.PyCharm.Community'),
    @('Développement', 'Ripgrep', 'BurntSushi.ripgrep.MSVC'),
    @('Développement', 'Ruby', 'RubyInstallerTeam.Ruby.4.0'),
    @('Développement', 'Rust', 'Rustlang.Rustup'),
    @('Développement', 'Starship', 'Starship.Starship'),
    @('Développement', 'Temurin21', 'EclipseAdoptium.Temurin.21.JDK'),
    @('Développement', 'Terraform', 'Hashicorp.Terraform'),
    @('Développement', 'UnityHub', 'Unity.UnityHub'),
    @('Développement', 'UV', 'astral-sh.uv'),
    @('Développement', 'Vagrant', 'Hashicorp.Vagrant'),
    @('Développement', 'VS2022', 'Microsoft.VisualStudio.2022.Community'),
    @('Développement', 'VS2026', 'Microsoft.VisualStudio.Community'),
    @('Développement', 'VSCode', 'Microsoft.VisualStudioCode'),
    @('Développement', 'VSCodium', 'VSCodium.VSCodium'),
    @('Développement', 'WezTerm', 'wez.wezterm'),
    @('Développement', 'WSL2', 'Microsoft.WSL'),
    @('Développement', 'Yarn', 'Yarn.Yarn'),
    @('Développement', 'Zed', 'ZedIndustries.Zed')
)

# Applications préinstallées proposées à la désinstallation : modèle de nom de paquet, libellé, catégorie.
#   inutile = rarement utile ; utile = peut servir (à ne retirer que si on ne s'en sert pas) ; tiers = sponsorisées.
$Script:BloatCatalog = @(
    @('Microsoft.BingNews', 'Actualités (Bing)', 'inutile'),
    @('Microsoft.BingWeather', 'Météo (Bing)', 'inutile'),
    @('Microsoft.BingSearch', 'Recherche Bing', 'inutile'),
    @('Microsoft.BingFinance', 'Finance (Bing)', 'inutile'),
    @('Microsoft.BingSports', 'Sports (Bing)', 'inutile'),
    @('Microsoft.BingTranslator', 'Traducteur (Bing)', 'inutile'),
    @('Microsoft.GetHelp', 'Obtenir de l''aide', 'inutile'),
    @('Microsoft.Getstarted', 'Astuces', 'inutile'),
    @('Microsoft.MicrosoftOfficeHub', 'Microsoft 365 (centre Office)', 'inutile'),
    @('Microsoft.MicrosoftSolitaireCollection', 'Solitaire Collection', 'inutile'),
    @('Microsoft.People', 'Contacts (People)', 'inutile'),
    @('Microsoft.WindowsFeedbackHub', 'Hub de commentaires', 'inutile'),
    @('Microsoft.MixedReality.Portal', 'Portail de réalité mixte', 'inutile'),
    @('Microsoft.Microsoft3DViewer', 'Visionneuse 3D', 'inutile'),
    @('Microsoft.Print3D', 'Print 3D', 'inutile'),
    @('Microsoft.3DBuilder', '3D Builder', 'inutile'),
    @('Microsoft.MSPaint', 'Paint 3D', 'inutile'),
    @('Microsoft.SkypeApp', 'Skype', 'inutile'),
    @('Microsoft.YourPhone', 'Liaison avec le téléphone (Phone Link)', 'inutile'),
    @('Clipchamp.Clipchamp', 'Clipchamp', 'inutile'),
    @('Microsoft.OutlookForWindows', 'Nouvel Outlook', 'inutile'),
    @('MSTeams', 'Microsoft Teams (version personnelle)', 'inutile'),
    @('MicrosoftTeams', 'Microsoft Teams (ancienne version)', 'inutile'),
    @('MicrosoftCorporationII.MicrosoftFamily', 'Microsoft Family', 'inutile'),
    @('Microsoft.PowerAutomateDesktop', 'Power Automate', 'inutile'),
    @('Microsoft.Wallet', 'Microsoft Pay (Wallet)', 'inutile'),
    @('Microsoft.WindowsMaps', 'Cartes', 'inutile'),
    @('Microsoft.Todos', 'Microsoft To Do', 'inutile'),
    @('Microsoft.549981C3F5F10', 'Cortana (ancienne)', 'inutile'),
    @('Microsoft.Copilot', 'Copilot', 'inutile'),
    @('Microsoft.Messaging', 'Messagerie', 'inutile'),
    @('Microsoft.OneConnect', 'Forfaits mobiles', 'inutile'),
    @('Microsoft.GroupMe10', 'GroupMe', 'inutile'),
    @('Microsoft.Office.Sway', 'Sway', 'inutile'),
    @('Microsoft.Advertising.Xaml', 'Composant publicitaire Xaml', 'inutile'),
    @('Microsoft.ZuneMusic', 'Lecteur multimédia (Groove)', 'utile'),
    @('Microsoft.ZuneVideo', 'Films et TV', 'utile'),
    @('Microsoft.MicrosoftStickyNotes', 'Pense-bêtes', 'utile'),
    @('Microsoft.WindowsAlarms', 'Horloge et alarmes', 'utile'),
    @('Microsoft.WindowsSoundRecorder', 'Enregistreur vocal', 'utile'),
    @('Microsoft.WindowsCamera', 'Caméra', 'utile'),
    @('Microsoft.Whiteboard', 'Whiteboard', 'utile'),
    @('Microsoft.Office.OneNote', 'OneNote', 'utile'),
    @('MicrosoftCorporationII.QuickAssist', 'Assistance rapide (prise en main à distance)', 'utile'),
    @('SpotifyAB.SpotifyMusic', 'Spotify (préinstallé)', 'tiers'),
    @('Disney.37853FC22B2CE', 'Disney+', 'tiers'),
    @('*Netflix*', 'Netflix', 'tiers'),
    @('*Facebook*', 'Facebook', 'tiers'),
    @('*Instagram*', 'Instagram', 'tiers'),
    @('BytedancePte.Ltd.TikTok', 'TikTok', 'tiers'),
    @('*Twitter*', 'Twitter / X', 'tiers'),
    @('*LinkedIn*', 'LinkedIn', 'tiers'),
    @('*CandyCrush*', 'Candy Crush', 'tiers'),
    @('*BubbleWitch*', 'Bubble Witch', 'tiers'),
    @('*Flipboard*', 'Flipboard', 'tiers'),
    @('*Duolingo*', 'Duolingo', 'tiers'),
    @('*PandoraMedia*', 'Pandora', 'tiers'),
    @('*iHeartRadio*', 'iHeartRadio', 'tiers'),
    @('*Shazam*', 'Shazam', 'tiers'),
    @('*Hulu*', 'Hulu', 'tiers'),
    @('*PrimeVideo*', 'Prime Video', 'tiers'),
    @('*DropboxOEM*', 'Dropbox (préinstallé)', 'tiers'),
    @('*McAfee*', 'McAfee (version d''essai)', 'tiers'),
    @('*Dolby*', 'Dolby', 'tiers'),
    @('*Viber*', 'Viber', 'tiers'),
    @('*Wunderlist*', 'Wunderlist', 'tiers'),
    @('*RoyalRevolt*', 'Royal Revolt', 'tiers'),
    @('*HiddenCity*', 'Hidden City', 'tiers')
)

# Paquets que l'on ne retire jamais, quelle que soit la demande (Store, composants système, essentiels).
$Script:AppxProtected = '^(Microsoft\.(WindowsStore|StorePurchaseApp|DesktopAppInstaller|SecHealthUI|UI\.Xaml|VCLibs|NET\.|WindowsAppRuntime|Windows\.(ShellExperienceHost|StartMenuExperienceHost|CloudExperienceHost|Search|Photos|SecHealthUI|ContentDeliveryManager|Apprep)|WindowsTerminal|WindowsCalculator|ScreenSketch|Paint$|WindowsNotepad|HEIFImageExtension|WebpImageExtension|VP9VideoExtensions|HEVCVideoExtension|RawImageExtension|WebMediaExtensions|GamingApp|GamingServices|Xbox|XboxIdentityProvider|AV1VideoExtension|AVCEncoderVideoExtension|MPEG2VideoExtension)|MicrosoftWindows\.|Windows\.|NcsiUwpApp|1527c705|c5e2524a|E2A4F912|F46D4000|InputApp|AAD\.BrokerPlugin|AccountsControl|AsyncTextService|BioEnrollment|CredDialogHost|ECApp|LockApp|PeopleExperienceHost|PinningConfirmationDialog|XGpuEjectDialog)'

function Get-BloatApps {
    # Liste les applications préinstallées du catalogue réellement présentes sur ce PC.
    Write-Log '=== Recherche des applications préinstallées ==='
    $all = @()
    try { $all = @(Get-AppxPackage -AllUsers -ErrorAction Stop) }
    catch { Write-Log ("Liste des applications impossible (droits administrateur requis ?) : " + $_.Exception.Message) 'WARN'; return }
    $res = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($row in $Script:BloatCatalog) {
        foreach ($p in @($all | Where-Object { $_.Name -like $row[0] })) {
            if ($seen.ContainsKey([string]$p.Name)) { continue }
            if ($p.NonRemovable) { continue }
            if ($p.Name -match $Script:AppxProtected) { continue }
            $seen[[string]$p.Name] = 1
            [void]$res.Add([pscustomobject]@{ Name = [string]$p.Name; Label = [string]$row[1]; Cat = [string]$row[2] })
        }
    }
    $sv = Get-Variable -Name Sync -ErrorAction SilentlyContinue
    if ($sv) { $sv.Value.Result = @($res) }
    Write-Log ("{0} application(s) préinstallée(s) trouvée(s)." -f $res.Count) 'OK'
}

function Remove-AppxApps {
    # Désinstalle des applications Store par nom exact (tous les comptes) et les retire des futurs comptes.
    # Non annulable par le Journal : on peut les réinstaller depuis le Microsoft Store ou avec winget.
    param([string[]]$Names)
    $ok = 0; $ko = 0; $okNames = @(); $koNames = @()
    foreach ($n in $Names) {
        if ($n -notmatch '^[A-Za-z0-9][A-Za-z0-9._\-]*$') { Write-Log "Nom refusé : $n" 'WARN'; $ko++; $koNames += $n; continue }
        if ($n -match $Script:AppxProtected) { Write-Log "Paquet protégé, ignoré : $n" 'WARN'; $ko++; $koNames += $n; continue }
        $pk = @(Get-AppxPackage -Name $n -AllUsers -ErrorAction SilentlyContinue | Where-Object { -not $_.NonRemovable })
        if ($pk.Count -eq 0) { Write-Log "Déjà absent : $n"; continue }
        $failed = $false
        foreach ($p in $pk) {
            try { Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop }
            catch { $failed = $true; Write-Log ("{0} : {1}" -f $n, $_.Exception.Message) 'WARN' }
        }
        try {
            Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object { $_.DisplayName -eq $n } |
                ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction Stop | Out-Null }
        } catch { Write-Log ("{0} (modèle des futurs comptes) : {1}" -f $n, $_.Exception.Message) 'WARN' }
        if ($failed) { $ko++; $koNames += $n } else { $ok++; $okNames += $n; Write-Log "Désinstallée : $n" 'OK' }
    }
    Write-Log ("{0} application(s) désinstallée(s), {1} échec(s) ou refus." -f $ok, $ko) $(if ($ko -eq 0) { 'OK' } else { 'WARN' })
    $sv = Get-Variable -Name Sync -ErrorAction SilentlyContinue
    if ($sv) { $sv.Value.Result = @{ Ok = @($okNames); Bad = @($koNames) } }
}

function Uninstall-OneDrive {
    # Désinstalle le client OneDrive SANS toucher à vos fichiers. Refuse si vos dossiers Bureau/Documents/Images y sont redirigés.
    Write-Log '=== Désinstallation de OneDrive ==='
    $folders = @('Desktop', 'MyDocuments', 'MyPictures') | ForEach-Object { [Environment]::GetFolderPath($_) }
    $redirected = @($folders | Where-Object { $_ -and $_ -like '*OneDrive*' })
    if ($redirected.Count -gt 0) {
        Write-Log 'Vos dossiers personnels sont enregistrés dans OneDrive :' 'WARN'
        foreach ($f in $redirected) { Write-Log "  $f" 'WARN' }
        Write-Log 'Désinstallation annulée pour ne pas couper l''accès à vos fichiers. Désactivez d''abord la sauvegarde des dossiers dans les paramètres de OneDrive.' 'WARN'
        return
    }
    Get-Process -Name OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    $cands = @("$env:SystemRoot\SysWOW64\OneDriveSetup.exe", "$env:SystemRoot\System32\OneDriveSetup.exe")
    $cands += @(Get-ChildItem -Path "$env:LOCALAPPDATA\Microsoft\OneDrive" -Filter 'OneDriveSetup.exe' -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    $exe = $cands | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    if (-not $exe) { Write-Log 'Programme de désinstallation de OneDrive introuvable (déjà désinstallé ?).' 'WARN'; return }
    try {
        Start-Process -FilePath $exe -ArgumentList '/uninstall' -Wait -ErrorAction Stop
        Write-Log 'OneDrive désinstallé. Le dossier OneDrive de votre profil et son contenu n''ont pas été supprimés.' 'OK'
    } catch { Write-Log "OneDrive : $($_.Exception.Message)" 'WARN' }
}

# ---------------------------------------------------------------- winget : installation et vérification
function Install-WingetApps {
    param([string[]]$Ids)
    Write-Log '=== Installation des applications (winget) ==='
    if (-not (Test-Winget)) { Write-Log 'winget n''est pas installé (paquet « Programme d''installation d''application » du Microsoft Store).' 'WARN'; return }
    $list = @($Ids | Where-Object { $_ })
    $i = 0; $ok = 0; $bad = @(); $okIds = @(); $already = @()
    foreach ($id in $list) {
        $sv = Get-Variable -Name Sync -ErrorAction SilentlyContinue
        if ($sv -and $sv.Value.Cancel) { Write-Log 'Installation interrompue.' 'WARN'; break }
        if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._+\-]*$') { Write-Log "Identifiant refusé : $id" 'WARN'; $bad += $id; continue }
        $i++
        Write-Log ("[{0}/{1}] {2}" -f $i, $list.Count, $id)
        Invoke-Winget "install --id $id --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity"
        $c = $Script:LastWingetCode
        if ($c -eq 0) { $ok++; $okIds += $id; Write-Log "Installé : $id" 'OK' }
        elseif ($c -eq -1978335189) { $ok++; $already += $id; Write-Log "Déjà installé et à jour : $id" 'OK' }
        else { $bad += $id; Write-Log "Échec ($c) : $id" 'WARN' }
    }
    Write-Log ("{0} application(s) installée(s) ou déjà présentes, {1} échec(s)." -f $ok, $bad.Count) $(if ($bad.Count -eq 0) { 'OK' } else { 'WARN' })
    if ($bad.Count -gt 0) { Write-Log ('Identifiants en échec : ' + ($bad -join ', ')) 'WARN' }
    $sv = Get-Variable -Name Sync -ErrorAction SilentlyContinue
    if ($sv) { $sv.Value.Result = @{ Ok = @($okIds); Bad = @($bad); Already = @($already) } }
}

function Search-WingetApp {
    param([string]$Query)
    if ($Query -notmatch '^[\w .+\-]{2,60}$') { Write-Log 'Recherche refusée : utilisez 2 à 60 lettres, chiffres, espaces, points, plus ou tirets.' 'WARN'; return }
    if (-not (Test-Winget)) { Write-Log 'winget n''est pas installé.' 'WARN'; return }
    Write-Log "=== Recherche winget : $Query ==="
    Invoke-Winget ('search ' + $Query.Trim() + ' --accept-source-agreements --disable-interactivity')
}

function Test-WingetCatalog {
    # Vérifie que chaque identifiant du catalogue existe encore dans winget (plusieurs minutes).
    Write-Log '=== Vérification des identifiants du catalogue (winget) ==='
    if (-not (Test-Winget)) { Write-Log 'winget n''est pas installé.' 'WARN'; return }
    $missing = @(); $n = 0; $total = @($Script:AppCatalog).Count
    foreach ($row in $Script:AppCatalog) {
        $sv = Get-Variable -Name Sync -ErrorAction SilentlyContinue
        if ($sv -and $sv.Value.Cancel) { Write-Log 'Vérification interrompue.' 'WARN'; break }
        $n++
        & cmd.exe /c ("winget.exe show --id {0} --exact --accept-source-agreements --disable-interactivity >nul 2>&1" -f $row[2])
        if ($LASTEXITCODE -ne 0) { $missing += $row[2]; Write-Log ("Introuvable : {0} ({1})" -f $row[2], $row[1]) 'WARN' }
        if ($n % 25 -eq 0) { Write-Log ("{0}/{1} vérifiés" -f $n, $total) }
    }
    Write-Log ("Vérification terminée : {0} identifiant(s) introuvable(s) sur {1}." -f $missing.Count, $n) $(if ($missing.Count -eq 0) { 'OK' } else { 'WARN' })
}

# ---------------------------------------------------------------- Nettoyage
# Catégories de l'outil Nettoyage de disque cochées d'office. Jamais cochées : Téléchargements, corbeille,
# vidages mémoire (utiles au diagnostic), pilotes anciens, fichiers d'installation de réinitialisation.
$Script:CleanmgrSafe = @('Active Setup Temp Folders', 'BranchCache', 'D3D Shader Cache', 'Delivery Optimization Files',
    'Diagnostic Data Viewer database Files', 'Downloaded Program Files', 'Internet Cache Files', 'Old ChkDsk Files',
    'RetailDemo Offline Content', 'Setup Log Files', 'Temporary Files', 'Temporary Setup Files', 'Thumbnail Cache',
    'Update Cleanup', 'Upgrade Discarded Files', 'Windows Defender',
    'Windows Error Reporting Files', 'Windows Upgrade Log Files')

function Invoke-DiskCleanup {
    # Nettoyage de disque Windows (cleanmgr) avec une sélection prudente. -WindowsOld supprime aussi l'ancienne installation.
    param([switch]$WindowsOld)
    Write-Log '=== Nettoyage de disque Windows ==='
    $base = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
    $flag = 'StateFlags0077'
    $names = @($Script:CleanmgrSafe)
    if ($WindowsOld) { $names += 'Previous Installations' }
    $drive = $env:SystemDrive.TrimEnd(':')
    $before = 0
    try { $before = (Get-PSDrive -Name $drive -ErrorAction Stop).Free } catch {}
    $set = @()
    foreach ($n in $names) {
        $k = $base + '\' + $n
        if (Test-Path -LiteralPath $k) {
            try { New-ItemProperty -Path $k -Name $flag -Value 2 -PropertyType DWord -Force -ErrorAction Stop | Out-Null; $set += $k } catch {}
        }
    }
    if ($set.Count -eq 0) { Write-Log 'Aucune catégorie de nettoyage disponible.' 'WARN'; return }
    Write-Log ("{0} catégorie(s) sélectionnée(s). La fenêtre de nettoyage Windows s'ouvre : patientez jusqu'à sa fermeture." -f $set.Count)
    try {
        Start-Process -FilePath 'cleanmgr.exe' -ArgumentList '/sagerun:77' -Wait -ErrorAction Stop
    } catch { Write-Log "cleanmgr : $($_.Exception.Message)" 'WARN' }
    finally {
        foreach ($k in $set) { Remove-ItemProperty -Path $k -Name $flag -ErrorAction SilentlyContinue }
    }
    $after = $before
    try { $after = (Get-PSDrive -Name $drive -ErrorAction Stop).Free } catch {}
    Write-Log ("Espace libéré sur {0}: environ {1} Mo" -f $drive, [math]::Max(0, [math]::Round(($after - $before) / 1MB, 0))) 'OK'
}

function Get-FolderBytes {
    param([string]$Path)
    $t = 0
    try { $t = (Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum } catch {}
    if ($null -eq $t) { return 0 }
    return [long]$t
}

function Clear-BrowserCaches {
    # Vide uniquement les caches (pas l'historique, les cookies, les mots de passe ni les sessions).
    Write-Log '=== Caches des navigateurs ==='
    $roots = @(
        @('Chrome', "$env:LOCALAPPDATA\Google\Chrome\User Data", 'chrome'),
        @('Edge', "$env:LOCALAPPDATA\Microsoft\Edge\User Data", 'msedge'),
        @('Brave', "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data", 'brave'),
        @('Vivaldi', "$env:LOCALAPPDATA\Vivaldi\User Data", 'vivaldi'))
    $total = 0L
    foreach ($r in $roots) {
        if (-not (Test-Path -LiteralPath $r[1])) { continue }
        if (Get-Process -Name $r[2] -ErrorAction SilentlyContinue) { Write-Log ("{0} est ouvert : fermez-le pour vider tout le cache." -f $r[0]) 'WARN' }
        $dirs = @()
        foreach ($prof in @(Get-ChildItem -LiteralPath $r[1] -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })) {
            foreach ($c in 'Cache', 'Code Cache', 'GPUCache') { $dirs += (Join-Path $prof.FullName $c) }
        }
        foreach ($c in 'ShaderCache', 'GrShaderCache') { $dirs += (Join-Path $r[1] $c) }
        $size = 0L
        foreach ($d in $dirs) {
            if (-not (Test-Path -LiteralPath $d)) { continue }
            $size += (Get-FolderBytes $d)
            Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Log ("{0} : {1} Mo de cache" -f $r[0], [math]::Round($size / 1MB, 0)) 'OK'
        $total += $size
    }
    $ff = "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles"
    if (Test-Path -LiteralPath $ff) {
        if (Get-Process -Name firefox -ErrorAction SilentlyContinue) { Write-Log 'Firefox est ouvert : fermez-le pour vider tout le cache.' 'WARN' }
        $size = 0L
        foreach ($c in @(Get-ChildItem -LiteralPath $ff -Directory -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'cache2' })) {
            if (-not (Test-Path -LiteralPath $c)) { continue }
            $size += (Get-FolderBytes $c)
            Get-ChildItem -LiteralPath $c -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Log ("Firefox : {0} Mo de cache" -f [math]::Round($size / 1MB, 0)) 'OK'
        $total += $size
    }
    Write-Log ("Total libéré : environ {0} Mo. Historique, cookies et mots de passe conservés." -f [math]::Round($total / 1MB, 0)) 'OK'
}

function Remove-DefaultUser0 {
    # Compte résiduel laissé par certaines installations de Windows (aucun dossier utilisateur n'est supprimé).
    Write-Log '=== Compte résiduel defaultuser0 ==='
    $u = $null
    try { $u = Get-LocalUser -Name 'defaultuser0' -ErrorAction Stop } catch { $u = $null }
    if (-not $u) { Write-Log 'Aucun compte defaultuser0 : rien à faire.' 'OK'; return }
    try { Remove-LocalUser -Name 'defaultuser0' -ErrorAction Stop; Write-Log 'Compte defaultuser0 supprimé.' 'OK' }
    catch { Write-Log "defaultuser0 : $($_.Exception.Message)" 'WARN' }
}

# ================================================================ Retour aux valeurs par défaut de Windows 11
# Principe : on ne défait que ce qui s'écarte de Windows 11 d'origine ET dont la valeur actuelle est connue comme un
# réglage d'optimisation (stratégies : seulement si la valeur est celle que posent nos outils). Aucun pilote de démarrage
# n'est touché. Avant toute modification : point de restauration + fichier des valeurs actuelles (annulable).
$Script:Win11DefCats = [ordered]@{
    sys  = 'Système'
    sec  = 'Sécurité'
    net  = 'Réseau'
    hw   = 'Matériel'
    nc   = 'Paramètre non critique'
    spec = 'Prise en charge spécifique'
    pref = 'Préférence utilisateur (sans impact négatif)'
    priv = 'Confidentialité et stratégies'
    polx = 'Autres stratégies détectées (à vérifier)'
    ui   = 'Interface et Explorateur (confort)'
    task = 'Tâches planifiées'
}

# Services : catégorie, nom, type de démarrage Windows 11 (2 auto, 3 manuel), démarrage différé (1) ou non (0), libellé
$Script:Win11DefServices = @(
    @('sys',  'SSDPSRV',          3, 0, 'Découverte SSDP'),
    @('sys',  'TrkWks',           2, 0, 'Suivi de liens distribués'),
    @('net',  'icssvc',           3, 0, 'Point d''accès mobile Windows'),
    @('net',  'upnphost',         3, 0, 'Hôte de périphérique UPnP'),
    @('nc',   'MapsBroker',       2, 1, 'Cartes téléchargées'),
    @('nc',   'RetailDemo',       3, 0, 'Mode démonstration magasin'),
    @('nc',   'WerSvc',           3, 0, 'Rapport d''erreurs Windows'),
    @('nc',   'Fax',              3, 0, 'Télécopie'),
    @('nc',   'Spooler',          2, 0, 'Spouleur d''impression'),
    @('nc',   'bthserv',          3, 0, 'Service Bluetooth'),
    @('nc',   'LanmanServer',     2, 0, 'Partage de fichiers (serveur SMB)'),
    @('nc',   'PhoneSvc',         3, 0, 'Service Téléphone'),
    @('nc',   'lfsvc',            3, 0, 'Géolocalisation'),
    @('nc',   'WMPNetworkSvc',    3, 0, 'Partage réseau Windows Media Player'),
    @('nc',   'DoSvc',            2, 1, 'Optimisation de la distribution'),
    @('spec', 'dmwappushservice', 3, 0, 'Routage de messages push WAP'),
    @('spec', 'TermService',      3, 0, 'Bureau à distance (RDP)'),
    @('pref', 'DiagTrack',        2, 0, 'Télémétrie (Expériences utilisateur connectées)'),
    @('pref', 'SysMain',          2, 0, 'SysMain (Superfetch)'),
    @('sys',  'wuauserv',         3, 0, 'Windows Update'),
    @('sys',  'UsoSvc',           2, 1, 'Orchestrateur des mises à jour'),
    @('sys',  'BITS',             3, 0, 'Service de transfert intelligent (BITS)'),
    @('sys',  'WSearch',          2, 1, 'Windows Search'),
    @('sys',  'Themes',           2, 0, 'Thèmes'),
    @('sys',  'AudioSrv',         2, 0, 'Audio Windows'),
    @('sys',  'AudioEndpointBuilder', 2, 0, 'Générateur de points de terminaison audio'),
    @('sys',  'EventLog',         2, 0, 'Journal d''événements Windows'),
    @('sys',  'ShellHWDetection', 2, 0, 'Détection matériel Shell (lecture automatique)'),
    @('sys',  'FontCache',        2, 0, 'Cache de polices Windows'),
    @('sys',  'CryptSvc',         2, 0, 'Services de chiffrement'),
    @('sys',  'Winmgmt',          2, 0, 'Infrastructure de gestion Windows (WMI)'),
    @('sys',  'WpnService',       2, 0, 'Notifications Push Windows'),
    @('sys',  'seclogon',         3, 0, 'Ouverture de session secondaire'),
    @('net',  'iphlpsvc',         2, 0, 'Assistance IP'),
    @('sec',  'mpssvc',           2, 0, 'Pare-feu Windows Defender'),
    @('sec',  'BFE',              2, 0, 'Moteur de filtrage de base'),
    @('sec',  'wscsvc',           2, 1, 'Centre de sécurité'),
    @('sec',  'RemoteRegistry',   4, 0, 'Registre à distance'),
    @('nc',   'XblAuthManager',   3, 0, 'Gestion de l''authentification Xbox Live'),
    @('nc',   'XblGameSave',      3, 0, 'Sauvegarde de jeu Xbox Live'),
    @('nc',   'XboxNetApiSvc',    3, 0, 'Service de mise en réseau Xbox Live'),
    @('nc',   'XboxGipSvc',       3, 0, 'Gestion des accessoires Xbox'),
    @('nc',   'WbioSrvc',         3, 0, 'Biométrie Windows'),
    @('nc',   'SCardSvr',         3, 0, 'Carte à puce')
)

# Registre : catégorie, chemin, nom, valeur Windows 11 ($null = « non définie »), type, valeur(s) posée(s) par nos outils ($null = tout écart)
$Script:Win11DefRegistry = @(
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection', 'AllowTelemetry', $null, 'DWord', 0),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection', 'AllowDesktopAnalyticsProcessing', $null, 'DWord', 0),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection', 'AllowDeviceNameInTelemetry', $null, 'DWord', 0),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection', 'MicrosoftEdgeDataOptIn', $null, 'DWord', 0),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection', 'AllowWUfBCloudProcessing', $null, 'DWord', 0),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection', 'AllowUpdateComplianceProcessing', $null, 'DWord', 0),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection', 'AllowCommercialDataPipeline', $null, 'DWord', 0),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection', 'DisableOneSettingsDownloads', $null, 'DWord', 1),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection', 'DoNotShowFeedbackNotifications', $null, 'DWord', 1),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\SQMClient\Windows', 'CEIPEnable', $null, 'DWord', 0),
    @('priv', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection', 'AllowTelemetry', $null, 'DWord', 0),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting', 'Disabled', $null, 'DWord', 1),
    @('pref', 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting', 'Disabled', $null, 'DWord', 1),
    @('pref', 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting', 'DontSendAdditionalData', $null, 'DWord', 1),
    @('pref', 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting', 'LoggingDisabled', $null, 'DWord', 1),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System', 'PublishUserActivities', $null, 'DWord', 0),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System', 'UploadUserActivities', $null, 'DWord', 0),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System', 'EnableActivityFeed', $null, 'DWord', 0),
    @('pref', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced', 'Start_TrackProgs', 1, 'DWord', 0),
    @('pref', 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows', 'LegacyDefaultPrinterMode', $null, 'DWord', 1),
    @('priv', 'HKCU:\Software\Policies\Microsoft\Windows\EdgeUI', 'DisableMFUTracking', $null, 'DWord', 1),
    @('priv', 'HKCU:\SOFTWARE\Microsoft\Siuf\Rules', 'NumberOfSIUFInPeriod', $null, 'DWord', 0),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization', 'RestrictImplicitInkCollection', $null, 'DWord', 1),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization', 'RestrictImplicitTextCollection', $null, 'DWord', 1),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\HandwritingErrorReports', 'PreventHandwritingErrorReports', $null, 'DWord', 1),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\TabletPC', 'PreventHandwritingDataSharing', $null, 'DWord', 1),
    @('priv', 'HKCU:\SOFTWARE\Microsoft\InputPersonalization\TrainedDataStore', 'HarvestContacts', $null, 'DWord', 0),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\WMDRM', 'DisableOnline', $null, 'DWord', 1),
    @('priv', 'HKCU:\SOFTWARE\Microsoft\MediaPlayer\Preferences', 'UsageTracking', $null, 'DWord', 0),
    @('priv', 'HKCU:\Software\Policies\Microsoft\WindowsMediaPlayer', 'PreventCDDVDMetadataRetrieval', $null, 'DWord', 1),
    @('priv', 'HKCU:\Software\Policies\Microsoft\WindowsMediaPlayer', 'PreventMusicFileMetadataRetrieval', $null, 'DWord', 1),
    @('priv', 'HKCU:\Software\Policies\Microsoft\WindowsMediaPlayer', 'PreventRadioPresetsRetrieval', $null, 'DWord', 1),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent', 'DisableSoftLanding', $null, 'DWord', 1),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent', 'DisableWindowsConsumerFeatures', $null, 'DWord', 1),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent', 'DisableTailoredExperiencesWithDiagnosticData', $null, 'DWord', 1),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent', 'DisableCloudOptimizedContent', $null, 'DWord', 1),
    @('priv', 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent', 'DisableTailoredExperiencesWithDiagnosticData', $null, 'DWord', 1),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo', 'DisabledByGroupPolicy', $null, 'DWord', 1),
    @('priv', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo', 'Enabled', $null, 'DWord', 0),
    @('priv', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy', 'TailoredExperiencesWithDiagnosticDataEnabled', $null, 'DWord', 0),
    @('priv', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\SystemSettings\AccountNotifications', 'EnableAccountNotifications', $null, 'DWord', 0),
    @('priv', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SystemSettings\AccountNotifications', 'EnableAccountNotifications', $null, 'DWord', 0),
    @('priv', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'ContentDeliveryAllowed', $null, 'DWord', 0),
    @('priv', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SubscribedContentEnabled', $null, 'DWord', 0),
    @('priv', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'OemPreInstalledAppsEnabled', $null, 'DWord', 0),
    @('priv', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'PreInstalledAppsEnabled', $null, 'DWord', 0),
    @('priv', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'PreInstalledAppsEverEnabled', $null, 'DWord', 0),
    @('priv', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SilentInstalledAppsEnabled', $null, 'DWord', 0),
    @('priv', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SystemPaneSuggestionsEnabled', $null, 'DWord', 0),
    @('priv', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'FeatureManagementEnabled', $null, 'DWord', 0),
    @('priv', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SoftLandingEnabled', $null, 'DWord', 0),
    @('priv', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SubscribedContent-338393Enabled', $null, 'DWord', 0),
    @('priv', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SubscribedContent-353694Enabled', $null, 'DWord', 0),
    @('priv', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SubscribedContent-353696Enabled', $null, 'DWord', 0),
    @('priv', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SubscribedContent-338387Enabled', $null, 'DWord', 0),
    @('priv', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SubscribedContent-338388Enabled', $null, 'DWord', 0),
    @('priv', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SubscribedContent-338389Enabled', $null, 'DWord', 0),
    @('priv', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SubscribedContent-353698Enabled', $null, 'DWord', 0),
    @('priv', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SubscribedContent-310093Enabled', $null, 'DWord', 0),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent', 'DisableWindowsSpotlightFeatures', $null, 'DWord', 1),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search', 'ConnectedSearchPrivacy', $null, 'DWord', 3),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search', 'AllowSearchToUseLocation', $null, 'DWord', 0),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search', 'EnableDynamicContentInWSB', $null, 'DWord', 0),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search', 'ConnectedSearchUseWeb', $null, 'DWord', 0),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search', 'ConnectedSearchUseWebOverMeteredConnections', $null, 'DWord', 0),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search', 'DisableWebSearch', $null, 'DWord', 1),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search', 'PreventRemoteQueries', $null, 'DWord', 1),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search', 'AllowCloudSearch', $null, 'DWord', 0),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer', 'DisableSearchBoxSuggestions', $null, 'DWord', 1),
    @('priv', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings', 'IsDynamicSearchBoxEnabled', $null, 'DWord', 0),
    @('priv', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings', 'IsMSACloudSearchEnabled', $null, 'DWord', 0),
    @('priv', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings', 'IsAADCloudSearchEnabled', $null, 'DWord', 0),
    @('priv', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings', 'IsDeviceSearchHistoryEnabled', $null, 'DWord', 0),
    @('priv', 'HKCU:\Control Panel\International\User Profile', 'HttpAcceptLanguageOptOut', $null, 'DWord', 1),
    @('priv', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search', 'BingSearchEnabled', $null, 'DWord', 0),
    @('priv', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search', 'DeviceHistoryEnabled', $null, 'DWord', 0),
    @('priv', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search', 'HistoryViewEnabled', $null, 'DWord', 0),
    @('priv', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search', 'VoiceShortcut', $null, 'DWord', 0),
    @('pref', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced', 'Start_IrisRecommendations', 1, 'DWord', 0),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Maps', 'AutoDownloadAndUpdateMapData', $null, 'DWord', 0),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Maps', 'AllowUntriggeredNetworkTrafficOnSettingsPage', $null, 'DWord', 0),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot', 'TurnOffWindowsCopilot', $null, 'DWord', 1),
    @('priv', 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot', 'TurnOffWindowsCopilot', $null, 'DWord', 1),
    @('priv', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced', 'ShowCopilotButton', $null, 'DWord', 0),
    @('priv', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings', 'AutoOpenCopilotLargeScreens', $null, 'DWord', 0),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI', 'DisableAIDataAnalysis', $null, 'DWord', 1),
    @('priv', 'HKCU:\Software\Policies\Microsoft\Windows\WindowsAI', 'DisableAIDataAnalysis', $null, 'DWord', 1),
    @('priv', 'HKLM:\SOFTWARE\Policies\WindowsNotepad', 'DisableAIFeatures', $null, 'DWord', 1),
    @('priv', 'HKCU:\Software\Microsoft\Notepad', 'ShowRewriteButton', $null, 'DWord', 0),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'EdgeEnhanceImagesEnabled', $null, 'DWord', 0),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'PersonalizationReportingEnabled', $null, 'DWord', 0),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'ShowRecommendationsEnabled', $null, 'DWord', 0),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'HideFirstRunExperience', $null, 'DWord', 1),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'UserFeedbackAllowed', $null, 'DWord', 0),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'ConfigureDoNotTrack', $null, 'DWord', 1),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'AlternateErrorPagesEnabled', $null, 'DWord', 0),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'EdgeCollectionsEnabled', $null, 'DWord', 0),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'EdgeShoppingAssistantEnabled', $null, 'DWord', 0),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'MicrosoftEdgeInsiderPromotionEnabled', $null, 'DWord', 0),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'RelatedMatchesCloudServiceEnabled', $null, 'DWord', 0),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'ShowMicrosoftRewards', $null, 'DWord', 0),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'MetricsReportingEnabled', $null, 'DWord', 0),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'StartupBoostEnabled', $null, 'DWord', 0),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'SendSiteInfoToImproveServices', $null, 'DWord', 0),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'SpotlightExperiencesAndRecommendationsEnabled', $null, 'DWord', 0),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'DiagnosticData', $null, 'DWord', 0),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'EdgeAssetDeliveryServiceEnabled', $null, 'DWord', 0),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'HubsSidebarEnabled', $null, 'DWord', 0),
    @('priv', 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment', 'POWERSHELL_TELEMETRY_OPTOUT', $null, 'String', '1'),
    @('priv', 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment', 'DOTNET_CLI_TELEMETRY_OPTOUT', $null, 'String', '1'),
    @('priv', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location', 'Value', 'Allow', 'String', 'Deny'),
    @('priv', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam', 'Value', 'Allow', 'String', 'Deny'),
    @('priv', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone', 'Value', 'Allow', 'String', 'Deny'),
    @('priv', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\documentsLibrary', 'Value', 'Allow', 'String', 'Deny'),
    @('priv', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\picturesLibrary', 'Value', 'Allow', 'String', 'Deny'),
    @('priv', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\videosLibrary', 'Value', 'Allow', 'String', 'Deny'),
    @('priv', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\broadFileSystemAccess', 'Value', 'Allow', 'String', 'Deny'),
    @('priv', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\userAccountInformation', 'Value', 'Allow', 'String', 'Deny'),
    @('priv', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\contacts', 'Value', 'Allow', 'String', 'Deny'),
    @('priv', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\appointments', 'Value', 'Allow', 'String', 'Deny'),
    @('priv', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\phoneCallHistory', 'Value', 'Allow', 'String', 'Deny'),
    @('priv', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\chat', 'Value', 'Allow', 'String', 'Deny'),
    @('priv', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\email', 'Value', 'Allow', 'String', 'Deny'),
    @('priv', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\userDataTasks', 'Value', 'Allow', 'String', 'Deny'),
    @('priv', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\userNotificationListener', 'Value', 'Allow', 'String', 'Deny'),
    @('priv', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\appDiagnostics', 'Value', 'Allow', 'String', 'Deny'),
    @('priv', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\activity', 'Value', 'Allow', 'String', 'Deny'),
    @('priv', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\radios', 'Value', 'Allow', 'String', 'Deny'),
    @('priv', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\graphicsCaptureWithoutBorder', 'Value', 'Allow', 'String', 'Deny'),
    @('priv', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\graphicsCaptureProgrammatic', 'Value', 'Allow', 'String', 'Deny'),
    @('priv', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\systemAIModels', 'Value', 'Allow', 'String', 'Deny'),
    @('priv', 'HKCU:\Software\Microsoft\Speech_OneCore\Settings\VoiceActivation\UserPreferenceForAllApps', 'AgentActivationEnabled', $null, 'DWord', 0),
    @('priv', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeviceAccess\Global\{C1D23ACC-752B-43E5-8448-8D0E519CD6D6}', 'Value', 'Allow', 'String', 'Deny'),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy', 'LetAppsAccessPhone', $null, 'DWord', 2),
    @('ui', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings', 'TaskbarEndTask', $null, 'DWord', 1),
    @('ui', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced', 'Hidden', 2, 'DWord', 1),
    @('ui', 'HKCU:\Software\Classes\CLSID\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}', 'System.IsPinnedToNameSpaceTree', $null, 'DWord', 0),
    @('ui', 'HKCU:\Software\Classes\CLSID\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}', 'System.IsPinnedToNameSpaceTree', $null, 'DWord', 0),
    @('ui', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced', 'LaunchTo', $null, 'DWord', 1),
    @('ui', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Start', 'ShowRecentList', $null, 'DWord', 0),
    @('ui', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced', 'EnableSnapAssistFlyout', $null, 'DWord', 0),
    @('ui', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced', 'TaskbarAl', $null, 'DWord', 0),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh', 'AllowNewsAndInterests', $null, 'DWord', 0),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds', 'EnableFeeds', $null, 'DWord', 0),
    @('ui', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced', 'ShowTaskViewButton', $null, 'DWord', 0),
    @('ui', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize', 'EnableTransparency', $null, 'DWord', 0),
    @('ui', 'HKCU:\Control Panel\Desktop', 'MenuShowDelay', '400', 'String', '0'),
    @('ui', 'HKCU:\Control Panel\Mouse', 'MouseHoverTime', '400', 'String', '0'),
    @('ui', 'HKCU:\Control Panel\Accessibility\StickyKeys', 'Flags', '510', 'String', '58'),
    @('sys', 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl', 'DisplayParameters', $null, 'DWord', 1),
    @('priv', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System', 'VerboseStatus', $null, 'DWord', 1),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR', 'AllowGameDVR', $null, 'DWord', 0),
    @('nc', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR', 'AppCaptureEnabled', $null, 'DWord', 0),
    @('nc', 'HKCU:\SOFTWARE\Microsoft\GameBar', 'ShowStartupPanel', $null, 'DWord', 0),
    @('priv', 'HKCU:\Software\Policies\Microsoft\Windows\Explorer', 'DisableNotificationCenter', $null, 'DWord', 1),
    @('sys', 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation', 'RealTimeIsUniversal', $null, 'DWord', 1),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate', 'DeferFeatureUpdates', $null, 'DWord', 1),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate', 'DeferFeatureUpdatesPeriodInDays', $null, 'DWord', 365),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate', 'ExcludeWUDriversInQualityUpdate', $null, 'DWord', 1),
    @('nc', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching', 'SearchOrderConfig', 1, 'DWord', 0),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore', 'AutoDownload', $null, 'DWord', 2),
    @('priv', 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings', 'FlightSettingsMaxPauseDays', $null, 'DWord', 7300),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Scan', 'AvgCPULoadFactor', $null, 'DWord', 25),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization', 'NoLockScreenCamera', $null, 'DWord', 1),
    @('sys', 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager', 'DisableWpbtExecution', $null, 'DWord', 1),
    @('sys', 'HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker', 'PreventDeviceEncryption', $null, 'DWord', 1),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync', 'DisableSettingSync', $null, 'DWord', 2),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync', 'DisableSettingSyncUserOverride', $null, 'DWord', 1),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync', 'DisableCredentialsSettingSync', $null, 'DWord', 2),
    @('priv', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync', 'DisableCredentialsSettingSyncUserOverride', $null, 'DWord', 1),
    @('sys', 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl', 'Win32PrioritySeparation', 2, 'DWord', $null),
    @('sys', 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile', 'SystemResponsiveness', 20, 'DWord', $null),
    @('sys', 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile', 'NetworkThrottlingIndex', 10, 'DWord', $null),
    @('sys', 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power', 'HiberbootEnabled', 1, 'DWord', $null),
    @('hw', 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games', 'GPU Priority', 8, 'DWord', $null),
    @('hw', 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games', 'Priority', 2, 'DWord', $null),
    @('nc', 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games', 'Scheduling Category', 'Medium', 'String', $null),
    @('nc', 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games', 'SFIO Priority', 'Normal', 'String', $null),
    @('nc', 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling', 'PowerThrottlingOff', $null, 'DWord', 1),
    @('nc', 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm', 'OverlayTestMode', $null, 'DWord', 5),
    @('nc', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR', 'AppCaptureEnabled', $null, 'DWord', 0),
    @('nc', 'HKCU:\System\GameConfigStore', 'GameDVR_Enabled', 1, 'DWord', 0),
    @('ui', 'HKCU:\Control Panel\Mouse', 'MouseSpeed', '1', 'String', '0'),
    @('ui', 'HKCU:\Control Panel\Mouse', 'MouseThreshold1', '6', 'String', '0'),
    @('ui', 'HKCU:\Control Panel\Mouse', 'MouseThreshold2', '10', 'String', '0'),
    @('ui', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced', 'HideFileExt', 1, 'DWord', 0),
    @('ui', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize', 'StartupDelayInMSec', $null, 'DWord', 0),
    @('net', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched', 'NonBestEffortLimit', $null, 'DWord', 0),
    @('net', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization', 'DODownloadMode', $null, 'DWord', 0),
    @('sys', 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters', 'DisabledComponents', $null, 'DWord', 32),
    # ---- Élargissement 2.1 : réglages modifiés par des outils d'optimisation courants (tout écart, quel que soit l'outil)
    # Sécurité : contrôle de compte (UAC), restrictions posées par des logiciels malveillants, protections du processeur
    @('sec', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System', 'EnableLUA', 1, 'DWord', $null),
    @('sec', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System', 'ConsentPromptBehaviorAdmin', 5, 'DWord', $null),
    @('sec', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System', 'ConsentPromptBehaviorUser', 3, 'DWord', $null),
    @('sec', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System', 'PromptOnSecureDesktop', 1, 'DWord', $null),
    @('sec', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System', 'EnableInstallerDetection', 1, 'DWord', $null),
    @('sec', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System', 'EnableVirtualization', 1, 'DWord', $null),
    @('sec', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System', 'EnableSecureUIAPaths', 1, 'DWord', $null),
    @('sec', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System', 'ValidateAdminCodeSignatures', 0, 'DWord', $null),
    @('sec', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System', 'LocalAccountTokenFilterPolicy', $null, 'DWord', $null),
    @('sec', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System', 'DisableTaskMgr', $null, 'DWord', $null),
    @('sec', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System', 'DisableTaskMgr', $null, 'DWord', $null),
    @('sec', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System', 'DisableRegistryTools', $null, 'DWord', $null),
    @('sec', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System', 'DisableChangePassword', $null, 'DWord', $null),
    @('sec', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System', 'DisableLockWorkstation', $null, 'DWord', $null),
    @('sec', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System', 'NoDispCPL', $null, 'DWord', $null),
    @('sec', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer', 'NoRun', $null, 'DWord', $null),
    @('sec', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer', 'NoControlPanel', $null, 'DWord', $null),
    @('sec', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer', 'NoFolderOptions', $null, 'DWord', $null),
    @('sec', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer', 'NoViewContextMenu', $null, 'DWord', $null),
    @('sec', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer', 'NoDrives', $null, 'DWord', $null),
    @('sec', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer', 'NoViewOnDrive', $null, 'DWord', $null),
    @('sec', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer', 'NoClose', $null, 'DWord', $null),
    @('sec', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer', 'NoLogoff', $null, 'DWord', $null),
    @('sec', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer', 'NoDesktop', $null, 'DWord', $null),
    @('sec', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer', 'NoTrayContextMenu', $null, 'DWord', $null),
    @('sec', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer', 'NoFind', $null, 'DWord', $null),
    @('sec', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer', 'NoSetTaskbar', $null, 'DWord', $null),
    @('sec', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer', 'DisallowRun', $null, 'DWord', $null),
    @('sec', 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management', 'FeatureSettingsOverride', $null, 'DWord', $null),
    @('sec', 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management', 'FeatureSettingsOverrideMask', $null, 'DWord', $null),
    @('sec', 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel', 'DisableExceptionChainValidation', $null, 'DWord', $null),
    @('sec', 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa', 'NoLMHash', 1, 'DWord', $null),
    @('sec', 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa', 'LimitBlankPasswordUse', 1, 'DWord', $null),
    @('sec', 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa', 'restrictanonymous', 0, 'DWord', $null),
    @('sec', 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa', 'everyoneincludesanonymous', 0, 'DWord', $null),
    @('spec', 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters', 'AllowInsecureGuestAuth', $null, 'DWord', $null, 'noauto'),
    @('spec', 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server', 'fDenyTSConnections', 1, 'DWord', $null, 'noauto'),
    # Système : mémoire, priorités, arrêt, système de fichiers, carte graphique
    @('sys', 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management', 'LargeSystemCache', 0, 'DWord', $null),
    @('sys', 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management', 'DisablePagingExecutive', 0, 'DWord', $null),
    @('sys', 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management', 'IoPageLockLimit', $null, 'DWord', $null),
    @('pref', 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management', 'ClearPageFileAtShutdown', 0, 'DWord', $null, 'noauto'),
    @('sys', 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters', 'EnablePrefetcher', 3, 'DWord', $null),
    @('sys', 'HKLM:\SYSTEM\CurrentControlSet\Control', 'WaitToKillServiceTimeout', '5000', 'String', $null),
    @('sys', 'HKCU:\Control Panel\Desktop', 'AutoEndTasks', $null, 'String', '1'),
    @('sys', 'HKCU:\Control Panel\Desktop', 'HungAppTimeout', $null, 'String', @('0', '100', '500', '1000', '1500', '2000', '2500', '3000', '4000')),
    @('sys', 'HKCU:\Control Panel\Desktop', 'WaitToKillAppTimeout', $null, 'String', @('0', '100', '500', '1000', '1500', '2000', '2500', '3000', '4000', '5000')),
    @('sys', 'HKCU:\Control Panel\Desktop', 'LowLevelHooksTimeout', $null, 'String', @('0', '100', '500', '1000', '1500', '2000', '2500', '3000', '4000')),
    @('sys', 'HKCU:\Control Panel\Desktop', 'ForegroundLockTimeout', 200000, 'DWord', $null),
    @('sys', 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel', 'GlobalTimerResolutionRequests', $null, 'DWord', $null),
    @('sys', 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel', 'DistributeTimers', $null, 'DWord', $null),
    @('sys', 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile', 'NoLazyMode', $null, 'DWord', $null),
    @('sys', 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile', 'AlwaysOn', $null, 'DWord', $null),
    @('sys', 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile', 'LazyModeTimeout', $null, 'DWord', $null),
    @('hw', 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games', 'Clock Rate', 10000, 'DWord', $null),
    @('nc', 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games', 'Background Only', 'False', 'String', $null),
    @('sys', 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem', 'NtfsDisableLastAccessUpdate', 2147483650, 'DWord', @(1, 2147483649)),
    @('sys', 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem', 'NtfsMemoryUsage', $null, 'DWord', 2),
    @('sys', 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem', 'NtfsDisable8dot3NameCreation', 2, 'DWord', $null),
    @('pref', 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem', 'LongPathsEnabled', 0, 'DWord', $null, 'noauto'),
    @('hw', 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers', 'TdrDelay', $null, 'DWord', $null),
    @('hw', 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers', 'TdrDdiDelay', $null, 'DWord', $null),
    @('hw', 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers', 'TdrLevel', $null, 'DWord', $null),
    @('hw', 'HKLM:\SYSTEM\CurrentControlSet\Control\Power', 'PlatformAoAcOverride', $null, 'DWord', $null),
    # Réseau : réglages TCP/IP, SMB, DNS et navigateur « accélérateurs » (absents d'un Windows d'origine)
    @('net', 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters', 'TcpTimedWaitDelay', $null, 'DWord', $null),
    @('net', 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters', 'MaxUserPort', $null, 'DWord', $null),
    @('net', 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters', 'DefaultTTL', $null, 'DWord', $null),
    @('net', 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters', 'Tcp1323Opts', $null, 'DWord', $null),
    @('net', 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters', 'TcpMaxDupAcks', $null, 'DWord', $null),
    @('net', 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters', 'SackOpts', $null, 'DWord', $null),
    @('net', 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters', 'TcpMaxDataRetransmissions', $null, 'DWord', $null),
    @('net', 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters', 'EnablePMTUBHDetect', $null, 'DWord', $null),
    @('net', 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters', 'GlobalMaxTcpWindowSize', $null, 'DWord', $null),
    @('net', 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters', 'TcpWindowSize', $null, 'DWord', $null),
    @('net', 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters', 'MaxFreeTcbs', $null, 'DWord', $null),
    @('net', 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters', 'MaxHashTableSize', $null, 'DWord', $null),
    @('net', 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters', 'TcpNumConnections', $null, 'DWord', $null),
    @('net', 'HKLM:\SYSTEM\CurrentControlSet\Services\AFD\Parameters', 'DefaultReceiveWindow', $null, 'DWord', $null),
    @('net', 'HKLM:\SYSTEM\CurrentControlSet\Services\AFD\Parameters', 'DefaultSendWindow', $null, 'DWord', $null),
    @('net', 'HKLM:\SYSTEM\CurrentControlSet\Services\AFD\Parameters', 'FastSendDatagramThreshold', $null, 'DWord', $null),
    @('net', 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters', 'IRPStackSize', $null, 'DWord', $null),
    @('net', 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters', 'Size', $null, 'DWord', $null),
    @('net', 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters', 'MaxCacheTtl', $null, 'DWord', $null),
    @('net', 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters', 'MaxNegativeCacheTtl', $null, 'DWord', $null),
    @('net', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings', 'MaxConnectionsPerServer', $null, 'DWord', $null),
    @('net', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings', 'MaxConnectionsPer1_0Server', $null, 'DWord', $null),
    @('net', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings', 'MaxConnectionsPerServer', $null, 'DWord', $null),
    @('net', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings', 'MaxConnectionsPer1_0Server', $null, 'DWord', $null)
)

$Script:Win11DefTasks = @(
    @('\Microsoft\Windows\Application Experience\', 'MareBackup'),
    @('\Microsoft\Windows\Application Experience\', 'Microsoft Compatibility Appraiser'),
    @('\Microsoft\Windows\Application Experience\', 'Microsoft Compatibility Appraiser Exp'),
    @('\Microsoft\Windows\Application Experience\', 'PcaPatchDbTask'),
    @('\Microsoft\Windows\Application Experience\', 'ProgramDataUpdater'),
    @('\Microsoft\Windows\Application Experience\', 'StartupAppTask'),
    @('\Microsoft\Windows\Autochk\', 'Proxy'),
    @('\Microsoft\Windows\Customer Experience Improvement Program\', 'Consolidator'),
    @('\Microsoft\Windows\Customer Experience Improvement Program\', 'KernelCeipTask'),
    @('\Microsoft\Windows\Customer Experience Improvement Program\', 'UsbCeip'),
    @('\Microsoft\Windows\DiskDiagnostic\', 'Microsoft-Windows-DiskDiagnosticDataCollector'),
    @('\Microsoft\Windows\Feedback\Siuf\', 'DmClient'),
    @('\Microsoft\Windows\Feedback\Siuf\', 'DmClientOnScenarioDownload'),
    @('\Microsoft\Windows\Maps\', 'MapsToastTask'),
    @('\Microsoft\Windows\Maps\', 'MapsUpdateTask'),
    @('\Microsoft\Windows\Windows Error Reporting\', 'QueueReporting')
)

$Script:ClassicMenuKey = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}'

function Format-DefValue {
    param($Value)
    if ($null -eq $Value) { return 'non définie' }
    if ($Value -is [byte[]]) { return (($Value | ForEach-Object { '{0:X2}' -f $_ }) -join ' ') }
    if ($Value -is [array]) { return ($Value -join ', ') }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [uint32]) {
        $n = [int64]$Value
        if ($n -lt 0) { $n += 4294967296 }
        return [string]$n
    }
    return [string]$Value
}

function Get-RegValueInfo {
    # Retourne @{ Exists; Value; Kind } sans lever d'erreur.
    param([string]$Path, [string]$Name)
    $r = @{ Exists = $false; Value = $null; Kind = $null }
    try {
        $k = Get-Item -LiteralPath $Path -ErrorAction Stop
        if (@($k.GetValueNames()) -contains $Name) {
            $r.Exists = $true
            $r.Value = $k.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $r.Kind = $k.GetValueKind($Name).ToString()
        }
    } catch {}
    return $r
}

function Get-StartText {
    param($Start)
    switch ([int]$Start) { 0 { 'Démarrage (0)' } 1 { 'Système (1)' } 2 { 'Automatique (2)' } 3 { 'Manuel (3)' } 4 { 'Désactivé (4)' } default { [string]$Start } }
}

# Stratégies : un Windows 11 d'origine (hors domaine) n'en pose quasiment aucune. Toute valeur trouvée sous les clés
# Policies vient donc d'un réglage, d'un outil d'optimisation ou d'un logiciel. La supprimer rend à Windows son comportement
# standard. Exclues : données que Windows range lui-même sous Policies (certificats, chiffrement TLS, TPM, restrictions logicielles).
$Script:PolicyRoots = @('HKEY_LOCAL_MACHINE\SOFTWARE\Policies', 'HKEY_CURRENT_USER\SOFTWARE\Policies', 'HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Policies')
$Script:PolicyExclude = '\\Policies\\Microsoft\\(SystemCertificates|Cryptography|TPM|Windows\\safer)(\\|$)'
$Script:PolicyMaxRows = 600

function Get-ShortHash {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try { return ((@($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text.ToLowerInvariant()))) | Select-Object -First 8 | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $sha.Dispose() }
}

function ConvertTo-HivePath {
    # 'HKLM:\X' ou 'Registry::HKEY_LOCAL_MACHINE\X' -> 'HKEY_LOCAL_MACHINE\X'
    param([string]$Path)
    $p = $Path -replace '^Registry::', ''
    $p = $p -replace '^HKLM:\\', 'HKEY_LOCAL_MACHINE\' -replace '^HKCU:\\', 'HKEY_CURRENT_USER\'
    return $p
}

function Get-ShortRegPath {
    param([string]$HivePath)
    return ($HivePath -replace '^HKEY_LOCAL_MACHINE\\', 'HKLM:\' -replace '^HKEY_CURRENT_USER\\', 'HKCU:\')
}

function Remove-RegValueExact {
    # Supprime exactement cette valeur (sans jokers : certains noms de stratégie contiennent * ou [ ]).
    param([string]$Path, [string]$Name)
    $hp = ConvertTo-HivePath $Path
    $parts = $hp -split '\\', 2
    $base = $null
    switch ($parts[0]) {
        'HKEY_LOCAL_MACHINE' { $base = [Microsoft.Win32.Registry]::LocalMachine }
        'HKEY_CURRENT_USER'  { $base = [Microsoft.Win32.Registry]::CurrentUser }
        default { throw ("Ruche non prise en charge : " + $parts[0]) }
    }
    $k = $base.OpenSubKey($parts[1], $true)
    if (-not $k) { throw 'clé introuvable' }
    try { $k.DeleteValue($Name, $true) } finally { $k.Close() }
}

function Get-PolicyRows {
    # Valeurs de stratégie hors catalogue. Lecture seule. Renvoie des objets prêts pour la liste.
    param([hashtable]$Known)
    $out = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($root in $Script:PolicyRoots) {
        $base = 'Registry::' + $root
        if (-not (Test-Path -LiteralPath $base)) { continue }
        $keys = @()
        try { $keys = @(Get-Item -LiteralPath $base -ErrorAction Stop) + @(Get-ChildItem -LiteralPath $base -Recurse -ErrorAction SilentlyContinue) } catch { continue }
        foreach ($k in $keys) {
            $kn = [string]$k.Name
            if ($kn -match $Script:PolicyExclude) { continue }
            $names = @()
            try { $names = @($k.GetValueNames()) } catch {}
            foreach ($n in $names) {
                if ([string]::IsNullOrEmpty($n)) { continue }
                $id = ($kn + '|' + $n).ToLowerInvariant()
                if ($Known.ContainsKey($id)) { continue }
                # même stratégie vue par la vue 32 bits : une seule ligne
                $rel = (($kn -replace '\\WOW6432Node\\', '\') + '|' + $n).ToLowerInvariant()
                if ($seen.ContainsKey($rel)) { continue }
                $seen[$rel] = $true
                $val = $null; $kind = ''
                try { $val = $k.GetValue($n, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames); $kind = $k.GetValueKind($n).ToString() } catch {}
                $short = Get-ShortRegPath $kn
                $after = ($kn -split '\\Policies\\', 2)
                $vendor = ''; if ($after.Count -gt 1) { $vendor = ($after[1] -split '\\')[0] }
                $seg = ($kn -split '\\')[-1]
                $lbl = $(if ($seg -eq $vendor -or -not $vendor) { $seg } else { $vendor + ' · ' + $seg }) + ' · ' + $n
                $cur = Format-DefValue $val
                if ($cur.Length -gt 60) { $cur = $cur.Substring(0, 57) + '...' }
                [void]$out.Add([pscustomobject]@{
                    Id = 'pol:' + (Get-ShortHash $id); Cat = 'polx'; CatName = $Script:Win11DefCats['polx']; Label = $lbl; Kind = 'pol'
                    Def = 'non définie'; Cur = $cur; Tip = ($short + '\' + $n + '  (' + $kind + ')'); On = $false
                    RegPath = 'Registry::' + $kn; RegName = $n
                })
                if ($out.Count -ge $Script:PolicyMaxRows) { Write-Log ("Plus de {0} stratégies : la liste est tronquée." -f $Script:PolicyMaxRows) 'WARN'; return @($out) }
            }
        }
    }
    return @($out)
}

function Get-Win11DefaultsRows {
    # Tous les écarts entre l'état actuel et Windows 11 d'origine. Lecture seule.
    $rows = New-Object System.Collections.ArrayList
    $domain = $false
    try { $domain = [bool](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).PartOfDomain } catch {}
    $add = {
        param($Cat, $Id, $Label, $Kind, $DefText, $CurText, $Tip, $On = $null)
        if ($null -eq $On) { $On = ($Cat -ne 'ui' -and $Cat -ne 'polx') }
        [void]$rows.Add([pscustomobject]@{ Id = $Id; Cat = $Cat; CatName = $Script:Win11DefCats[$Cat]; Label = $Label; Kind = $Kind; Def = $DefText; Cur = $CurText; Tip = $Tip; On = [bool]$On })
    }
    # --- Services
    foreach ($s in $Script:Win11DefServices) {
        $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $s[1]
        $i = Get-RegValueInfo $key 'Start'
        if (-not $i.Exists) { continue }
        $cur = [int]$i.Value
        if ($cur -lt 2 -or $cur -eq [int]$s[2]) { continue }
        & $add $s[0] ('svc:' + $s[1]) ([string]$s[1]) 'svc' (Get-StartText $s[2]) (Get-StartText $cur) ("Service « {0} » ({1})" -f $s[4], $s[1])
    }
    # --- Registre
    $j = 0
    $known = @{}   # valeurs déjà listées par le catalogue : la détection des stratégies ne les répète pas
    foreach ($e in $Script:Win11DefRegistry) {
        $j++
        $path = [string]$e[1]; $name = [string]$e[2]
        if ($domain -and $path -match '\\Policies\\') { continue }
        $i = Get-RegValueInfo $path $name
        if (-not $i.Exists) { continue }
        $curTxt = Format-DefValue $i.Value
        if ($null -ne $e[5]) {
            $ms = @($e[5] | ForEach-Object { Format-DefValue $_ })
            if ($ms -notcontains $curTxt) { continue }
        }
        if ($null -ne $e[3]) {
            if ((Format-DefValue $e[3]) -eq $curTxt) { continue }
        }
        $seg = ($path -split '\\')[-1]
        $lbl = $seg + ' · ' + $name
        if ($name -eq 'Value') { $lbl = 'Autorisation : ' + $seg }
        if ($path -match '\\Policies\\') { $lbl = $seg + ' · ' + $name + ' (stratégie)' }
        $on = $null; if ($e.Count -ge 7 -and $e[6]) { $on = $false }
        $known[((ConvertTo-HivePath $path) + '|' + $name).ToLowerInvariant()] = $true
        & $add $e[0] ('reg:' + $j) $lbl 'reg' (Format-DefValue $e[3]) $curTxt ($path + '\' + $name) $on
    }
    # --- Stratégies hors catalogue (tout logiciel ou outil) ; ignorées sur un PC de domaine
    if (-not $domain) {
        foreach ($pr in @(Get-PolicyRows $known)) { [void]$rows.Add($pr) }
    }
    # --- Nagle : valeurs par interface réseau
    $ifRoot = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
    try {
        foreach ($k in @(Get-ChildItem -LiteralPath $ifRoot -ErrorAction Stop)) {
            foreach ($n in 'TcpAckFrequency', 'TCPNoDelay') {
                $i = Get-RegValueInfo $k.PSPath $n
                if ($i.Exists -and (Format-DefValue $i.Value) -eq '1') {
                    & $add 'net' ('if:' + $n + ':' + $k.PSChildName) ($n + '_' + $k.PSChildName) 'if' 'non définie' '1' ($k.PSPath + '|' + $n)
                }
            }
        }
    } catch {}
    # --- Menu contextuel classique
    if (Test-Path -LiteralPath ($Script:ClassicMenuKey + '\InprocServer32')) {
        & $add 'ui' 'key:classic' 'Menu contextuel classique (Windows 10)' 'key' 'menu Windows 11' 'menu classique' $Script:ClassicMenuKey
    }
    # --- Tâches planifiées désactivées
    $t = 0
    foreach ($tk in $Script:Win11DefTasks) {
        $t++
        $task = $null
        try { $task = Get-ScheduledTask -TaskPath ([string]$tk[0]) -TaskName ([string]$tk[1]) -ErrorAction Stop } catch {}
        if ($task -and [string]$task.State -eq 'Disabled') {
            & $add 'task' ('task:' + $t) ([string]$tk[1]) 'task' 'Activée' 'Désactivée' ([string]$tk[0] + [string]$tk[1])
        }
    }
    $order = @($Script:Win11DefCats.Keys)
    return @($rows | Sort-Object @{ Expression = { $order.IndexOf($_.Cat) } }, Label)
}

function Get-Win11DefaultsState {
    Write-Log '=== Comparaison avec les valeurs par défaut de Windows 11 (lecture seule) ==='
    $rows = @(Get-Win11DefaultsRows)
    $dom = $false
    try { $dom = [bool](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).PartOfDomain } catch {}
    if ($dom) { Write-Log 'PC joint à un domaine : les stratégies de groupe ne sont pas touchées.' 'WARN' }
    $np = @($rows | Where-Object { $_.Kind -eq 'pol' }).Count
    if ($np -gt 0) { Write-Log ("{0} stratégie(s) hors catalogue détectée(s) : non cochées, à vérifier une par une (survolez la ligne pour voir la clé)." -f $np) 'WARN' }
    Write-Log 'Référence : valeurs d''origine de Windows 11 24H2 à 26H2 (même base système), pour le compte qui lance la Toolbox côté HKCU.'
    if ($rows.Count -eq 0) { Write-Log 'Aucun écart : ce PC est déjà aux valeurs par défaut de Windows 11 pour les réglages connus.' 'OK' }
    else { Write-Log ("{0} réglage(s) différent(s) de Windows 11." -f $rows.Count) 'OK' }
    Set-SyncResult $rows
}

function ConvertTo-DwordInt {
    param($Value)
    $n = [int64]$Value
    if ($n -gt 2147483647) { $n -= 4294967296 }
    return [int]$n
}

function Set-DefRegValue {
    param([string]$Path, [string]$Name, $Value, [string]$Kind)
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
    $v = $Value
    switch ($Kind) {
        'DWord'       { $v = ConvertTo-DwordInt $Value }
        'QWord'       { $v = [int64]$Value }
        'Binary'      { $v = [byte[]]@($Value) }
        'MultiString' { $v = [string[]]@($Value) }
        default       { $v = [string]$Value }
    }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $v -PropertyType $Kind -Force -ErrorAction Stop | Out-Null
}

function Get-ServiceModeName {
    param([string]$Name)
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $Name
    $s = (Get-RegValueInfo $key 'Start').Value
    $d = (Get-RegValueInfo $key 'DelayedAutostart').Value
    if ($null -eq $s) { return '' }
    switch ([int]$s) { 2 { if ($d -eq 1) { 'delayed-auto' } else { 'auto' } } 3 { 'demand' } 4 { 'disabled' } 1 { 'system' } 0 { 'boot' } default { '' } }
}

function Restore-Win11Defaults {
    param([string[]]$Ids)
    Write-Log '=== Retour aux valeurs par défaut de Windows 11 ==='
    $want = @($Ids | Where-Object { $_ })
    if ($want.Count -eq 0) { Write-Log 'Aucun réglage sélectionné.' 'WARN'; return }
    $rows = @(Get-Win11DefaultsRows | Where-Object { $want -contains $_.Id })
    if ($rows.Count -eq 0) { Write-Log 'Rien à rétablir : les réglages choisis sont déjà ceux de Windows 11.' 'OK'; return }
    [void](New-DriverRestorePoint)
    $dir = Join-Path $Script:LogDir 'Backup'
    try { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null } catch {}
    $file = Join-Path $dir ("AvantDefauts_{0}_{1}.json" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $rec = New-Object System.Collections.ArrayList
    $ok = 0; $ko = 0
    $okNames = New-Object System.Collections.ArrayList
    $koNames = New-Object System.Collections.ArrayList
    $regIdx = @{}
    $j = 0
    foreach ($e in $Script:Win11DefRegistry) { $j++; $regIdx['reg:' + $j] = $e }
    $taskIdx = @{}
    $t = 0
    foreach ($tk in $Script:Win11DefTasks) { $t++; $taskIdx['task:' + $t] = $tk }
    foreach ($r in $rows) {
        try {
            switch ($r.Kind) {
                'svc' {
                    $sv = $Script:Win11DefServices | Where-Object { ('svc:' + $_[1]) -eq $r.Id } | Select-Object -First 1
                    $before = Get-ServiceModeName ([string]$sv[1])
                    $mode = 'demand'
                    if ([int]$sv[2] -eq 2) { if ([int]$sv[3] -eq 1) { $mode = 'delayed-auto' } else { $mode = 'auto' } }
                    elseif ([int]$sv[2] -eq 4) { $mode = 'disabled' }
                    & sc.exe config ([string]$sv[1]) start= $mode | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw ("sc.exe a répondu " + $LASTEXITCODE) }
                    [void]$rec.Add(@{ Kind = 'svc'; Name = [string]$sv[1]; Mode = $before })
                    Write-Log ("Service {0} : {1} -> {2}" -f $sv[1], $r.Cur, $r.Def) 'OK'
                }
                'reg' {
                    $e = $regIdx[$r.Id]
                    $path = [string]$e[1]; $name = [string]$e[2]
                    $i = Get-RegValueInfo $path $name
                    $val = $i.Value
                    if ($val -is [byte[]]) { $val = @($val | ForEach-Object { [int]$_ }) }
                    [void]$rec.Add(@{ Kind = 'reg'; Path = $path; Name = $name; Existed = $i.Exists; Value = $val; VKind = $i.Kind })
                    if ($null -eq $e[3]) {
                        Remove-ItemProperty -LiteralPath $path -Name $name -ErrorAction Stop
                    } else {
                        Set-DefRegValue $path $name $e[3] ([string]$e[4])
                    }
                    Write-Log ("{0} : {1} -> {2}" -f $name, $r.Cur, $r.Def) 'OK'
                }
                'pol' {
                    $p = [string]$r.RegPath; $n = [string]$r.RegName
                    $i = Get-RegValueInfo $p $n
                    if ($i.Exists) {
                        $val = $i.Value
                        if ($val -is [byte[]]) { $val = @($val | ForEach-Object { [int]$_ }) }
                        [void]$rec.Add(@{ Kind = 'reg'; Path = $p; Name = $n; Existed = $true; Value = $val; VKind = $i.Kind })
                        Remove-RegValueExact $p $n
                        Write-Log ("Stratégie retirée : {0}\{1} ({2})" -f (Get-ShortRegPath (ConvertTo-HivePath $p)), $n, $r.Cur) 'OK'
                    }
                }
                'if' {
                    $parts = ([string]$r.Tip) -split '\|'
                    $p = $parts[0]; $n = $parts[1]
                    $i = Get-RegValueInfo $p $n
                    [void]$rec.Add(@{ Kind = 'reg'; Path = $p; Name = $n; Existed = $i.Exists; Value = $i.Value; VKind = $i.Kind })
                    Remove-ItemProperty -LiteralPath $p -Name $n -ErrorAction Stop
                    Write-Log ("{0} supprimée ({1})" -f $n, $r.Label) 'OK'
                }
                'key' {
                    $k = $Script:ClassicMenuKey
                    $sub = $k + '\InprocServer32'
                    [void]$rec.Add(@{ Kind = 'regkey'; Path = $sub; Name = 'InprocServer32' })
                    $kids = @(Get-ChildItem -LiteralPath $k -ErrorAction SilentlyContinue)
                    if ($kids.Count -le 1) { Remove-Item -LiteralPath $k -Recurse -Force -ErrorAction Stop }
                    else { Remove-Item -LiteralPath $sub -Recurse -Force -ErrorAction Stop }
                    Write-Log 'Menu contextuel : retour au menu Windows 11 (rouvrez l''Explorateur ou la session)' 'OK'
                }
                'task' {
                    $tk = $taskIdx[$r.Id]
                    Enable-ScheduledTask -TaskPath ([string]$tk[0]) -TaskName ([string]$tk[1]) -ErrorAction Stop | Out-Null
                    [void]$rec.Add(@{ Kind = 'task'; Path = [string]$tk[0]; Name = [string]$tk[1] })
                    Write-Log ("Tâche réactivée : {0}" -f $tk[1]) 'OK'
                }
            }
            $ok++; [void]$okNames.Add([string]$r.Label)
        } catch {
            $ko++; [void]$koNames.Add([string]$r.Label)
            Write-Log ("{0} : {1}" -f $r.Label, $_.Exception.Message) 'WARN'
        }
        # le fichier d'annulation est mis à jour après chaque réglage : rien n'est perdu en cas d'interruption
        try { Set-Content -LiteralPath $file -Value (ConvertTo-Json -InputObject @($rec) -Depth 5) -Encoding UTF8 -ErrorAction Stop } catch {}
    }
    $koTxt = ''; if ($ko -gt 0) { $koTxt = ", $ko en échec" }
    Write-Log ("{0} réglage(s) rétabli(s){1}. Valeurs d'avant enregistrées : {2}" -f $ok, $koTxt, $file) 'OK'
    Write-Log 'Un redémarrage est conseillé (services, priorités système). Annulation possible depuis la même carte.' 'WARN'
    $Script:RebootNeeded = $true
    Set-SyncResult @{ Ok = @($okNames); Bad = @($koNames); Reboot = $true; File = $file }
}

function Undo-Win11Defaults {
    Write-Log '=== Annulation du dernier retour aux valeurs par défaut ==='
    $dir = Join-Path $Script:LogDir 'Backup'
    $f = $null
    try { $f = Get-ChildItem -LiteralPath $dir -Filter 'AvantDefauts_*.json' -ErrorAction Stop | Where-Object { $_.Name -notmatch '_annule\.json$' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1 } catch {}
    if (-not $f) { Write-Log 'Aucun rétablissement à annuler.' 'WARN'; return }
    $recs = @()
    try { $recs = @(Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json | Where-Object { $_ }) } catch { Write-Log ("Fichier illisible : " + $_.Exception.Message) 'ERROR'; return }
    [array]::Reverse($recs)
    $ok = 0; $ko = 0
    foreach ($r in $recs) {
        try {
            switch ([string]$r.Kind) {
                'svc' {
                    if ([string]$r.Mode) { & sc.exe config ([string]$r.Name) start= ([string]$r.Mode) | Out-Null; if ($LASTEXITCODE -ne 0) { throw ("sc.exe " + $LASTEXITCODE) } }
                }
                'reg' {
                    if ($r.Existed) {
                        $v = $r.Value
                        if ([string]$r.VKind -eq 'Binary') { $v = [byte[]]@($v | ForEach-Object { [byte]$_ }) }
                        Set-DefRegValue ([string]$r.Path) ([string]$r.Name) $v ([string]$r.VKind)
                    } else { Remove-ItemProperty -LiteralPath ([string]$r.Path) -Name ([string]$r.Name) -ErrorAction SilentlyContinue }
                }
                'regkey' { New-Item -Path ([string]$r.Path) -Force -Value '' -ErrorAction Stop | Out-Null }
                'task'   { Disable-ScheduledTask -TaskPath ([string]$r.Path) -TaskName ([string]$r.Name) -ErrorAction Stop | Out-Null }
            }
            $ok++
        } catch { $ko++; Write-Log ("{0} : {1}" -f $r.Name, $_.Exception.Message) 'WARN' }
    }
    try { Rename-Item -LiteralPath $f.FullName -NewName ($f.BaseName + '_annule.json') -ErrorAction Stop } catch {}
    $koTxt = ''; if ($ko -gt 0) { $koTxt = ", $ko en échec" }
    Write-Log ("{0} réglage(s) remis comme avant{1}." -f $ok, $koTxt) 'OK'
    Set-SyncResult @{ Ok = @(if ($ok -gt 0) { 1..$ok | ForEach-Object { [string]$_ } }); Bad = @(); Reboot = $true }
}

Write-Host "  BJMPC Outils $Script:ToolsVersion : ce fichier est chargé par BJMPC Toolbox." -ForegroundColor Cyan
