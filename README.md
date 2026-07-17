# WinClean

Un équivalent de CleanMyMac pour Windows, en PowerShell. Sans installateur, sans service en tâche de fond, sans abonnement — un seul script que vous pouvez lire en entier avant de le lancer.

Utilisable **à la main** dans un terminal, ou **comme skill** pour Claude Code.

> **Rien n'est supprimé sans un scan préalable, un rapport chiffré et une confirmation explicite.**
> Les suppressions demandent de taper `SUPPRIMER` en toutes lettres — pas un `y/n` distrait.

## Les quatre modules

| Module | Ce qu'il fait |
|---|---|
| **Nettoyage disque** | Temporaires, cache Windows Update, corbeille, miniatures, logs, caches Chrome/Edge/Firefox, caches npm/pip/Yarn/pnpm |
| **Analyse de l'espace** | Plus gros fichiers et dossiers, doublons (SHA256), fichiers volumineux oubliés — **lecture seule** |
| **Gestion du démarrage** | Ce qui se lance au boot (registre, dossiers Démarrage, tâches planifiées), activable/désactivable |
| **Désinstallation** | Programmes installés + détection des restes (dossiers AppData/ProgramData, clés de registre) |

## Installation

```powershell
git clone https://github.com/teufsk8-dev/winclean.git
cd winclean
.\scripts\WinClean.ps1
```

Si Windows bloque l'exécution :

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

Ça n'autorise le script que pour cette fenêtre de terminal, et ne change rien à la configuration de la machine.

### Comme skill Claude Code

Clonez dans votre dossier de skills, puis demandez simplement « nettoie mon PC » ou « qu'est-ce qui se lance au démarrage ? » :

```powershell
git clone https://github.com/teufsk8-dev/winclean.git $env:USERPROFILE\.claude\skills\winclean
```

## Utilisation

```powershell
.\scripts\WinClean.ps1                        # menu principal
.\scripts\WinClean.ps1 -Module Nettoyage      # Nettoyage | Analyse | Demarrage | Desinstallation
```

Le module **Nettoyage** scanne, chiffre, puis attend :

```
Nom                                Taille     Niveau
---                                ------     ------
Fichiers temporaires (utilisateur) 1,84 Go    Sur
Cache npm                          1 016,1 Mo Sur
Corbeille                          918,9 Mo   Prudent
Cache Edge                         619,7 Mo   Sur
Cache Chrome                       480,0 Mo   Sur
Cache miniatures et icones         138,7 Mo   Sur

Recuperable au total : 5,03 Go   dont 4,13 Go en cibles 'Sur'

s = toutes les cibles 'Sur'    t = tout    1,3,5 = selection    q = annuler
```

## Automatisation

Pour un nettoyage chaque soir, sans surveillance :

```powershell
.\scripts\WinClean.ps1 -InstallTask -At 20:00   # tâche quotidienne à 20h
.\scripts\WinClean.ps1 -RemoveTask              # pour la retirer
```

La tâche ne nettoie **que les cibles Sûres** — jamais la corbeille, jamais les cibles Prudentes. Droits standard, journalisée dans `logs/`. Si le PC est éteint à l'heure dite, elle se rattrape au démarrage suivant.

Une exclusion est câblée par défaut : **`%TEMP%\claude`**, le bac à sable de Claude Code. Bien qu'il soit dans les fichiers temporaires, il peut contenir des rendus ou médias sans copie ailleurs — l'automatisation n'y touche jamais.

## Sûr / Prudent

Chaque cible porte un niveau, et le raccourci `s` ne nettoie que les cibles **Sûr**.

- **Sûr** — se régénère tout seul, aucune perte. Les caches navigateurs ne touchent **ni mots de passe, ni historique, ni favoris** : uniquement `Cache`, `Code Cache`, `GPUCache`. Fermez le navigateur avant, sinon les fichiers verrouillés survivent (le script le signale).
- **Prudent** — à regarder avant : corbeille (irréversible), Prefetch (démarrages un peu plus lents quelques jours), logs CBS/DISM, cache NuGet (à garder si vous compilez hors-ligne).

## Droits administrateur

Sans admin, les cibles système sont ignorées du scan (temporaires Windows, cache Windows Update, Delivery Optimization, Prefetch, logs). Le script l'annonce au lancement. Un PowerShell administrateur vaut souvent 1 à 5 Go de plus — le cache Windows Update est régulièrement le premier poste d'un disque saturé.

## Réversibilité

- **Démarrage** — passe par `StartupApproved`, le mécanisme exact du Gestionnaire des tâches. Réversible depuis WinClean comme depuis le Gestionnaire des tâches, et les deux restent cohérents.
- **Nettoyage** — irréversible par nature (ce sont des suppressions), d'où le scan et la confirmation.
- **Restes de désinstallation** — la détection se fait sur le nom du programme et de l'éditeur, donc faillible par construction. Chaque chemin est affiché, la sélection est manuelle. Lisez la liste : un dossier peut contenir vos données.

Toute suppression est journalisée dans `logs/winclean-AAAA-MM-JJ.log`.

## Tests

```powershell
.\tests\Test-WinClean.ps1
```

24 assertions dans un bac à sable temporaire — aucune donnée réelle n'est touchée. La suite vérifie notamment que le nettoyage vide un dossier sans le supprimer, qu'une suppression filtrée épargne les fichiers hors périmètre, que les caches des profils Chrome partent **sans que `Login Data` soit touché**, qu'un fichier verrouillé est compté et non forcé, et que la bascule `StartupApproved` fait bien l'aller-retour.

## Limites connues

- Windows uniquement, PowerShell 5.1+ (testé sur Windows 11 / PS 5.1).
- Les fichiers verrouillés par un processus ne sont pas supprimés — le script le signale plutôt que de forcer.
- WinSxS et `Windows.old` ne sont pas couverts : voir `DISM /Online /Cleanup-Image /StartComponentCleanup` et le Nettoyage de disque Windows.
- La désinstallation ne couvre pas les applications du Microsoft Store (APPX), seulement les programmes classiques du registre.
- Le module Analyse peut être lent sur un profil volumineux : la recherche de doublons hashe les fichiers de même taille.

## Licence

MIT — voir [LICENSE](LICENSE).
