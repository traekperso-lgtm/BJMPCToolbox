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
        $r = Invoke-Engine 'tools' ("(Get-DriverDecision $dev $cand).Code")
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
$t = Join-Path $env:TEMP ('BJMPC-Test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
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

Describe 'Analyse statique' {
    It 'PSScriptAnalyzer : aucune erreur, syntaxe compatible PowerShell 5.1' {
        if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) { Set-ItResult -Skipped -Because 'PSScriptAnalyzer absent'; return }
        $settings = @{ IncludeRules = @('PSUseCompatibleSyntax', 'PSAvoidAssignmentToAutomaticVariable', 'PSMisleadingBacktick', 'PSPossibleIncorrectComparisonWithNull', 'PSReservedParams')
            Rules = @{ PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1') } } }
        $all = foreach ($f in Get-ChildItem (Join-Path (Split-Path -Parent $PSScriptRoot) '*.ps1')) { Invoke-ScriptAnalyzer -Path $f.FullName -Settings $settings }
        ($all | ForEach-Object { '{0}:{1} {2}' -f $_.ScriptName, $_.Line, $_.Message }) | Should -BeNullOrEmpty
    }
}
