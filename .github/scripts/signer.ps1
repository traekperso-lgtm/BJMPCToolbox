# Signature Authenticode BJMPC Informatique (utilisé par GitHub Actions, sous Windows).
# Le certificat vient du secret BJMPC_CERT_PFX (fichier .pfx encodé en base64).
# Sans secret (fork, première compilation) : rien n'est signé, la compilation continue.
#   .\signer.ps1 -Chemins fichier1.exe, dossier\*.dll, script.ps1
#   .\signer.ps1 -Preparer   -> exporte SIGNTOOL et BJMPC_PFX_PATH pour les étapes suivantes (Inno Setup)
param(
    [string[]]$Chemins = @(),
    [switch]$Preparer
)
$ErrorActionPreference = 'Stop'

if (-not $env:BJMPC_CERT_PFX) {
    Write-Output '::warning::Secret BJMPC_CERT_PFX absent : fichiers NON signés (voir certificat/LISEZMOI-certificat.txt).'
    if ($Preparer -and $env:GITHUB_OUTPUT) { 'signe=false' >> $env:GITHUB_OUTPUT }
    exit 0
}

$pfx = Join-Path $env:RUNNER_TEMP 'bjmpc-signature.pfx'
if (-not (Test-Path $pfx)) { [IO.File]::WriteAllBytes($pfx, [Convert]::FromBase64String($env:BJMPC_CERT_PFX)) }

$signtool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\x64\\' } | Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
if (-not $signtool) { throw 'signtool.exe introuvable (Windows SDK)' }

if ($Preparer) {
    if ($env:GITHUB_ENV) { "SIGNTOOL=$signtool" >> $env:GITHUB_ENV; "BJMPC_PFX_PATH=$pfx" >> $env:GITHUB_ENV }
    if ($env:GITHUB_OUTPUT) { 'signe=true' >> $env:GITHUB_OUTPUT }
}

$horodateurs = 'http://timestamp.digicert.com', 'http://timestamp.sectigo.com', 'http://timestamp.globalsign.com/tsa/r6advanced1'
$motDePasse = 'BJMPC-Informatique'   # le vrai secret est le contenu du .pfx, gardé dans les secrets GitHub
$cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2($pfx, $motDePasse, 'Exportable')

$fichiers = foreach ($c in $Chemins) { Get-ChildItem -Path $c -File -ErrorAction Stop }
foreach ($f in $fichiers) {
    $ok = $false
    foreach ($ts in $horodateurs) {
        if ($f.Extension -in '.ps1', '.psm1', '.psd1') {
            $r = Set-AuthenticodeSignature -FilePath $f.FullName -Certificate $cert -HashAlgorithm SHA256 -TimestampServer $ts -ErrorAction SilentlyContinue
            $ok = $r -and $r.SignerCertificate
        } else {
            & $signtool sign /f $pfx /p $motDePasse /fd sha256 /tr $ts /td sha256 /d 'BJMPC Informatique' $f.FullName | Out-Null
            $ok = $LASTEXITCODE -eq 0
        }
        if ($ok) { break }
        Start-Sleep -Seconds 3
    }
    if (-not $ok) { throw "signature impossible : $($f.FullName)" }
    Write-Output "signé : $($f.Name)"
}
