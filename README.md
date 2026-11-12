# BJMPC Toolbox

🇫🇷 [Français](#-français) · 🇬🇧 [English](#-english)

> **Version 2.1** · Windows 11 · Windows PowerShell 5.1 (WPF) · by **BJMPC Informatique**

---

## 🇫🇷 Français

### Qu'est-ce que c'est ?

**BJMPC Toolbox** est une boîte à outils graphique pour **diagnostiquer, réparer, sauvegarder, mettre à jour et optimiser Windows 11**. Elle est pensée pour un technicien qui intervient chez des clients : tout se fait avec des **boutons, des listes déroulantes et des cases à cocher** (aucune question à taper), et **chaque modification est réversible**.

Elle est écrite en Windows PowerShell 5.1 (interface WPF), sans installation : on lance, on travaille, on ferme.

### Nouveautés de la version 2

- **Interface plus simple** : 6 sections au lieu de 14 pages, chacune avec ses onglets.
- **Réparation automatique** : la Toolbox lit l'Observateur d'événements, explique chaque erreur en clair et lance la réparation adaptée quand il en existe une. Surveillance en direct des nouvelles erreurs.
- **Sauvegarde automatique des fichiers du client** vers un autre disque, à la demande ou planifiée.
- **Optimisations dépassées retirées** : Nagle, priorités MMCSS, SysMain désactivé, services « inutiles », Win32PrioritySeparation, compression mémoire, désactivation de HVCI… Elles n'apportent rien de mesurable sur Windows 11 aujourd'hui, ou retirent une protection.
- **Pilotes revus en profondeur** : entre deux familles de pilotes d'une même puce, c'est la date qui départage (comme le fait Windows), plus le seul numéro de version ; retour arrière réel après une mise à jour.

Le détail, version par version, est dans [`LISEZMOI.txt`](LISEZMOI.txt).

### ⚠️ Statut : mature mais expérimental

- **Mature** : l'outil est utilisé en conditions réelles, chaque fonction est contrôlée (autotest, points de restauration, sauvegardes avant modification, journal).
- **Expérimental** : il agit sur le système (services, registre, pilotes, stratégies). Windows évolue, les configurations matérielles sont infinies, et certaines fonctions (recherche de pilotes sur le Windows Update, valeurs par défaut de Windows 11) reposent sur des sources ou des valeurs qui peuvent varier selon l'édition, la version ou le moment.
- **Nouveautés 2.x encore peu éprouvées sur le terrain** : la tâche planifiée de sauvegarde automatique, la mise à jour puis la restauration d'un pilote, et les réparations lancées depuis l'Observateur d'événements ont été testées hors ligne ou en simulation, pas encore sur un grand nombre de PC. Essayez-les d'abord sur une machine non critique.
- **Utilisez-le en connaissance de cause** : créez un point de restauration (l'outil le fait pour vous avant les opérations sensibles) et relisez les listes avant de cliquer. Aucune garantie n'est fournie ; vous restez responsable de vos machines.

### Lancer l'outil

1. Téléchargez tout le dossier (les fichiers vont ensemble, ne les séparez pas).
2. Double-clic sur **`BJMPC-Toolbox.bat`** : la demande d'administrateur s'affiche, puis la fenêtre s'ouvre.
3. Facultatif : `Verif.bat` lance un **autotest en lecture seule** (construit chaque page, vérifie chaque bouton) ; `Apercu.bat` montre l'aperçu du résumé client.

Prérequis : Windows 11, droits administrateur, Windows PowerShell 5.1 (inclus dans Windows). Certaines fonctions ont besoin d'Internet (pilotes, winget).

### Contenu du dossier

| Fichier | Rôle |
|---|---|
| `BJMPC-Toolbox.ps1` | L'application (fenêtre) |
| `BJMPC-Evenements-Win11.ps1` | Réparation guidée par l'Observateur d'événements, surveillance en direct |
| `BJMPC-Sauvegarde-Win11.ps1` | Sauvegarde des fichiers du client, à la demande et automatique |
| `BJMPC-Optimisation-Win11.ps1` | Moteur jeux / réseau / disque / écran (utilisable seul en console) |
| `BJMPC-Reglages-Win11.ps1` | Catalogue de réglages Windows (confidentialité, interface, mises à jour…) |
| `BJMPC-Maintenance-Win11.ps1` | Moteur maintenance et réparation (utilisable seul en console) |
| `BJMPC-Outils-Win11.ps1` | Diagnostics, dépannage, pilotes, catalogue winget, nettoyage, retour aux valeurs Windows |
| `BJMPC-Toolbox.bat` | Lanceur (demande l'élévation administrateur) |
| `Verif.bat` / `Apercu.bat` | Autotest en lecture seule / aperçu du résumé client |

### Les six sections

| Section | Onglets |
|---|---|
| **Accueil** | Vue d'ensemble · Résumé pour le client |
| **Réparer** | Réparation automatique · Réparer Windows · Nettoyage et dépannage · Registre · Diagnostics |
| **Optimiser** | Jeux et alimentation · Réseau et DNS · Disque et démarrage · Affichage et OLED |
| **Confidentialité et réglages** | Confidentialité · Interface et Explorateur · Mises à jour et sécurité |
| **Logiciels et pilotes** | Applications · Pilotes |
| **Sauvegarde et restauration** | Sauvegarde des fichiers · Restauration |

- **Accueil** : ce qui est en ordre sur ce PC et où agir pour le reste (sauvegarde récente, point de restauration, place libre, santé des disques, plantages récents…). Un bouton « Réglages recommandés » applique seulement ce qui est sûr partout. Le *résumé pour le client* raconte l'intervention en langage simple.
- **Réparation automatique** : chaque erreur de l'Observateur d'événements est rangée dans une famille.
  - *À réparer* : services arrêtés, DNS, horloge, échecs répétés de Windows Update, fichiers de Windows abîmés, erreurs de disque, index de recherche, Store, compteurs de performance, plantage du pilote graphique.
  - *À regarder* : pannes matérielles (WHEA, arrêts brutaux, surchauffe) et logiciels tiers qui plantent, avec ce qu'il faut vérifier. Aucun logiciel ne répare cela.
  - *Non reconnues* : affichées telles quelles, jamais « corrigées » au hasard.
  - *Sans gravité* : le bruit connu de Windows (DCOM 10016…).
  - Après une réparation, l'analyse suivante dit si l'erreur est revenue. La *surveillance en direct* affiche chaque nouvelle erreur en quelques secondes.
- **Réparer Windows / Nettoyage et dépannage / Diagnostics** : DISM, SFC, CHKDSK, réinitialisations, dépannage rapide, nettoyage, et des mesures en lecture seule (disques SMART, erreurs matérielles, Wi-Fi, audit de sécurité, licence…). « Nettoyage et dépannage » inclut aussi le diagnostic des imprimantes réseau mortes (TCP/IP, WSD, IPP) qui bloquent Word, Excel et l'impression, avec sauvegarde avant retrait. Il propose aussi de rétablir la lecture automatique des CD audio et DVD (réglages bloquants corrigés, lecteur au choix), annulable depuis le Journal, et un **détecteur de doublons de photos** : seules les photos au contenu identique (SHA-256 puis octet par octet) sont regroupées, jamais sur la seule taille ou la date ; en option, même image avec des métadonnées différentes (pixels comparés). Les doublons sont mis de côté dans un dossier `BJMPC-Doublons`, jamais supprimés, et se remettent en place en un clic.
- **Registre** : « Rétablir les valeurs par défaut de Windows 11 » (référence 24H2 à 26H2). Compare services, sécurité et contrôle de compte, mémoire, priorités, réseau, télémétrie et tâches planifiées à leur valeur d'origine, et détecte toute stratégie (clés *Policies*) posée par un outil d'optimisation ou un logiciel. Les écarts sont remis à la valeur standard quel que soit l'outil qui les a posés, avec point de restauration et annulation en un clic. Ce n'est pas une comparaison de tout le registre : Microsoft ne publie pas de liste complète des valeurs par défaut.
- **Optimiser** : réglages de jeu de Windows, **HAGS** (carte dédiée : état, activer, désactiver), mode d'alimentation, cartes réseau, DNS chiffré, SSD et démarrage, échelle d'affichage, protection OLED.
- **Confidentialité et réglages** : catalogue de réglages Windows à cocher.
- **Applications** : catalogue de logiciels (winget), mises à jour, inventaire, retrait des applications préinstallées.
- **Pilotes** : analyse de tous les appareils, comparée à ce que Windows Update propose pour ce matériel exact. Jamais un pilote plus ancien que celui en place, et le pilote fourni par Windows est gardé s'il est plus récent que celui du constructeur. Carte graphique : dernier pilote par l'outil officiel (NVIDIA, AMD, Intel). Appareils sans pilote : paquet chipset signé, jamais de pilote non signé. Point de restauration et sauvegarde avant, vérification de l'appareil et retrait de l'ancienne version après. Autres onglets : pilotes installés (anciennes versions), ajouter un pilote, appareils absents, sauvegardes.
- **Sauvegarde des fichiers** : deux modes. *Dossiers choisis* : dossiers personnels et favoris copiés vers un autre disque, seuls les fichiers nouveaux ou modifiés, rien n'est jamais supprimé dans la sauvegarde. *Miroir* : copie exacte du dossier utilisateur (hors AppData, OneDrive et dossiers système) ; un fichier supprimé du PC reste 30 jours dans `Miroir-Corbeille`, et un passage qui retirerait une grande partie du miroir est suspendu jusqu'à confirmation. Tâche planifiée quotidienne ou hebdomadaire, indépendante de la Toolbox.
- **Restauration** : journal des modifications (annuler tout ou une catégorie) et points de restauration.

### Sécurité et réversibilité

- Avant chaque modification, la **valeur d'origine** (registre, service, tâche, DNS, carte réseau, plan d'alimentation…) est enregistrée dans `C:\BJMPC-Logs\Backup\` ; l'onglet *Restauration* l'annule.
- **Pilotes** : seuls des pilotes signés proposés par Windows Update pour le matériel exact sont installés automatiquement, après revérification des règles (jamais plus ancien, pilote de Windows gardé s'il est plus récent). Un point de restauration et une copie du pilote en place sont faits avant ; l'ancienne version n'est retirée que si l'appareil fonctionne avec la nouvelle. « Restaurer » retire le nouveau pilote puis remet l'ancien. Un pilote ajouté depuis un dossier doit avoir une signature valide et un INF qui déclare bien l'appareil.
- **Réparations automatiques** : les réparations rapides et sans risque sont cochées d'office ; les lourdes (DISM/SFC, CHKDSK, Windows Update) se cochent à la main et ne partent jamais seules.
- **Retour aux valeurs Windows 11** : compare le PC à un Windows 11 d'origine, tableau *valeur par défaut / valeur actuelle*, cases à cocher, point de restauration puis fichier `AvantDefauts_<PC>_<date>.json` pour tout annuler. Les stratégies posées par un autre outil ou un logiciel sont listées à part et jamais cochées d'office ; rien n'est touché sur un PC en domaine.
- Jamais de désactivation de Defender, du pare-feu ou de Windows Update.
- `C:\BJMPC-Logs\` (journaux, sauvegardes de pilotes) est réservé en écriture aux administrateurs dès le premier lancement.

### Limites connues

- **Sauvegarde des fichiers** : ce sont les fichiers personnels, pas Windows ni les logiciels ; une seule version de chaque fichier est gardée ; un fichier ouvert pendant la copie est repris la fois suivante ; les mots de passe des navigateurs ne sont pas copiés.
- **Réparation automatique** : 33 règles couvrent les erreurs courantes ; le reste est montré sans réparation inventée.
- Le Windows Update est approximatif et peut limiter les requêtes : un résultat anormal est signalé « Erreur », jamais pris pour « aucun pilote ».
- La suppression « forcée » de pilotes (DriverStore Explorer) n'est volontairement pas reprise.
- Les valeurs « par défaut de Windows 11 » peuvent varier selon l'édition et la version : comparez avant d'appliquer.

### Retours

Ouvrez une *issue* en précisant la version de Windows, la version de l'outil (2.1) et, si possible, le journal de `C:\BJMPC-Logs\`.

---

## 🇬🇧 English

### What is it?

**BJMPC Toolbox** is a graphical toolbox to **diagnose, repair, back up, update and optimise Windows 11**. It is designed for a technician working on customers' PCs: everything is driven by **buttons, drop-downs and checkboxes** (nothing to type), and **every change is reversible**.

It is written in Windows PowerShell 5.1 (WPF UI) and needs no installation: launch it, work, close it.

### What's new in version 2

- **Simpler interface**: 6 sections instead of 14 pages, each with its own tabs.
- **Automatic repair**: the Toolbox reads the Event Viewer, explains each error in plain words and runs the matching repair when one exists. Live monitoring of new errors.
- **Automatic backup of the customer's files** to another disk, on demand or scheduled.
- **Outdated tweaks removed**: Nagle, MMCSS priorities, disabling SysMain, "useless" services, Win32PrioritySeparation, memory compression, disabling HVCI… They bring nothing measurable on today's Windows 11, or remove a protection.
- **Drivers reviewed in depth**: between two driver families for the same chip, the date decides (as Windows does), no longer the version number alone; a real rollback after an update.

The version-by-version detail is in [`LISEZMOI.txt`](LISEZMOI.txt) (French).

### ⚠️ Status: mature but experimental

- **Mature**: the tool is used in real-world conditions; each feature is checked (self-test, restore points, backups before changes, logs).
- **Experimental**: it changes the system (services, registry, drivers, policies). Windows keeps evolving, hardware setups are endless, and some features (driver search on the Windows Update, Windows 11 default values) rely on sources or values that can vary with the edition, build or time.
- **2.x features with little field time yet**: the scheduled backup task, updating then restoring a driver, and repairs launched from the Event Viewer were tested offline or in simulation, not yet on many PCs. Try them on a non-critical machine first.
- **Use it knowingly**: create a restore point (the tool does it for you before sensitive operations) and review the lists before clicking. No warranty is provided; you remain responsible for your machines.

### Getting started

1. Download the whole folder (the files belong together; do not separate them).
2. Double-click **`BJMPC-Toolbox.bat`**: the administrator prompt appears, then the window opens.
3. Optional: `Verif.bat` runs a **read-only self-test** (builds every page, checks every button); `Apercu.bat` previews the customer summary.

Requirements: Windows 11, administrator rights, Windows PowerShell 5.1 (built into Windows). Some features need Internet access (drivers, winget). The interface and messages are in French.

### Folder contents

| File | Purpose |
|---|---|
| `BJMPC-Toolbox.ps1` | The application (window) |
| `BJMPC-Evenements-Win11.ps1` | Event Viewer guided repair, live monitoring |
| `BJMPC-Sauvegarde-Win11.ps1` | Backup of the customer's files, on demand and scheduled |
| `BJMPC-Optimisation-Win11.ps1` | Gaming / network / disk / display engine (can be used alone in a console) |
| `BJMPC-Reglages-Win11.ps1` | Catalogue of Windows tweaks (privacy, interface, updates…) |
| `BJMPC-Maintenance-Win11.ps1` | Maintenance and repair engine (can be used alone in a console) |
| `BJMPC-Outils-Win11.ps1` | Diagnostics, troubleshooting, drivers, winget catalogue, cleanup, Windows defaults restore |
| `BJMPC-Toolbox.bat` | Launcher (asks for administrator elevation) |
| `Verif.bat` / `Apercu.bat` | Read-only self-test / customer summary preview |

### The six sections

| Section | Tabs |
|---|---|
| **Home** | Overview · Customer summary |
| **Repair** | Automatic repair · Repair Windows · Cleanup & troubleshooting · Registry · Diagnostics |
| **Optimise** | Gaming & power · Network & DNS · Disk & startup · Display & OLED |
| **Privacy & settings** | Privacy · Interface & Explorer · Updates & security |
| **Software & drivers** | Applications · Drivers |
| **Backup & restore** | File backup · Restore |

- **Home**: what is in order on this PC and where to act for the rest (recent backup, restore point, free space, disk health, recent crashes…). A "Recommended settings" button applies only what is safe everywhere. The *customer summary* tells the story of the visit in plain language.
- **Automatic repair**: each Event Viewer error is sorted into a family.
  - *To repair*: stopped services, DNS, clock, repeated Windows Update failures, damaged Windows files, disk errors, search index, Store, performance counters, graphics driver crashes.
  - *To look at*: hardware faults (WHEA, sudden shutdowns, overheating) and crashing third-party software, with what to check. No software can repair those.
  - *Unrecognised*: shown as they are, never "fixed" at random.
  - *Harmless*: well-known Windows noise (DCOM 10016…).
  - After a repair, the next scan tells whether the error came back. *Live monitoring* shows each new error within seconds.
- **Repair Windows / Cleanup & troubleshooting / Diagnostics**: DISM, SFC, CHKDSK, resets, quick fixes, cleanup, and read-only measurements (SMART disks, hardware errors, Wi-Fi, security audit, licence…). Also: dead network printers (TCP/IP, WSD, IPP), audio CD / DVD AutoPlay, and a **duplicate photo finder** that only groups photos whose content is identical (SHA-256 then byte by byte), never on size or date alone; optionally the same image with different metadata (pixels compared). Duplicates are moved to a `BJMPC-Doublons` folder, never deleted, and can be put back in one click.
- **Registry**: "Restore Windows 11 defaults" (reference: 24H2 to 26H2). Compares services, security and UAC, memory, priorities, network, telemetry and scheduled tasks with their original values, and detects any policy (*Policies* keys) set by a tweaking tool or a program. Differences are put back to the standard value whatever tool set them, with a restore point and one-click undo. This is not a whole-registry comparison: Microsoft does not publish a complete list of default values.
- **Optimise**: Windows gaming settings, **HAGS** (dedicated card: state, enable, disable), power mode, network adapters, encrypted DNS, SSD and startup, display scaling, OLED care.
- **Privacy & settings**: a catalogue of Windows tweaks to tick.
- **Applications**: software catalogue (winget), updates, inventory, removal of preinstalled apps.
- **Drivers**: every device is checked against what Windows Update offers for that exact hardware. Never a driver older than the installed one, and the Windows in-box driver is kept when it is newer than the vendor's. Graphics card: latest driver through the official vendor tool (NVIDIA, AMD, Intel). Devices without a driver: signed chipset package, never an unsigned driver. Restore point and backup before, device check and removal of the old version after. Other tabs: installed drivers (old versions), add a driver, absent devices, backups.
- **File backup**: two modes. *Chosen folders*: personal folders and bookmarks copied to another disk, only new or changed files, nothing is ever deleted from the backup. *Mirror*: exact copy of the user folder (except AppData, OneDrive and system folders); a file deleted from the PC is kept 30 days in `Miroir-Corbeille`, and a run that would remove a large part of the mirror is suspended until confirmed. Daily or weekly scheduled task, independent of the Toolbox.
- **Restore**: change journal (undo everything or one category) and restore points.

### Safety and reversibility

- Before every change, the **original value** (registry, service, task, DNS, network adapter, power plan…) is saved in `C:\BJMPC-Logs\Backup\`; the *Restore* tab undoes it.
- **Drivers**: only signed drivers offered by Windows Update for the exact hardware are installed automatically, after the rules are checked again (never older, Windows in-box driver kept when newer). A restore point and a copy of the installed driver are made first; the old version is removed only if the device works with the new one. "Restore" removes the new driver, then puts the old one back. A driver added from a folder must have a valid signature and an INF that declares the device.
- **Automatic repairs**: quick, risk-free repairs are ticked by default; heavy ones (DISM/SFC, CHKDSK, Windows Update) must be ticked by hand and never start on their own.
- **Windows 11 defaults restore**: compares the PC with a pristine Windows 11, shows a *default value / current value* table with checkboxes, creates a restore point and an `AvantDefauts_<PC>_<date>.json` file so everything can be undone. Policies set by another tool or program are listed separately and never ticked by default; nothing is touched on a domain-joined PC.
- Defender, the firewall and Windows Update are never disabled.
- `C:\BJMPC-Logs\` (logs, driver backups) becomes writable by administrators only on first launch.

### Known limitations

- **File backup**: personal files only, not Windows or installed software; a single version of each file is kept; a file open during the copy is picked up next time; browser passwords are not copied.
- **Automatic repair**: 33 rules cover common errors; the rest is shown without an invented fix.
- The Windows Update is fuzzy and may rate-limit: an abnormal response is reported as "Error", never mistaken for "no driver".
- "Forced" driver deletion (as in DriverStore Explorer) is intentionally not implemented.
- "Windows 11 default" values may vary with the edition and build: compare before applying.

### Feedback

Open an *issue* with your Windows version, the tool version (2.1) and, if possible, the log from `C:\BJMPC-Logs\`.
