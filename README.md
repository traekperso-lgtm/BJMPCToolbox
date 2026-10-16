# BJMPC Toolbox

🇫🇷 [Français](#-français) · 🇬🇧 [English](#-english)

> **Version 1.7** · Windows 11 · Windows PowerShell 5.1 (WPF) · by **BJMPC Informatique**

---

## 🇫🇷 Français

### Qu'est-ce que c'est ?

**BJMPC Toolbox** est une boîte à outils graphique pour **diagnostiquer, réparer, mettre à jour et optimiser Windows 11**. Elle est pensée pour un technicien qui intervient chez des clients : tout se fait avec des **boutons, des listes déroulantes et des cases à cocher** (aucune question à taper), et **chaque modification est réversible**.

Elle est écrite en Windows PowerShell 5.1 (interface WPF), sans installation : on lance, on travaille, on ferme.

### ⚠️ Statut : mature mais expérimental

- **Mature** : l'outil est utilisé en conditions réelles, chaque fonction est contrôlée (autotest, points de restauration, sauvegardes avant modification, journal).
- **Expérimental** : il agit sur le système (services, registre, pilotes, stratégies). Windows évolue, les configurations matérielles sont infinies, et certaines fonctions (recherche de pilotes sur le Microsoft Update Catalog, valeurs par défaut de Windows 11) reposent sur des sources ou des valeurs qui peuvent varier selon l'édition, la version ou le moment.
- **Utilisez-le en connaissance de cause** : créez un point de restauration (l'outil le fait pour vous avant les opérations sensibles), testez d'abord sur une machine non critique, et relisez les listes avant de cliquer sur « Appliquer ». Aucune garantie n'est fournie ; vous restez responsable de vos machines.

### Lancer l'outil

1. Téléchargez tout le dossier (les fichiers vont ensemble, ne les séparez pas).
2. Double-clic sur **`BJMPC-Toolbox.bat`** : la demande d'administrateur s'affiche, puis la fenêtre s'ouvre.
3. Facultatif : `Verif.bat` lance un **autotest en lecture seule** (construit chaque page, vérifie chaque bouton) ; `Apercu.bat` montre l'aperçu du résumé client.

Prérequis : Windows 11, droits administrateur, Windows PowerShell 5.1 (inclus dans Windows). Certaines fonctions ont besoin d'Internet (pilotes, winget).

### Contenu du dossier

| Fichier | Rôle |
|---|---|
| `BJMPC-Toolbox.ps1` | L'application (fenêtre) |
| `BJMPC-Optimisation-Win11.ps1` | Moteur gaming / réseau / système / écran (utilisable seul en console) |
| `BJMPC-Reglages-Win11.ps1` | Catalogue de 73 réglages Windows (confidentialité, interface, mises à jour…) |
| `BJMPC-Maintenance-Win11.ps1` | Moteur maintenance et réparation (utilisable seul en console) |
| `BJMPC-Outils-Win11.ps1` | Diagnostics, dépannage, pilotes, catalogue winget, nettoyage, retour aux valeurs Windows |
| `BJMPC-Toolbox.bat` | Lanceur (demande l'élévation administrateur) |
| `Verif.bat` / `Apercu.bat` | Autotest en lecture seule / aperçu du résumé client |

### Les pages

- **Tableau de bord** : matériel, état du système, points d'attention.
- **Outils** : diagnostics et dépannage (licence, disque, réseau, horloge, file d'impression, caches, rapports…).
- **Maintenance** : réparation de Windows et remise à l'état des services essentiels, point de restauration.
- **Pilotes** *(refaite en 1.6)* : cinq onglets.
  - *Mises à jour* : recherche sur le **Microsoft Update Catalog** (stricte, ou élargie), tableau installé / proposé / date / taille, installation des seuls pilotes cochés.
  - *Pilotes installés* : équivalent de DriverStore Explorer (anciennes versions, suppression avec copie préalable, export CSV).
  - *Ajouter un pilote* : depuis un dossier ou un .zip, avec contrôle de signature.
  - *Appareils absents* : fantômes anciens, liste sauvegardée avant suppression.
  - *Sauvegardes* : export de tous les pilotes tiers et restauration.
- **Gaming et GPU / Réseau et DNS / Système et NVMe / Affichage et OLED** : optimisations ciblées pour PC moderne, sans toucher à la sécurité.
- **Confidentialité / Interface et Explorateur / Mises à jour et sécurité** : catalogue de réglages Windows à cocher.
- **Applications** : catalogue de logiciels (winget) et suppression des applications préinstallées.
- **Résumé pour le client** : journal de session traduit en langage simple, pour expliquer ce qui a été fait.
- **Journal et annulation** : annule tout, ou une catégorie ; points de restauration ; **nouveau en 1.7 : « Rétablir les valeurs par défaut de Windows 11 »**.

### Sécurité et réversibilité

- Avant chaque modification, la **valeur d'origine** (registre, service, tâche, DNS, carte réseau, plan d'alimentation…) est enregistrée dans `C:\BJMPC-Logs\Backup\` ; la page *Journal* l'annule.
- **Pilotes** : l'installation n'accepte qu'un paquet dont la signature est valide (WHQL Microsoft en mode strict), dont l'INF déclare bien la puce, l'architecture, la classe, avec une version plus récente. Au moindre doute : refus. Un point de restauration et une copie de l'ancien pilote sont créés avant ; l'application effective est vérifiée après.
- **Retour aux valeurs Windows 11** : compare le PC à un Windows 11 d'origine (services, priorités système, Nagle, télémétrie, stratégies, tâches…), tableau *valeur par défaut / valeur actuelle*, cases à cocher, point de restauration puis fichier `AvantDefauts_<PC>_<date>.json` pour tout annuler. Une valeur « non définie par défaut » est **supprimée** (pas mise à 0). Les stratégies ne sont retirées que si elles ont la valeur posée par l'outil, jamais sur un PC en domaine. Pilotes de démarrage, Defender, pare-feu et Windows Update ne sont jamais touchés.
- Jamais de désactivation de Defender, du pare-feu ou de Windows Update.
- Les journaux sont dans `C:\BJMPC-Logs\` ; en cas d'erreur de lancement : `Toolbox_erreurs.log`.

### Limites connues

- Le Microsoft Update Catalog est approximatif et peut limiter les requêtes : un résultat anormal est signalé « Erreur », jamais pris pour « aucun pilote ».
- La suppression « forcée » de pilotes (DriverStore Explorer) n'est volontairement pas reprise.
- Les valeurs « par défaut de Windows 11 » peuvent varier selon l'édition et la version : comparez avant d'appliquer.
- Les réglages réseau avancés, DNS et plans d'alimentation se défont depuis le Journal, pas depuis la carte « valeurs par défaut ».

### Retours

Ouvrez une *issue* en précisant la version de Windows, la version de l'outil (1.7) et, si possible, le journal de `C:\BJMPC-Logs\`.

---

## 🇬🇧 English

### What is it?

**BJMPC Toolbox** is a graphical toolbox to **diagnose, repair, update and optimise Windows 11**. It is designed for a technician working on customers' PCs: everything is driven by **buttons, drop-downs and checkboxes** (nothing to type), and **every change is reversible**.

It is written in Windows PowerShell 5.1 (WPF UI) and needs no installation: launch it, work, close it.

### ⚠️ Status: mature but experimental

- **Mature**: the tool is used in real-world conditions; each feature is checked (self-test, restore points, backups before changes, logs).
- **Experimental**: it changes the system (services, registry, drivers, policies). Windows keeps evolving, hardware setups are endless, and some features (driver search on the Microsoft Update Catalog, Windows 11 default values) rely on sources or values that can vary with the edition, build or time.
- **Use it knowingly**: create a restore point (the tool does it for you before sensitive operations), try it on a non-critical machine first, and review the lists before clicking "Apply". No warranty is provided; you remain responsible for your machines.

### Getting started

1. Download the whole folder (the files belong together; do not separate them).
2. Double-click **`BJMPC-Toolbox.bat`**: the administrator prompt appears, then the window opens.
3. Optional: `Verif.bat` runs a **read-only self-test** (builds every page, checks every button); `Apercu.bat` previews the customer summary.

Requirements: Windows 11, administrator rights, Windows PowerShell 5.1 (built into Windows). Some features need Internet access (drivers, winget). The interface and messages are in French.

### Folder contents

| File | Purpose |
|---|---|
| `BJMPC-Toolbox.ps1` | The application (window) |
| `BJMPC-Optimisation-Win11.ps1` | Gaming / network / system / display engine (can be used alone in a console) |
| `BJMPC-Reglages-Win11.ps1` | Catalogue of 73 Windows tweaks (privacy, interface, updates…) |
| `BJMPC-Maintenance-Win11.ps1` | Maintenance and repair engine (can be used alone in a console) |
| `BJMPC-Outils-Win11.ps1` | Diagnostics, troubleshooting, drivers, winget catalogue, cleanup, Windows defaults restore |
| `BJMPC-Toolbox.bat` | Launcher (asks for administrator elevation) |
| `Verif.bat` / `Apercu.bat` | Read-only self-test / customer summary preview |

### Pages

- **Dashboard**: hardware, system state, points of attention.
- **Tools**: diagnostics and troubleshooting (licence, disk, network, clock, print queue, caches, reports…).
- **Maintenance**: Windows repair and reset of essential services, restore point.
- **Drivers** *(rebuilt in 1.6)*: five tabs.
  - *Updates*: search on the **Microsoft Update Catalog** (strict or extended), table of installed / proposed / date / size, installs only the ticked drivers.
  - *Installed drivers*: DriverStore Explorer equivalent (old versions, deletion with prior copy, CSV export).
  - *Add a driver*: from a folder or .zip, with signature check.
  - *Absent devices*: old ghost devices, list saved before removal.
  - *Backups*: export of all third-party drivers and restore.
- **Gaming & GPU / Network & DNS / System & NVMe / Display & OLED**: targeted optimisations for modern PCs, without touching security.
- **Privacy / Interface & Explorer / Updates & security**: a catalogue of Windows tweaks to tick.
- **Applications**: software catalogue (winget) and removal of preinstalled apps.
- **Customer summary**: the session log translated into plain language to explain what was done.
- **Journal & undo**: undo everything or one category; restore points; **new in 1.7: "Restore Windows 11 defaults"**.

### Safety and reversibility

- Before every change, the **original value** (registry, service, task, DNS, network adapter, power plan…) is saved in `C:\BJMPC-Logs\Backup\`; the *Journal* page undoes it.
- **Drivers**: only a package with a valid signature (Microsoft WHQL in strict mode), whose INF declares the chip, architecture and class, with a newer version, is accepted. Any doubt means refusal. A restore point and a copy of the old driver are made first; the effective application is verified afterwards.
- **Windows 11 defaults restore**: compares the PC with a pristine Windows 11 (services, system priorities, Nagle, telemetry, policies, tasks…), shows a *default value / current value* table with checkboxes, creates a restore point and an `AvantDefauts_<PC>_<date>.json` file so everything can be undone. A value that is "not defined by default" is **deleted** (not set to 0). Policies are removed only if they hold the value set by the tool, and never on a domain-joined PC. Boot drivers, Defender, firewall and Windows Update are never touched.
- Defender, the firewall and Windows Update are never disabled.
- Logs are in `C:\BJMPC-Logs\`; if the launch fails: `Toolbox_erreurs.log`.

### Known limitations

- The Microsoft Update Catalog is fuzzy and may rate-limit: an abnormal response is reported as "Error", never mistaken for "no driver".
- "Forced" driver deletion (as in DriverStore Explorer) is intentionally not implemented.
- "Windows 11 default" values may vary with the edition and build: compare before applying.
- Advanced network settings, DNS and power plans are undone from the Journal, not from the "defaults" card.

### Feedback

Open an *issue* with your Windows version, the tool version (1.7) and, if possible, the log from `C:\BJMPC-Logs\`.
