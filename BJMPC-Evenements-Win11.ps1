#Requires -Version 5.1
<#
.SYNOPSIS
    BJMPC Informatique - Réparation guidée par l'Observateur d'événements
.DESCRIPTION
    Bibliothèque utilisée par BJMPC Toolbox (Réparer > Réparation automatique).

    1. Get-EventFindings lit les erreurs et alertes récentes des journaux Système et Application, les regroupe
       (même source, même numéro, même service ou même application) et rapproche chaque groupe d'une règle connue.
       Chaque constat est rangé dans une famille :
         fix      une réparation existe, elle est proposée (cochée) ;
         advice   panne matérielle ou logiciel tiers : pas de réparation automatique honnête, un conseil précis ;
         noise    message connu comme sans conséquence (documenté par Microsoft) ;
         unknown  erreur que le catalogue ne connaît pas : affichée telle quelle, jamais « réparée » au hasard.
    2. Invoke-EventFix lance les réparations choisies, de la plus légère à la plus lourde, et note leur date.
       À l'analyse suivante, un constat réparé est marqué « pas de nouvelle erreur depuis » ou « revenu ».
    3. Watch-Events tourne dans un fil à part pendant que la fenêtre est ouverte : toutes les quelques secondes,
       il lit les nouveaux événements et les envoie à l'interface (surveillance en direct).

    La lecture ne modifie rien. Les réparations lourdes (DISM/SFC, CHKDSK, Windows Update, index de recherche)
    s'appuient sur les fonctions des moteurs Maintenance et Outils, chargés avec ce fichier par l'interface.

    Pour ajouter une règle : une entrée dans $Script:EvtRules (voir le commentaire au-dessus du tableau).
#>

$ErrorActionPreference = 'Continue'
$Script:EventsVersion = '1.1'
$Script:LogDir       = Join-Path $env:SystemDrive 'BJMPC-Logs'
$Script:LogFile      = Join-Path $Script:LogDir ("Evenements_{0}_{1}.log" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmmss'))
$Script:EvtStateFile = Join-Path $Script:LogDir 'Evenements_reparations.json'
# Journaux lus. Defender et l'intégrité du code ont leur propre journal (références : pages Microsoft Learn
# « Microsoft Defender Antivirus event IDs and error codes » et « Understanding App Control event IDs »).
$Script:EvtLogs = @('System', 'Application', 'Microsoft-Windows-Windows Defender/Operational', 'Microsoft-Windows-CodeIntegrity/Operational')

# Réparations disponibles, de la plus légère à la plus lourde (c'est l'ordre d'exécution).
# Safe = peut être lancée sans demander par la surveillance en direct (rapide, sans perte, sans redémarrage).
$Script:EvtFixes = [ordered]@{
    dns_flush     = @{ Label = 'Vider le cache DNS'; Safe = $true }
    time_sync     = @{ Label = 'Resynchroniser l''horloge'; Safe = $true }
    svc_start     = @{ Label = 'Relancer le service arrêté'; Safe = $true }
    audio_restart = @{ Label = 'Relancer les services audio'; Safe = $true }
    perf_rebuild  = @{ Label = 'Reconstruire les compteurs de performance'; Safe = $true }
    shader_cache  = @{ Label = 'Vider les caches de shaders de la carte graphique'; Safe = $true }
    print_queue   = @{ Label = 'Vider la file d''impression et relancer le spouleur'; Safe = $false }
    search_reset  = @{ Label = 'Reconstruire l''index de recherche Windows'; Safe = $false }
    store_reset   = @{ Label = 'Réinitialiser le Microsoft Store'; Safe = $false }
    wu_reset      = @{ Label = 'Réinitialiser Windows Update'; Safe = $false }
    chkdsk_scan   = @{ Label = 'Analyser le disque système (CHKDSK en ligne)'; Safe = $false }
    sfc_dism      = @{ Label = 'Réparer les fichiers de Windows (DISM puis SFC, 20 à 45 min)'; Safe = $false }
}

# Règles, lues dans l'ordre : la première qui correspond gagne.
#   P      expression régulière sur le nom de la source (ProviderName)
#   Ids    numéros d'événement concernés (vide = tous ceux de la source)
#   M      (facultatif) expression régulière que le texte de l'événement doit contenir
#   W      $true si la règle vaut aussi pour de simples alertes (sinon : erreurs et critiques seulement)
#   Min    (facultatif) nombre d'occurrences à partir duquel la réparation est proposée ; en dessous : conseil
#   Kind   fix | advice | noise      Fix = clé de $Script:EvtFixes (pour fix)      Sev = gravité de 1 à 3
#   Title  {0} est remplacé par le nom du service ou de l'application quand il y en a un
$Script:EvtRules = @(
    # ---- Disque et système de fichiers
    @{ Id = 'disk_io'; P = '^(disk|cdrom|atapi)$'; Ids = @(7, 11, 51, 52, 153, 154); W = $true; Kind = 'fix'; Fix = 'chkdsk_scan'; Sev = 3
       Title = 'Un disque renvoie des erreurs de lecture ou d''écriture'
       Why = 'Le disque (ou son câble) a du mal à lire ou écrire certaines zones. C''est souvent le signe d''un disque en fin de vie.'
       Advice = 'Sauvegardez les fichiers sans attendre, puis contrôlez la santé du disque (Réparer > Diagnostics). Si les erreurs reviennent après l''analyse, le disque est à remplacer.' }
    @{ Id = 'disk_removed'; P = '^(disk|classpnp)$'; Ids = @(157); W = $true; Kind = 'advice'; Sev = 2
       Title = 'Un disque a été retiré ou s''est déconnecté en cours d''utilisation'
       Why = 'Windows a perdu la liaison avec un disque : câble ou alimentation défaillants, boîtier USB, ou disque en panne. Un disque externe débranché sans éjection produit aussi ce message.'
       Advice = 'Disque externe : l''éjecter proprement avant de le débrancher et essayer un autre câble ou port. Disque interne : contrôler les câbles et la santé du disque (Réparer > Diagnostics).' }
    @{ Id = 'ntfs'; P = '^(Ntfs|Microsoft-Windows-Ntfs)$'; Ids = @(50, 55, 98, 130, 131, 137, 140); W = $true; Kind = 'fix'; Fix = 'chkdsk_scan'; Sev = 3
       Title = 'Le système de fichiers d''un disque est endommagé'
       Why = 'Windows a trouvé des incohérences dans l''organisation des fichiers (coupure de courant, arrêt forcé, disque fatigué).'
       Advice = 'Si l''analyse en ligne signale des erreurs à corriger : Réparer Windows > CHKDSK > « Réparer au redémarrage ».' }
    @{ Id = 'stor_timeout'; P = '^(storahci|stornvme|storport|iaStor\w*|nvme\w*|secnvme|amd_sata|vmd\w*)$'; Ids = @(); Kind = 'advice'; Sev = 2
       Title = 'Un disque a mis trop de temps à répondre'
       Why = 'Le contrôleur a dû réinitialiser la liaison avec un disque. Cela provoque des gels de quelques secondes.'
       Advice = 'Mettre à jour le firmware du SSD et le pilote de stockage, vérifier le câble SATA ou le logement M.2. Contrôler la santé du disque (Réparer > Diagnostics).' }
    @{ Id = 'vss'; P = '^(volsnap|VSS)$'; Ids = @(); Kind = 'advice'; Sev = 1
       Title = 'Les clichés instantanés de Windows sont en erreur'
       Why = 'Ce mécanisme sert aux points de restauration et à certaines sauvegardes.'
       Advice = 'Vérifier la place libre sur le disque, puis créer un point de restauration d''essai (Sauvegarde et restauration > Restauration).' }
    @{ Id = 'dump'; P = '^volmgr$'; Ids = @(46, 161); Kind = 'advice'; Sev = 1
       Title = 'Windows n''a pas pu enregistrer son rapport de plantage'
       Why = 'Le fichier d''échange est absent ou trop petit : en cas d''écran bleu, il n''y aura pas de trace à analyser.'
       Advice = 'Laisser Windows gérer la mémoire virtuelle (Paramètres système avancés > Performances > Mémoire virtuelle > gestion automatique).' }

    # ---- Matériel et arrêts brutaux
    @{ Id = 'whea'; P = 'WHEA-Logger'; Ids = @(); Kind = 'advice'; Sev = 3
       Title = 'Le processeur ou la carte mère signale une erreur matérielle (WHEA)'
       Why = 'Ce sont les composants eux-mêmes qui remontent l''erreur : aucun réglage de Windows ne peut la corriger.'
       Advice = 'Vérifier les températures, mettre à jour le BIOS, repasser la mémoire en réglage par défaut (sans XMP/EXPO) pour essai, puis tester la mémoire (Nettoyage et dépannage > Diagnostic de la mémoire).' }
    @{ Id = 'power_loss'; P = '(Kernel-Power|^EventLog)$'; Ids = @(41, 6008); Kind = 'advice'; Sev = 3
       Title = 'Le PC s''est arrêté brutalement'
       Why = 'Coupure de courant, plantage complet ou appui long sur le bouton : Windows n''a pas pu s''éteindre proprement.'
       Advice = 'Survolez la ligne : un code d''arrêt (BugcheckCode) non nul indique un écran bleu à rechercher ; un horodatage du bouton d''alimentation (PowerButtonTimestamp) non nul indique un arrêt forcé à la main ; si tout est à zéro, suspecter l''alimentation, la surchauffe ou la mémoire. Regarder aussi les écrans bleus ou erreurs WHEA de cette liste.' }
    @{ Id = 'bsod'; P = '(WER-SystemErrorReporting|^BugCheck)$'; Ids = @(1001); Kind = 'fix'; Fix = 'sfc_dism'; Sev = 3
       Title = 'Écran bleu : Windows a planté complètement'
       Why = 'Le code du plantage est dans le détail (survolez la ligne). Des fichiers système abîmés en sont une cause possible, que la réparation élimine.'
       Advice = 'Si les écrans bleus continuent ensuite : pilotes (Logiciels et pilotes > Pilotes), mémoire et températures.' }
    @{ Id = 'fast_boot'; P = 'Kernel-Boot$'; Ids = @(29); Kind = 'advice'; Sev = 1
       Title = 'Le démarrage rapide de Windows a échoué'
       Why = 'Windows n''a pas pu reprendre à partir de son image de démarrage rapide et a fait un démarrage complet à la place. Fréquent après un arrêt brutal.'
       Advice = 'Si cela se répète : Optimiser > Disque et démarrage > « Désactiver le démarrage rapide seulement ».' }
    @{ Id = 'cpu_throttle'; P = 'Kernel-Processor-Power'; Ids = @(37); W = $true; Kind = 'advice'; Sev = 2
       Title = 'Le processeur est bridé par le matériel'
       Why = 'Le firmware limite la vitesse du processeur, le plus souvent à cause de la chaleur ou d''un chargeur trop faible.'
       Advice = 'Dépoussiérer, vérifier le ventilateur et la pâte thermique ; sur un portable, utiliser le chargeur d''origine.' }
    @{ Id = 'low_memory'; P = 'Resource-Exhaustion-Detector'; Ids = @(2004); W = $true; Kind = 'advice'; Sev = 2
       Title = 'Windows a manqué de mémoire'
       Why = 'La mémoire vive et le fichier d''échange étaient pleins : des programmes ont pu se fermer seuls.'
       Advice = 'Le détail nomme les programmes les plus gourmands. Fermer ce qui ne sert pas, ou ajouter de la mémoire vive.' }
    @{ Id = 'gpu_driver'; P = '^(Display|nvlddmkm|amdkmdag|amdwddmg|atikmdag|igfx\w*|intelgfx\w*|dxgkrnl)$'; Ids = @(); W = $true; Kind = 'fix'; Fix = 'shader_cache'; Sev = 2
       Title = 'Le pilote de la carte graphique a planté'
       Why = 'L''écran a pu se figer ou devenir noir un instant. Un cache de shaders abîmé peut en être la cause ; un pilote trop ancien ou une surchauffe aussi.'
       Advice = 'Si cela revient : installer le dernier pilote graphique (Logiciels et pilotes > Pilotes) et surveiller la température de la carte.' }
    @{ Id = 'device'; P = 'Kernel-PnP'; Ids = @(219, 411, 441, 442); W = $true; Kind = 'advice'; Sev = 1
       Title = 'Un périphérique ou son pilote n''a pas démarré'
       Why = 'Windows n''a pas réussi à mettre en route un appareil au démarrage ou au branchement.'
       Advice = 'Logiciels et pilotes > Pilotes : chercher une mise à jour pour l''appareil nommé dans le détail.' }
    @{ Id = 'net_adapter'; P = '^(Netwtw\w+|Netwbw\w+|e1\w*express|e1[dir]\w*|e2f\w*|rt\d+\w*|rtwlan\w*|RTL\w+|mtkwl\w*|BCM\w+|athw\w*|Qcamain\w*)$'; Ids = @(); Kind = 'advice'; Sev = 2
       Title = 'La carte réseau signale une erreur'
       Why = 'Le pilote Wi-Fi ou Ethernet a perdu la liaison ou n''a pas pu démarrer.'
       Advice = 'Optimiser > Réseau et DNS > « Régler les cartes réseau » (mise en veille de la carte), puis mettre le pilote à jour.' }
    @{ Id = 'bluetooth'; P = '^(BTHUSB|BTHPORT|BthLEEnum|BTHMINI|BthEnum)$'; Ids = @(); Kind = 'advice'; Sev = 1
       Title = 'L''adaptateur Bluetooth signale une erreur'
       Why = 'L''adaptateur n''a pas répondu ou a été réinitialisé.'
       Advice = 'Mettre à jour le pilote Bluetooth ; sur un adaptateur USB, essayer un autre port.' }
    @{ Id = 'secure_boot'; P = 'TPM-WMI'; Ids = @(1795, 1796, 1801); Kind = 'advice'; Sev = 1
       Title = 'Mise à jour des certificats du démarrage sécurisé en attente'
       Why = 'Windows n''a pas pu mettre à jour les certificats Secure Boot dans le firmware de la carte mère.'
       Advice = 'Installer la dernière version du BIOS/UEFI du constructeur, puis laisser Windows Update terminer.' }

    # ---- Services
    @{ Id = 'svc'; P = '^Service Control Manager$'; Ids = @(7000, 7001, 7009, 7011, 7022, 7023, 7024, 7031, 7032, 7034, 7038); Kind = 'fix'; Fix = 'svc_start'; Sev = 2
       Title = 'Le service « {0} » ne démarre pas ou s''est arrêté'
       Why = 'Un programme de fond de Windows ou d''un logiciel s''est arrêté seul, ou n''a pas démarré dans le délai prévu.'
       Advice = 'Si le service retombe après avoir été relancé : c''est le logiciel auquel il appartient qu''il faut mettre à jour ou réinstaller.' }

    # ---- Réseau, heure, mises à jour
    @{ Id = 'dns'; P = '(DNS-Client|^DNS Client Events|^Dnscache)$'; Ids = @(1014); W = $true; Min = 3; Kind = 'fix'; Fix = 'dns_flush'; Sev = 1
       Title = 'Des noms de sites ne sont pas résolus (DNS)'
       Why = 'Le serveur DNS n''a pas répondu à temps : des sites ne s''ouvrent pas ou lentement.'
       Advice = 'Si cela continue : changer de DNS (Optimiser > Réseau et DNS) ou redémarrer la box.' }
    @{ Id = 'ip_conflict'; P = '^Tcpip$'; Ids = @(4198, 4199); Kind = 'advice'; Sev = 2
       Title = 'Conflit d''adresse IP sur le réseau'
       Why = 'Un autre appareil utilise la même adresse que ce PC : la connexion se coupe par moments.'
       Advice = 'Redémarrer la box, et retirer toute adresse IP fixe réglée à la main sur ce PC ou sur l''autre appareil.' }
    @{ Id = 'time'; P = 'Time-Service'; Ids = @(); W = $true; Min = 2; Kind = 'fix'; Fix = 'time_sync'; Sev = 1
       Title = 'L''horloge du PC ne se synchronise pas'
       Why = 'Une heure fausse fait échouer les connexions sécurisées et les mises à jour.'
       Advice = 'Si l''heure se dérègle à chaque démarrage, la pile de la carte mère est à remplacer.' }
    @{ Id = 'wu'; P = 'WindowsUpdateClient'; Ids = @(20, 25, 31, 34); Min = 3; Kind = 'fix'; Fix = 'wu_reset'; Sev = 2
       Title = 'Des mises à jour Windows échouent à s''installer'
       Why = 'La même mise à jour échoue plusieurs fois : le cache de Windows Update est probablement abîmé.'
       Advice = 'Un échec isolé se règle souvent seul : relancer Windows Update. Si cela persiste après la réinitialisation : Réparer Windows > DISM puis SFC.' }

    # ---- Composants de Windows
    @{ Id = 'perf'; P = '^(Perflib|PerfNet|PerfProc|PerfDisk|PerfOS|Microsoft-Windows-Perflib|LoadPerf)$'; Ids = @(); Kind = 'fix'; Fix = 'perf_rebuild'; Sev = 1
       Title = 'Les compteurs de performance de Windows sont endommagés'
       Why = 'Sans gravité pour l''usage courant, mais le Gestionnaire des tâches ou des outils de mesure peuvent afficher des valeurs fausses.'
       Advice = '' }
    @{ Id = 'search'; P = '^(Microsoft-Windows-Search|Windows Search Service|ESENT)$'; Ids = @(); M = '(?i)windows\.edb|search|indexer|SearchIndexer'; Kind = 'fix'; Fix = 'search_reset'; Sev = 1
       Title = 'L''index de recherche de Windows est en erreur'
       Why = 'La recherche dans le menu Démarrer ou l''Explorateur peut être lente ou incomplète.'
       Advice = 'L''index se reconstruit en arrière-plan pendant quelques heures après la réparation.' }
    @{ Id = 'store_app'; P = '(Immersive-Shell|AppModel-Runtime|AppXDeployment\w*)$'; Ids = @(69, 404, 5973); Min = 3; Kind = 'fix'; Fix = 'store_reset'; Sev = 1
       Title = 'Une application du Microsoft Store ne se lance pas'
       Why = 'L''activation d''une application intégrée a échoué à plusieurs reprises.'
       Advice = 'Si cela continue : Réparer Windows > « Applications Windows » (ré-enregistrement).' }
    @{ Id = 'profile'; P = 'User Profiles? Service'; Ids = @(1500, 1508, 1511, 1515); Kind = 'advice'; Sev = 3
       Title = 'Windows a ouvert une session avec un profil temporaire'
       Why = 'Le profil de l''utilisateur n''a pas pu être chargé : ses fichiers et réglages semblent avoir disparu, mais ils sont toujours sur le disque.'
       Advice = 'Ne rien enregistrer dans cette session. Redémarrer ; si cela revient, sauvegarder le dossier C:\Users\<nom> avant toute réparation du profil.' }

    # ---- Applications
    @{ Id = 'app_crash'; P = '^Application Error$'; Ids = @(1000); Kind = 'advice'; Sev = 1
       Title = '« {0} » se ferme tout seul (plantage)'
       Why = 'Ce programme s''est arrêté sur une erreur.'
       Advice = 'Mettre ce logiciel à jour ou le réinstaller. S''il s''agit d''un jeu : vérifier ses fichiers dans son lanceur et mettre le pilote graphique à jour.' }
    @{ Id = 'app_hang'; P = '^Application Hang$'; Ids = @(1002); Kind = 'advice'; Sev = 1
       Title = '« {0} » ne répond plus par moments'
       Why = 'Windows a dû fermer ce programme parce qu''il était bloqué.'
       Advice = 'Mettre ce logiciel à jour. Si plusieurs programmes sont concernés, regarder les erreurs de disque et de mémoire de cette liste.' }
    @{ Id = 'dotnet'; P = '^\.NET Runtime$'; Ids = @(); Kind = 'advice'; Sev = 1
       Title = 'Un programme .NET a planté'
       Why = 'Le détail nomme le programme (ligne « Application »).'
       Advice = 'Mettre ce logiciel à jour ou le réinstaller.' }
    @{ Id = 'sxs'; P = '^SideBySide$'; Ids = @(); Kind = 'advice'; Sev = 1
       Title = 'Un logiciel ne trouve pas un composant Visual C++'
       Why = 'Le programme nommé dans le détail a été installé sans une bibliothèque dont il a besoin.'
       Advice = 'Réinstaller ce logiciel, ou installer les « Visual C++ Redistributable » (Logiciels et pilotes > Applications).' }
    @{ Id = 'msi'; P = '^MsiInstaller$'; Ids = @(1023, 1024, 10005, 11708); Kind = 'advice'; Sev = 1
       Title = 'Une installation ou une mise à jour de logiciel a échoué'
       Why = 'Le détail nomme le produit concerné.'
       Advice = 'Relancer l''installation en administrateur, après un redémarrage.' }

    # ---- Microsoft Defender et intégrité du code (journaux dédiés)
    @{ Id = 'def_threat'; P = 'Windows Defender'; Ids = @(1006, 1008, 1015, 1116, 1119); W = $true; Kind = 'advice'; Sev = 3
       Title = 'Microsoft Defender a détecté une menace ou n''a pas pu la traiter'
       Why = 'Le détail (survolez la ligne) donne le nom de la menace, le fichier et l''action tentée. Une menace déjà mise en quarantaine ne demande rien de plus.'
       Advice = 'Ouvrir Sécurité Windows > Protection contre les virus > Historique de protection ; si l''action a échoué, mettre à jour les définitions puis lancer une analyse complète, voire Microsoft Defender hors ligne.' }
    @{ Id = 'def_update'; P = 'Windows Defender'; Ids = @(2001, 2003, 2004); W = $true; Kind = 'advice'; Sev = 2
       Title = 'Les définitions ou le moteur de Defender ne se sont pas mis à jour'
       Why = 'Souvent une coupure réseau passagère. Sans mise à jour, la détection prend du retard.'
       Advice = 'Vérifier la connexion Internet, puis Sécurité Windows > Protection contre les virus > Mises à jour de la protection > Rechercher les mises à jour. Si cela échoue encore : Réparer Windows > Windows Update.' }
    @{ Id = 'def_engine'; P = 'Windows Defender'; Ids = @(3002, 5008); W = $true; Kind = 'advice'; Sev = 2
       Title = 'La protection en temps réel de Defender a eu une défaillance'
       Why = 'Le moteur de Defender s''est arrêté ou une fonction de protection a échoué.'
       Advice = 'Redémarrer le PC puis lancer une analyse complète (méthode indiquée par Microsoft). Si cela se répète, rechercher les mises à jour Windows ; un autre antivirus installé peut gêner Defender.' }
    @{ Id = 'def_off'; P = 'Windows Defender'; Ids = @(5001, 5010, 5012); W = $true; Kind = 'advice'; Sev = 1
       Title = 'La protection de Defender a été désactivée'
       Why = 'Normal si un autre antivirus a pris le relais ou si la désactivation était voulue. Sinon, c''est à vérifier : certains logiciels malveillants coupent la protection.'
       Advice = 'Ouvrir Sécurité Windows et vérifier qu''une protection est active (Defender ou l''antivirus installé).' }
    @{ Id = 'def_minor'; P = 'Windows Defender'; Ids = @(1118, 5007); W = $true; Kind = 'noise'; Sev = 0
       Title = 'Messages d''état de Defender'
       Why = 'Microsoft indique qu''aucune action n''est nécessaire pour un échec de traitement non critique ; un changement de configuration n''est à vérifier que s''il est inattendu.'; Advice = '' }
    @{ Id = 'ci_block'; P = 'CodeIntegrity'; Ids = @(3001, 3004, 3023, 3033, 3077); W = $true; Kind = 'advice'; Sev = 2
       Title = 'Windows a bloqué un pilote ou un fichier (signature ou stratégie de sécurité)'
       Why = 'Le fichier nommé dans le détail n''a pas une signature acceptée, ou une stratégie (App Control, Smart App Control, isolation du noyau) l''a refusé. Le matériel ou le logiciel concerné peut ne pas fonctionner.'
       Advice = 'Mettre à jour ce pilote ou ce logiciel auprès de son éditeur. Ne pas désactiver la protection pour le faire passer, sauf si l''origine du fichier est connue et sûre.' }

    # ---- Bruit connu : rien à réparer
    @{ Id = 'dcom'; P = 'DistributedCOM'; Ids = @(10000, 10001, 10005, 10010, 10016); Kind = 'noise'; Sev = 0
       Title = 'Messages DCOM (autorisations ou composant lent à répondre)'
       Why = 'Microsoft indique que ces messages sont attendus et sans conséquence : il ne faut pas les « corriger ».'; Advice = '' }
    @{ Id = 'schannel'; P = '^Schannel$'; Ids = @(); Kind = 'noise'; Sev = 0
       Title = 'Connexions sécurisées refusées par un serveur distant'
       Why = 'Un site ou un service a refusé une connexion chiffrée (ancien protocole, certificat). Le PC n''est pas en cause.'; Advice = '' }
    @{ Id = 'devsetup'; P = '(DeviceSetupManager|Kernel-EventTracing|CAPI2|^Microsoft-Windows-WMI|CertificateServicesClient\w*|^BROWSER|^Server|HttpEvent)$'; Ids = @(); Kind = 'noise'; Sev = 0
       Title = 'Messages techniques sans conséquence'
       Why = 'Téléchargement d''informations sur les appareils, traces de diagnostic, certificats : ces messages apparaissent sur des PC en parfait état.'; Advice = '' }
    @{ Id = 'profile_noise'; P = 'User Profiles? Service'; Ids = @(1530, 1534, 1552); W = $true; Kind = 'noise'; Sev = 0
       Title = 'Fermeture de session : registre encore utilisé par un programme'
       Why = 'Windows libère lui-même le registre : aucun réglage n''est perdu.'; Advice = '' }
)

# ---------------------------------------------------------------- Utilitaires
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try { Add-Content -Path $Script:LogFile -Value $line -Encoding UTF8 -ErrorAction Stop } catch {}
    switch ($Level) {
        'OK'    { Write-Host "  [OK]  $Message" -ForegroundColor Green }
        'WARN'  { Write-Host "  [!]   $Message" -ForegroundColor Yellow }
        'ERROR' { Write-Host "  [X]   $Message" -ForegroundColor Red }
        default { Write-Host "  [..]  $Message" -ForegroundColor Cyan }
    }
}

function Set-EventResult {
    param($Value)
    $sv = Get-Variable -Name Sync -ErrorAction SilentlyContinue
    if ($sv -and $sv.Value) { $sv.Value.Result = $Value }
}

function Get-EventFixState {
    # Date de la dernière réparation de chaque constat (clé du constat -> date).
    $h = @{}
    try {
        if (Test-Path -LiteralPath $Script:EvtStateFile) {
            $o = Get-Content -LiteralPath $Script:EvtStateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $o.PSObject.Properties) { try { $h[[string]$p.Name] = [datetime]$p.Value } catch {} }
        }
    } catch {}
    return $h
}

function Save-EventFixState {
    param([hashtable]$State)
    try {
        $o = [ordered]@{}
        foreach ($k in $State.Keys) { $o[[string]$k] = ([datetime]$State[$k]).ToString('s') }
        Set-Content -LiteralPath $Script:EvtStateFile -Value (ConvertTo-Json -InputObject $o) -Encoding UTF8 -ErrorAction Stop
    } catch { Write-Log "Mémorisation des réparations impossible : $($_.Exception.Message)" 'WARN' }
}

# ---------------------------------------------------------------- Lecture et regroupement
function Get-EventSub {
    # Ce qui distingue deux événements de même numéro : le service ou l'application concerné.
    param($Ev)
    try {
        $p = [string]$Ev.ProviderName
        if ($p -eq 'Service Control Manager') {
            $i = 0; if ([int]$Ev.Id -eq 7009 -or [int]$Ev.Id -eq 7011) { $i = 1 }
            return ([string]$Ev.Properties[$i].Value).Trim()
        }
        if ($p -eq 'Application Error' -or $p -eq 'Application Hang') { return ([string]$Ev.Properties[0].Value).Trim() }
    } catch {}
    return ''
}

function Get-EventGroups {
    # Lit les journaux Système et Application depuis $After (erreurs, critiques et alertes), du plus récent au plus
    # ancien, et regroupe par source + numéro + service/application. Le texte n'est mis en forme qu'une fois par
    # groupe : c'est ce qui rend la lecture rapide.
    param([datetime]$After, [int]$MaxPerLog = 6000)
    $groups = @{}; $trunc = $false; $read = 0
    $iso = $After.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $xp = "*[System[(Level=1 or Level=2 or Level=3) and TimeCreated[@SystemTime>'$iso']]]"
    foreach ($log in $Script:EvtLogs) {
        $rd = $null
        try {
            # Journal absent sur ce PC (Defender désinstallé, édition particulière) : on passe sans bruit.
            try { $null = New-Object System.Diagnostics.Eventing.Reader.EventLogConfiguration($log) } catch { continue }
            $q = New-Object System.Diagnostics.Eventing.Reader.EventLogQuery($log, [System.Diagnostics.Eventing.Reader.PathType]::LogName, $xp)
            $q.ReverseDirection = $true
            $rd = New-Object System.Diagnostics.Eventing.Reader.EventLogReader($q)
            $n = 0
            while ($true) {
                $e = $rd.ReadEvent()
                if ($null -eq $e) { break }
                $n++
                if ($n -gt $MaxPerLog) { $trunc = $true; $e.Dispose(); break }
                $sub = Get-EventSub $e
                $key = '{0}|{1}|{2}' -f $e.ProviderName, $e.Id, $sub
                $g = $groups[$key]
                if (-not $g) {
                    $msg = ''
                    try { $msg = [string]$e.FormatDescription() } catch {}
                    $vals = @()
                    try { $vals = @($e.Properties | ForEach-Object { [string]$_.Value }) } catch {}
                    if (-not $msg) { $msg = ($vals | Where-Object { $_ }) -join ' | ' }
                    $msg = ($msg -replace '\s+', ' ').Trim()
                    if ($msg.Length -gt 600) { $msg = $msg.Substring(0, 600) + '…' }
                    $path = ''
                    if ($sub -and [string]$e.ProviderName -like 'Application *') {
                        $path = [string](@($vals | Where-Object { $_ -match '^[A-Za-z]:\\' -and $_.EndsWith('\' + $sub, [StringComparison]::OrdinalIgnoreCase) }) | Select-Object -First 1)
                    }
                    $when = Get-Date; if ($e.TimeCreated) { $when = [datetime]$e.TimeCreated }
                    $g = @{ Key = $key; Provider = [string]$e.ProviderName; Id = [int]$e.Id; Sub = $sub; Log = $log; Count = 0; Last = $when; Level = 2; Sample = $msg; Path = $path }
                    if ($null -ne $e.Level) { $g.Level = [int]$e.Level }
                    $groups[$key] = $g
                }
                $g.Count++
                if ($null -ne $e.Level -and [int]$e.Level -lt [int]$g.Level) { $g.Level = [int]$e.Level }
                $e.Dispose()
            }
            $read += [math]::Min($n, $MaxPerLog)
        } catch { Write-Log "Lecture du journal $log : $($_.Exception.Message)" 'WARN' }
        finally { if ($rd) { $rd.Dispose() } }
    }
    return @{ Groups = $groups; Truncated = $trunc; Read = $read }
}

function Find-EventRule {
    param($G)
    foreach ($r in $Script:EvtRules) {
        if ([string]$G.Provider -notmatch [string]$r.P) { continue }
        if (@($r.Ids).Count -gt 0 -and @($r.Ids) -notcontains [int]$G.Id) { continue }
        if ($r.M -and ([string]$G.Sample -notmatch [string]$r.M)) { continue }
        return $r
    }
    return $null
}

function ConvertTo-EventFinding {
    # Rend le constat correspondant à un groupe d'événements, ou $null s'il n'y a rien à en dire
    # (simple alerte sans règle : ce n'est pas une erreur).
    param($G, [hashtable]$State = @{})
    $r = Find-EventRule $G
    $warnOnly = ([int]$G.Level -ge 3)
    $kind = 'unknown'; $fix = ''; $sev = 1; $rule = ''; $why = ''; $advice = ''
    $title = ('{0} · événement {1}' -f $G.Provider, $G.Id)
    if ($r) {
        if ($warnOnly -and -not $r.W) { return $null }
        $rule = [string]$r.Id; $kind = [string]$r.Kind; $fix = [string]$r.Fix; $sev = [int]$r.Sev
        $why = [string]$r.Why; $advice = [string]$r.Advice
        $name = $(if ($G.Sub) { [string]$G.Sub } else { 'non précisé' })
        $title = ([string]$r.Title).Replace('{0}', $name)
        if ($rule -eq 'svc') {
            # On regarde l'état du service MAINTENANT : inutile de proposer de relancer ce qui tourne déjà.
            $svc = Get-EventServiceInfo ([string]$G.Sub)
            if (-not $svc) {
                $kind = 'advice'; $fix = ''; $sev = 1
                $advice = 'Ce service n''existe plus sur ce PC (logiciel désinstallé depuis) : rien à faire.'
            } elseif ([string]$svc.Status -eq 'Running') {
                $kind = 'advice'; $fix = ''; $sev = 1
                $advice = 'Le service fonctionne de nouveau : rien à faire. S''il retombe souvent, mettre à jour ou réinstaller le logiciel auquel il appartient.'
            } elseif ([string]$svc.StartType -ne 'Automatic') {
                $kind = 'advice'; $fix = ''; $sev = 1
                $advice = 'Ce service ne démarre qu''à la demande : il est normal qu''il soit arrêté. S''il échoue à chaque fois, mettre à jour ou réinstaller le logiciel auquel il appartient.'
            } elseif ($G.Sub -match '(?i)audio') { $fix = 'audio_restart' }
            elseif ($G.Sub -match '(?i)spoul|spool') { $fix = 'print_queue' }
        }
        if ($rule -eq 'app_crash' -or $rule -eq 'app_hang') {
            $inWin = ($G.Path -and $G.Path.StartsWith([string]$env:windir + '\', [StringComparison]::OrdinalIgnoreCase))
            $inDrv = ($inWin -and $G.Path -match '(?i)\\DriverStore\\')
            $sysExe = ($G.Sub -match '(?i)^(explorer|dwm|svchost|SearchHost|StartMenuExperienceHost|ShellExperienceHost|sihost|ctfmon|taskhostw|RuntimeBroker|SystemSettings|lsass|csrss|winlogon)\.exe$')
            if ($inDrv) {
                # Programme livré avec un pilote (carte graphique, audio…) : c'est le pilote qu'il faut mettre à jour.
                $why = 'Ce programme fait partie d''un pilote (carte graphique, son…).'
                $advice = 'Mettre ce pilote à jour (Logiciels et pilotes > Pilotes, ou le site du fabricant).'
            } elseif (($sysExe -or $inWin) -and [int]$G.Count -ge 2) {
                # Un composant de Windows lui-même qui plante à répétition : les fichiers système sont à vérifier.
                $kind = 'fix'; $fix = 'sfc_dism'; $sev = 2
                $why = 'C''est un composant de Windows lui-même qui plante à répétition : ses fichiers sont peut-être abîmés.'
                $advice = 'Si cela continue après la réparation : pilotes et mémoire.'
            } elseif ($sysExe -or $inWin) {
                $advice = 'Plantage isolé d''un composant de Windows : à surveiller. S''il se répète, la réparation des fichiers système sera proposée.'
            } elseif ([int]$G.Count -ge 5) { $sev = 2 }
        }
        if ($r.Min -and [int]$G.Count -lt [int]$r.Min -and $kind -eq 'fix') {
            $kind = 'advice'; $fix = ''
            if (-not $advice) { $advice = 'Événement isolé : à surveiller, pas de réparation nécessaire pour l''instant.' }
        }
    } elseif ($warnOnly) { return $null }
    else {
        $why = 'Cette erreur ne fait pas partie de celles que la Toolbox sait interpréter. Elle est affichée telle quelle, sans réparation hasardeuse.'
        $advice = 'Survolez la ligne pour lire le message complet ; cherchez « {0} {1} » pour en savoir plus.' -f $G.Provider, $G.Id
    }
    $label = ''; $safe = $false
    if ($fix -and $Script:EvtFixes.Contains($fix)) { $label = [string]$Script:EvtFixes[$fix].Label; $safe = [bool]$Script:EvtFixes[$fix].Safe }
    elseif ($kind -eq 'fix') { $kind = 'advice'; $fix = '' }
    # Clé du constat : par règle (plusieurs numéros d'événement d'une même panne n'en font qu'un), sinon par source.
    $fkey = $(if ($rule) { 'r:{0}|{1}' -f $rule, $G.Sub } else { [string]$G.Key })
    $status = ''; $fixedAt = $null
    if ($State.ContainsKey($fkey)) {
        $fixedAt = [datetime]$State[$fkey]
        $status = $(if ([datetime]$G.Last -gt $fixedAt.AddMinutes(2)) { 'back' } else { 'fixed' })
    }
    return [pscustomobject]@{
        Key = $fkey; Rule = $rule; Kind = $kind; Fix = $fix; FixLabel = $label; Safe = $safe; Sev = $sev
        Title = $title; Why = $why; Advice = $advice
        Count = [int]$G.Count; Last = [datetime]$G.Last; Log = [string]$G.Log; Provider = [string]$G.Provider; EventId = [string]$G.Id
        Sub = [string]$G.Sub; Sample = [string]$G.Sample; Status = $status; FixedAt = $fixedAt
    }
}

function Merge-EventFindings {
    # Réunit les constats de même clé (même règle, même service) : on additionne, on garde le plus récent.
    param($List)
    $out = @()
    foreach ($grp in (@($List) | Group-Object Key)) {
        $items = @($grp.Group | Sort-Object Last -Descending)
        $f = $items[0]
        if ($items.Count -gt 1) {
            $f.Count = [int](($items | Measure-Object Count -Sum).Sum)
            $f.EventId = (@($items | ForEach-Object { [string]$_.EventId } | Sort-Object -Unique) -join ', ')
            # Si l'un des numéros justifie une réparation, le constat réuni la propose.
            $best = @($items | Where-Object { $_.Kind -eq 'fix' }) | Select-Object -First 1
            if ($best -and $f.Kind -ne 'fix') { $f.Kind = 'fix'; $f.Fix = $best.Fix; $f.FixLabel = $best.FixLabel; $f.Safe = $best.Safe }
            if ($f.FixedAt) { $f.Status = $(if ([datetime]$f.Last -gt ([datetime]$f.FixedAt).AddMinutes(2)) { 'back' } else { 'fixed' }) }
            # Le seuil « Min » d'une règle se juge sur le total, pas numéro par numéro.
            $r = @($Script:EvtRules | Where-Object { [string]$_.Id -eq [string]$f.Rule }) | Select-Object -First 1
            if ($r -and $r.Min -and [string]$r.Kind -eq 'fix' -and $f.Kind -eq 'advice' -and [int]$f.Count -ge [int]$r.Min -and $Script:EvtFixes.Contains([string]$r.Fix)) {
                $f.Kind = 'fix'; $f.Fix = [string]$r.Fix; $f.FixLabel = [string]$Script:EvtFixes[[string]$r.Fix].Label; $f.Safe = [bool]$Script:EvtFixes[[string]$r.Fix].Safe
                $f.Advice = [string]$r.Advice
            }
        }
        $out += $f
    }
    return $out
}

function Get-EventServiceInfo {
    # Service désigné par un événement (nom affiché ou nom court). La liste est relue à chaque analyse.
    param([string]$Name)
    if (-not $Name) { return $null }
    if (-not $Script:EvtSvcCache) {
        $Script:EvtSvcCache = @{}
        foreach ($s in @(Get-Service -ErrorAction SilentlyContinue)) { $Script:EvtSvcCache[[string]$s.DisplayName] = $s; $Script:EvtSvcCache[[string]$s.Name] = $s }
    }
    return $Script:EvtSvcCache[$Name]
}

function Get-EventFindings {
    # Analyse à la demande. -Hours prime sur -Days.
    param([int]$Days = 7, [int]$Hours = 0)
    $after = $(if ($Hours -gt 0) { (Get-Date).AddHours(-$Hours) } else { (Get-Date).AddDays(-[math]::Max(1, $Days)) })
    $span = $(if ($Hours -gt 0) { "$Hours dernières heures" } else { "$Days derniers jours" })
    Write-Log "Lecture de l'Observateur d'événements (Système, Application, Defender, intégrité du code ; $span)…"
    $res = Get-EventGroups -After $after
    $state = Get-EventFixState
    $Script:EvtSvcCache = $null
    $list = @()
    foreach ($g in @($res.Groups.Values)) { $f = ConvertTo-EventFinding $g $state; if ($f) { $list += $f } }
    $list = @(Merge-EventFindings $list)
    $order = @{ fix = 0; advice = 1; unknown = 2; noise = 3 }
    $list = @($list | Sort-Object @{ Expression = { $order[[string]$_.Kind] } }, @{ Expression = { -[int]$_.Sev } }, @{ Expression = { $_.Last }; Descending = $true })
    $nFix = @($list | Where-Object { $_.Kind -eq 'fix' -and $_.Status -ne 'fixed' }).Count
    $nAdv = @($list | Where-Object { $_.Kind -eq 'advice' }).Count
    $nUnk = @($list | Where-Object { $_.Kind -eq 'unknown' }).Count
    $nNoise = @($list | Where-Object { $_.Kind -eq 'noise' }).Count
    Write-Log ("{0} événement(s) lus, regroupés en {1} constat(s)." -f $res.Read, $list.Count)
    if ($res.Truncated) { Write-Log 'Journal très chargé : seuls les événements les plus récents ont été lus. Réduisez la période pour tout voir.' 'WARN' }
    foreach ($f in @($list | Where-Object { $_.Kind -ne 'noise' } | Select-Object -First 40)) {
        $tag = switch ([string]$f.Kind) { 'fix' { 'RÉPARABLE' } 'advice' { 'À REGARDER' } default { 'NON RECONNU' } }
        Write-Host ("  {0,-12} {1,4} × {2}" -f $tag, $f.Count, $f.Title) -ForegroundColor $(if ($f.Kind -eq 'fix') { 'Cyan' } elseif ($f.Kind -eq 'advice') { 'Yellow' } else { 'Gray' })
    }
    if ($list.Count -eq 0) { Write-Log 'Aucune erreur sur la période : rien à réparer.' 'OK' }
    else { Write-Log ("À réparer : {0} · à regarder : {1} · non reconnus : {2} · sans gravité : {3}" -f $nFix, $nAdv, $nUnk, $nNoise) 'OK' }
    Set-EventResult @{ Findings = $list; Truncated = [bool]$res.Truncated; Since = $after; Read = [int]$res.Read }
}

# ---------------------------------------------------------------- Réparations
function Start-EventService {
    # Relance un service signalé comme arrêté, seulement s'il est en démarrage automatique.
    param([string]$Name)
    if (-not $Name) { return }
    $svc = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $Name -or $_.Name -eq $Name }) | Select-Object -First 1
    if (-not $svc) { Write-Log "Service introuvable (logiciel désinstallé depuis ?) : $Name" 'WARN'; return }
    if ([string]$svc.Status -eq 'Running') { Write-Log "Service déjà reparti : $($svc.DisplayName)" 'OK'; return }
    if ([string]$svc.StartType -ne 'Automatic') { Write-Log "Service en démarrage « $($svc.StartType) » : il est normal qu'il soit arrêté ($($svc.DisplayName))"; return }
    try {
        Start-Service -Name $svc.Name -ErrorAction Stop
        Write-Log "Service relancé : $($svc.DisplayName)" 'OK'
    } catch { Write-Log "Le service $($svc.DisplayName) refuse de démarrer : $($_.Exception.Message)" 'WARN' }
}

function Repair-PerfCounters {
    foreach ($exe in @("$env:windir\System32\lodctr.exe", "$env:windir\SysWOW64\lodctr.exe")) {
        if (Test-Path -LiteralPath $exe) { & $exe /R 2>&1 | Out-Null; Write-Log ("lodctr /R ({0}) : code {1}" -f (Split-Path (Split-Path $exe -Parent) -Leaf), $LASTEXITCODE) }
    }
    & "$env:windir\System32\wbem\winmgmt.exe" /resyncperf 2>&1 | Out-Null
    Write-Log 'Compteurs de performance reconstruits' 'OK'
}

function Invoke-EventFix {
    # $Items : @(@{ K = clé du constat; F = clé de réparation; S = service concerné }, …)
    # Les réparations identiques ne sont lancées qu'une fois, dans l'ordre de $Script:EvtFixes.
    param($Items, [switch]$Live)
    $todo = @(@($Items) | Where-Object { $_ -and $_.F -and $Script:EvtFixes.Contains([string]$_.F) })
    if ($todo.Count -eq 0) { Write-Log 'Aucune réparation à lancer.' 'WARN'; Set-EventResult @{ Ok = @(); Bad = @(); Reboot = $false }; return }
    $fixes = @($Script:EvtFixes.Keys | Where-Object { $k = [string]$_; @($todo | Where-Object { [string]$_.F -eq $k }).Count -gt 0 })
    if ($Live) { Write-Log '=== Réparation automatique (surveillance en direct) ===' } else { Write-Log ("=== Réparation de {0} constat(s) : {1} action(s) ===" -f $todo.Count, $fixes.Count) }
    $heavy = @($fixes | Where-Object { -not $Script:EvtFixes[$_].Safe })
    if ($heavy.Count -gt 0 -and (Get-Command New-RestorePoint -ErrorAction SilentlyContinue)) { New-RestorePoint }
    $ok = @(); $bad = @(); $doneFix = @()
    foreach ($f in $fixes) {
        $label = [string]$Script:EvtFixes[$f].Label
        Write-Host ''
        Write-Log "--- $label"
        try {
            $fn = switch ($f) {
                'dns_flush' { 'Clear-DnsCache' } 'time_sync' { 'Sync-Clock' } 'audio_restart' { 'Restart-AudioServices' }
                'shader_cache' { 'Clear-ShaderCache' } 'print_queue' { 'Clear-PrintQueue' } 'search_reset' { 'Reset-Search' }
                'store_reset' { 'Reset-Store' } 'wu_reset' { 'Reset-WindowsUpdate' } 'chkdsk_scan' { 'Invoke-Chkdsk' }
                'sfc_dism' { 'Invoke-DISM' } default { '' }
            }
            if ($fn -and -not (Get-Command $fn -ErrorAction SilentlyContinue)) { throw "fonction $fn indisponible (moteurs Maintenance et Outils non chargés)" }
            switch ($f) {
                'svc_start'    { foreach ($s in @($todo | Where-Object { [string]$_.F -eq 'svc_start' } | ForEach-Object { [string]$_.S } | Sort-Object -Unique)) { Start-EventService $s } }
                'perf_rebuild' { Repair-PerfCounters }
                'sfc_dism'     { Invoke-DISM; Invoke-SFC }
                default        { & $fn }
            }
            $ok += $label; $doneFix += $f
        } catch { $bad += $label; Write-Log "$label : $($_.Exception.Message)" 'ERROR' }
    }
    # On note la date : à la prochaine analyse, ces constats seront marqués « réparé » ou « revenu ».
    $state = Get-EventFixState
    $now = Get-Date
    foreach ($it in $todo) { if ($doneFix -contains [string]$it.F -and $it.K) { $state[[string]$it.K] = $now } }
    Save-EventFixState $state
    Write-Host ''
    Write-Log ("Réparations terminées : {0} faite(s), {1} en échec. Les anciennes erreurs restent dans le journal de Windows : relancez l'analyse plus tard pour voir si elles reviennent." -f $ok.Count, $bad.Count) 'OK'
    $rb = $false; try { $rb = [bool]$Script:RebootNeeded } catch {}
    Set-EventResult @{ Ok = $ok; Bad = $bad; Reboot = $rb }
}

# ---------------------------------------------------------------- Surveillance en direct
function Watch-Events {
    # Tourne dans un fil à part tant que $Sync.EvtStop est faux. Chaque constat nouveau part dans $Sync.EvtQueue.
    param([int]$Every = 5)
    $last = Get-Date
    while (-not $Sync.EvtStop) {
        for ($i = 0; $i -lt ($Every * 4) -and -not $Sync.EvtStop; $i++) { Start-Sleep -Milliseconds 250 }
        if ($Sync.EvtStop) { break }
        $start = Get-Date
        try {
            $res = Get-EventGroups -After $last -MaxPerLog 300
            $Script:EvtSvcCache = $null
            $new = @()
            foreach ($g in @($res.Groups.Values)) { $f = ConvertTo-EventFinding $g @{}; if ($f) { $new += $f } }
            foreach ($f in @(Merge-EventFindings $new)) { $Sync.EvtQueue.Enqueue($f) }
        } catch {}
        $last = $start
        $Sync.EvtBeat = $start
    }
}
