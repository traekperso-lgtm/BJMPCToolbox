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
$Script:ToolsVersion = '1.5'
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
    $out = Invoke-NativeLines 'pnputil.exe' ('/add-driver "' + $dir + '\*.inf" /subdirs /install')
    $code = $LASTEXITCODE
    foreach ($l in @($out | Select-Object -Last 6)) { Write-Host ("   " + $l) -ForegroundColor DarkGray }
    if ($code -eq 0 -or $code -eq 3010) { Write-Log 'Pilotes réinstallés.' 'OK'; if ($code -eq 3010) { $Script:RebootNeeded = $true } }
    else { Write-Log ("pnputil a signalé un problème (code {0})." -f $code) 'WARN' }
}

# ---------------------------------------------------------------- Pilotes proposés par Windows Update
function Get-DriverUpdates {
    # Lecture seule : demande à Windows Update quels pilotes il propose pour cet ordinateur.
    Write-Log '=== Pilotes proposés par Windows Update (recherche, 1 à 2 minutes) ==='
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $res = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Driver'")
        $rows = New-Object System.Collections.ArrayList
        foreach ($u in $res.Updates) {
            $dt = ''; try { $dt = ([datetime]$u.DriverVerDate).ToString('yyyy-MM-dd') } catch {}
            $mb = 0; try { $mb = [math]::Round([double]$u.MaxDownloadSize / 1MB, 1) } catch {}
            [void]$rows.Add([pscustomobject]@{
                Id = [string]$u.Identity.UpdateID; Title = [string]$u.Title; Maker = [string]$u.DriverManufacturer
                Model = [string]$u.DriverModel; Class = [string]$u.DriverClass; Date = $dt; SizeMB = $mb
            })
        }
        if ($rows.Count -eq 0) { Write-Log 'Windows Update ne propose aucun pilote : les pilotes sont à jour selon Microsoft.' 'OK' }
        else { Write-Log ("{0} pilote(s) proposé(s) par Windows Update." -f $rows.Count) 'WARN' }
        Set-SyncResult @($rows)
    } catch { Write-Log ("Recherche impossible : " + $_.Exception.Message) 'WARN' }
}

function Install-DriverUpdates {
    # Télécharge et installe les pilotes choisis (identifiants Windows Update). Windows garde l'ancien pilote :
    # retour possible depuis le Gestionnaire de périphériques (Propriétés > Pilote > Restaurer le pilote).
    param([string[]]$Ids)
    $ids = @($Ids | Where-Object { $_ -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$' } | ForEach-Object { $_.ToLower() })
    if ($ids.Count -eq 0) { Write-Log 'Aucun pilote valide à installer.' 'WARN'; return }
    Write-Log ("=== Installation de {0} pilote(s) via Windows Update ===" -f $ids.Count)
    $okT = @(); $koT = @()
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $res = $session.CreateUpdateSearcher().Search("IsInstalled=0 and IsHidden=0 and Type='Driver'")
        $coll = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($u in $res.Updates) {
            if ($ids -contains ([string]$u.Identity.UpdateID).ToLower()) {
                try { if (-not $u.EulaAccepted) { $u.AcceptEula() } } catch {}
                [void]$coll.Add($u)
            }
        }
        if ($coll.Count -eq 0) { Write-Log "Ces pilotes ne sont plus proposés par Windows Update." 'WARN'; Set-SyncResult @{ Ok = @(); Bad = @(); Reboot = $false }; return }
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
            if ($rc -eq 2) { Write-Log "Installé : $t" 'OK'; $okT += $t }
            else { Write-Log ("Échec (code {0}) : {1}" -f $rc, $t) 'WARN'; $koT += $t }
        }
        $reb = [bool]$ir.RebootRequired
        if ($reb) { $Script:RebootNeeded = $true; Write-Log 'Un redémarrage est nécessaire pour terminer.' 'WARN' }
        Set-SyncResult @{ Ok = @($okT); Bad = @($koT); Reboot = $reb }
    } catch {
        Write-Log ("Installation impossible : " + $_.Exception.Message) 'ERROR'
        Set-SyncResult @{ Ok = @($okT); Bad = @($ids); Reboot = $false }
    }
}

# ---------------------------------------------------------------- Recherche de pilotes (Microsoft Update Catalog) avec contrôle WHQL strict
# Principe : on ne fait confiance ni au site, ni au transport (HTTP) : seule compte la signature Microsoft
# (« Microsoft Windows Hardware Compatibility Publisher ») du fichier .cat, vérifiée ici AVANT toute installation,
# puis revérifiée par Windows lui-même à l'installation (pnputil, sans /force).
$Script:DrvTmp = Join-Path $env:TEMP 'bjmpc_drivers'
$Script:CatalogBase = 'https://www.catalog.update.microsoft.com'
$Script:DrvClasses = @('Display', 'Net', 'MEDIA', 'Bluetooth', 'System', 'HDC', 'SCSIAdapter', 'Image', 'Camera', 'Biometric', 'USB', 'Sensor', 'Firmwares', 'SmartCardReader', 'AudioEndpoint', 'Processor', 'Printer', 'Ports')

function New-DriverRestorePoint {
    try { Checkpoint-Computer -Description ("BJMPC Pilotes " + (Get-Date -Format 'yyyy-MM-dd HH:mm')) -RestorePointType MODIFY_SETTINGS -ErrorAction Stop; Write-Log 'Point de restauration créé.' 'OK'; return $true }
    catch { Write-Log ("Point de restauration non créé (un point récent existe peut-être, ou la protection système est désactivée) : " + $_.Exception.Message) 'WARN'; return $false }
}

function ConvertTo-SafeVersion {
    param([string]$Text)
    $v = $null
    if ($Text -and [version]::TryParse(($Text.Trim()), [ref]$v)) { return $v }
    return $null
}

function Get-DriverDevices {
    # Lecture seule : appareils branchés avec leur pilote actuel (liste complète pour l'interface).
    $l = @(Get-DriverDeviceRows)
    Set-SyncResult $l
}

function Get-DriverDeviceRows {
    # Lecture seule : appareils branchés pour lesquels un pilote plus récent peut exister, avec leur pilote actuel.
    Write-Log '=== Appareils et pilotes installés ==='
    $rows = New-Object System.Collections.ArrayList
    try {
        $sd = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop | Where-Object { $_.DeviceID -and $_.DeviceName -and $Script:DrvClasses -contains [string]$_.DeviceClass })
        $present = @{}
        foreach ($d in @(Get-PnpDevice -PresentOnly -ErrorAction Stop)) { $present[[string]$d.InstanceId] = 1 }
        foreach ($d in $sd) {
            if (-not $present.ContainsKey([string]$d.DeviceID)) { continue }
            if (([string]$d.DeviceID) -match '^(ROOT|SWD|HTREE)\\') { continue }
            $dt = ''; try { $dt = ([datetime]$d.DriverDate).ToString('yyyy-MM-dd') } catch {}
            [void]$rows.Add([pscustomobject]@{
                Id = [string]$d.DeviceID; Name = [string]$d.DeviceName; Class = [string]$d.DeviceClass; Maker = [string]$d.Manufacturer
                Version = [string]$d.DriverVersion; Date = $dt; Inf = [string]$d.InfName; ClassGuid = [string]$d.ClassGuid; Problem = 0
            })
        }
    } catch { Write-Log ("Lecture impossible : " + $_.Exception.Message) 'WARN'; return }
    # Appareils présents sans pilote ou en erreur (« Autres périphériques », « Périphérique PCI »…)
    try {
        $have = @{}; foreach ($r in $rows) { $have[[string]$r.Id] = 1 }
        foreach ($d in @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop | Where-Object { $_.ConfigManagerErrorCode -ne 0 -and $_.ConfigManagerErrorCode -ne 22 -and $_.ConfigManagerErrorCode -ne 45 })) {
            $id = [string]$d.DeviceID
            if (-not $id -or $have.ContainsKey($id) -or $id -match '^(ROOT|SWD|HTREE)\\') { continue }
            $cls = if ($d.PNPClass) { [string]$d.PNPClass } else { 'Autres' }
            [void]$rows.Add([pscustomobject]@{
                Id = $id; Name = $(if ($d.Name) { [string]$d.Name } else { $id }); Class = $cls; Maker = [string]$d.Manufacturer
                Version = ''; Date = ''; Inf = ''; ClassGuid = ''; Problem = [int]$d.ConfigManagerErrorCode
            })
        }
    } catch { Write-Log ("Appareils sans pilote : lecture impossible : " + $_.Exception.Message) 'WARN' }
    $list = @($rows | Sort-Object @{ Expression = { [int]($_.Problem -gt 0) }; Descending = $true }, Class, Name)
    Write-Log ("{0} appareil(s) analysable(s), dont {1} sans pilote ou en erreur." -f $list.Count, @($list | Where-Object { $_.Problem -gt 0 }).Count) 'OK'
    return $list
}

function Get-DeviceInfo {
    # Nom, classe, pilote actuel d'un appareil (avec ou sans pilote installé).
    param([string]$InstanceId, $SignedMap)
    $d = $null; if ($SignedMap) { $d = $SignedMap[$InstanceId] }
    if (-not $d) { try { $d = Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop | Where-Object { [string]$_.DeviceID -eq $InstanceId } | Select-Object -First 1 } catch {} }
    if ($d) { return [pscustomobject]@{ Name = [string]$d.DeviceName; Class = [string]$d.DeviceClass; Version = [string]$d.DriverVersion; ClassGuid = [string]$d.ClassGuid; Inf = [string]$d.InfName } }
    $e = $null
    try { $e = Get-CimInstance Win32_PnPEntity -ErrorAction Stop | Where-Object { [string]$_.DeviceID -eq $InstanceId } | Select-Object -First 1 } catch {}
    if ($e) { return [pscustomobject]@{ Name = $(if ($e.Name) { [string]$e.Name } else { $InstanceId }); Class = [string]$e.PNPClass; Version = ''; ClassGuid = ''; Inf = '' } }
    return $null
}

function Get-DeviceHardwareIds {
    param([string]$InstanceId)
    $ids = @()
    try {
        $p = Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName 'DEVPKEY_Device_HardwareIds' -ErrorAction Stop
        $ids = @($p.Data | Where-Object { $_ })
    } catch {}
    return $ids
}

function Get-DeviceCompatibleIds {
    param([string]$InstanceId)
    $ids = @()
    try { $p = Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName 'DEVPKEY_Device_CompatibleIds' -ErrorAction Stop; $ids = @($p.Data | Where-Object { $_ }) } catch {}
    return $ids
}

function Invoke-CatalogWeb {
    param([string]$Url, [string]$PostBody)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.Timeout = 30000; $req.ReadWriteTimeout = 30000
    $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
    $req.Accept = 'text/html,application/xhtml+xml,*/*;q=0.8'
    if (-not $Script:CatCookies) { $Script:CatCookies = New-Object Net.CookieContainer }
    $req.CookieContainer = $Script:CatCookies
    if ($PostBody) {
        $req.Method = 'POST'; $req.ContentType = 'application/x-www-form-urlencoded'
        $bytes = [Text.Encoding]::UTF8.GetBytes($PostBody)
        $req.ContentLength = $bytes.Length
        $s = $req.GetRequestStream(); $s.Write($bytes, 0, $bytes.Length); $s.Close()
    }
    $resp = $req.GetResponse()
    try { $sr = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8); return $sr.ReadToEnd() } finally { $resp.Close() }
}

function ConvertFrom-CatalogHtml {
    # Extrait les lignes du tableau de résultats du Catalog. Retourne @() si la page n'a pas la forme attendue.
    param([string]$Html)
    $out = New-Object System.Collections.ArrayList
    foreach ($m in [regex]::Matches($Html, '(?is)<tr[^>]*\sid\s*=\s*"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})_R\d+"[^>]*>(.*?)</tr>')) {
        $cells = @([regex]::Matches($m.Groups[2].Value, '(?is)<td[^>]*>(.*?)</td>') | ForEach-Object { ([regex]::Replace($_.Groups[1].Value, '(?is)<[^>]+>', ' ') -replace '&nbsp;', ' ' -replace '&amp;', '&' -replace '\s+', ' ').Trim() })
        if ($cells.Count -lt 7) { continue }
        $dt = [datetime]::MinValue
        [void][datetime]::TryParseExact($cells[4], 'M/d/yyyy', [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$dt)
        $mb = 0.0
        if ($cells[6] -match '([\d\.,]+)\s*(KB|MB|GB)') {
            $n = [double]($Matches[1] -replace ',', '.' -replace '[^\d\.]', '')
            switch ($Matches[2]) { 'KB' { $mb = $n / 1024 } 'MB' { $mb = $n } 'GB' { $mb = $n * 1024 } }
        }
        [void]$out.Add([pscustomobject]@{ Guid = $m.Groups[1].Value.ToLower(); Title = $cells[1]; Products = $cells[2]; Classification = $cells[3]; Date = $dt; VersionText = $cells[5]; SizeMB = [math]::Round($mb, 1) })
    }
    return @($out)
}

function Get-CatalogCandidates {
    # Résultats du Catalog pour un identifiant matériel, filtrés (pilotes Windows 10/11, bonne architecture, version lisible).
    param([string]$HwId, [string]$Arch, $Cache)
    if ($Cache.ContainsKey($HwId)) { return @($Cache[$HwId]) }
    # Une page de résultats valide contient des lignes OU le message « aucun résultat ». Toute autre réponse (limite de
    # requêtes, page d'erreur) n'est PAS « aucun pilote » : on réessaie, puis on signale l'erreur.
    $rowsAll = @()
    $ok = $false
    foreach ($wait in @(0, 3, 8)) {
        if ($wait -gt 0) { Start-Sleep -Seconds $wait }
        $html = Invoke-CatalogWeb ($Script:CatalogBase + '/Search.aspx?q=' + [Uri]::EscapeDataString($HwId))
        $rowsAll = @(ConvertFrom-CatalogHtml $html)
        if ($rowsAll.Count -gt 0 -or $html -match '(?i)did not find any results|aucun r[ée]sultat|no results') { $ok = $true; break }
    }
    if (-not $ok) {
        # Garde la réponse brute pour diagnostic (C:\BJMPC-Logs\Pilotes\catalog_reponse.html) et un extrait dans le journal.
        try {
            $dd = Join-Path $Script:LogDir 'Pilotes'; New-Item -ItemType Directory -Path $dd -Force -ErrorAction Stop | Out-Null
            [IO.File]::WriteAllText((Join-Path $dd 'catalog_reponse.html'), ('<!-- ' + $HwId + ' -->' + "`n" + [string]$html).Substring(0, [Math]::Min(200000, ([string]$html).Length + $HwId.Length + 10)))
            $txt = ([regex]::Replace([string]$html, '(?is)<script.*?</script>|<style.*?</style>|<[^>]+>', ' ') -replace '\s+', ' ').Trim()
            Write-Log ('Réponse du Catalog (extrait) : ' + $txt.Substring(0, [Math]::Min(220, $txt.Length))) 'WARN'
        } catch {}
        throw 'Réponse inattendue du Catalog (trop de requêtes ?)'
    }
    $out = New-Object System.Collections.ArrayList
    foreach ($r in $rowsAll) {
        if ($r.Classification -notmatch 'Driver') { continue }
        if ($r.Products -notmatch 'Windows (10|11)') { continue }
        if ($Arch -eq 'x64' -and ($r.Title -match 'ARM64' -or $r.Products -match 'ARM64')) { continue }
        if ($Arch -eq 'ARM64' -and $r.Title -notmatch 'ARM64' -and $r.Products -notmatch 'ARM64') { continue }
        $v = ConvertTo-SafeVersion $r.VersionText
        if (-not $v -and $r.Title -match '(\d+(\.\d+){2,3})\s*$') { $v = ConvertTo-SafeVersion $Matches[1] }
        if (-not $v) { continue }
        [void]$out.Add(@{ V = $v; R = $r; H = $HwId })
    }
    $Cache[$HwId] = @($out)
    Start-Sleep -Milliseconds 700
    return @($out)
}

function Select-BestCandidate {
    param($Cands, $InstalledVersion)
    $best = $null
    foreach ($c in @($Cands)) {
        if ($InstalledVersion -and $c.V -le $InstalledVersion) { continue }
        if ($best -eq $null -or $c.V -gt $best.V -or ($c.V -eq $best.V -and $c.R.Date -gt $best.R.Date)) { $best = $c }
    }
    return $best
}

function Get-CandidateGuids {
    # Les résultats du Catalog sont approximatifs : plusieurs paquets différents (même titre, tailles différentes) partagent
    # le même mot-clé. On garde les meilleurs paquets distincts (plus récents que l'installé) pour les essayer l'un après l'autre.
    param($Cands, $InstalledVersion, [int]$Max = 6)
    $seenKey = @{}; $g = New-Object System.Collections.ArrayList
    foreach ($c in @($Cands | Sort-Object @{ Expression = { $_.V }; Descending = $true }, @{ Expression = { $_.R.Date }; Descending = $true })) {
        if ($InstalledVersion -and $c.V -le $InstalledVersion) { continue }
        $k = ([string]$c.R.Title + '|' + [string]$c.R.SizeMB + '|' + [string]$c.V)
        if ($seenKey.ContainsKey($k)) { continue }
        $seenKey[$k] = 1
        [void]$g.Add([string]$c.R.Guid)
        if ($g.Count -ge $Max) { break }
    }
    return @($g)
}

function Find-DriverCatalog {
    # Lecture seule : pour chaque appareil choisi, cherche dans le Microsoft Update Catalog un pilote signé plus récent.
    # On cherche d'abord SANS le SUBSYS/REV (identifiant de la puce : VEN_xxxx&DEV_xxxx), car le Catalog est bien mieux
    # fourni ainsi. Le SUBSYS (variante d'un fabricant de PC) n'est utilisé qu'en cas de doute : plusieurs éditeurs pour
    # la même puce, ou aucun résultat sans lui. Le contrôle strict de l'INF reste fait avant toute installation.
    param([string[]]$Instances, [switch]$Extended, [string]$Scope = '')
    Write-Log ('=== Recherche dans le Microsoft Update Catalog (identifiants matériel' + $(if ($Extended) { ', niveau élargi pour les introuvables' } else { ', niveau strict' }) + ') ===')
    if ($Scope) {
        # Périmètre choisi dans l'interface : Main (appareils principaux + sans pilote), Missing (sans pilote), All.
        $main = @('Display', 'Net', 'MEDIA', 'Bluetooth', 'Image', 'Camera', 'HDC', 'SCSIAdapter', 'Biometric', 'SmartCardReader', 'Sensor')
        $dev = @(Get-DriverDeviceRows)
        $sel = @()
        if ($Scope -eq 'All') { $sel = $dev }
        elseif ($Scope -eq 'Missing') { $sel = @($dev | Where-Object { $_.Problem -gt 0 }) }
        else { $sel = @($dev | Where-Object { $_.Problem -gt 0 -or $main -contains [string]$_.Class }) }
        $Instances = @($sel | ForEach-Object { [string]$_.Id })
        Write-Log ("{0} appareil(s) à analyser." -f $Instances.Count)
    }
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'ARM64' } else { 'x64' }
    $sd = @{}
    try { foreach ($d in @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop)) { if ($d.DeviceID) { $sd[[string]$d.DeviceID] = $d } } } catch {}
    $rows = New-Object System.Collections.ArrayList
    $net = $true
    $badRun = 0
    $cache = @{}
    $total = @($Instances | Where-Object { $_ }).Count; $k = 0
    foreach ($inst in @($Instances | Where-Object { $_ })) {
        $k++
        $d = Get-DeviceInfo $inst $sd
        $name = if ($d) { [string]$d.Name } else { $inst }
        $instV = if ($d) { ConvertTo-SafeVersion ([string]$d.Version) } else { $null }
        Write-Host ("  [{0}/{1}] {2}" -f $k, $total, $name) -ForegroundColor DarkGray
        $row = [pscustomobject]@{ Id = $inst; Name = $name; Class = $(if ($d) { [string]$d.Class } else { '' }); Installed = $(if ($d) { [string]$d.Version } else { '' }); Status = 'none'; State = 'none'; Alts = ''; Verified = $false; Note = ''; Guid = ''; Title = ''; Version = ''; Date = ''; SizeMB = 0.0; HwId = ''; Doubt = $false; Level = 1 }
        if (-not $net) { $row.Status = 'error'; $row.State = 'error'; $row.Note = 'Recherche interrompue (Catalog injoignable ou trop sollicité)'; [void]$rows.Add($row); continue }
        $hw = @(Get-DeviceHardwareIds $inst | Select-Object -First 8)
        if ($hw.Count -eq 0) { $row.Note = 'Aucun identifiant matériel lisible'; [void]$rows.Add($row); continue }
        $base = @($hw | ForEach-Object { ([string]$_) -replace '&(SUBSYS|REV)_[0-9A-Fa-f]+', '' } | Select-Object -Unique | Select-Object -First 3)
        $spec = @($hw | Where-Object { ([string]$_) -match 'SUBSYS_' } | Select-Object -First 2)
        $row.HwId = [string]$base[0]
        $best = $null; $nres = 0; $doubt = $false; $refined = $false; $why = ''; $pool = @()
        try {
            $seen = @()
            foreach ($h in $base) {
                $cands = @(Get-CatalogCandidates $h $arch $cache)
                $nres += $cands.Count
                $best = Select-BestCandidate $cands $instV
                if ($best) { $seen = $cands; $pool = $cands; break }
            }
            if ($best) {
                $vendors = @($seen | ForEach-Object { (([string]$_.R.Title) -split ' - ')[0].Trim().ToLower() } | Select-Object -Unique)
                if ($vendors.Count -ge 2) { $doubt = $true }
            }
            $why = $(if ($doubt) { 'plusieurs éditeurs pour cette puce' } else { 'introuvable sans le SUBSYS' })
            if (($doubt -or $nres -eq 0) -and $spec.Count -gt 0) {
                foreach ($h in $spec) {
                    $cands2 = @(Get-CatalogCandidates $h $arch $cache)
                    $nres += $cands2.Count
                    $b2 = Select-BestCandidate $cands2 $instV
                    if ($b2) { $best = $b2; $pool = $cands2; $refined = $true; $doubt = $false; break }
                }
            }
        } catch {
            Write-Log ("Catalog : " + $_.Exception.Message) 'WARN'
            $row.Status = 'error'; $row.State = 'error'
            if ($_.Exception.Message -like 'Réponse inattendue*') {
                $badRun++
                $row.Note = 'Réponse inattendue du Catalog : relancez la recherche dans quelques minutes'
                if ($badRun -ge 2) { $net = $false; Write-Log 'Le Catalog ne répond pas normalement (limite de requêtes ?) : recherche interrompue. Réessayez dans quelques minutes.' 'WARN' }
            }
            else { $net = $false; $row.Note = 'Catalog injoignable' }
            [void]$rows.Add($row); continue
        }
        if (-not $best -and $Extended -and $nres -eq 0) {
            # Niveau 2 : identifiants de puce sans préfixe de bus, identifiants compatibles, puis nom du produit.
            $q = New-Object System.Collections.ArrayList
            foreach ($b in $base) { $t = ([string]$b) -replace '^[A-Za-z]+\\', ''; if ($t -and $t -ne $b) { [void]$q.Add($t) } }
            # Les identifiants de CLASSE (CC_xxxx, Class_xx) ne désignent aucun pilote précis : jamais cherchés.
            foreach ($c in @(Get-DeviceCompatibleIds $inst | Where-Object { ([string]$_) -notmatch '(?i)[&\\]CC_|Class_|^[A-Za-z]+\\VEN_[0-9A-F]{4}$' } | Select-Object -First 2)) { [void]$q.Add([string]$c) }
            if ($name -notmatch '^(Périphérique|Contrôleur de bus|Unknown|Autre)' -and $name.Length -ge 6) { [void]$q.Add(([string]$name -replace '\(R\)|\(TM\)|\(C\)|[®™]', '' -replace '\s+', ' ').Trim()) }
            try {
                foreach ($h in @($q | Select-Object -Unique)) {
                    $cands3 = @(Get-CatalogCandidates $h $arch $cache)
                    $b3 = Select-BestCandidate $cands3 $instV
                    if ($b3) { $best = $b3; $pool = $cands3; $row.Level = 2; $refined = $false; $row.Note = 'ÉLARGI : trouvé par « ' + $h + ' » (le contrôle de l''INF décidera à l''installation)'; break }
                }
            } catch { Write-Log ("Catalog injoignable : " + $_.Exception.Message) 'WARN'; $net = $false }
        }
        if ($best) {
            $badRun = 0
            $row.Status = 'found'; $row.State = 'update'; $row.Guid = $best.R.Guid; $row.Title = $best.R.Title; $row.Version = $best.R.VersionText
            $row.Alts = (@(Get-CandidateGuids $pool $instV) -join '~'); if (-not $row.Alts) { $row.Alts = [string]$best.R.Guid }
            # Le Catalog trouve par mots-clés (résultats approximatifs) : un paquet « proposé » peut ne pas contenir cet appareil.
            # Les paquets légers sont donc téléchargés et contrôlés dès la recherche ; les gros (pilotes graphiques) le sont à l'installation.
            if ($d -and [double]$best.R.SizeMB -le 60) {
                Write-Host '      contrôle du paquet…' -ForegroundColor DarkGray
                $chk = $null
                try { $chk = Resolve-CatalogPackage -Ids @($row.Alts -split '~') -Device $d -HwIds $hw -CompatIds @(Get-DeviceCompatibleIds $inst) -Level $row.Level } catch { Write-Log ("Contrôle impossible : " + $_.Exception.Message) 'WARN' }
                if ($chk -and $chk.Ok) {
                    $row.Alts = $chk.Guid; $row.Verified = $true
                    try { Remove-Item -LiteralPath $chk.Work -Recurse -Force -ErrorAction SilentlyContinue } catch {}
                } elseif ($chk -and $chk.Errors -lt @($row.Alts -split '~').Count) {
                    $row.Status = 'none'; $row.State = 'nomatch'; $row.Alts = ''
                    $row.Note = 'Le Catalog propose des paquets pour cette puce, mais aucun ne déclare cet appareil'
                    Write-Log ("{0} : paquets du Catalog sans rapport avec cet appareil (écartés)." -f $name) 'WARN'
                    [void]$rows.Add($row); continue
                }
            }
            $row.Date = $(if ($best.R.Date -gt [datetime]'1990-01-01') { $best.R.Date.ToString('yyyy-MM-dd') } else { '' }); $row.SizeMB = $best.R.SizeMB; $row.HwId = $best.H; $row.Doubt = $doubt
            if ($row.Level -ge 2) { }
            elseif ($refined) { $row.Note = 'affiné avec le SUBSYS (' + $why + ')' }
            elseif ($doubt) { $row.Note = 'plusieurs éditeurs pour cette puce : le contrôle strict décidera' }
            Write-Log ("{0} : v{1} proposée ({2}) - {3}{4}" -f $name, $row.Version, $row.Date, $(if ($row.Installed) { 'installé : v' + $row.Installed } else { 'aucun pilote installé' }), $(if ($row.Note) { ' [' + $row.Note + ']' } else { '' })) 'WARN'
        } else {
            if ($nres -gt 0) { $row.State = 'current' }
            $row.Note = $(if ($nres -gt 0) { 'Le Catalog ne propose rien de plus récent que l''installé' } else { 'Aucun pilote correspondant sur le Catalog Microsoft' })
            Write-Log ("{0} : aucun pilote plus récent dans le Catalog." -f $name) 'OK'
        }
        [void]$rows.Add($row)
    }
    $nf = @($rows | Where-Object { $_.Status -eq 'found' }).Count
    Write-Log ("{0} pilote(s) plus récent(s) trouvé(s) sur {1} appareil(s)." -f $nf, $rows.Count) $(if ($nf -gt 0) { 'WARN' } else { 'OK' })
    Set-SyncResult @($rows)
}

function Test-DriverPackage {
    # Contrôle strict d'un dossier de pilote. Retourne @{ Ok; Reasons; Report; Inf; Version; Date }.
    # Refus si : signature .cat absente/invalide/non Microsoft WHQL ; architecture ; identifiant matériel absent de l'INF ;
    # classe différente ; version non plus récente que celle installée.
    param([string]$Dir, [string[]]$HwIds, [string]$InstalledVersion, [string]$ClassGuid, [string]$OnlyInf, [string[]]$CompatIds = @(), [int]$Level = 1)
    $rep = New-Object System.Collections.ArrayList
    $bad = New-Object System.Collections.ArrayList
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
        $dv = $null; $dd = ''
        if ($txt -match '(?im)^\s*DriverVer\s*=\s*([\d/]+)\s*,\s*([\d\.]+)') { $dd = $Matches[1]; $dv = ConvertTo-SafeVersion $Matches[2] } else { [void]$mine.Add(("{0} : DriverVer illisible" -f $f.Name)) }
        if ($dv -and $instV -and $dv -le $instV) { [void]$mine.Add(("{0} : version {1} pas plus récente que {2}" -f $f.Name, $dv, $instV)) }
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

function Get-CatalogPackage {
    # Télécharge le(s) .cab d'une mise à jour du Catalog (liens Microsoft uniquement) et les extrait.
    # Retourne la liste des dossiers extraits.
    param([string]$UpdateId, [string]$Work)
    $body = 'updateIDs=' + [Uri]::EscapeDataString('[{"size":0,"languages":"","uidInfo":"' + $UpdateId + '","updateID":"' + $UpdateId + '"}]')
    $html = Invoke-CatalogWeb ($Script:CatalogBase + '/DownloadDialog.aspx') $body
    $urls = @([regex]::Matches($html, "(?i)downloadInformation\[\d+\]\.files\[\d+\]\.url\s*=\s*'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
    $urls = @($urls | Where-Object { $_ -match '^https?://[A-Za-z0-9\.\-]+\.(microsoft\.com|windowsupdate\.com)/[^\s]+\.cab$' })
    $dirs = @()
    foreach ($u in $urls) {
        $cab = Join-Path $Work ([IO.Path]::GetFileName(([Uri]$u).AbsolutePath))
        Write-Log ("Téléchargement : {0}" -f ([Uri]$u).Host)
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $wc = New-Object Net.WebClient
        $wc.DownloadFile($u, $cab)
        $ex = Join-Path $Work ([IO.Path]::GetFileNameWithoutExtension($cab))
        New-Item -ItemType Directory -Path $ex -Force | Out-Null
        [void](Invoke-NativeLines 'expand.exe' ('-F:* "' + $cab + '" "' + $ex + '"'))
        $dirs += $ex
    }
    return @($dirs)
}

function Resolve-CatalogPackage {
    # Télécharge, dans l'ordre, les paquets proposés et retourne le premier dont l'INF passe Test-DriverPackage.
    # Retour : @{ Ok; Test; Work; Guid; Errors } (Errors = paquets impossibles à télécharger).
    param([string[]]$Ids, $Device, [string[]]$HwIds, [string[]]$CompatIds, [int]$Level = 1)
    $res = @{ Ok = $false; Test = $null; Work = ''; Guid = ''; Errors = 0 }
    $n = 0
    foreach ($uid in $Ids) {
        $n++
        $work = Join-Path $Script:DrvTmp $uid
        try {
            if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
            New-Item -ItemType Directory -Path $work -Force -ErrorAction Stop | Out-Null
            if (@($Ids).Count -gt 1) { Write-Log ("Paquet {0}/{1} du Catalog" -f $n, @($Ids).Count) }
            $dirs = @(Get-CatalogPackage $uid $work)
            if ($dirs.Count -eq 0) { Write-Log 'Aucun lien de téléchargement Microsoft pour ce paquet.' 'WARN'; $res.Errors++ }
            foreach ($ex in $dirs) {
                $t = Test-DriverPackage -Dir $ex -HwIds $HwIds -InstalledVersion ([string]$Device.Version) -ClassGuid ([string]$Device.ClassGuid) -CompatIds $CompatIds -Level $Level
                if ($t.Ok) { $res.Ok = $true; $res.Test = $t; $res.Work = $work; $res.Guid = $uid; break }
                foreach ($r in @($t.Reasons | Select-Object -First 2)) { Write-Log ("Paquet {0} refusé : {1}" -f $n, $r) 'WARN' }
            }
        } catch { Write-Log ("Paquet {0} : {1}" -f $n, $_.Exception.Message) 'WARN'; $res.Errors++ }
        finally { if (-not $res.Ok) { try { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue } catch {} } }
        if ($res.Ok) { break }
    }
    return $res
}

function Install-CatalogDriver {
    # Essaie les paquets proposés par le Catalog (UpdateId = GUID, ou plusieurs séparés par ~, du meilleur au moins bon),
    # garde le premier qui passe le contrôle (Test-DriverPackage), sauvegarde l'ancien pilote, installe, puis VÉRIFIE
    # que Windows l'a vraiment appliqué à l'appareil.
    param([string]$InstanceId, [string]$UpdateId, [int]$Level = 1)
    if ($Level -lt 1 -or $Level -gt 2) { $Level = 1 }
    $ids = @(([string]$UpdateId -split '~') | Where-Object { $_ -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$' } | Select-Object -First 6)
    if ($ids.Count -eq 0) { Write-Log 'Identifiant de mise à jour refusé.' 'ERROR'; return }
    $d = Get-DeviceInfo $InstanceId $null
    if (-not $d) { Write-Log "Appareil introuvable : $InstanceId" 'ERROR'; $Script:DrvCatBad += $InstanceId; return }
    $name = [string]$d.Name
    Write-Log "--- $name ---"
    $goodWork = ''
    try {
        $hw = @(Get-DeviceHardwareIds $InstanceId)
        $cp = @(Get-DeviceCompatibleIds $InstanceId)
        $r0 = Resolve-CatalogPackage -Ids $ids -Device $d -HwIds $hw -CompatIds $cp -Level $Level
        if (-not $r0.Ok) { Write-Log "Aucun des $($ids.Count) paquet(s) proposé(s) ne passe le contrôle : rien n'est installé pour $name." 'WARN'; $Script:DrvCatBad += $name; return }
        $good = $r0.Test; $goodWork = $r0.Work
        foreach ($l in @($good.Report)) { Write-Log $l 'OK' }
        # Sauvegarde du pilote actuel (si c'est un pilote tiers oemNN.inf)
        $inf = ([string]$d.Inf).ToLower()
        if ($inf -match '^oem\d+\.inf$') {
            $bk = Join-Path $Script:LogDir ("Pilotes\Avant_MAJ_{0}_{1}\{2}" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmmss'), ($inf -replace '\.inf$', ''))
            New-Item -ItemType Directory -Path $bk -Force | Out-Null
            [void](Invoke-NativeLines 'pnputil.exe' ('/export-driver ' + $inf + ' "' + $bk + '"'))
            if (Get-ChildItem -LiteralPath $bk -Filter *.inf -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1) { Write-Log ("Ancien pilote sauvegardé : " + $bk) 'OK' }
            else { Write-Log 'Sauvegarde de l''ancien pilote impossible : installation annulée pour cet appareil.' 'WARN'; $Script:DrvCatBad += $name; return }
        }
        $oemBefore = @(Get-ChildItem -LiteralPath (Join-Path $env:windir 'INF') -Filter 'oem*.inf' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name.ToLower() })
        $out = Invoke-NativeLines 'pnputil.exe' ('/add-driver "' + $good.Inf + '" /install')
        $code = $LASTEXITCODE
        foreach ($l in @($out | Select-Object -Last 3)) { Write-Host ("   " + $l) -ForegroundColor DarkGray }
        if ($code -eq 0 -or $code -eq 3010) {
            if ($code -eq 3010) { $Script:RebootNeeded = $true; $Script:DrvCatReboot = $true }
            # Vérification : Windows a-t-il réellement appliqué le pilote à cet appareil ?
            $after = Get-DeviceInfo $InstanceId $null
            $applied = $true
            if ($code -ne 3010 -and $after -and ([string]$after.Inf -eq [string]$d.Inf) -and ([string]$after.Version -eq [string]$d.Version)) { $applied = $false }
            if ($applied) { Write-Log ("Installé : {0} → v{1}" -f $name, $good.Version) 'OK'; $Script:DrvCatOk += $name }
            else {
                Write-Log ("{0} : le pilote est valide mais Windows ne l'a pas appliqué à cet appareil (il ne correspond pas exactement, ou le pilote actuel est jugé meilleur)." -f $name) 'WARN'
                $oemNew = @(Get-ChildItem -LiteralPath (Join-Path $env:windir 'INF') -Filter 'oem*.inf' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name.ToLower() } | Where-Object { $oemBefore -notcontains $_ })
                foreach ($o in $oemNew) {
                    if ($o -match '^oem\d+\.inf$') { $dl = Invoke-NativeLines 'pnputil.exe' ('/delete-driver ' + $o); Write-Log ("Paquet inutilisé retiré du magasin : " + $o) 'OK' }
                }
                $Script:DrvCatBad += $name
            }
        } else { Write-Log ("Windows a refusé l'installation (code {0})." -f $code) 'WARN'; $Script:DrvCatBad += $name }
    } catch { Write-Log ("Échec pour {0} : {1}" -f $name, $_.Exception.Message) 'WARN'; $Script:DrvCatBad += $name }
    finally { if ($goodWork) { try { Remove-Item -LiteralPath $goodWork -Recurse -Force -ErrorAction SilentlyContinue } catch {} } }
}

function Install-CatalogDrivers {
    # Installe plusieurs pilotes du Catalog. Items = 'InstanceId|Guid1~Guid2~…|Niveau' (niveau 1 strict, 2 élargi).
    param([string[]]$Items)
    $Script:DrvCatOk = @(); $Script:DrvCatBad = @(); $Script:DrvCatReboot = $false
    Write-Log ("=== Installation de {0} pilote(s) du Catalog (contrôle WHQL strict) ===" -f @($Items).Count)
    [void](New-DriverRestorePoint)
    foreach ($it in @($Items)) {
        $p = ([string]$it) -split '\|'
        if ($p.Count -lt 2) { continue }
        $lv = 1; if ($p.Count -ge 3 -and $p[2] -eq '2') { $lv = 2 }
        Install-CatalogDriver -InstanceId $p[0] -UpdateId $p[1] -Level $lv
    }
    Write-Log ("{0} installé(s), {1} refusé(s) ou en échec." -f @($Script:DrvCatOk).Count, @($Script:DrvCatBad).Count) $(if (@($Script:DrvCatBad).Count -eq 0) { 'OK' } else { 'WARN' })
    Set-SyncResult @{ Ok = @($Script:DrvCatOk); Bad = @($Script:DrvCatBad); Reboot = [bool]$Script:DrvCatReboot }
}

function Get-DownloadsRoot {
    $p = ''
    try { $p = [string](New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path } catch {}
    if (-not $p -or -not (Test-Path -LiteralPath $p)) { $p = Join-Path $env:USERPROFILE 'Downloads' }
    return $p
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
    [void](New-DriverRestorePoint)
    $added = @(); $rb = $false
    foreach ($inf in $ok) {
        $args2 = '/add-driver "' + $inf + '"'; if ($Install) { $args2 += ' /install' }
        [void](Invoke-NativeLines 'pnputil.exe' $args2)
        $code = $LASTEXITCODE
        if ($code -eq 0 -or $code -eq 3010) { $added += (Split-Path $inf -Leaf); if ($code -eq 3010) { $rb = $true; $Script:RebootNeeded = $true } }
        else { $ko += (Split-Path $inf -Leaf); Write-Log ("Refusé par Windows : {0} (code {1})" -f (Split-Path $inf -Leaf), $code) 'WARN' }
    }
    Write-Log ("{0} pilote(s) ajouté(s){1}." -f $added.Count, $(if ($Install) { ' et installé(s)' } else { ' au magasin' })) $(if ($added.Count -gt 0) { 'OK' } else { 'WARN' })
    if ($tmpZip) { try { Remove-Item -LiteralPath $tmpZip -Recurse -Force -ErrorAction SilentlyContinue } catch {} }
    Set-SyncResult @{ Ok = @($added); Bad = @($ko); Reboot = $rb }
}

# ---------------------------------------------------------------- Appareils fantômes (non branchés depuis 15 jours ou plus)
$Script:GhostClasses = @('USB', 'USBDevice', 'WPD', 'DiskDrive', 'CDROM', 'Monitor', 'HIDClass', 'Keyboard', 'Mouse', 'Image', 'Camera', 'MEDIA', 'Net', 'Bluetooth', 'Ports', 'Printer', 'SmartCardReader')

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
            $last = $null
            foreach ($k in @('{83da6326-97a6-4088-9453-a1923f573b29} 102', '{83da6326-97a6-4088-9453-a1923f573b29} 103')) {
                try {
                    $p = Get-PnpDeviceProperty -InstanceId $id -KeyName $k -ErrorAction Stop
                    if ($p.Data -is [datetime] -and ($last -eq $null -or $p.Data -gt $last)) { $last = $p.Data }
                } catch {}
            }
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
    net  = 'Réseau'
    hw   = 'Matériel'
    nc   = 'Paramètre non critique'
    spec = 'Prise en charge spécifique'
    pref = 'Préférence utilisateur (sans impact négatif)'
    priv = 'Confidentialité et stratégies'
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
    @('pref', 'SysMain',          2, 0, 'SysMain (Superfetch)')
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
    @('sys', 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters', 'DisabledComponents', $null, 'DWord', 32)
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

function Get-Win11DefaultsRows {
    # Tous les écarts entre l'état actuel et Windows 11 d'origine. Lecture seule.
    $rows = New-Object System.Collections.ArrayList
    $domain = $false
    try { $domain = [bool](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).PartOfDomain } catch {}
    $add = {
        param($Cat, $Id, $Label, $Kind, $DefText, $CurText, $Tip)
        [void]$rows.Add([pscustomobject]@{ Id = $Id; Cat = $Cat; CatName = $Script:Win11DefCats[$Cat]; Label = $Label; Kind = $Kind; Def = $DefText; Cur = $CurText; Tip = $Tip; On = ($Cat -ne 'ui') })
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
        & $add $e[0] ('reg:' + $j) $lbl 'reg' (Format-DefValue $e[3]) $curTxt ($path + '\' + $name)
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
