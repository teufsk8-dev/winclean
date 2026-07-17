#Requires -Version 5.1
<#
.SYNOPSIS
    WinClean - equivalent maison de CleanMyMac pour Windows.

.DESCRIPTION
    Quatre modules, tous en lecture seule tant que tu n'as pas confirme :
      1. Nettoyage disque     - temporaires, caches, corbeille, logs, caches dev
      2. Analyse de l'espace  - gros fichiers, gros dossiers, doublons, fichiers oublies
      3. Gestion du demarrage - ce qui se lance au boot, activable / desactivable
      4. Desinstallation      - programmes installes + restes laisses derriere

    Rien n'est supprime sans un scan prealable, un rapport chiffre et une
    confirmation explicite. Les operations de suppression sont journalisees
    dans le dossier .\logs.

.PARAMETER Module
    Ouvre directement un module : Nettoyage, Analyse, Demarrage, Desinstallation.
    Sans ce parametre, le menu principal s'affiche.

.EXAMPLE
    .\WinClean.ps1
    .\WinClean.ps1 -Module Nettoyage
#>
[CmdletBinding()]
param(
    [ValidateSet('Nettoyage', 'Analyse', 'Demarrage', 'Desinstallation')]
    [string]$Module
)

$ErrorActionPreference = 'Stop'
$script:Root   = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:LogDir = Join-Path $script:Root 'logs'
$script:LogFile = Join-Path $script:LogDir ("winclean-{0:yyyy-MM-dd}.log" -f (Get-Date))


# ---------------------------------------------------------------------------
# Utilitaires
# ---------------------------------------------------------------------------

function Write-Log {
    param([string]$Message)
    if (-not (Test-Path $script:LogDir)) {
        New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
    }
    $line = "{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $Message
    Add-Content -Path $script:LogFile -Value $line -Encoding utf8
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1TB) { return "{0:N2} To" -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return "{0:N2} Go" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N1} Mo" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N0} Ko" -f ($Bytes / 1KB) }
    return "$([math]::Round($Bytes)) o"
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PathSize {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $sum = 0
    try {
        $items = Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue
        foreach ($i in $items) { $sum += $i.Length }
    } catch { }
    return $sum
}

function Expand-TargetPaths {
    # Resout les jokers (ex: profils Chrome) en chemins reels
    param([string[]]$Patterns)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($p in $Patterns) {
        $expanded = [Environment]::ExpandEnvironmentVariables($p)
        if ($expanded -match '[\*\?]') {
            try {
                Get-Item -Path $expanded -Force -ErrorAction SilentlyContinue |
                    ForEach-Object { $out.Add($_.FullName) }
            } catch { }
        } elseif (Test-Path -LiteralPath $expanded) {
            $out.Add($expanded)
        }
    }
    return $out.ToArray()
}

function Write-Title {
    param([string]$Text)
    Write-Host ""
    Write-Host ("  " + $Text) -ForegroundColor Cyan
    Write-Host ("  " + ("-" * $Text.Length)) -ForegroundColor DarkCyan
}

function Read-Choice {
    param([string]$Prompt, [string]$Default = '')
    if ($Default) { $p = "$Prompt [$Default]" } else { $p = $Prompt }
    $answer = Read-Host $p
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim()
}

function Confirm-Destructive {
    <#  Demande de taper un mot entier. Pas de "y/n" pour ce qui efface. #>
    param([string]$Prompt, [string]$Word = 'SUPPRIMER')
    Write-Host ""
    Write-Host $Prompt -ForegroundColor Yellow
    $answer = Read-Host "  Tape $Word pour confirmer (autre chose = annuler)"
    return ($answer -ceq $Word)
}


# ---------------------------------------------------------------------------
# Module 1 : Nettoyage disque
# ---------------------------------------------------------------------------

function Get-CleanupTargets {
    $t = @()

    $t += [pscustomobject]@{
        Nom = 'Fichiers temporaires (utilisateur)'
        Niveau = 'Sur'; Admin = $false
        Paths = @('%LOCALAPPDATA%\Temp')
        Note  = 'Regenere automatiquement.'
    }
    $t += [pscustomobject]@{
        Nom = 'Fichiers temporaires (Windows)'
        Niveau = 'Sur'; Admin = $true
        Paths = @('%SystemRoot%\Temp')
        Note  = 'Regenere automatiquement.'
    }
    $t += [pscustomobject]@{
        Nom = 'Cache Windows Update'
        Niveau = 'Sur'; Admin = $true
        Paths = @('%SystemRoot%\SoftwareDistribution\Download')
        Note  = 'Installeurs deja appliques. Retelecharges si besoin.'
    }
    $t += [pscustomobject]@{
        Nom = 'Delivery Optimization'
        Niveau = 'Sur'; Admin = $true
        Paths = @('%SystemRoot%\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization')
        Note  = 'Cache de partage des mises a jour.'
    }
    $t += [pscustomobject]@{
        Nom = 'Rapports d''erreurs (WER)'
        Niveau = 'Sur'; Admin = $false
        Paths = @(
            '%LOCALAPPDATA%\Microsoft\Windows\WER\ReportArchive',
            '%LOCALAPPDATA%\Microsoft\Windows\WER\ReportQueue',
            '%ProgramData%\Microsoft\Windows\WER\ReportArchive',
            '%ProgramData%\Microsoft\Windows\WER\ReportQueue'
        )
        Note  = 'Dumps de crash. Utiles seulement pour du debug.'
    }
    $t += [pscustomobject]@{
        Nom = 'Cache miniatures et icones'
        Niveau = 'Sur'; Admin = $false
        Paths = @('%LOCALAPPDATA%\Microsoft\Windows\Explorer')
        Filter = 'thumbcache_*.db', 'iconcache_*.db'
        Note  = 'Reconstruit a la volee. Explorateur un peu lent au debut.'
    }
    $t += [pscustomobject]@{
        Nom = 'Cache Chrome'
        Niveau = 'Sur'; Admin = $false
        Paths = @(
            '%LOCALAPPDATA%\Google\Chrome\User Data\*\Cache',
            '%LOCALAPPDATA%\Google\Chrome\User Data\*\Code Cache',
            '%LOCALAPPDATA%\Google\Chrome\User Data\*\GPUCache'
        )
        Note  = 'Ferme Chrome avant. Ne touche ni mots de passe ni historique.'
    }
    $t += [pscustomobject]@{
        Nom = 'Cache Edge'
        Niveau = 'Sur'; Admin = $false
        Paths = @(
            '%LOCALAPPDATA%\Microsoft\Edge\User Data\*\Cache',
            '%LOCALAPPDATA%\Microsoft\Edge\User Data\*\Code Cache',
            '%LOCALAPPDATA%\Microsoft\Edge\User Data\*\GPUCache'
        )
        Note  = 'Ferme Edge avant.'
    }
    $t += [pscustomobject]@{
        Nom = 'Cache Firefox'
        Niveau = 'Sur'; Admin = $false
        Paths = @('%LOCALAPPDATA%\Mozilla\Firefox\Profiles\*\cache2')
        Note  = 'Ferme Firefox avant.'
    }
    $t += [pscustomobject]@{
        Nom = 'Cache npm'
        Niveau = 'Sur'; Admin = $false
        Paths = @('%LOCALAPPDATA%\npm-cache\_cacache')
        Note  = 'Paquets retelecharges au prochain install.'
    }
    $t += [pscustomobject]@{
        Nom = 'Cache pip'
        Niveau = 'Sur'; Admin = $false
        Paths = @('%LOCALAPPDATA%\pip\Cache')
        Note  = 'Wheels retelecharges au prochain install.'
    }
    $t += [pscustomobject]@{
        Nom = 'Cache Yarn / pnpm'
        Niveau = 'Sur'; Admin = $false
        Paths = @('%LOCALAPPDATA%\Yarn\Cache', '%LOCALAPPDATA%\pnpm-store')
        Note  = 'Paquets retelecharges au prochain install.'
    }
    $t += [pscustomobject]@{
        Nom = 'Corbeille'
        Niveau = 'Prudent'; Admin = $false
        Paths = @()
        Special = 'RecycleBin'
        Note  = 'Irreversible : verifie son contenu avant.'
    }
    $t += [pscustomobject]@{
        Nom = 'Prefetch'
        Niveau = 'Prudent'; Admin = $true
        Paths = @('%SystemRoot%\Prefetch')
        Note  = 'Windows le reconstruit ; demarrages un peu plus lents quelques jours.'
    }
    $t += [pscustomobject]@{
        Nom = 'Logs Windows (CBS, DISM)'
        Niveau = 'Prudent'; Admin = $true
        Paths = @('%SystemRoot%\Logs\CBS', '%SystemRoot%\Logs\DISM')
        Note  = 'Utiles seulement pour diagnostiquer une MAJ ratee.'
    }
    $t += [pscustomobject]@{
        Nom = 'Cache NuGet'
        Niveau = 'Prudent'; Admin = $false
        Paths = @('%USERPROFILE%\.nuget\packages')
        Note  = 'Gros mais retelecharge a chaque build hors-ligne. A eviter si tu bosses sans reseau.'
    }

    return $t
}

function Get-RecycleBinSize {
    try {
        $shell = New-Object -ComObject Shell.Application
        $bin = $shell.Namespace(0xA)
        $sum = 0
        foreach ($item in $bin.Items()) { $sum += $item.ExtendedProperty('Size') }
        return $sum
    } catch { return 0 }
}

function Invoke-CleanupScan {
    Write-Title 'Analyse des cibles de nettoyage'
    $isAdmin = Test-Admin
    if (-not $isAdmin) {
        Write-Host "  Session non-admin : les cibles systeme seront ignorees." -ForegroundColor DarkYellow
        Write-Host "  Relance dans un PowerShell admin pour les inclure." -ForegroundColor DarkYellow
    }

    $targets = Get-CleanupTargets
    $results = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($t in $targets) {
        $i++
        Write-Progress -Activity 'Analyse' -Status $t.Nom -PercentComplete (($i / $targets.Count) * 100)

        if ($t.Admin -and -not $isAdmin) { continue }

        $size = 0
        $realPaths = @()
        if ($t.PSObject.Properties.Name -contains 'Special' -and $t.Special -eq 'RecycleBin') {
            $size = Get-RecycleBinSize
        } else {
            $realPaths = Expand-TargetPaths -Patterns $t.Paths
            foreach ($p in $realPaths) {
                if ($t.PSObject.Properties.Name -contains 'Filter' -and $t.Filter) {
                    foreach ($f in $t.Filter) {
                        Get-ChildItem -LiteralPath $p -Filter $f -Force -File -ErrorAction SilentlyContinue |
                            ForEach-Object { $size += $_.Length }
                    }
                } else {
                    $size += Get-PathSize -Path $p
                }
            }
        }

        $results.Add([pscustomobject]@{
            Nom       = $t.Nom
            Niveau    = $t.Niveau
            Octets    = $size
            Taille    = Format-Size $size
            Chemins   = $realPaths
            Filter    = $(if ($t.PSObject.Properties.Name -contains 'Filter') { $t.Filter } else { $null })
            Special   = $(if ($t.PSObject.Properties.Name -contains 'Special') { $t.Special } else { $null })
            Note      = $t.Note
        })
    }
    Write-Progress -Activity 'Analyse' -Completed
    return $results | Sort-Object Octets -Descending
}

function Measure-TargetSize {
    <# Mesure une cible. Doit mesurer exactement le meme ensemble que le scan,
       sinon le gain annonce apres nettoyage est faux. #>
    param([object]$Target)
    $sum = 0
    foreach ($p in $Target.Chemins) {
        if ($Target.Filter) {
            foreach ($f in $Target.Filter) {
                Get-ChildItem -LiteralPath $p -Filter $f -Force -File -ErrorAction SilentlyContinue |
                    ForEach-Object { $sum += $_.Length }
            }
        } else {
            $sum += Get-PathSize -Path $p
        }
    }
    return $sum
}

function Remove-CleanupTarget {
    <# Supprime une cible issue de Invoke-CleanupScan.
       Retourne { Nom, Liberes, Restants, Erreur }. Ne demande rien : l'appelant
       est responsable d'avoir obtenu la confirmation. #>
    param([Parameter(Mandatory = $true)][object]$Target)

    $before = $Target.Octets

    if ($Target.Special -eq 'RecycleBin') {
        try {
            Clear-RecycleBin -Force -ErrorAction Stop
            return [pscustomobject]@{ Nom = $Target.Nom; Liberes = $before; Restants = 0; Erreur = $null }
        } catch {
            return [pscustomobject]@{ Nom = $Target.Nom; Liberes = 0; Restants = $before; Erreur = $_.Exception.Message }
        }
    }

    foreach ($p in $Target.Chemins) {
        try {
            if ($Target.Filter) {
                foreach ($f in $Target.Filter) {
                    Get-ChildItem -LiteralPath $p -Filter $f -Force -File -ErrorAction SilentlyContinue |
                        Remove-Item -Force -ErrorAction SilentlyContinue
                }
            } else {
                # On vide le contenu, on ne supprime pas le dossier lui-meme :
                # certains services rouspetent si leur dossier disparait.
                Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue |
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            }
        } catch { }
    }

    $after = Measure-TargetSize -Target $Target
    $gain = $before - $after
    if ($gain -lt 0) { $gain = 0 }
    return [pscustomobject]@{ Nom = $Target.Nom; Liberes = $gain; Restants = $after; Erreur = $null }
}

function Invoke-CleanupModule {
    $scan = Invoke-CleanupScan
    $found = @($scan | Where-Object { $_.Octets -gt 0 })

    if ($found.Count -eq 0) {
        Write-Host ""
        Write-Host "  Rien a nettoyer. Le disque est deja propre." -ForegroundColor Green
        return
    }

    Write-Host ""
    $idx = 0
    $rows = foreach ($r in $found) {
        $idx++
        [pscustomobject]@{
            '#'      = $idx
            'Cible'  = $r.Nom
            'Taille' = $r.Taille
            'Niveau' = $r.Niveau
        }
    }
    $rows | Format-Table -AutoSize | Out-Host

    $totalSafe = ($found | Where-Object { $_.Niveau -eq 'Sur' } | Measure-Object Octets -Sum).Sum
    $totalAll  = ($found | Measure-Object Octets -Sum).Sum
    Write-Host ("  Recuperable au total : {0}   dont {1} en cibles 'Sur'" -f (Format-Size $totalAll), (Format-Size $totalSafe)) -ForegroundColor Green
    foreach ($r in $found) {
        Write-Host ("   - {0} : {1}" -f $r.Nom, $r.Note) -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "  s = toutes les cibles 'Sur'    t = tout    1,3,5 = selection    q = annuler"
    $choice = Read-Choice -Prompt '  Que nettoyer ?' -Default 'q'

    $selected = @()
    switch -Regex ($choice) {
        '^[qQ]$' { Write-Host "  Annule. Rien n'a ete touche." -ForegroundColor DarkGray; return }
        '^[sS]$' { $selected = @($found | Where-Object { $_.Niveau -eq 'Sur' }) }
        '^[tT]$' { $selected = $found }
        default {
            $nums = $choice -split '[,\s]+' | Where-Object { $_ -match '^\d+$' }
            foreach ($n in $nums) {
                $n = [int]$n
                if ($n -ge 1 -and $n -le $found.Count) { $selected += $found[$n - 1] }
            }
        }
    }

    if ($selected.Count -eq 0) {
        Write-Host "  Selection vide. Rien n'a ete touche." -ForegroundColor DarkGray
        return
    }

    $selTotal = ($selected | Measure-Object Octets -Sum).Sum
    Write-Host ""
    Write-Host "  A supprimer :" -ForegroundColor Yellow
    foreach ($s in $selected) {
        Write-Host ("    {0}  ({1})" -f $s.Nom, $s.Taille)
        foreach ($p in $s.Chemins) { Write-Host ("       $p") -ForegroundColor DarkGray }
        if ($s.Special -eq 'RecycleBin') { Write-Host "       (contenu de la corbeille)" -ForegroundColor DarkGray }
    }

    if (-not (Confirm-Destructive -Prompt ("  Soit {0} a liberer, definitivement." -f (Format-Size $selTotal)))) {
        Write-Host "  Annule. Rien n'a ete touche." -ForegroundColor DarkGray
        return
    }

    Write-Host ""
    $freed = 0
    foreach ($s in $selected) {
        Write-Host ("  Nettoyage : {0}" -f $s.Nom) -NoNewline
        $r = Remove-CleanupTarget -Target $s
        $freed += $r.Liberes

        if ($r.Erreur) {
            Write-Host ("   echec : {0}" -f $r.Erreur) -ForegroundColor Red
        } elseif ($r.Restants -gt 0) {
            Write-Host ("   {0} liberes, {1} verrouilles (fichiers en cours d'usage)" -f (Format-Size $r.Liberes), (Format-Size $r.Restants)) -ForegroundColor Yellow
        } else {
            Write-Host ("   {0} liberes" -f (Format-Size $r.Liberes)) -ForegroundColor Green
        }
        Write-Log ("Nettoye '{0}' : {1} liberes, {2} restants" -f $r.Nom, (Format-Size $r.Liberes), (Format-Size $r.Restants))
    }

    Write-Host ""
    Write-Host ("  Termine. {0} liberes au total." -f (Format-Size $freed)) -ForegroundColor Green
    Write-Host ("  Journal : {0}" -f $script:LogFile) -ForegroundColor DarkGray
}


# ---------------------------------------------------------------------------
# Module 2 : Analyse de l'espace  (lecture seule)
# ---------------------------------------------------------------------------

function Show-DiskOverview {
    Write-Title 'Volumes'
    Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
        $used = $_.Size - $_.FreeSpace
        $pct = 0
        if ($_.Size -gt 0) { $pct = [math]::Round(($used / $_.Size) * 100) }
        $bar = ('#' * [math]::Round($pct / 5)).PadRight(20, '.')
        $color = 'Green'
        if ($pct -ge 75) { $color = 'Yellow' }
        if ($pct -ge 90) { $color = 'Red' }
        Write-Host ("  {0}  [{1}]  {2}% utilise   {3} libres sur {4}" -f `
            $_.DeviceID, $bar, $pct, (Format-Size $_.FreeSpace), (Format-Size $_.Size)) -ForegroundColor $color
    }
}

function Get-BigFiles {
    param([string]$Path, [int]$Top = 20)
    Write-Host "  Parcours de $Path ..." -ForegroundColor DarkGray
    Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
        Sort-Object Length -Descending |
        Select-Object -First $Top |
        ForEach-Object {
            [pscustomobject]@{
                Taille   = Format-Size $_.Length
                Modifie  = $_.LastWriteTime.ToString('yyyy-MM-dd')
                Fichier  = $_.FullName
            }
        }
}

function Get-BigFolders {
    param([string]$Path, [int]$Top = 20)
    Write-Host "  Calcul des tailles de dossiers sous $Path ... (ca peut prendre une minute)" -ForegroundColor DarkGray
    $dirs = Get-ChildItem -LiteralPath $Path -Directory -Force -ErrorAction SilentlyContinue
    $out = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($d in $dirs) {
        $i++
        Write-Progress -Activity 'Mesure des dossiers' -Status $d.Name -PercentComplete (($i / [math]::Max($dirs.Count,1)) * 100)
        $size = Get-PathSize -Path $d.FullName
        $out.Add([pscustomobject]@{ Octets = $size; Taille = Format-Size $size; Dossier = $d.FullName })
    }
    Write-Progress -Activity 'Mesure des dossiers' -Completed
    return $out | Sort-Object Octets -Descending | Select-Object -First $Top Taille, Dossier
}

function Get-DuplicateFiles {
    param([string]$Path, [int]$MinSizeMB = 1)
    Write-Host "  Recherche de doublons > $MinSizeMB Mo sous $Path ..." -ForegroundColor DarkGray
    $min = $MinSizeMB * 1MB
    $files = Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
             Where-Object { $_.Length -ge $min }

    # Deux fichiers de tailles differentes ne peuvent pas etre identiques :
    # on ne hashe que les groupes de meme taille, sinon c'est interminable.
    $candidates = $files | Group-Object Length | Where-Object { $_.Count -gt 1 }
    if (-not $candidates) { return @() }

    $hashes = New-Object System.Collections.Generic.List[object]
    $total = ($candidates | Measure-Object Count -Sum).Sum
    $i = 0
    foreach ($group in $candidates) {
        foreach ($f in $group.Group) {
            $i++
            Write-Progress -Activity 'Empreintes' -Status $f.Name -PercentComplete (($i / $total) * 100)
            try {
                $h = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
                $hashes.Add([pscustomobject]@{ Hash = $h; Length = $f.Length; Path = $f.FullName })
            } catch { }
        }
    }
    Write-Progress -Activity 'Empreintes' -Completed

    $dupes = $hashes | Group-Object Hash | Where-Object { $_.Count -gt 1 }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($d in $dupes) {
        $wasted = $d.Group[0].Length * ($d.Count - 1)
        $out.Add([pscustomobject]@{
            Octets    = $wasted
            Gaspille  = Format-Size $wasted
            Copies    = $d.Count
            Taille    = Format-Size $d.Group[0].Length
            Fichiers  = ($d.Group | ForEach-Object { $_.Path })
        })
    }
    return $out | Sort-Object Octets -Descending
}

function Get-ForgottenFiles {
    param([string]$Path, [int]$Months = 12, [int]$MinSizeMB = 50, [int]$Top = 25)
    Write-Host "  Fichiers > $MinSizeMB Mo non modifies depuis $Months mois ..." -ForegroundColor DarkGray
    $cutoff = (Get-Date).AddMonths(-$Months)
    Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff -and $_.Length -ge ($MinSizeMB * 1MB) } |
        Sort-Object Length -Descending |
        Select-Object -First $Top |
        ForEach-Object {
            [pscustomobject]@{
                Taille  = Format-Size $_.Length
                Modifie = $_.LastWriteTime.ToString('yyyy-MM-dd')
                Fichier = $_.FullName
            }
        }
}

function Invoke-AnalyzeModule {
    Show-DiskOverview

    Write-Title 'Analyse de l''espace'
    Write-Host "  Ce module ne supprime rien : il te montre ou part le disque."
    Write-Host ""
    Write-Host "  1  Plus gros fichiers"
    Write-Host "  2  Plus gros dossiers"
    Write-Host "  3  Doublons"
    Write-Host "  4  Fichiers oublies (gros et vieux)"
    Write-Host "  q  Retour"
    $c = Read-Choice -Prompt '  Choix' -Default 'q'
    if ($c -eq 'q') { return }

    $default = $env:USERPROFILE
    $path = Read-Choice -Prompt '  Dossier a analyser' -Default $default
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host "  Chemin introuvable : $path" -ForegroundColor Red
        return
    }

    switch ($c) {
        '1' { Get-BigFiles   -Path $path -Top 20 | Format-Table -AutoSize | Out-Host }
        '2' { Get-BigFolders -Path $path -Top 20 | Format-Table -AutoSize | Out-Host }
        '3' {
            $d = Get-DuplicateFiles -Path $path -MinSizeMB 1
            if (-not $d -or $d.Count -eq 0) {
                Write-Host "  Aucun doublon trouve." -ForegroundColor Green
            } else {
                $waste = ($d | Measure-Object Octets -Sum).Sum
                Write-Host ""
                Write-Host ("  {0} groupes de doublons, {1} gaspilles." -f $d.Count, (Format-Size $waste)) -ForegroundColor Yellow
                foreach ($g in ($d | Select-Object -First 15)) {
                    Write-Host ""
                    Write-Host ("  {0} copies x {1}  ->  {2} gaspilles" -f $g.Copies, $g.Taille, $g.Gaspille) -ForegroundColor Cyan
                    foreach ($f in $g.Fichiers) { Write-Host "     $f" -ForegroundColor DarkGray }
                }
                Write-Host ""
                Write-Host "  A toi de choisir quelle copie garder : je ne devine pas laquelle compte." -ForegroundColor DarkYellow
            }
        }
        '4' { Get-ForgottenFiles -Path $path | Format-Table -AutoSize | Out-Host }
    }
}


# ---------------------------------------------------------------------------
# Module 3 : Gestion du demarrage
# ---------------------------------------------------------------------------

$script:RunKeys = @(
    @{ Hive = 'HKCU'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';                 Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' }
    @{ Hive = 'HKLM'; Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run';                 Approved = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' }
    @{ Hive = 'HKLM'; Path = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run';     Approved = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32' }
)

function Test-StartupEnabled {
    # Windows stocke l'etat active/desactive dans StartupApproved, comme le
    # Gestionnaire des taches. Premier octet : 2 = active, 3 = desactive.
    param([string]$ApprovedKey, [string]$Name)
    try {
        $v = Get-ItemProperty -Path $ApprovedKey -Name $Name -ErrorAction Stop
        $bytes = $v.$Name
        if ($bytes -is [byte[]] -and $bytes.Length -gt 0) {
            return (($bytes[0] -band 1) -eq 0)
        }
    } catch { }
    return $true
}

function Set-StartupState {
    param([string]$ApprovedKey, [string]$Name, [bool]$Enabled)
    if (-not (Test-Path $ApprovedKey)) { New-Item -Path $ApprovedKey -Force | Out-Null }
    $bytes = New-Object byte[] 12
    if ($Enabled) {
        $bytes[0] = 2
    } else {
        $bytes[0] = 3
        $ft = [BitConverter]::GetBytes((Get-Date).ToFileTime())
        [Array]::Copy($ft, 0, $bytes, 4, 8)
    }
    New-ItemProperty -Path $ApprovedKey -Name $Name -Value $bytes -PropertyType Binary -Force | Out-Null
}

function Get-StartupEntries {
    $out = New-Object System.Collections.Generic.List[object]

    foreach ($k in $script:RunKeys) {
        if (-not (Test-Path $k.Path)) { continue }
        $props = Get-Item -Path $k.Path -ErrorAction SilentlyContinue
        if (-not $props) { continue }
        foreach ($name in $props.GetValueNames()) {
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            $cmd = $props.GetValue($name)
            $out.Add([pscustomobject]@{
                Nom      = $name
                Source   = "Registre $($k.Hive)"
                Actif    = Test-StartupEnabled -ApprovedKey $k.Approved -Name $name
                Commande = $cmd
                Type     = 'Registry'
                Key      = $k.Path
                Approved = $k.Approved
            })
        }
    }

    $folders = @(
        @{ Path = [Environment]::GetFolderPath('Startup');       Label = 'Dossier Demarrage (moi)' },
        @{ Path = [Environment]::GetFolderPath('CommonStartup'); Label = 'Dossier Demarrage (tous)' }
    )
    $approvedFolder = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'
    foreach ($f in $folders) {
        if (-not $f.Path -or -not (Test-Path -LiteralPath $f.Path)) { continue }
        Get-ChildItem -LiteralPath $f.Path -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'desktop.ini' } | ForEach-Object {
                $out.Add([pscustomobject]@{
                    Nom      = $_.BaseName
                    Source   = $f.Label
                    Actif    = Test-StartupEnabled -ApprovedKey $approvedFolder -Name $_.Name
                    Commande = $_.FullName
                    Type     = 'Folder'
                    Key      = $_.FullName
                    Approved = $approvedFolder
                    FileName = $_.Name
                })
            }
    }

    try {
        Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
            $_.Triggers.CimClass.CimClassName -contains 'MSFT_TaskLogonTrigger' -or
            $_.Triggers.CimClass.CimClassName -contains 'MSFT_TaskBootTrigger'
        } | Where-Object { $_.TaskPath -notlike '\Microsoft\*' } | ForEach-Object {
            $exec = ($_.Actions | Where-Object { $_.Execute } | Select-Object -First 1).Execute
            $out.Add([pscustomobject]@{
                Nom      = $_.TaskName
                Source   = 'Tache planifiee'
                Actif    = ($_.State -ne 'Disabled')
                Commande = $exec
                Type     = 'Task'
                Key      = $_.TaskPath + $_.TaskName
                TaskName = $_.TaskName
                TaskPath = $_.TaskPath
            })
        }
    } catch { }

    return $out
}

function Invoke-StartupModule {
    Write-Title 'Programmes lances au demarrage'
    $entries = @(Get-StartupEntries)
    if ($entries.Count -eq 0) {
        Write-Host "  Rien au demarrage." -ForegroundColor Green
        return
    }

    $i = 0
    $rows = foreach ($e in $entries) {
        $i++
        $etat = 'actif'
        if (-not $e.Actif) { $etat = 'desactive' }
        [pscustomobject]@{
            '#'     = $i
            'Etat'  = $etat
            'Nom'   = $e.Nom
            'Source'= $e.Source
        }
    }
    $rows | Format-Table -AutoSize | Out-Host

    Write-Host "  d <n> = desactiver    a <n> = activer    i <n> = voir la commande    q = retour"
    $c = Read-Choice -Prompt '  Action' -Default 'q'
    if ($c -match '^[qQ]$') { return }

    if ($c -notmatch '^([daiDAI])\s*(\d+)$') {
        Write-Host "  Commande non comprise." -ForegroundColor Red
        return
    }
    $verb = $Matches[1].ToLower()
    $n = [int]$Matches[2]
    if ($n -lt 1 -or $n -gt $entries.Count) {
        Write-Host "  Numero hors liste." -ForegroundColor Red
        return
    }
    $e = $entries[$n - 1]

    if ($verb -eq 'i') {
        Write-Host ""
        Write-Host ("  Nom      : {0}" -f $e.Nom)
        Write-Host ("  Source   : {0}" -f $e.Source)
        Write-Host ("  Commande : {0}" -f $e.Commande)
        Write-Host ("  Cle      : {0}" -f $e.Key) -ForegroundColor DarkGray
        return
    }

    $enable = ($verb -eq 'a')
    $label = 'Desactivation'
    if ($enable) { $label = 'Activation' }

    if ($e.Type -eq 'Registry' -and $e.Source -like '*HKLM*' -and -not (Test-Admin)) {
        Write-Host "  Cette entree est systeme (HKLM) : il faut un PowerShell admin." -ForegroundColor Yellow
        return
    }

    try {
        switch ($e.Type) {
            'Registry' { Set-StartupState -ApprovedKey $e.Approved -Name $e.Nom -Enabled $enable }
            'Folder'   { Set-StartupState -ApprovedKey $e.Approved -Name $e.FileName -Enabled $enable }
            'Task'     {
                if ($enable) { Enable-ScheduledTask -TaskName $e.TaskName -TaskPath $e.TaskPath | Out-Null }
                else         { Disable-ScheduledTask -TaskName $e.TaskName -TaskPath $e.TaskPath | Out-Null }
            }
        }
        Write-Host ("  {0} de '{1}' : ok" -f $label, $e.Nom) -ForegroundColor Green
        Write-Host "  Reversible a tout moment ici ou dans le Gestionnaire des taches." -ForegroundColor DarkGray
        Write-Log ("$label demarrage '{0}' ({1})" -f $e.Nom, $e.Source)
    } catch {
        Write-Host ("  Echec : {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
}


# ---------------------------------------------------------------------------
# Module 4 : Desinstallation propre
# ---------------------------------------------------------------------------

function Get-InstalledPrograms {
    $keys = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($k in $keys) {
        Get-ItemProperty -Path $k -ErrorAction SilentlyContinue | ForEach-Object {
            if ([string]::IsNullOrWhiteSpace($_.DisplayName)) { return }
            if ($_.SystemComponent -eq 1) { return }
            if ($_.ParentKeyName) { return }
            $date = $null
            if ($_.InstallDate -match '^\d{8}$') {
                try { $date = [datetime]::ParseExact($_.InstallDate, 'yyyyMMdd', $null) } catch { }
            }
            $out.Add([pscustomobject]@{
                Nom       = $_.DisplayName
                Version   = $_.DisplayVersion
                Editeur   = $_.Publisher
                Installe  = $date
                TailleKo  = $_.EstimatedSize
                Uninstall = $_.UninstallString
                Quiet     = $_.QuietUninstallString
                Location  = $_.InstallLocation
                RegKey    = $_.PSPath
            })
        }
    }
    return $out | Sort-Object Nom -Unique
}

function Get-Leftovers {
    param([object]$Program)

    # On cherche des dossiers/cles dont le nom colle au programme ou a son
    # editeur. Volontairement conservateur : mieux vaut rater un reste que
    # proposer d'effacer les donnees d'un autre logiciel.
    $needles = New-Object System.Collections.Generic.List[string]
    $clean = ($Program.Nom -replace '[\d\.\(\)]', '' -replace '\s+', ' ').Trim()
    if ($clean.Length -ge 4) { $needles.Add($clean) }
    if ($Program.Editeur -and $Program.Editeur.Length -ge 4) { $needles.Add($Program.Editeur.Trim()) }

    $roots = @(
        $env:LOCALAPPDATA,
        $env:APPDATA,
        $env:ProgramData,
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)}
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

    $found = New-Object System.Collections.Generic.List[object]
    foreach ($root in $roots) {
        Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $dir = $_
            foreach ($needle in $needles) {
                if ($dir.Name -like "*$needle*" -or $needle -like "*$($dir.Name)*") {
                    $size = Get-PathSize -Path $dir.FullName
                    $found.Add([pscustomobject]@{
                        Type   = 'Dossier'
                        Octets = $size
                        Taille = Format-Size $size
                        Cible  = $dir.FullName
                    })
                    break
                }
            }
        }
    }

    foreach ($hive in @('HKCU:\Software', 'HKLM:\Software')) {
        Get-ChildItem -Path $hive -ErrorAction SilentlyContinue | ForEach-Object {
            $key = $_
            foreach ($needle in $needles) {
                if ($key.PSChildName -like "*$needle*") {
                    $found.Add([pscustomobject]@{
                        Type   = 'Cle registre'
                        Octets = 0
                        Taille = '-'
                        Cible  = $key.Name
                    })
                    break
                }
            }
        }
    }

    return $found | Sort-Object Cible -Unique
}

function Invoke-UninstallModule {
    Write-Title 'Programmes installes'
    $progs = @(Get-InstalledPrograms)
    Write-Host ("  {0} programmes trouves." -f $progs.Count) -ForegroundColor DarkGray

    $filter = Read-Choice -Prompt '  Filtrer par nom (Entree = tout)' -Default ''
    $list = $progs
    if ($filter) { $list = @($progs | Where-Object { $_.Nom -like "*$filter*" }) }
    if ($list.Count -eq 0) {
        Write-Host "  Aucun programme ne correspond." -ForegroundColor Yellow
        return
    }

    $i = 0
    $rows = foreach ($p in $list) {
        $i++
        $taille = '-'
        if ($p.TailleKo) { $taille = Format-Size ($p.TailleKo * 1KB) }
        $inst = '-'
        if ($p.Installe) { $inst = $p.Installe.ToString('yyyy-MM-dd') }
        [pscustomobject]@{
            '#'        = $i
            'Nom'      = $p.Nom
            'Version'  = $p.Version
            'Taille'   = $taille
            'Installe' = $inst
        }
    }
    $rows | Format-Table -AutoSize | Out-Host

    $c = Read-Choice -Prompt '  Numero a desinstaller (q = retour)' -Default 'q'
    if ($c -match '^[qQ]$') { return }
    if ($c -notmatch '^\d+$') { Write-Host "  Entree invalide." -ForegroundColor Red; return }
    $n = [int]$c
    if ($n -lt 1 -or $n -gt $list.Count) { Write-Host "  Numero hors liste." -ForegroundColor Red; return }
    $p = $list[$n - 1]

    Write-Host ""
    Write-Host ("  {0}  {1}" -f $p.Nom, $p.Version) -ForegroundColor Cyan
    Write-Host ("  Editeur   : {0}" -f $p.Editeur)
    Write-Host ("  Emplacement: {0}" -f $p.Location)
    Write-Host ("  Commande  : {0}" -f $(if ($p.Quiet) { $p.Quiet } else { $p.Uninstall })) -ForegroundColor DarkGray

    if (-not $p.Uninstall -and -not $p.Quiet) {
        Write-Host "  Ce programme ne declare pas de desinstalleur. A retirer via Parametres > Applications." -ForegroundColor Yellow
        return
    }

    $go = Read-Choice -Prompt '  Lancer le desinstalleur ? (o/n)' -Default 'n'
    if ($go -notmatch '^[oOyY]') { Write-Host "  Annule." -ForegroundColor DarkGray; return }

    $cmd = $p.Uninstall
    if ($p.Quiet) { $cmd = $p.Quiet }
    Write-Host "  Desinstalleur lance. Suis ses fenetres, puis reviens ici." -ForegroundColor Cyan
    Write-Log ("Desinstallation lancee : {0}" -f $p.Nom)
    try {
        Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $cmd -Wait
    } catch {
        Write-Host ("  Echec du lancement : {0}" -f $_.Exception.Message) -ForegroundColor Red
        return
    }

    Write-Host ""
    Write-Host "  Recherche des restes ..." -ForegroundColor DarkGray
    $left = @(Get-Leftovers -Program $p)
    if ($left.Count -eq 0) {
        Write-Host "  Aucun reste detecte. Propre." -ForegroundColor Green
        return
    }

    Write-Host ""
    Write-Host "  Restes possibles :" -ForegroundColor Yellow
    $j = 0
    foreach ($l in $left) {
        $j++
        Write-Host ("   {0,2}. [{1}] {2}  {3}" -f $j, $l.Type, $l.Cible, $l.Taille)
    }
    Write-Host ""
    Write-Host "  Attention : la detection se fait sur le nom. Verifie chaque ligne -" -ForegroundColor DarkYellow
    Write-Host "  un dossier peut contenir tes propres donnees (profils, licences, projets)." -ForegroundColor DarkYellow
    Write-Host ""
    $sel = Read-Choice -Prompt '  Numeros a supprimer (ex: 1,3) ou q' -Default 'q'
    if ($sel -match '^[qQ]$') { Write-Host "  Rien supprime." -ForegroundColor DarkGray; return }

    $targets = @()
    foreach ($x in ($sel -split '[,\s]+' | Where-Object { $_ -match '^\d+$' })) {
        $xi = [int]$x
        if ($xi -ge 1 -and $xi -le $left.Count) { $targets += $left[$xi - 1] }
    }
    if ($targets.Count -eq 0) { Write-Host "  Selection vide." -ForegroundColor DarkGray; return }

    Write-Host ""
    foreach ($t in $targets) { Write-Host ("    {0}" -f $t.Cible) }
    if (-not (Confirm-Destructive -Prompt '  Suppression definitive des elements ci-dessus.')) {
        Write-Host "  Annule." -ForegroundColor DarkGray
        return
    }

    foreach ($t in $targets) {
        try {
            if ($t.Type -eq 'Dossier') {
                Remove-Item -LiteralPath $t.Cible -Recurse -Force -ErrorAction Stop
            } else {
                $ps = $t.Cible -replace '^HKEY_CURRENT_USER', 'HKCU:' -replace '^HKEY_LOCAL_MACHINE', 'HKLM:'
                Remove-Item -Path $ps -Recurse -Force -ErrorAction Stop
            }
            Write-Host ("  Supprime : {0}" -f $t.Cible) -ForegroundColor Green
            Write-Log ("Reste supprime : {0}" -f $t.Cible)
        } catch {
            Write-Host ("  Echec : {0} - {1}" -f $t.Cible, $_.Exception.Message) -ForegroundColor Red
        }
    }
}


# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------

function Show-Banner {
    $admin = 'session standard'
    if (Test-Admin) { $admin = 'session administrateur' }
    Write-Host ""
    Write-Host "  WinClean" -ForegroundColor Cyan -NoNewline
    Write-Host "  -  nettoyage et entretien Windows  ($admin)" -ForegroundColor DarkGray
}

function Show-Menu {
    Write-Host ""
    Write-Host "  1  Nettoyage disque        temporaires, caches, corbeille, logs"
    Write-Host "  2  Analyse de l'espace     gros fichiers, doublons, oublis      (lecture seule)"
    Write-Host "  3  Gestion du demarrage    voir et desactiver ce qui se lance au boot"
    Write-Host "  4  Desinstallation         programmes + restes"
    Write-Host "  q  Quitter"
    Write-Host ""
}

function Start-WinClean {
    Show-Banner
    if (-not (Test-Admin)) {
        Write-Host "  Astuce : certaines cibles systeme demandent un PowerShell admin." -ForegroundColor DarkYellow
    }
    while ($true) {
        Show-Menu
        $c = Read-Choice -Prompt '  Choix' -Default 'q'
        switch ($c) {
            '1' { Invoke-CleanupModule }
            '2' { Invoke-AnalyzeModule }
            '3' { Invoke-StartupModule }
            '4' { Invoke-UninstallModule }
            default { Write-Host "  A bientot."; return }
        }
    }
}

# Sourcer le fichier ('. .\WinClean.ps1') charge les fonctions sans rien lancer.
if ($MyInvocation.InvocationName -ne '.') {
    if ($Module) {
        Show-Banner
        switch ($Module) {
            'Nettoyage'      { Invoke-CleanupModule }
            'Analyse'        { Invoke-AnalyzeModule }
            'Demarrage'      { Invoke-StartupModule }
            'Desinstallation'{ Invoke-UninstallModule }
        }
    } else {
        Start-WinClean
    }
}
