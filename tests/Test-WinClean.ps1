<#
.SYNOPSIS
    Suite de tests de WinClean.

.DESCRIPTION
    Exerce le moteur de suppression sur des fichiers factices, dans un bac a
    sable temporaire. Ne touche jamais de donnees reelles.

    Le test 5 ecrit une entree jetable dans HKCU\...\StartupApproved\Run et la
    retire dans un bloc finally, y compris en cas d'echec.

.EXAMPLE
    .\tests\Test-WinClean.ps1
#>
[CmdletBinding()]
param()

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path (Split-Path -Parent $here) 'scripts\WinClean.ps1')

$sandbox = Join-Path $env:TEMP 'winclean-sandbox'
if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force }

$script:pass = 0
$script:fail = 0
function Assert-That {
    param([string]$Nom, [bool]$Condition, [string]$Detail = '')
    if ($Condition) { $script:pass++; Write-Host "  OK    $Nom" -ForegroundColor Green }
    else            { $script:fail++; Write-Host "  ECHEC $Nom  $Detail" -ForegroundColor Red }
}

# Les fichiers factices sont ecrits avec -NoNewline : sans ca, Set-Content
# ajoute un CRLF et chaque fichier pese 2 octets de plus que prevu.

Write-Host "`n=== TEST 1 : vide le contenu, garde le dossier ===" -ForegroundColor Cyan
$t1 = Join-Path $sandbox 'cible1'
New-Item -ItemType Directory -Path "$t1\sous\encore" -Force | Out-Null
1..5 | ForEach-Object { Set-Content "$t1\f$_.tmp" ('x' * 100000) -NoNewline }
Set-Content "$t1\sous\profond.tmp" ('x' * 50000) -NoNewline
Set-Content "$t1\sous\encore\tresprofond.tmp" ('x' * 50000) -NoNewline

$cible1 = [pscustomobject]@{
    Nom = 'Test contenu'; Chemins = @($t1); Filter = $null; Special = $null
    Octets = (Get-PathSize -Path $t1)
}
$r1 = Remove-CleanupTarget -Target $cible1
Assert-That 'le dossier cible survit'        (Test-Path -LiteralPath $t1)
Assert-That 'le contenu recursif est efface' ((Get-ChildItem $t1 -Recurse -Force).Count -eq 0)
Assert-That 'les octets liberes sont exacts' ($r1.Liberes -eq 600000) "attendu 600000, obtenu $($r1.Liberes)"
Assert-That 'restants a zero'                ($r1.Restants -eq 0)

Write-Host "`n=== TEST 2 : suppression filtree, epargne le reste ===" -ForegroundColor Cyan
$t2 = Join-Path $sandbox 'cible2'
New-Item -ItemType Directory -Path $t2 -Force | Out-Null
Set-Content "$t2\thumbcache_32.db"  ('x' * 200000) -NoNewline
Set-Content "$t2\thumbcache_96.db"  ('x' * 200000) -NoNewline
Set-Content "$t2\iconcache_16.db"   ('x' * 100000) -NoNewline
Set-Content "$t2\NE_PAS_TOUCHER.db" ('x' * 999) -NoNewline    # meme extension, autre prefixe
Set-Content "$t2\donnees.dat"       ('x' * 777) -NoNewline

$cible2 = [pscustomobject]@{
    Nom = 'Test filtre'; Chemins = @($t2); Filter = @('thumbcache_*.db', 'iconcache_*.db'); Special = $null
    Octets = 0
}
$cible2.Octets = Measure-TargetSize -Target $cible2
$r2 = Remove-CleanupTarget -Target $cible2
Assert-That 'les caches cibles sont effaces' (-not (Test-Path -LiteralPath "$t2\thumbcache_32.db"))
Assert-That 'iconcache efface'               (-not (Test-Path -LiteralPath "$t2\iconcache_16.db"))
Assert-That 'le .db hors filtre est epargne' (Test-Path -LiteralPath "$t2\NE_PAS_TOUCHER.db")
Assert-That 'le fichier hors filtre epargne' (Test-Path -LiteralPath "$t2\donnees.dat")
Assert-That 'liberes = somme des filtres'    ($r2.Liberes -eq 500000) "attendu 500000, obtenu $($r2.Liberes)"
# Regression : mesurer le restant avec Get-PathSize comptait les fichiers hors
# filtre et les annoncait comme "verrouilles", en sous-estimant le gain.
Assert-That 'rien annonce comme verrouille'  ($r2.Restants -eq 0) "obtenu $($r2.Restants) - mesure incoherente avec le scan"

Write-Host "`n=== TEST 3 : jokers facon profils Chrome ===" -ForegroundColor Cyan
$t3 = Join-Path $sandbox 'chrome'
foreach ($p in @('Default', 'Profile 1', 'Profile 2')) {
    New-Item -ItemType Directory -Path "$t3\$p\Cache" -Force | Out-Null
    Set-Content "$t3\$p\Cache\data" ('x' * 100000) -NoNewline
    New-Item -ItemType Directory -Path "$t3\$p\Login Data" -Force | Out-Null
    Set-Content "$t3\$p\Login Data\secrets" ('x' * 500) -NoNewline   # ne doit jamais partir
}
$paths = Expand-TargetPaths -Patterns @("$t3\*\Cache")
Assert-That 'le joker resout les 3 profils' ($paths.Count -eq 3) "obtenu $($paths.Count)"

$cible3 = [pscustomobject]@{ Nom = 'Test chrome'; Chemins = $paths; Filter = $null; Special = $null; Octets = 0 }
$cible3.Octets = Measure-TargetSize -Target $cible3
$r3 = Remove-CleanupTarget -Target $cible3
Assert-That 'les 3 caches sont vides'        ((Get-ChildItem "$t3\*\Cache" -Recurse -Force).Count -eq 0)
Assert-That 'les mots de passe sont intacts' (Test-Path -LiteralPath "$t3\Default\Login Data\secrets")
Assert-That 'liberes = 3 x 100000'           ($r3.Liberes -eq 300000) "obtenu $($r3.Liberes)"

Write-Host "`n=== TEST 4 : fichier verrouille, comptabilise et non force ===" -ForegroundColor Cyan
$t4 = Join-Path $sandbox 'cible4'
New-Item -ItemType Directory -Path $t4 -Force | Out-Null
Set-Content "$t4\libre.tmp"      ('x' * 300000) -NoNewline
Set-Content "$t4\verrouille.tmp" ('x' * 100000) -NoNewline
$fs = [System.IO.File]::Open("$t4\verrouille.tmp", 'Open', 'Read', 'None')   # verrou exclusif
try {
    $cible4 = [pscustomobject]@{
        Nom = 'Test verrou'; Chemins = @($t4); Filter = $null; Special = $null
        Octets = (Get-PathSize -Path $t4)
    }
    $r4 = Remove-CleanupTarget -Target $cible4
    Assert-That 'le fichier libre est efface'  (-not (Test-Path -LiteralPath "$t4\libre.tmp"))
    Assert-That 'le fichier verrouille survit' (Test-Path -LiteralPath "$t4\verrouille.tmp")
    Assert-That 'liberes = seulement le libre' ($r4.Liberes -eq 300000) "obtenu $($r4.Liberes)"
    Assert-That 'restants = le verrouille'     ($r4.Restants -eq 100000) "obtenu $($r4.Restants)"
    Assert-That 'aucune exception levee'       ($null -eq $r4.Erreur)
} finally {
    $fs.Close(); $fs.Dispose()
}

Write-Host "`n=== TEST 5 : etat demarrage, aller-retour ===" -ForegroundColor Cyan
$fakeKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
$fakeName = 'ZZ_WinCleanTest_ASupprimer'
try {
    Set-StartupState -ApprovedKey $fakeKey -Name $fakeName -Enabled $true
    Assert-That 'ecrit actif -> lu actif'         (Test-StartupEnabled -ApprovedKey $fakeKey -Name $fakeName)
    Set-StartupState -ApprovedKey $fakeKey -Name $fakeName -Enabled $false
    Assert-That 'ecrit desactive -> lu desactive' (-not (Test-StartupEnabled -ApprovedKey $fakeKey -Name $fakeName))
    $raw = (Get-ItemProperty -Path $fakeKey -Name $fakeName).$fakeName
    Assert-That 'octet desactive = 3 (format Gestionnaire des taches)' ($raw[0] -eq 3) "obtenu $($raw[0])"
    Assert-That 'longueur 12 octets'              ($raw.Length -eq 12) "obtenu $($raw.Length)"
    Set-StartupState -ApprovedKey $fakeKey -Name $fakeName -Enabled $true
    $raw2 = (Get-ItemProperty -Path $fakeKey -Name $fakeName).$fakeName
    Assert-That 'octet actif = 2'                 ($raw2[0] -eq 2) "obtenu $($raw2[0])"
} finally {
    Remove-ItemProperty -Path $fakeKey -Name $fakeName -ErrorAction SilentlyContinue
}

if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host "`n=================================" -ForegroundColor Cyan
$color = 'Green'
if ($script:fail -gt 0) { $color = 'Red' }
Write-Host ("  REUSSIS : {0}    ECHECS : {1}" -f $script:pass, $script:fail) -ForegroundColor $color
if ($script:fail -gt 0) { exit 1 }
