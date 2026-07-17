---
name: winclean
description: Nettoyer et entretenir un PC Windows - libérer de l'espace disque (fichiers temporaires, caches navigateurs et dev, corbeille, cache Windows Update, logs), analyser où part le disque (gros fichiers, gros dossiers, doublons, fichiers oubliés), gérer les programmes qui se lancent au démarrage, et désinstaller proprement un logiciel avec ses restes. Un équivalent de CleanMyMac pour Windows. Utiliser ce skill quand l'utilisateur dit "nettoyer mon PC", "libérer de l'espace", "mon disque est plein", "disque C plein", "vider les caches", "supprimer les temporaires", "mon PC est lent au démarrage", "qu'est-ce qui se lance au boot", "désactiver le démarrage automatique", "désinstaller proprement", "trouver les doublons", "quels sont mes plus gros fichiers", "CleanMyMac pour Windows", "clean my pc", "free up disk space", "startup programs". Windows uniquement (PowerShell 5.1+).
---

# WinClean

Entretien d'un poste Windows en quatre modules, via `scripts/WinClean.ps1`.

## Principe non négociable

**Rien n'est supprimé sans scan préalable, rapport chiffré et confirmation explicite de l'utilisateur.**

Le script est construit pour ça, mais c'est ton comportement qui compte : n'exécute jamais une suppression que l'utilisateur n'a pas explicitement demandée après avoir vu les chiffres. Quand il demande « nettoie mon PC », il demande un **scan** — présente le résultat, puis attends son feu vert.

## Utilisation

Le script est interactif (menus, `Read-Host`). Selon la situation :

**L'utilisateur veut piloter lui-même** — donne-lui la commande, c'est le plus confortable :

```powershell
cd <chemin>\winclean
.\scripts\WinClean.ps1                       # menu principal
.\scripts\WinClean.ps1 -Module Nettoyage     # direct sur un module
```

Modules : `Nettoyage`, `Analyse`, `Demarrage`, `Desinstallation`.

**Tu pilotes pour lui** — les menus interactifs ne se scriptent pas depuis un outil non-interactif. Source le fichier pour charger les fonctions sans lancer le menu, puis appelle-les :

```powershell
. .\scripts\WinClean.ps1     # le point est significatif : charge sans exécuter

Invoke-CleanupScan | Where-Object { $_.Octets -gt 0 } | Format-Table Nom, Taille, Niveau
Get-StartupEntries | Format-Table Nom, Source, Actif
Get-InstalledPrograms | Sort-Object TailleKo -Descending | Select-Object -First 20 Nom, Version
Show-DiskOverview
Get-BigFiles -Path $env:USERPROFILE -Top 20
Get-BigFolders -Path $env:USERPROFILE -Top 20
Get-DuplicateFiles -Path $env:USERPROFILE -MinSizeMB 1
Get-ForgottenFiles -Path $env:USERPROFILE -Months 12 -MinSizeMB 50
```

Toutes ces fonctions sont en **lecture seule** — sûres à lancer sans rien demander.
Puis présente le tableau et laisse l'utilisateur lancer `.\scripts\WinClean.ps1 -Module Nettoyage` pour la partie destructive.

## Les quatre modules

### 1. Nettoyage disque

Scanne ~16 cibles, les classe par taille, affiche un total et le détail. Deux niveaux :

- **Sûr** — se régénère tout seul, aucune perte : temporaires utilisateur et Windows, cache Windows Update, Delivery Optimization, rapports d'erreurs (WER), miniatures et icônes, caches Chrome / Edge / Firefox, caches npm / pip / Yarn / pnpm.
- **Prudent** — à regarder avant : corbeille (irréversible), Prefetch (démarrages plus lents quelques jours), logs Windows CBS/DISM, cache NuGet (à garder si build hors-ligne).

Les caches navigateurs ne touchent **ni mots de passe, ni historique, ni favoris** — uniquement `Cache`, `Code Cache`, `GPUCache`. Dire à l'utilisateur de fermer le navigateur concerné avant, sinon les fichiers verrouillés survivent (le script le signale et compte l'écart).

Le nettoyage **vide le contenu** des dossiers cibles sans supprimer le dossier lui-même : certains services rouspètent si leur dossier disparaît.

### 2. Analyse de l'espace — lecture seule, ne supprime jamais

Vue des volumes, plus gros fichiers, plus gros dossiers, doublons (SHA256, groupés par taille d'abord pour ne pas hasher tout le disque), fichiers volumineux non modifiés depuis N mois.

Pour les doublons, le script **ne choisit pas** quelle copie garder et ne propose pas de suppression. C'est délibéré : lui seul sait laquelle compte.

### 3. Gestion du démarrage

Liste les clés `Run` (HKCU, HKLM, WOW6432Node), les dossiers Démarrage, et les tâches planifiées déclenchées à l'ouverture de session (hors `\Microsoft\*`).

L'activation/désactivation passe par `StartupApproved` — **le mécanisme exact du Gestionnaire des tâches** (premier octet : `2` = actif, `3` = désactivé + horodatage). Conséquence utile à dire à l'utilisateur : c'est **réversible**, ici comme dans le Gestionnaire des tâches, et les deux restent cohérents.

Les tâches planifiées passent par `Enable-ScheduledTask` / `Disable-ScheduledTask`.

### 4. Désinstallation

Énumère les programmes depuis le registre (HKLM 64/32 bits, HKCU), filtre les composants système et les entrées enfants. Lance le désinstalleur officiel (`QuietUninstallString` si dispo, sinon `UninstallString`), attend sa fin, puis cherche les restes.

**La détection des restes se fait sur le nom du programme et de l'éditeur.** C'est faillible par construction — un dossier peut contenir les données de l'utilisateur (profils, licences, projets). Le script liste chaque chemin, exige une sélection puis le mot `SUPPRIMER`. Ne shunte jamais cette étape et ne suggère pas « supprime tout ».

## Droits administrateur

Sans admin, les cibles système sont **silencieusement ignorées du scan** (temporaires Windows, cache Windows Update, Delivery Optimization, Prefetch, logs CBS/DISM), et les entrées de démarrage HKLM ne sont pas modifiables. Le script l'annonce au lancement.

Si l'utilisateur veut ces cibles, lui faire relancer PowerShell en administrateur. Ça vaut typiquement 1 à 5 Go de plus (le cache Windows Update est souvent le plus gros poste d'un disque saturé).

## Journal

Toute suppression est journalisée dans `logs/winclean-AAAA-MM-JJ.log` à côté du script. Les scans ne sont pas journalisés.

## Limites connues

- Windows uniquement, PowerShell 5.1 ou plus (testé sur Windows 11 / PS 5.1).
- Les fichiers verrouillés par un processus en cours ne sont pas supprimés — le script le signale plutôt que de forcer.
- Le nettoyage WinSxS / `Windows.old` (souvent plusieurs Go) n'est pas couvert : il relève de `DISM /Online /Cleanup-Image /StartComponentCleanup` et du Nettoyage de disque Windows. À mentionner si le disque est vraiment saturé.
- La désinstallation ne couvre pas les applications du Microsoft Store (paquets APPX), seulement les programmes classiques du registre.
