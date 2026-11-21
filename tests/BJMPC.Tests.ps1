# Tests automatiques de BJMPC Toolbox (Pester 5, Windows PowerShell 5.1).
# Chaque scénario s'exécute dans un espace PowerShell neuf, avec le code du moteur tel que la Toolbox le charge.
# Aucun test ne modifie le système : seuls des fichiers d'essai sont créés dans le dossier temporaire, puis effacés.

BeforeAll {
    $Root = Split-Path -Parent $PSScriptRoot
    $tb = [IO.File]::ReadAllText((Join-Path $Root 'BJMPC-Toolbox.ps1'))
    $m = [regex]::Match($tb, '(?s)function Get-EngineCode \{.*?\r?\n\}\r?\n')
    . ([scriptblock]::Create($m.Value))
    $E = @{}
    $E.opt = (Get-EngineCode (Join-Path $Root 'BJMPC-Optimisation-Win11.ps1')) + "`r`n" + (Get-EngineCode (Join-Path $Root 'BJMPC-Reglages-Win11.ps1'))
    $E.maint = Get-EngineCode (Join-Path $Root 'BJMPC-Maintenance-Win11.ps1')
    $E.tools = Get-EngineCode (Join-Path $Root 'BJMPC-Outils-Win11.ps1')
    $E.bak = Get-EngineCode (Join-Path $Root 'BJMPC-Sauvegarde-Win11.ps1')
    $E.evt = $E.maint + "`r`n" + $E.tools + "`r`n" + (Get-EngineCode (Join-Path $Root 'BJMPC-Evenements-Win11.ps1'))
    $Script:Engines = $E

    function Invoke-Engine {
        # Exécute $Code après le code du moteur ; rend @{ Out; Errors; Result }.
        param([string]$Engine, [string]$Code)
        $ps = [powershell]::Create()
        try {
            [void]$ps.AddScript('$Sync = [hashtable]::Synchronized(@{}); function Write-Host { }' + "`r`n" + $Script:Engines[$Engine] + "`r`n" + $Code + "`r`n" + ',$Sync.Result')
            $out = @($ps.Invoke())
            return @{ Out = $out; Errors = @($ps.Streams.Error | ForEach-Object { $_.ToString() }); Result = $(if ($out.Count) { $out[-1] } else { $null }) }
        } finally { $ps.Dispose() }
    }
}

Describe 'Fichiers' {
    It '<_> : syntaxe sans erreur, encodage UTF-8 avec BOM et fins de ligne CRLF' -ForEach @(
        'BJMPC-Toolbox.ps1', 'BJMPC-Optimisation-Win11.ps1', 'BJMPC-Reglages-Win11.ps1', 'BJMPC-Maintenance-Win11.ps1',
        'BJMPC-Outils-Win11.ps1', 'BJMPC-Sauvegarde-Win11.ps1', 'BJMPC-Evenements-Win11.ps1') {
        $p = Join-Path (Split-Path -Parent $PSScriptRoot) $_
        $t = $null; $e = $null
        [void][Management.Automation.Language.Parser]::ParseFile($p, [ref]$t, [ref]$e)
        @($e).Count | Should -Be 0
        $b = [IO.File]::ReadAllBytes($p)
        ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) | Should -BeTrue
        $txt = [Text.Encoding]::UTF8.GetString($b)
        ([regex]::Matches($txt, "(?<!`r)`n")).Count | Should -Be 0
    }
}

Describe 'Moteurs' {
    It 'Le moteur <_> se charge sans erreur' -ForEach @('opt', 'maint', 'tools', 'bak', 'evt') {
        $r = Invoke-Engine $_ "'CHARGE'"
        $r.Errors | Should -BeNullOrEmpty
        $r.Out | Should -Contain 'CHARGE'
    }
}

Describe 'Pilotes : règles de décision' {
    It '<Name> -> <Expect>' -ForEach @(
        @{ Name = 'pilote constructeur ancien, Windows Update plus récent'; Inf = 'oem12.inf'; Inbox = $false; Cls = 'MEDIA'; Ven = '10EC'; D = '2021-01-01'; V = '6.0.1'; P = 0; CD = '2024-03-01'; CV = '6.0.9'; Expect = 'install' }
        @{ Name = 'pilote de Windows plus récent que le constructeur'; Inf = 'storahci.inf'; Inbox = $true; Cls = 'SCSIAdapter'; Ven = '8086'; D = '2025-06-01'; V = '10.0.1'; P = 0; CD = '2023-01-01'; CV = '19.5'; Expect = 'keep-inbox' }
        @{ Name = 'pilote en place plus récent'; Inf = 'oem3.inf'; Inbox = $false; Cls = 'Net'; Ven = '10EC'; D = '2025-09-01'; V = '2.0'; P = 0; CD = '2024-01-01'; CV = '1.9'; Expect = 'keep-newer' }
        @{ Name = 'carte graphique'; Inf = 'oem40.inf'; Inbox = $false; Cls = 'Display'; Ven = '10DE'; D = '2024-01-01'; V = '32.0'; P = 0; CD = '2025-02-01'; CV = '33.0'; Expect = 'gpu' }
        @{ Name = 'SMBus Intel sans pilote'; Inf = ''; Inbox = $false; Cls = 'Autres'; Ven = '8086'; D = ''; V = ''; P = 28; CD = ''; CV = ''; Expect = 'chipset' }
        @{ Name = 'appareil inconnu sans pilote'; Inf = ''; Inbox = $false; Cls = 'Autres'; Ven = '1B21'; D = ''; V = ''; P = 28; CD = ''; CV = ''; Expect = 'missing' }
    ) {
        $dev = "[pscustomobject]@{ Class = '$Cls'; Ven = '$Ven'; Inf = '$Inf'; Inbox = `$$Inbox; Problem = $P; Version = '$V'; Date = $(if ($D) { "[datetime]'$D'" } else { '$null' }) }"
        $cand = $(if ($CD) { "[pscustomobject]@{ Date = [datetime]'$CD'; Version = '$CV' }" } else { '$null' })
        $r = Invoke-Engine 'tools' ("(Get-DriverDecision ($dev) ($cand)).Code")
        $r.Out | Should -Contain $Expect
    }
}

Describe 'Observateur d''événements : classement' {
    It '<P> <Id> -> <Expect>' -ForEach @(
        @{ P = 'Microsoft-Windows-Windows Defender'; Id = 1116; L = 3; Expect = 'def_threat' }
        @{ P = 'Microsoft-Windows-CodeIntegrity'; Id = 3077; L = 2; Expect = 'ci_block' }
        @{ P = 'disk'; Id = 157; L = 3; Expect = 'disk_removed' }
        @{ P = 'Ntfs'; Id = 55; L = 2; Expect = 'ntfs' }
        @{ P = 'Microsoft-Windows-Kernel-Power'; Id = 41; L = 1; Expect = 'power_loss' }
    ) {
        $code = "`$g = @{ Key = '$P|$Id|'; Provider = '$P'; Id = $Id; Sub = ''; Log = 'x'; Count = 1; Last = (Get-Date); Level = $L; Sample = 's'; Path = '' }; (ConvertTo-EventFinding `$g @{}).Rule"
        (Invoke-Engine 'evt' $code).Out | Should -Contain $Expect
    }
}

Describe 'Doublons de photos' {
    It 'Regroupe seulement les contenus identiques ; même image PNG/BMP en option pixels' {
        $code = @'
$t = Join-Path $env:TEMP ('BJMPC-Test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $t -Force | Out-Null
try {
    Add-Type -AssemblyName System.Drawing
    $bmp = New-Object Drawing.Bitmap 40, 30
    for ($x = 0; $x -lt 40; $x++) { for ($y = 0; $y -lt 30; $y++) { $bmp.SetPixel($x, $y, [Drawing.Color]::FromArgb(255, ($x * 6) % 256, ($y * 8) % 256, 90)) } }
    $bmp.Save((Join-Path $t 'a.png'), [Drawing.Imaging.ImageFormat]::Png)
    Copy-Item (Join-Path $t 'a.png') (Join-Path $t 'b.png')
    $bmp.Save((Join-Path $t 'c.bmp'), [Drawing.Imaging.ImageFormat]::Bmp)
    $bmp.SetPixel(5, 5, [Drawing.Color]::Black); $bmp.Save((Join-Path $t 'd.bmp'), [Drawing.Imaging.ImageFormat]::Bmp)
    $bmp.SetPixel(6, 6, [Drawing.Color]::Black); $bmp.Save((Join-Path $t 'e.bmp'), [Drawing.Imaging.ImageFormat]::Bmp)
    $bmp.Dispose()
    (Get-Item (Join-Path $t 'e.bmp')).LastWriteTime = (Get-Item (Join-Path $t 'd.bmp')).LastWriteTime
    Find-DuplicatePhotos -Known @() -Folders @($t) -Pixels $false
    'BIN=' + (@($Sync.Result.Groups | ForEach-Object { '{0}:{1}' -f $_.Kind, @($_.Files).Count }) -join ',')
    Find-DuplicatePhotos -Known @() -Folders @($t) -Pixels $true
    'PIX=' + (@($Sync.Result.Groups | ForEach-Object { '{0}:{1}' -f $_.Kind, @($_.Files).Count }) -join ',')
} finally { Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue }
'@
        $r = Invoke-Engine 'tools' $code
        $r.Out | Should -Contain 'BIN=bin:2'
        $r.Out | Should -Contain 'PIX=pix:3'
    }
}

Describe 'Sauvegarde miroir' {
    It 'Copie, exclut AppData / OneDrive / NTUSER, met les fichiers retirés en corbeille, suspend une suppression massive' {
        $code = @'
# Dossier temporaire en chemin long : $env:TEMP peut être un nom court 8.3 (RUNNER~1), que robocopy ne rapproche pas des exclusions.
$t = Join-Path (Join-Path $env:LOCALAPPDATA 'Temp') ('BJMPC-Test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
try {
    $s = Join-Path $t 'src'; $d = Join-Path $t 'dst\Miroir'; $tr = Join-Path $t 'dst\Miroir-Corbeille'
    New-Item -ItemType Directory -Force -Path (Join-Path $s 'Docs'), (Join-Path $s 'AppData\Local'), (Join-Path $s 'OneDrive - Test'), $d | Out-Null
    Set-Content -LiteralPath (Join-Path $s 'Docs\a.txt') -Value 'a'
    Set-Content -LiteralPath (Join-Path $s 'AppData\Local\x.txt') -Value 'x'
    Set-Content -LiteralPath (Join-Path $s 'OneDrive - Test\o.txt') -Value 'o'
    Set-Content -LiteralPath (Join-Path $s 'NTUSER.DAT') -Value 'n'
    Set-Content -LiteralPath (Join-Path $d 'ancien.txt') -Value 'old'
    $r = Invoke-MirrorCopy $s $d $tr (Join-Path $t 'robo.log')
    'CODE=' + [int]($r.Code -lt 8)
    'COPIE=' + (Test-Path -LiteralPath (Join-Path $d 'Docs\a.txt'))
    'EXCLU=' + (-not (Test-Path -LiteralPath (Join-Path $d 'AppData')) -and -not (Test-Path -LiteralPath (Join-Path $d 'OneDrive - Test')) -and -not (Test-Path -LiteralPath (Join-Path $d 'NTUSER.DAT')))
    'CORBEILLE=' + ([bool](Get-ChildItem -LiteralPath $tr -Recurse -Filter 'ancien.txt') -and -not (Test-Path -LiteralPath (Join-Path $d 'ancien.txt')))
    $Script:BakSuspectMin = 0
    Remove-Item -LiteralPath (Join-Path $s 'Docs') -Recurse -Force
    $r2 = Invoke-MirrorCopy $s $d $tr (Join-Path $t 'robo.log')
    'SUSPENDU=' + [bool]$r2.Suspect + ';' + (Test-Path -LiteralPath (Join-Path $d 'Docs\a.txt'))
} finally { Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue }
'@
        $r = Invoke-Engine 'bak' $code
        foreach ($k in 'CODE=1', 'COPIE=True', 'EXCLU=True', 'CORBEILLE=True', 'SUSPENDU=True;True') { $r.Out | Should -Contain $k }
    }
}

Describe 'Retour aux valeurs de Windows 11 : catalogue' {
    It 'Aucun doublon, catégories connues' {
        $code = @'
$d = @($Script:Win11DefRegistry | Group-Object { ([string]$_[1] + '|' + [string]$_[2]).ToLower() } | Where-Object Count -gt 1).Count
$s = @($Script:Win11DefServices | Group-Object { ([string]$_[1]).ToLower() } | Where-Object Count -gt 1).Count
$c = @($Script:Win11DefRegistry | Where-Object { -not $Script:Win11DefCats.Contains([string]$_[0]) }).Count
"DOUBLONS=$d;$s;CATS=$c"
'@
        (Invoke-Engine 'tools' $code).Out | Should -Contain 'DOUBLONS=0;0;CATS=0'
    }
}

Describe 'Catalogue de réglages (Confidentialité, Interface, Mises à jour)' {
    It 'Identifiants uniques, valeurs de registre bien formées et sans doublon, télémétrie complète' {
        $r = Invoke-Engine 'opt' @'
$ids = @($Script:TweakCatalog | ForEach-Object { $_.Id })
$bad = @(); $seen = @{}; $dup = @()
foreach ($t in $Script:TweakCatalog) {
    foreach ($g in @($t.Reg)) {
        if (@($g).Count -ne 4 -or [string]$g[0] -notmatch '^HK(LM|CU):\\' -or @('DWord', 'String', 'QWord', 'Binary', 'ExpandString', 'MultiString') -notcontains [string]$g[3]) { $bad += ($t.Id + ' ' + ($g -join '|')) ; continue }
        $k = ([string]$g[0] + '|' + [string]$g[1]).ToLowerInvariant()
        if ($seen.ContainsKey($k)) { $dup += $k } else { $seen[$k] = $t.Id }
    }
}
$need = @('tel_win', 'tel_wer', 'tel_netcomm', 'tel_samples', 'tel_cdp', 'tel_findmy', 'tel_ncsi', 'ai_recall', 'ai_clicktodo')
$Sync.Result = @{ N = $ids.Count; U = @($ids | Select-Object -Unique).Count; Bad = $bad; Dup = $dup; Missing = @($need | Where-Object { $ids -notcontains $_ })
    Def = @($Script:TweakCatalog | Where-Object { $_.Risk -eq 'warn' -and $_.Default } | ForEach-Object { $_.Id }) }
'@
        $r.Errors | Should -BeNullOrEmpty
        $r.Result.U | Should -Be $r.Result.N
        $r.Result.Bad | Should -BeNullOrEmpty
        $r.Result.Dup | Should -BeNullOrEmpty
        $r.Result.Missing | Should -BeNullOrEmpty
        $r.Result.Def | Should -BeNullOrEmpty -Because 'un réglage à risque ne doit jamais être coché d''office'
    }
}

Describe 'DNS chiffrés' {
    It 'Adresses IP valides, modèles DoH en https, Mullvad et Quad9 retirés, DNS4ALL présent' {
        $r = Invoke-Engine 'opt' @'
$bad = @()
foreach ($k in @($Script:DnsPresets.Keys)) {
    $p = $Script:DnsPresets[$k]
    if (@($p.Servers).Count -lt 2) { $bad += "$k : moins de 2 adresses" }
    foreach ($sv in @($p.Servers)) {
        $ip = $null
        if (-not [Net.IPAddress]::TryParse([string]$sv[0], [ref]$ip)) { $bad += "$k : IP $($sv[0])" }
        if ([string]$sv[1] -notmatch '^https://[a-z0-9.-]+/dns-query$') { $bad += "$k : modèle $($sv[1])" }
    }
}
$all = ($Script:DnsPresets.Values | ForEach-Object { $_.Servers | ForEach-Object { $_ -join ' ' } }) -join ' '
$Sync.Result = @{ Bad = $bad; Keys = @($Script:DnsPresets.Keys); Old = ($all -match 'mullvad|quad9|9\.9\.9\.9|194\.242\.2\.')
    Fn = @('Set-DnsPreset', 'Restore-DnsOrigin', 'Select-DnsPreset' | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) }) }
'@
        $r.Errors | Should -BeNullOrEmpty
        $r.Result.Bad | Should -BeNullOrEmpty
        $r.Result.Old | Should -BeFalse
        $r.Result.Fn | Should -BeNullOrEmpty
        $r.Result.Keys | Should -Contain 'dns4all'
        $r.Result.Keys | Should -Contain 'fdn'
    }
}

Describe 'Pilote NVMe natif : magasin de fonctionnalités' {
    It 'Transformation des identifiants identique à Windows (48433719 -> 1853569164) et réversible' {
        $r = Invoke-Engine 'opt' @'
$ok = Initialize-FeatureStoreApi
$Sync.Result = @{ Ok = $ok; A = [BJ.FeatureStore]::Obfuscate([uint32]48433719); B = [BJ.FeatureStore]::Deobfuscate([BJ.FeatureStore]::Obfuscate([uint32]60786016)); Keys = @(Get-NvmeFeatureKeys) }
'@
        $r.Errors | Should -BeNullOrEmpty
        $r.Result.Ok | Should -BeTrue
        $r.Result.A | Should -Be 1853569164
        $r.Result.B | Should -Be 60786016
        @($r.Result.Keys).Count | Should -Be 2
        @($r.Result.Keys)[0] | Should -Match 'FeatureManagement\\Overrides\\8\\3244671118$'
    }
}

Describe 'Pare-feu : télémétrie' {
    It 'Analyse, blocage réel puis retrait complet des règles du groupe BJMPC' {
        $r = Invoke-Engine 'opt' @'
$Script:LogFile = Join-Path $env:TEMP 'bjmpc-test-fw.log'
$Script:StateFile = Join-Path $env:TEMP ('bjmpc-test-orig-' + [guid]::NewGuid().ToString('N') + '.json')
Get-TelemetryFirewallReport
$before = $Sync.Result
Block-TelemetryFirewall
$rules = @(Get-NetFirewallRule -Group $Script:FwGroup -ErrorAction SilentlyContinue)
$diag = $rules | Where-Object { $_.Name -eq 'BJMPC-Tel-diagtrack' }
$svc = $(if ($diag) { [string]($diag | Get-NetFirewallServiceFilter).Service } else { '' })
$dir = @($rules | ForEach-Object { [string]$_.Direction + '/' + [string]$_.Action } | Select-Object -Unique)
Get-TelemetryFirewallReport
$mid = $Sync.Result
Unblock-TelemetryFirewall
$after = @(Get-NetFirewallRule -Group $Script:FwGroup -ErrorAction SilentlyContinue).Count
$Sync.Result = @{ Present = @($before.Items | Where-Object { $_.Present }).Count; Rules = $rules.Count; Svc = $svc; Dir = $dir
    Blocked = @($mid.Items | Where-Object { $_.Blocked }).Count; After = $after }
'@
        $r.Errors | Should -BeNullOrEmpty
        $r.Result.Present | Should -BeGreaterThan 0
        $r.Result.Rules | Should -Be $r.Result.Present
        $r.Result.Svc | Should -Be 'DiagTrack'
        $r.Result.Dir | Should -Be @('Outbound/Block')
        $r.Result.Blocked | Should -Be $r.Result.Present
        $r.Result.After | Should -Be 0
    }
}

Describe 'Imprimantes : pilote Microsoft vers pilote du fabricant' {
    It 'Reconnaissance des modèles, bascule réelle (pilote + port TCP/IP) puis retour exact' {
        $r = Invoke-Engine 'tools' @'
$Script:LogFile = Join-Path $env:TEMP 'bjmpc-test-prn.log'
$Script:PrnDir = Join-Path $env:TEMP ('bjmpc-prn-' + [guid]::NewGuid().ToString('N'))
$Script:PrnSwapFile = Join-Path $Script:PrnDir 'Bascules-pilote.json'
$m1 = Find-VendorDriverFor 'HP LaserJet Pro M404dn' @('HP Universal Printing PCL 6', 'HP LaserJet Pro M404-M405 PCL 6 (V3)')
$m2 = Find-VendorDriverFor 'Brother MFC-J5330DW' @('Brother MFC-J5330DW FAX', 'Brother MFC-J5330DW Printer')
$cls = $null
foreach ($d in 'Microsoft IPP Class Driver', 'Microsoft PCL6 Class Driver', 'Microsoft PS Class Driver') {
    if (-not (Get-PrinterDriver -Name $d -ErrorAction SilentlyContinue)) { try { Add-PrinterDriver -Name $d -ErrorAction Stop } catch {} }
    if (Get-PrinterDriver -Name $d -ErrorAction SilentlyContinue) { $cls = $d; break }
}
$vend = 'Generic / Text Only'
if (-not (Get-PrinterDriver -Name $vend -ErrorAction SilentlyContinue)) { Add-PrinterDriver -Name $vend -ErrorAction Stop }
Add-PrinterPort -Name 'BJTEST_PORT' -PrinterHostAddress '192.0.2.77' -ErrorAction Stop
Add-Printer -Name 'BJMPC Test IPP' -DriverName $cls -PortName 'BJTEST_PORT' -ErrorAction Stop
Get-PrinterDriverReport
$rep = @($Sync.Result.Rows | Where-Object { $_.Name -eq 'BJMPC Test IPP' })
Switch-PrinterToVendor -Name 'BJMPC Test IPP' -Driver $vend
$mid = Get-Printer -Name 'BJMPC Test IPP'
$swOk = @($Sync.Result.Ok)
Restore-PrinterDriver -Name 'BJMPC Test IPP'
$end = Get-Printer -Name 'BJMPC Test IPP'
$portLeft = [bool](Get-PrinterPort -Name 'IP_192.0.2.77' -ErrorAction SilentlyContinue)
Remove-Printer -Name 'BJMPC Test IPP' -ErrorAction SilentlyContinue; Remove-PrinterPort -Name 'BJTEST_PORT' -ErrorAction SilentlyContinue
$Sync.Result = @{ M1 = $m1; M2 = $m2; Cls = $cls; RepClass = $(if ($rep) { $rep[0].Class } else { $null }); SwOk = $swOk
    MidDrv = [string]$mid.DriverName; MidPort = [string]$mid.PortName; EndDrv = [string]$end.DriverName; EndPort = [string]$end.PortName; PortLeft = $portLeft }
'@
        $r.Errors | Should -BeNullOrEmpty
        $r.Result.M1 | Should -Be 'HP LaserJet Pro M404-M405 PCL 6 (V3)'
        $r.Result.M2 | Should -Be 'Brother MFC-J5330DW Printer'
        $r.Result.Cls | Should -Not -BeNullOrEmpty
        $r.Result.RepClass | Should -BeTrue
        $r.Result.SwOk | Should -Contain 'BJMPC Test IPP'
        $r.Result.MidDrv | Should -Be 'Generic / Text Only'
        $r.Result.MidPort | Should -Be 'IP_192.0.2.77'
        $r.Result.EndDrv | Should -Be $r.Result.Cls
        $r.Result.EndPort | Should -Be 'BJTEST_PORT'
        $r.Result.PortLeft | Should -BeFalse
    }
}

Describe 'Stockage (lecture seule)' {
    It 'Rapport de stockage, état du pilote NVMe et lecture des réglages d''alimentation sans erreur' {
        $r = Invoke-Engine 'opt' @'
$Script:LogFile = Join-Path $env:TEMP 'bjmpc-test-stockage.log'
Get-StorageReport
$rep = $Sync.Result
$nv = Get-NvmeState
$g = Get-ActivePlanGuid
$pi = Get-PowerIndex $g '2a737441-1930-4402-8d77-b2bebba308a3' '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
$Sync.Result = @{ Disks = @($rep.Disks).Count; HasNotes = ($null -ne $rep.Notes); Nvme = $nv; Pi = $pi; Plan = $g }
'@
        $r.Errors | Should -BeNullOrEmpty
        $r.Result.Disks | Should -BeGreaterThan 0
        $r.Result.Plan | Should -Match '^[0-9a-f-]{36}$'
        $r.Result.Nvme | Should -Not -BeNullOrEmpty
        if (-not $r.Result.Nvme.Eligible) { [string]$r.Result.Nvme.Reason | Should -Not -BeNullOrEmpty }
    }
}

Describe 'Analyse statique' {
    It 'PSScriptAnalyzer : aucune erreur, syntaxe compatible PowerShell 5.1' {
        if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) { Set-ItResult -Skipped -Because 'PSScriptAnalyzer absent'; return }
        $settings = @{ IncludeRules = @('PSUseCompatibleSyntax', 'PSAvoidAssignmentToAutomaticVariable', 'PSMisleadingBacktick', 'PSPossibleIncorrectComparisonWithNull', 'PSReservedParams')
            Rules = @{ PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1') } } }
        $all = foreach ($f in Get-ChildItem (Join-Path (Split-Path -Parent $PSScriptRoot) '*.ps1')) { Invoke-ScriptAnalyzer -Path $f.FullName -Settings $settings }
        ($all | ForEach-Object { '{0}:{1} {2}' -f $_.ScriptName, $_.Line, $_.Message }) | Should -BeNullOrEmpty
    }
}
