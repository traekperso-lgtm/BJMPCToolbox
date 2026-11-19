#Requires -Version 5.1
<#
    BJMPC Informatique - installation du certificat de confiance (à faire une fois par PC)

    Ce que fait ce script :
      1. ajoute le certificat « BJMPC Informatique » aux magasins « Autorités de certification racines de confiance »
         et « Éditeurs approuvés » de l'ordinateur ;
      2. débloque (marque « provenant d'Internet ») les fichiers de ce dossier qui portent une signature
         BJMPC Informatique VALIDE - et uniquement ceux-là ;
    Résultat : Windows affiche « Éditeur vérifié : BJMPC Informatique » au lieu de « Éditeur inconnu »,
    et les installateurs BJMPC de ce dossier se lancent sans l'écran bleu SmartScreen.

    Retirer le certificat :  Installer-certificat-BJMPC.cmd /retirer
#>
param([switch]$Retirer, [switch]$Silencieux)

$Empreinte = '537606BC75F6C55A27F95050B50188B2F997E779'
$CertB64 = @'
MIIEkjCCAvqgAwIBAgIURimqrDaCyseSm4iiRNhCzWIq7HIwDQYJKoZIhvcNAQELBQAwWDEbMBkG
A1UEAwwSQkpNUEMgSW5mb3JtYXRpcXVlMRswGQYDVQQKDBJCSk1QQyBJbmZvcm1hdGlxdWUxDzAN
BgNVBAcMBkpvbnphYzELMAkGA1UEBhMCRlIwHhcNMjYxMTE5MjIyMTQwWhcNMzExMTE5MjIyMTQw
WjBYMRswGQYDVQQDDBJCSk1QQyBJbmZvcm1hdGlxdWUxGzAZBgNVBAoMEkJKTVBDIEluZm9ybWF0
aXF1ZTEPMA0GA1UEBwwGSm9uemFjMQswCQYDVQQGEwJGUjCCAaIwDQYJKoZIhvcNAQEBBQADggGP
ADCCAYoCggGBAL5JtB7or1P1+ksIm9Xt3c0bVGA5B2GFL1yM/c0LqVZUmRIGkpPyikjZuyzroS2o
FR3j8Vk3r98bR3ONDuJCnBdlEldzkk7u9f4k7Ztl5Yzyl4oYzkngVhSNzEVreTZ7qUxXcly9LQkX
0cC4paCMv06nRI98yDExrltg5W/+TQEAN+5o7/9VzVAzy+AE6/xSRnWeJcJnuR1NX+2h2NoS7Cy5
BgjimbQ7kmsR/Yo46WBAcDPWLK7ogP3C147kcrI34Lk9kREFzIgEogEO1ArZMlMX2+O3Xrx5toUs
61BGK9uadujtNAzl4bQ+9BSqrwiv1lSlRVunPiE/OCG91ItUKnND8NAMiXt0P76ludcQ1Eyi7lhO
M4EVrKrJdl8VS0LrIWtpk2i7C+gKSH4BM3C4aSz1bvRAlSPHTJPD5oUnbEu3Fm3gz8flYmvacQqo
Ahhia6yxk9eDUWT0KLhJs0lGJZ33oOsPXxSSj1/aP42uTijVkDChfsxutpfaQPNrQ9R2DQIDAQAB
o1QwUjAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDATBgNVHSUEDDAKBggrBgEFBQcDAzAd
BgNVHQ4EFgQUiIgTB4BL1PjKw/ZCOc8KEVpGH7UwDQYJKoZIhvcNAQELBQADggGBAEHcPFyyeJgd
36eOZcAM0QieBObM24Nr5c6DUmZ+5WMbQuV/3jyRTYO6nS8WpUixYYn9cwTea6llq7E/5CcHgwFA
/SCjJeVdnylcSaEJ4PG1/YrvV9WQv2CNLqH6cbl1SNYirNMAlWIWF3YD+Q5e5uSRoT3so0HbHOrA
WdT7IVYPHJxFuNme+1Pn6fgDytH7IaIcUcPCp7916+Up68khJyqu0g1C9t3f0NJSXh4PI+ay1YAt
t/qp68AoOZGHytd1uc56F/DsQ7KIGX5mGtANT4XP+aZNrwhxyBuN1IYe8107GovkkvahtfJ0CkE6
1c2FwKXnKE+pQLs+m1FLtxtu6oAo8WrEIlLXURGMxgcdiGLLI5NJ95g+6jntnRBzbjS/vnrLi0C/
KbLGvV1zwF7m+s9p+6JjfhF83qq4g1h525eMJaiOIDKHTfUGEzzx99FC0S8FzYT1Xgj3iV3jSAVG
g22Bt8GTdYexleF5XJUA4Wu8+H8J/ZYkPeX6TIXayDF/CA==
'@

# ---------------------------------------------------------------- droits administrateur
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Retirer) { $arguments += '-Retirer' }
    if ($Silencieux) { $arguments += '-Silencieux' }
    try { Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments -ErrorAction Stop }
    catch { Write-Host 'Droits administrateur refusés : rien n''a été modifié.' -ForegroundColor Red; if (-not $Silencieux) { Read-Host 'Entrée pour fermer' } }
    exit
}

function Fin($code) { if (-not $Silencieux) { Write-Host ''; Read-Host 'Appuyez sur Entrée pour fermer' | Out-Null }; exit $code }
$Host.UI.RawUI.WindowTitle = 'BJMPC Informatique - certificat'
Write-Host ''
Write-Host '  BJMPC Informatique - certificat de signature' -ForegroundColor Cyan
Write-Host '  ----------------------------------------------'

$cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2(,[Convert]::FromBase64String(($CertB64 -replace '\s', '')))
if ($cert.Thumbprint -ne $Empreinte) { Write-Host 'Certificat altéré : empreinte inattendue. Arrêt.' -ForegroundColor Red; Fin 2 }

$magasins = 'Root', 'TrustedPublisher'

if ($Retirer) {
    foreach ($m in $magasins) {
        $s = New-Object Security.Cryptography.X509Certificates.X509Store($m, 'LocalMachine'); $s.Open('ReadWrite')
        $s.Certificates | Where-Object Thumbprint -eq $Empreinte | ForEach-Object { $s.Remove($_) }
        $s.Close()
    }
    Write-Host '  Certificat BJMPC Informatique retiré de ce PC.' -ForegroundColor Green
    Fin 0
}

Write-Host ("  Titulaire  : {0}" -f $cert.GetNameInfo('SimpleName', $false))
Write-Host ("  Empreinte  : {0}" -f $Empreinte)
Write-Host ("  Valide du  : {0:dd/MM/yyyy} au {1:dd/MM/yyyy}" -f $cert.NotBefore, $cert.NotAfter)
Write-Host ''

foreach ($m in $magasins) {
    $s = New-Object Security.Cryptography.X509Certificates.X509Store($m, 'LocalMachine'); $s.Open('ReadWrite')
    if (-not ($s.Certificates | Where-Object Thumbprint -eq $Empreinte)) { $s.Add($cert) }
    $s.Close()
}
Write-Host '  [OK] Certificat installé (racines de confiance + éditeurs approuvés).' -ForegroundColor Green

# ---------------------------------------------------------------- déblocage des fichiers BJMPC signés
$dossier = Split-Path -Parent $PSCommandPath
$debloques = 0; $refuses = 0
Get-ChildItem -LiteralPath $dossier -File -Recurse -Include *.exe, *.msi, *.ps1 -ErrorAction SilentlyContinue | ForEach-Object {
    $sig = Get-AuthenticodeSignature -LiteralPath $_.FullName
    if ($sig.Status -eq 'Valid' -and $sig.SignerCertificate.Thumbprint -eq $Empreinte) {
        if (Get-Item -LiteralPath $_.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue) {
            Unblock-File -LiteralPath $_.FullName
            Write-Host ("  [OK] Débloqué : {0}" -f $_.Name) -ForegroundColor Green
            $debloques++
        }
    } elseif ($_.FullName -ne $PSCommandPath -and $_.Extension -ne '.ps1') {
        Write-Host ("  [--] Ignoré (pas signé BJMPC) : {0}" -f $_.Name) -ForegroundColor DarkGray
        $refuses++
    }
}
Write-Host ''
Write-Host ("  Terminé. {0} fichier(s) débloqué(s)." -f $debloques) -ForegroundColor Cyan
Write-Host '  Vous pouvez lancer les installateurs BJMPC de ce dossier.'
Fin 0
