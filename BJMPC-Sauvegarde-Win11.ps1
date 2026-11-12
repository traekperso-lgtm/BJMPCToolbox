#Requires -Version 5.1
<#
.SYNOPSIS
    BJMPC Informatique - Sauvegarde des fichiers du client (à la demande ou automatique)
.DESCRIPTION
    Bibliothèque utilisée par BJMPC Toolbox (page "Sauvegardes"), et script autonome lancé par la tâche planifiée.

    Ce qui est sauvegardé : les dossiers personnels choisis (Bureau, Documents, Images, Vidéos, Musique,
    Téléchargements) et les favoris des navigateurs. Les mots de passe des navigateurs ne sont pas copiés
    (ils sont chiffrés par Windows et inutilisables sur un autre PC).

    Principe : copie incrémentale avec robocopy vers <destination>\BJMPC-Sauvegarde\<PC>\<utilisateur>\.
    Seuls les fichiers nouveaux ou modifiés sont copiés. Rien n'est jamais supprimé dans la sauvegarde :
    un fichier effacé par erreur sur le PC y reste disponible.

    Sauvegarde automatique : le script et sa configuration sont copiés dans
    C:\Program Files\BJMPC\Sauvegarde (dossier réservé aux administrateurs), et une tâche planifiée
    "BJMPC Sauvegarde automatique" lance ce script avec -Run. La Toolbox peut donc être sur une clé USB.
    Le disque de destination est retrouvé par son identifiant de volume, même si sa lettre change.

    Deux modes :
      - « Dossiers choisis » : copie incrémentale, rien n'est jamais supprimé dans la sauvegarde.
      - « Miroir » : copie exacte du dossier utilisateur (hors AppData, OneDrive et dossiers système) dans ...\Miroir.
        Un fichier supprimé du PC quitte le miroir, mais il est d'abord déplacé dans ...\Miroir-Corbeille et gardé
        30 jours. Si un passage devait retirer une grande partie du miroir (dossier déplacé, disque différent,
        logiciel malveillant), il est suspendu et la Toolbox demande confirmation.

    Journaux et dernier résultat : C:\BJMPC-Logs\Sauvegarde.
.PARAMETER Run
    Lance la sauvegarde configurée, sans interface (utilisé par la tâche planifiée).
#>
param([switch]$Run)

$ErrorActionPreference = 'Continue'
$Script:BackupVersion = '1.1'
$Script:LogDir      = Join-Path $env:SystemDrive 'BJMPC-Logs'
$Script:LogFile     = Join-Path $Script:LogDir ("Sauvegarde_{0}_{1}.log" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmmss'))
$Script:BakHome     = Join-Path $env:ProgramFiles 'BJMPC\Sauvegarde'
$Script:BakConfig   = Join-Path $Script:BakHome 'config.json'
$Script:BakScript   = Join-Path $Script:BakHome 'BJMPC-Sauvegarde-Win11.ps1'
$Script:BakLogDir   = Join-Path $Script:LogDir 'Sauvegarde'
$Script:BakState    = Join-Path $Script:BakLogDir 'etat.json'
$Script:BakTaskName = 'BJMPC Sauvegarde automatique'
$Script:BakTaskPath = '\BJMPC\'
$Script:BakRootName = 'BJMPC-Sauvegarde'
$Script:BakAutoOk   = $false
$Script:BakMirrorDir   = 'Miroir'
$Script:BakTrashDir    = 'Miroir-Corbeille'
$Script:BakTrashDays   = 30
$Script:BakSuspectMin  = 500     # au-delà de ce nombre de fichiers retirés...
$Script:BakSuspectRate = 0.25    # ...et de cette part du miroir, le passage est suspendu
# Miroir : dossiers du profil jamais copiés (données d'applications, raccourcis système, nuage)
$Script:BakMirrorSkipDirs = @('AppData', 'Local Settings', 'Application Data', 'Cookies', 'NetHood', 'PrintHood', 'Recent', 'SendTo',
    'Start Menu', 'Templates', 'My Documents', 'IntelGraphicsProfiles', 'MicrosoftEdgeBackups', 'iCloudDrive', '$RECYCLE.BIN', 'System Volume Information')
$Script:BakMirrorSkipFiles = @('NTUSER.DAT*', 'ntuser.ini', 'ntuser.pol', 'UsrClass.dat*', 'desktop.ini', 'Thumbs.db', '*.tmp', '~$*')

# Dossiers personnels proposés (données pures : l'interface en tire ses cases à cocher).
# Reg = nom de la valeur dans "User Shell Folders", Def = nom du dossier par défaut dans le profil.
$Script:BakFolders = @(
    @{ Id = 'Desktop';   Label = 'Bureau';          Reg = 'Desktop';     Def = 'Desktop';   Default = $true },
    @{ Id = 'Documents'; Label = 'Documents';       Reg = 'Personal';    Def = 'Documents'; Default = $true },
    @{ Id = 'Pictures';  Label = 'Images';          Reg = 'My Pictures'; Def = 'Pictures';  Default = $true },
    @{ Id = 'Videos';    Label = 'Vidéos';          Reg = 'My Video';    Def = 'Videos';    Default = $true },
    @{ Id = 'Music';     Label = 'Musique';         Reg = 'My Music';    Def = 'Music';     Default = $true },
    @{ Id = 'Downloads'; Label = 'Téléchargements'; Reg = '{374DE290-123F-4565-9164-39C4925E467B}'; Def = 'Downloads'; Default = $false }
)

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

function Set-BackupResult {
    # Transmet un résultat à l'interface (sans effet quand le script tourne seul).
    param($Value)
    $sv = Get-Variable -Name Sync -ErrorAction SilentlyContinue
    if ($sv -and $sv.Value) { $sv.Value.Result = $Value }
}

function Format-BackupSize {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N1} Go' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N0} Mo' -f ($Bytes / 1MB)) }
    return ('{0:N0} Ko' -f ($Bytes / 1KB))
}

function Get-TreeBytes {
    # Taille d'un dossier, sans suivre les jonctions et sans s'arrêter sur un dossier interdit.
    param([string]$Path)
    $total = [long]0
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        try {
            $di = New-Object IO.DirectoryInfo $d
            foreach ($f in $di.GetFiles()) { $total += $f.Length }
            foreach ($s in $di.GetDirectories()) {
                if (-not ($s.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $stack.Push($s.FullName) }
            }
        } catch {}
    }
    return $total
}

# ---------------------------------------------------------------- Profils, dossiers et disques
function Get-InteractiveSid {
    # SID de la personne connectée à l'écran (la Toolbox peut être élevée avec un autre compte).
    try {
        $u = [string](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName
        if ($u) { return (New-Object Security.Principal.NTAccount($u)).Translate([Security.Principal.SecurityIdentifier]).Value }
    } catch {}
    try { return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { return '' }
}

function Resolve-ProfileFolder {
    # Emplacement réel d'un dossier personnel (il peut avoir été déplacé, par exemple dans OneDrive).
    param([string]$ProfilePath, [string]$Sid, $Def)
    $p = ''
    if ($Sid) {
        try {
            $k = "Registry::HKEY_USERS\$Sid\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
            $raw = (Get-Item -LiteralPath $k -ErrorAction Stop).GetValue([string]$Def.Reg, $null, 'DoNotExpandEnvironmentNames')
            if ($raw) { $p = [regex]::Replace([string]$raw, '(?i)%USERPROFILE%', [Text.RegularExpressions.MatchEvaluator] { param($m) $ProfilePath }) }
        } catch {}
    }
    if ($p -match '%') { $p = '' }
    if (-not $p) { $p = Join-Path $ProfilePath ([string]$Def.Def) }
    return $p.TrimEnd('\')
}

function Get-BackupProfiles {
    $curSid = Get-InteractiveSid
    $list = @()
    try {
        foreach ($p in @(Get-CimInstance Win32_UserProfile -ErrorAction Stop | Where-Object { -not $_.Special -and $_.LocalPath })) {
            $path = [string]$p.LocalPath
            if (-not (Test-Path -LiteralPath $path)) { continue }
            $name = Split-Path $path -Leaf
            if ($name -match '^(defaultuser\d*|Default|Public)$') { continue }
            $folders = @()
            foreach ($d in $Script:BakFolders) {
                $fp = Resolve-ProfileFolder $path ([string]$p.SID) $d
                $folders += [pscustomobject]@{ Id = [string]$d.Id; Label = [string]$d.Label; Path = $fp; Exists = (Test-Path -LiteralPath $fp); Default = [bool]$d.Default }
            }
            $list += [pscustomobject]@{ Name = $name; Path = $path; Sid = [string]$p.SID; Current = ([string]$p.SID -eq $curSid); Folders = $folders }
        }
    } catch { Write-Log "Liste des profils : $($_.Exception.Message)" 'WARN' }
    return @($list | Sort-Object @{ Expression = { -not $_.Current } }, Name)
}

function Get-BackupDrives {
    # Disques utilisables comme destination : tout volume avec une lettre, sauf le disque de Windows.
    $out = @()
    try {
        $sys = ([string]$env:SystemDrive).TrimEnd(':')
        foreach ($v in @(Get-Volume -ErrorAction Stop | Where-Object { $_.DriveLetter -and $_.DriveType -in 'Fixed', 'Removable' -and $_.FileSystem })) {
            if ([string]$v.DriveLetter -eq $sys) { continue }
            $kind = if ($v.DriveType -eq 'Removable') { 'amovible' } else { 'disque' }
            try {
                $bus = [string](Get-Partition -DriveLetter $v.DriveLetter -ErrorAction Stop | Get-Disk -ErrorAction Stop).BusType
                if ($bus -eq 'USB') { $kind = 'USB' }
            } catch {}
            $out += [pscustomobject]@{
                Root = ('{0}:\' -f $v.DriveLetter); Label = [string]$v.FileSystemLabel; Kind = $kind
                Free = [long]$v.SizeRemaining; Size = [long]$v.Size
            }
        }
    } catch { Write-Log "Liste des disques : $($_.Exception.Message)" 'WARN' }
    return @($out | Sort-Object @{ Expression = { $_.Kind -ne 'USB' } }, Root)
}

# ---------------------------------------------------------------- Configuration
function Get-BackupConfig {
    if (-not (Test-Path -LiteralPath $Script:BakConfig)) { return $null }
    try {
        $c = Get-Content -LiteralPath $Script:BakConfig -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($c -and $c.Profile -and @($c.Sources).Count -gt 0) { return $c }
    } catch { Write-Log "Configuration illisible : $($_.Exception.Message)" 'WARN' }
    return $null
}

function Get-BackupSourceFile {
    # Fichier de ce script : lancé seul, ou depuis le dossier de la Toolbox.
    if ($PSCommandPath -and (Split-Path $PSCommandPath -Leaf) -like 'BJMPC-Sauvegarde*') { return $PSCommandPath }
    $sv = Get-Variable -Name Sync -ErrorAction SilentlyContinue
    if ($sv -and $sv.Value -and $sv.Value.Root) { return (Join-Path ([string]$sv.Value.Root) 'BJMPC-Sauvegarde-Win11.ps1') }
    return ''
}

function Set-BackupConfig {
    # Enregistre le choix fait dans l'interface. Les emplacements des dossiers sont résolus maintenant
    # (session ouverte), pour que la tâche planifiée n'ait rien à deviner.
    param(
        [string]$ProfilePath, [string]$Sid, [string[]]$Folders, [bool]$Browsers = $true, [string]$Destination,
        [string]$Frequency = 'daily', [string]$Time = '12:30', [string]$Day = 'Monday', [string]$Mode = 'folders'
    )
    if ($Mode -ne 'mirror') { $Mode = 'folders' }
    if (-not $ProfilePath -or -not (Test-Path -LiteralPath $ProfilePath)) { Write-Log "Profil introuvable : $ProfilePath" 'ERROR'; return $false }
    $dest = ([string]$Destination).Trim().Trim('"')
    if (-not $dest) { Write-Log 'Choisissez un disque ou un dossier de destination.' 'ERROR'; return $false }
    if ($dest -match '^[A-Za-z]:$') { $dest += '\' }
    if (-not (Test-Path -LiteralPath $dest)) { Write-Log "Destination introuvable : $dest" 'ERROR'; return $false }
    $full = [IO.Path]::GetFullPath($dest)
    $prof = [IO.Path]::GetFullPath($ProfilePath).TrimEnd('\')
    if (($full.TrimEnd('\') + '\').StartsWith($prof + '\', [StringComparison]::OrdinalIgnoreCase)) {
        Write-Log 'La destination est dans le profil à sauvegarder : choisissez un autre disque.' 'ERROR'; return $false
    }
    $sources = @()
    if ($Mode -eq 'mirror') {
        $sources = @([pscustomobject]@{ Id = 'Profile'; Label = 'Dossier utilisateur (miroir)'; Path = $prof })
        $Folders = @()
    }
    foreach ($d in $Script:BakFolders) {
        if (@($Folders) -notcontains [string]$d.Id) { continue }
        $fp = Resolve-ProfileFolder $prof $Sid $d
        if (($full.TrimEnd('\') + '\').StartsWith($fp + '\', [StringComparison]::OrdinalIgnoreCase)) {
            Write-Log "La destination est dans le dossier « $($d.Label) » : choisissez un autre emplacement." 'ERROR'; return $false
        }
        $sources += [pscustomobject]@{ Id = [string]$d.Id; Label = [string]$d.Label; Path = $fp }
    }
    if ($sources.Count -eq 0 -and -not $Browsers) { Write-Log 'Rien à sauvegarder : cochez au moins un dossier.' 'ERROR'; return $false }
    if ($Time -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { $Time = '12:30' }
    if ($Frequency -ne 'weekly') { $Frequency = 'daily' }
    if ($Day -notin 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday') { $Day = 'Monday' }

    $vol = ''; $sub = ''
    if ($full -notmatch '^\\\\') {
        try {
            $v = Get-Volume -DriveLetter $full.Substring(0, 1) -ErrorAction Stop
            $vol = [string]$v.UniqueId
            $sub = $full.Substring(3).TrimEnd('\')
        } catch { Write-Log "Identifiant du volume indisponible : la lettre du disque devra rester la même." 'WARN' }
        if ($full.Substring(0, 2) -ieq $env:SystemDrive) {
            Write-Log 'Attention : la destination est sur le disque de Windows. Si ce disque tombe en panne, la sauvegarde est perdue avec lui.' 'WARN'
        }
    }
    $cfg = [ordered]@{
        Version = 1; Mode = $Mode; Computer = $env:COMPUTERNAME; User = (Split-Path $prof -Leaf); Profile = $prof; Sid = $Sid
        Sources = @($sources); Browsers = [bool]$Browsers
        DestRoot = $full; DestVolume = $vol; DestSub = $sub
        Frequency = $Frequency; Time = $Time; Day = $Day
        Saved = (Get-Date -Format 's')
    }
    try {
        New-Item -ItemType Directory -Path $Script:BakHome -Force -ErrorAction Stop | Out-Null
        $src = Get-BackupSourceFile
        if ($src -and (Test-Path -LiteralPath $src) -and ([IO.Path]::GetFullPath($src) -ine [IO.Path]::GetFullPath($Script:BakScript))) {
            Copy-Item -LiteralPath $src -Destination $Script:BakScript -Force -ErrorAction Stop
        }
        Set-Content -LiteralPath $Script:BakConfig -Value (ConvertTo-Json -InputObject $cfg -Depth 5) -Encoding UTF8 -ErrorAction Stop
    } catch { Write-Log "Enregistrement de la configuration impossible : $($_.Exception.Message)" 'ERROR'; return $false }
    Write-Log ("Sauvegarde configurée ({0}) : {1} -> {2}" -f $(if ($Mode -eq 'mirror') { 'miroir du dossier utilisateur' } else { 'dossiers choisis' }), (Split-Path $prof -Leaf), $full) 'OK'
    return $true
}

function Resolve-BackupDestination {
    # Rend le dossier racine de destination, ou '' si le disque n'est pas branché.
    param($Cfg)
    $root = [string]$Cfg.DestRoot
    if ($root -match '^\\\\') { if (Test-Path -LiteralPath $root) { return $root } else { return '' } }
    $vid = [string]$Cfg.DestVolume
    if ($vid) {
        try {
            $v = Get-Volume -ErrorAction Stop | Where-Object { $_.UniqueId -eq $vid -and $_.DriveLetter } | Select-Object -First 1
            if (-not $v) { return '' }
            $r = ('{0}:\' -f $v.DriveLetter)
            if ([string]$Cfg.DestSub) { $r = Join-Path $r ([string]$Cfg.DestSub) }
            return $r
        } catch {}
    }
    if ($root -and (Test-Path -LiteralPath $root)) { return $root }
    return ''
}

function Get-BackupFolder {
    param($Cfg, [string]$Root)
    return (Join-Path $Root (Join-Path $Script:BakRootName (Join-Path ([string]$Cfg.Computer) ([string]$Cfg.User))))
}

function Save-BackupState {
    param([hashtable]$State)
    try {
        New-Item -ItemType Directory -Path $Script:BakLogDir -Force -ErrorAction Stop | Out-Null
        Set-Content -LiteralPath $Script:BakState -Value (ConvertTo-Json -InputObject $State -Depth 4) -Encoding UTF8 -ErrorAction Stop
    } catch {}
}

# ---------------------------------------------------------------- Copie
function Copy-BackupTree {
    # Copie incrémentale d'un dossier. Rend @{ Files; Code } ; Code est celui de robocopy (8 et plus : des échecs).
    param([string]$Source, [string]$Target, [string]$RoboLog, [switch]$OnlyMissing)
    # /XX : les fichiers présents seulement dans la cible ne sont ni listés ni supprimés.
    $ra = @($Source.TrimEnd('\'), $Target.TrimEnd('\'), '/E', '/XJ', '/XX', '/R:1', '/W:1', '/MT:8', '/COPY:DAT', '/DCOPY:DAT', '/FFT',
        '/NP', '/NJH', '/NJS', '/NDL', '/NC', '/NS', '/FP', '/TEE', "/UNILOG+:$RoboLog",
        '/XF', 'desktop.ini', 'Thumbs.db', '*.tmp', '~$*', '/XD', '$RECYCLE.BIN', 'System Volume Information')
    if ($OnlyMissing) { $ra += @('/XC', '/XN', '/XO') }
    $n = 0
    # Avec ces options, robocopy écrit une ligne par fichier copié : tabulations puis chemin complet.
    & robocopy.exe @ra 2>$null | ForEach-Object {
        if ([string]$_ -match '^\t.*\t(?:[A-Za-z]:\\|\\\\)') {
            $n++
            if (($n % 500) -eq 0) { Write-Host ("  [..]  {0} fichiers copiés…" -f $n) -ForegroundColor DarkGray }
        }
    }
    return @{ Files = $n; Code = [int]$LASTEXITCODE }
}

function Copy-BrowserBookmarks {
    # Favoris de Chrome, Edge, Brave, Vivaldi, Opera et Firefox. Les mots de passe ne sont pas copiés.
    param([string]$ProfilePath, [string]$Target)
    $local = Join-Path $ProfilePath 'AppData\Local'
    $roam  = Join-Path $ProfilePath 'AppData\Roaming'
    $n = 0
    $chromium = @(
        @('Chrome', (Join-Path $local 'Google\Chrome\User Data')),
        @('Edge', (Join-Path $local 'Microsoft\Edge\User Data')),
        @('Brave', (Join-Path $local 'BraveSoftware\Brave-Browser\User Data')),
        @('Vivaldi', (Join-Path $local 'Vivaldi\User Data')),
        @('Opera', (Join-Path $roam 'Opera Software'))
    )
    foreach ($b in $chromium) {
        if (-not (Test-Path -LiteralPath $b[1])) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $b[1] -Filter 'Bookmarks' -File -Recurse -Depth 1 -ErrorAction SilentlyContinue)) {
            try {
                $pd = Join-Path (Join-Path $Target $b[0]) $f.Directory.Name
                New-Item -ItemType Directory -Path $pd -Force -ErrorAction Stop | Out-Null
                Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $pd 'Bookmarks') -Force -ErrorAction Stop
                $n++
            } catch { Write-Log "Favoris $($b[0]) : $($_.Exception.Message)" 'WARN' }
        }
    }
    $ff = Join-Path $roam 'Mozilla\Firefox\Profiles'
    if (Test-Path -LiteralPath $ff) {
        foreach ($d in @(Get-ChildItem -LiteralPath $ff -Directory -ErrorAction SilentlyContinue)) {
            $bb = Join-Path $d.FullName 'bookmarkbackups'
            if (-not (Test-Path -LiteralPath $bb)) { continue }
            try {
                $pd = Join-Path (Join-Path $Target 'Firefox') $d.Name
                New-Item -ItemType Directory -Path $pd -Force -ErrorAction Stop | Out-Null
                foreach ($f in @(Get-ChildItem -LiteralPath $bb -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 5)) {
                    Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $pd $f.Name) -Force -ErrorAction Stop
                }
                $n++
            } catch { Write-Log "Favoris Firefox : $($_.Exception.Message)" 'WARN' }
        }
    }
    return $n
}

# ---------------------------------------------------------------- Miroir
function Get-BakLongPath {
    # Préfixe \\?\ : chemins de plus de 260 caractères (fréquents dans un dossier utilisateur).
    param([string]$Path)
    if ($Path.StartsWith('\\?\')) { return $Path }
    if ($Path.StartsWith('\\')) { return '\\?\UNC\' + $Path.Substring(2) }
    return '\\?\' + $Path
}

function Get-MirrorSkipDirs {
    # Chemins complets exclus du miroir pour ce profil (OneDrive peut s'appeler « OneDrive - Entreprise »).
    param([string]$ProfilePath)
    $dirs = @()
    foreach ($n in $Script:BakMirrorSkipDirs) { $dirs += (Join-Path $ProfilePath $n) }
    try { foreach ($d in @(Get-ChildItem -LiteralPath $ProfilePath -Directory -Force -Filter 'OneDrive*' -ErrorAction Stop)) { $dirs += $d.FullName } } catch {}
    return $dirs
}

function Get-MirrorBytes {
    # Taille de ce que le miroir copiera (le profil sans les dossiers exclus ni les jonctions).
    param([string]$ProfilePath)
    $skip = @(Get-MirrorSkipDirs $ProfilePath | ForEach-Object { $_.TrimEnd('\').ToLowerInvariant() })
    $total = [long]0
    try {
        $di = New-Object IO.DirectoryInfo $ProfilePath
        foreach ($f in $di.GetFiles()) { if ($f.Name -notlike 'ntuser*' -and $f.Name -notlike 'UsrClass*') { $total += $f.Length } }
        foreach ($d in $di.GetDirectories()) {
            if ($d.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($skip -contains $d.FullName.TrimEnd('\').ToLowerInvariant()) { continue }
            $total += (Get-TreeBytes $d.FullName)
        }
    } catch {}
    return $total
}

function Get-MirrorExtras {
    # Ce qui est dans le miroir mais plus sur le PC. Rend @{ Items = @(@{ Rel; IsDir; Files }); ExtraFiles; Total; Error }.
    # Chemins assemblés avec [IO.Path]::Combine : la commande de jonction de PowerShell 5.1 refuse le préfixe \\?\.
    param([string]$Source, [string]$Target)
    $items = New-Object System.Collections.ArrayList
    $extraFiles = 0; $total = 0; $err = ''
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push('')
    while ($stack.Count -gt 0) {
        $rel = $stack.Pop()
        $td = Get-BakLongPath ($(if ($rel) { [IO.Path]::Combine($Target, $rel) } else { $Target }))
        $sd = Get-BakLongPath ($(if ($rel) { [IO.Path]::Combine($Source, $rel) } else { $Source }))
        try {
            foreach ($f in [IO.Directory]::GetFiles($td)) {
                $total++
                $name = [IO.Path]::GetFileName($f)
                if (-not [IO.File]::Exists([IO.Path]::Combine($sd, $name))) {
                    [void]$items.Add(@{ Rel = $(if ($rel) { [IO.Path]::Combine($rel, $name) } else { $name }); IsDir = $false; Files = 1 }); $extraFiles++
                }
            }
            foreach ($d in [IO.Directory]::GetDirectories($td)) {
                $name = [IO.Path]::GetFileName($d)
                $r2 = $(if ($rel) { [IO.Path]::Combine($rel, $name) } else { $name })
                if ([IO.Directory]::Exists([IO.Path]::Combine($sd, $name))) { $stack.Push($r2); continue }
                $n = 0
                try { $n = @([IO.Directory]::GetFiles($d, '*', [IO.SearchOption]::AllDirectories)).Count } catch { $n = 1 }
                $total += $n; $extraFiles += $n
                [void]$items.Add(@{ Rel = $r2; IsDir = $true; Files = $n })
            }
        } catch { $err = $_.Exception.Message; Write-Log ("Miroir : dossier illisible ({0})" -f $err) 'WARN' }
    }
    return @{ Items = @($items); ExtraFiles = $extraFiles; Total = $total; Error = $err }
}

function Clear-MirrorTrash {
    # Vide les passages de la corbeille du miroir plus vieux que $Script:BakTrashDays jours.
    param([string]$Trash)
    if (-not (Test-Path -LiteralPath $Trash)) { return }
    $limit = (Get-Date).AddDays(-$Script:BakTrashDays)
    foreach ($d in @(Get-ChildItem -LiteralPath $Trash -Directory -ErrorAction SilentlyContinue)) {
        $dt = $null
        if ($d.Name -notmatch '^(\d{4}-\d{2}-\d{2}_\d{6})(-\d+)?$') { continue }
        try { $dt = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd_HHmmss', [Globalization.CultureInfo]::InvariantCulture) } catch { continue }
        if ($dt -lt $limit) {
            try { Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction Stop; Write-Log ("Corbeille du miroir : passage du {0:dd/MM/yyyy} vidé (plus de {1} jours)." -f $dt, $Script:BakTrashDays) }
            catch { Write-Log ("Corbeille du miroir : {0} non vidé ({1})" -f $d.Name, $_.Exception.Message) 'WARN' }
        }
    }
}

function Invoke-MirrorCopy {
    # Miroir du dossier utilisateur. Rend @{ Files; Code; Moved; Suspect; ExtraFiles; Total }.
    param([string]$Source, [string]$Target, [string]$Trash, [string]$RoboLog, [switch]$AcceptDeletions)
    $res = @{ Files = 0; Code = 0; Moved = 0; Suspect = $false; ExtraFiles = 0; Total = 0 }
    $purge = $true
    if (Test-Path -LiteralPath $Target) {
        $ex = Get-MirrorExtras $Source $Target
        $res.ExtraFiles = $ex.ExtraFiles; $res.Total = $ex.Total
        # Liste incomplète : on ne sait pas ce que /MIR effacerait sans corbeille, donc ce passage ne retire rien.
        if ($ex.Error) { $purge = $false }
        if (-not $AcceptDeletions -and $ex.ExtraFiles -gt $Script:BakSuspectMin -and $ex.ExtraFiles -gt ($Script:BakSuspectRate * [math]::Max(1, $ex.Total))) {
            $res.Suspect = $true
            Write-Log ("Miroir suspendu : ce passage retirerait {0} fichier(s) sur {1} ({2:P0}). Si c'est voulu, confirmez depuis la Toolbox." -f $ex.ExtraFiles, $ex.Total, ($ex.ExtraFiles / [math]::Max(1, $ex.Total))) 'ERROR'
            return $res
        }
        if (@($ex.Items).Count -gt 0) {
            # Un dossier de corbeille par passage, jamais réutilisé (deux passages dans la même seconde : suffixe -2, -3…)
            $stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
            $bin = Join-Path $Trash $stamp; $k = 2
            while (Test-Path -LiteralPath $bin) { $bin = Join-Path $Trash ("{0}-{1}" -f $stamp, $k); $k++ }
            foreach ($it in @($ex.Items)) {
                try {
                    $from = Get-BakLongPath ([IO.Path]::Combine($Target, [string]$it.Rel))
                    $to = Get-BakLongPath ([IO.Path]::Combine($bin, [string]$it.Rel))
                    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($to))
                    if ($it.IsDir) { [IO.Directory]::Move($from, $to) } else { [IO.File]::Move($from, $to) }
                    $res.Moved += [int]$it.Files
                } catch { $purge = $false; Write-Log ("Miroir : « {0} » non déplacé dans la corbeille ({1})" -f $it.Rel, $_.Exception.Message) 'WARN' }
            }
            Write-Log ("Miroir : {0} fichier(s) supprimé(s) du PC depuis le dernier passage, gardés {1} jours dans {2}." -f $res.Moved, $Script:BakTrashDays, $bin) 'OK'
        }
    }
    $ra = @($Source.TrimEnd('\'), $Target.TrimEnd('\'))
    # Si un élément n'a pas pu aller dans la corbeille, ce passage ne supprime rien (copie seule).
    if ($purge) { $ra += '/MIR' } else { $ra += '/E'; Write-Log 'Miroir : ce passage copie sans rien retirer ; le ménage se fera au prochain.' 'WARN' }
    $ra += @('/XJ', '/R:1', '/W:1', '/MT:8', '/COPY:DAT', '/DCOPY:DAT', '/FFT', '/XA:O',
        '/NP', '/NJH', '/NJS', '/NDL', '/NC', '/NS', '/FP', '/TEE', "/UNILOG+:$RoboLog")
    $ra += '/XF'; $ra += $Script:BakMirrorSkipFiles
    $ra += '/XD'; $ra += @(Get-MirrorSkipDirs $Source)
    $n = 0
    & robocopy.exe @ra 2>$null | ForEach-Object {
        if ([string]$_ -match '^\t.*\t(?:[A-Za-z]:\\|\\\\)') {
            $n++
            if (($n % 500) -eq 0) { Write-Host ("  [..]  {0} fichiers copiés…" -f $n) -ForegroundColor DarkGray }
        }
    }
    $res.Files = $n; $res.Code = [int]$LASTEXITCODE
    Clear-MirrorTrash $Trash
    return $res
}

function Invoke-FileBackup {
    # Lance la sauvegarde configurée. Rend 0 (tout copié), 1 (quelques fichiers ignorés), 2 (non configurée),
    # 3 (disque absent), 4 (place insuffisante), 5 (échec) ou 6 (miroir suspendu : trop de fichiers à retirer).
    # -AcceptDeletions : confirme un passage de miroir suspendu (choix fait dans la Toolbox).
    param([switch]$AcceptDeletions)
    $cfg = Get-BackupConfig
    if (-not $cfg) { Write-Log 'Aucune sauvegarde configurée.' 'WARN'; return 2 }
    $started = Get-Date
    $state = @{ Date = (Get-Date -Format 's'); User = [string]$cfg.User; Result = 'echec'; Files = 0; Skipped = $false; Folder = ''; Message = '' }
    $root = Resolve-BackupDestination $cfg
    if (-not $root) {
        $state.Result = 'absent'; $state.Message = "Disque de sauvegarde absent ($($cfg.DestRoot))."
        # On garde la date de la dernière sauvegarde réussie pour l'afficher.
        try { $old = Get-Content -LiteralPath $Script:BakState -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json; if ($old.LastSuccess) { $state.LastSuccess = [string]$old.LastSuccess } } catch {}
        Save-BackupState $state
        Write-Log "$($state.Message) Branchez-le : la sauvegarde reprendra à la prochaine exécution." 'WARN'
        return 3
    }
    $dest = Get-BackupFolder $cfg $root
    $first = -not (Test-Path -LiteralPath $dest)
    $state.Folder = $dest
    Write-Log ("Sauvegarde de {0} vers {1}" -f $cfg.User, $dest)

    $sources = @(@($cfg.Sources) | Where-Object { $_ -and $_.Path -and (Test-Path -LiteralPath ([string]$_.Path)) })
    foreach ($s in @(@($cfg.Sources) | Where-Object { $_ -and $_.Path -and -not (Test-Path -LiteralPath ([string]$_.Path)) })) {
        Write-Log "Dossier absent, ignoré : $($s.Label) ($($s.Path))" 'WARN'
    }

    if ($first -and $root -notmatch '^\\\\') {
        Write-Log 'Première sauvegarde : calcul de la place nécessaire…'
        $need = [long]0
        foreach ($s in $sources) {
            if ([string]$cfg.Mode -eq 'mirror') { $need += (Get-MirrorBytes ([string]$s.Path)) } else { $need += (Get-TreeBytes ([string]$s.Path)) }
        }
        $free = [long]0
        try { $free = (New-Object IO.DriveInfo ($root.Substring(0, 1))).AvailableFreeSpace } catch {}
        Write-Log ("À copier : {0}. Place libre sur la destination : {1}." -f (Format-BackupSize $need), (Format-BackupSize $free))
        if ($free -gt 0 -and $need -gt ($free - 1GB)) {
            $state.Result = 'place'; $state.Message = ("Place insuffisante : {0} à copier, {1} libres." -f (Format-BackupSize $need), (Format-BackupSize $free))
            Save-BackupState $state
            Write-Log $state.Message 'ERROR'
            return 4
        }
    }

    try {
        New-Item -ItemType Directory -Path $dest -Force -ErrorAction Stop | Out-Null
        New-Item -ItemType Directory -Path $Script:BakLogDir -Force -ErrorAction Stop | Out-Null
    } catch {
        $state.Message = "Écriture impossible sur la destination : $($_.Exception.Message)"
        Save-BackupState $state; Write-Log $state.Message 'ERROR'; return 5
    }
    $robolog = Join-Path $Script:BakLogDir ("Fichiers_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

    $total = 0; $skipped = $false; $fatal = $false; $done = @()
    $mirror = ([string]$cfg.Mode -eq 'mirror')
    foreach ($s in $sources) {
        Write-Log ("Copie de « {0} »…" -f $s.Label)
        if ($mirror) {
            $r = Invoke-MirrorCopy ([string]$s.Path) (Join-Path $dest $Script:BakMirrorDir) (Join-Path $dest $Script:BakTrashDir) $robolog -AcceptDeletions:$AcceptDeletions
            if ($r.Suspect) {
                $state.Result = 'suspect'
                $state.Message = ("Miroir suspendu : {0} fichier(s) sur {1} auraient quitté la sauvegarde. Vérifiez le PC ; si c'est voulu, cliquez sur « Confirmer et mettre le miroir à jour »." -f $r.ExtraFiles, $r.Total)
                try { $old = Get-Content -LiteralPath $Script:BakState -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json; if ($old.LastSuccess) { $state.LastSuccess = [string]$old.LastSuccess } } catch {}
                Save-BackupState $state
                Set-BackupResult @{ Ok = @(); Bad = @('miroir suspendu'); Reboot = $false }
                return 6
            }
        } else {
            $r = Copy-BackupTree ([string]$s.Path) (Join-Path $dest ([string]$s.Label)) $robolog
        }
        $total += [int]$r.Files
        if ($r.Code -ge 16) { $fatal = $true; Write-Log ("{0} : copie interrompue (code {1})." -f $s.Label, $r.Code) 'ERROR' }
        elseif ($r.Code -band 8) { $skipped = $true; $done += [string]$s.Label; Write-Log ("{0} : {1} fichier(s) copié(s), certains n'ont pas pu l'être (ouverts ou protégés)." -f $s.Label, $r.Files) 'WARN' }
        else { $done += [string]$s.Label; Write-Log ("{0} : {1} fichier(s) nouveau(x) ou modifié(s)." -f $s.Label, $r.Files) 'OK' }
    }
    if ($cfg.Browsers) {
        $nb = Copy-BrowserBookmarks ([string]$cfg.Profile) (Join-Path $dest 'Navigateurs')
        if ($nb -gt 0) { $done += 'favoris des navigateurs'; Write-Log ("Favoris des navigateurs : {0} profil(s) copié(s)." -f $nb) 'OK' }
    }

    # Ménage : on garde les 20 derniers journaux de fichiers.
    try {
        Get-ChildItem -LiteralPath $Script:BakLogDir -Filter 'Fichiers_*.log' -File -ErrorAction Stop | Sort-Object LastWriteTime -Descending |
            Select-Object -Skip 20 | Remove-Item -Force -ErrorAction SilentlyContinue
    } catch {}

    $secs = [int]((Get-Date) - $started).TotalSeconds
    $state.Files = $total; $state.Skipped = $skipped; $state.Seconds = $secs; $state.Done = @($done)
    if ($fatal) {
        $state.Result = 'echec'; $state.Message = 'La copie a été interrompue. Détails dans le journal.'
        try { $old = Get-Content -LiteralPath $Script:BakState -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json; if ($old.LastSuccess) { $state.LastSuccess = [string]$old.LastSuccess } } catch {}
        Save-BackupState $state
        Write-Log ("Sauvegarde incomplète. Journal des fichiers : {0}" -f $robolog) 'ERROR'
        Set-BackupResult @{ Ok = @($(if ($Script:BakAutoOk) { 'auto' })); Bad = @('sauvegarde'); Reboot = $false }
        return 5
    }
    $state.Result = $(if ($skipped) { 'partiel' } else { 'ok' })
    $state.LastSuccess = [string]$state.Date
    $state.Message = $(if ($skipped) { "Quelques fichiers ouverts ou protégés n'ont pas été copiés ; ils le seront à la prochaine sauvegarde." } else { '' })
    Save-BackupState $state
    try {
        $note = @("Sauvegarde BJMPC du {0}" -f (Get-Date -Format 'dd/MM/yyyy HH:mm'), "Ordinateur : $($cfg.Computer)", "Utilisateur : $($cfg.User)",
            ("Contenu : " + ($done -join ', ')), '', 'Pour récupérer un fichier : ouvrez le dossier correspondant et copiez-le où vous voulez.')
        if ($mirror) { $note += @('', ("Miroir : copie exacte du dossier utilisateur. Un fichier supprimé du PC est gardé {0} jours dans « {1} »." -f $Script:BakTrashDays, $Script:BakTrashDir)) }
        Set-Content -LiteralPath (Join-Path $dest 'LISEZMOI-Sauvegarde.txt') -Value $note -Encoding UTF8 -ErrorAction Stop
    } catch {}
    Write-Log ("Sauvegarde terminée en {0} s : {1} fichier(s) copié(s) dans {2}" -f $secs, $total, $dest) 'OK'
    if ($skipped) { Write-Log ("Fichiers non copiés : voir {0}" -f $robolog) 'WARN' }
    # 'auto' : la sauvegarde automatique vient d'être programmée dans la même action (pour le résumé client).
    $okList = @($done); if ($Script:BakAutoOk) { $okList += 'auto' }
    Set-BackupResult @{ Ok = $okList; Bad = @(); Reboot = $false }
    if ($skipped) { return 1 }
    return 0
}

function Restore-FileBackup {
    # Recopie vers le PC les fichiers présents dans la sauvegarde mais absents du PC. N'écrase jamais un fichier existant.
    $cfg = Get-BackupConfig
    if (-not $cfg) { Write-Log 'Aucune sauvegarde configurée.' 'WARN'; return }
    $root = Resolve-BackupDestination $cfg
    if (-not $root) { Write-Log "Disque de sauvegarde absent ($($cfg.DestRoot))." 'ERROR'; return }
    $dest = Get-BackupFolder $cfg $root
    if (-not (Test-Path -LiteralPath $dest)) { Write-Log "Aucune sauvegarde trouvée dans $dest" 'ERROR'; return }
    try { New-Item -ItemType Directory -Path $Script:BakLogDir -Force -ErrorAction Stop | Out-Null } catch {}
    $robolog = Join-Path $Script:BakLogDir ("Restauration_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $total = 0; $done = @()
    foreach ($s in @($cfg.Sources)) {
        $from = $(if ([string]$cfg.Mode -eq 'mirror') { Join-Path $dest $Script:BakMirrorDir } else { Join-Path $dest ([string]$s.Label) })
        if (-not (Test-Path -LiteralPath $from)) { continue }
        Write-Log ("Restauration de « {0} »…" -f $s.Label)
        $r = Copy-BackupTree $from ([string]$s.Path) $robolog -OnlyMissing
        $total += [int]$r.Files
        if ($r.Code -ge 8) { Write-Log ("{0} : certains fichiers n'ont pas pu être restaurés (code {1})." -f $s.Label, $r.Code) 'WARN' }
        else { $done += [string]$s.Label; Write-Log ("{0} : {1} fichier(s) remis en place." -f $s.Label, $r.Files) 'OK' }
    }
    Write-Log ("Restauration terminée : {0} fichier(s) manquant(s) remis en place. Aucun fichier existant n'a été remplacé." -f $total) 'OK'
    Set-BackupResult @{ Ok = @($done); Bad = @(); Reboot = $false }
}

# ---------------------------------------------------------------- Tâche planifiée
function Register-BackupTask {
    $cfg = Get-BackupConfig
    if (-not $cfg) { Write-Log 'Configurez d''abord la sauvegarde.' 'ERROR'; return }
    if (-not (Test-Path -LiteralPath $Script:BakScript)) { Write-Log "Script de sauvegarde introuvable : $Script:BakScript" 'ERROR'; return }
    try {
        $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arg = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Run' -f $Script:BakScript
        $action = New-ScheduledTaskAction -Execute $exe -Argument $arg
        $at = [datetime]::ParseExact([string]$cfg.Time, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture)
        if ([string]$cfg.Frequency -eq 'weekly') { $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek ([string]$cfg.Day) -At $at }
        else { $trigger = New-ScheduledTaskTrigger -Daily -At $at }
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 8)
        if ([string]$cfg.DestRoot -match '^\\\\') {
            # Partage réseau : le compte Système n'y a pas accès, la tâche tourne dans la session de l'utilisateur.
            $account = (New-Object Security.Principal.SecurityIdentifier([string]$cfg.Sid)).Translate([Security.Principal.NTAccount]).Value
            $principal = New-ScheduledTaskPrincipal -UserId $account -LogonType Interactive -RunLevel Limited
            $who = "session de $account (partage réseau)"
        } else {
            $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
            $who = 'compte Système, même session fermée'
        }
        Register-ScheduledTask -TaskName $Script:BakTaskName -TaskPath $Script:BakTaskPath -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
            -Description 'Sauvegarde automatique des fichiers personnels (BJMPC Informatique).' -Force -ErrorAction Stop | Out-Null
        $when = if ([string]$cfg.Frequency -eq 'weekly') { "chaque semaine ($($cfg.Day)) à $($cfg.Time)" } else { "chaque jour à $($cfg.Time)" }
        Write-Log "Sauvegarde automatique activée : $when ($who). Si le PC est éteint à cette heure, elle se lance au démarrage suivant." 'OK'
        $Script:BakAutoOk = $true
        Set-BackupResult @{ Ok = @('auto'); Bad = @(); Reboot = $false }
    } catch { Write-Log "Création de la tâche planifiée impossible : $($_.Exception.Message)" 'ERROR' }
}

function Unregister-BackupTask {
    $t = Get-ScheduledTask -TaskName $Script:BakTaskName -TaskPath $Script:BakTaskPath -ErrorAction SilentlyContinue
    if (-not $t) { Write-Log 'La sauvegarde automatique n''était pas activée.'; return }
    try {
        Unregister-ScheduledTask -TaskName $Script:BakTaskName -TaskPath $Script:BakTaskPath -Confirm:$false -ErrorAction Stop
        Write-Log 'Sauvegarde automatique désactivée. Les fichiers déjà sauvegardés sont conservés.' 'OK'
    } catch { Write-Log "Suppression de la tâche impossible : $($_.Exception.Message)" 'ERROR' }
}

# ---------------------------------------------------------------- État (pour l'interface)
function Get-BackupStatus {
    $cfg = Get-BackupConfig
    $st = $null
    try { if (Test-Path -LiteralPath $Script:BakState) { $st = Get-Content -LiteralPath $Script:BakState -Raw -Encoding UTF8 | ConvertFrom-Json } } catch {}
    $auto = $false; $next = $null
    try {
        $t = Get-ScheduledTask -TaskName $Script:BakTaskName -TaskPath $Script:BakTaskPath -ErrorAction Stop
        $auto = ([string]$t.State -ne 'Disabled')
        $next = (Get-ScheduledTaskInfo -TaskName $Script:BakTaskName -TaskPath $Script:BakTaskPath -ErrorAction Stop).NextRunTime
    } catch {}
    $root = ''; $folder = ''
    if ($cfg) { $root = Resolve-BackupDestination $cfg; if ($root) { $folder = Get-BackupFolder $cfg $root } }
    $res = @{
        Configured = [bool]$cfg; Config = $cfg; State = $st
        Auto = $auto; NextRun = $next
        DestPresent = [bool]$root; Folder = $folder; HasBackup = [bool]($folder -and (Test-Path -LiteralPath $folder))
        Profiles = @(Get-BackupProfiles); Drives = @(Get-BackupDrives)
    }
    Set-BackupResult $res
}

# ---------------------------------------------------------------- Lancement sans interface (tâche planifiée)
if ($Run) {
    try { New-Item -ItemType Directory -Path $Script:BakLogDir -Force -ErrorAction Stop | Out-Null } catch {}
    $Script:LogFile = Join-Path $Script:BakLogDir ("Sauvegarde_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $code = 5
    try { $code = [int](@(Invoke-FileBackup) | Select-Object -Last 1) } catch { Write-Log $_.Exception.Message 'ERROR' }
    try {
        Get-ChildItem -LiteralPath $Script:BakLogDir -Filter 'Sauvegarde_*.log' -File -ErrorAction Stop | Sort-Object LastWriteTime -Descending |
            Select-Object -Skip 30 | Remove-Item -Force -ErrorAction SilentlyContinue
    } catch {}
    exit $code
}
