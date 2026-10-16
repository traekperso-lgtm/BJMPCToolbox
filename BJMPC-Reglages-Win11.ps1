#Requires -Version 5.1
<#
.SYNOPSIS
    BJMPC Informatique - Catalogue de réglages Windows (confidentialité, interface, mises à jour, sécurité)
.DESCRIPTION
    Bibliothèque utilisée par BJMPC Toolbox. Elle s'appuie sur les primitives réversibles de
    BJMPC-Optimisation-Win11.ps1 (Set-Reg, Set-SvcMode, Disable-TaskSafe, Add-Orig) : chaque valeur est
    enregistrée AVANT modification et peut être annulée depuis la page "Journal et annulation".
    Aucune fonction ne pose de question : l'interface choisit les réglages à appliquer.

    Le catalogue ci-dessous est une liste de données (aucun code) : l'interface en tire ses cases à cocher.
    Chaque réglage : Id, Group, Label, Desc, Risk (safe | warn), Default (coché par défaut), Reboot,
    Needs (chemins : le réglage n'est appliqué que si l'un existe), Reg, Svc, Task, Feat, Fn.
#>

$ErrorActionPreference = 'Continue'
$Script:ReglagesVersion = '1.0'

$Script:TweakCatalog = @(
    @{
        Id = 'tel_win'; Group = 'Télémétrie et diagnostics'; Risk = 'safe'; Default = $true; Reboot = $false
        Label = 'Télémétrie Windows au niveau minimal'
        Desc = 'Stratégies DataCollection, programme d''amélioration (CEIP), services et tâches de collecte (Appraiser, CEIP, disque, retours). Sur Windows Famille/Pro, le niveau « Requis » reste envoyé : c''est une limite imposée par Microsoft.'
        Fn = ''
        Needs = @()
        Reg = @(
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection', 'AllowTelemetry', 0, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection', 'AllowDesktopAnalyticsProcessing', 0, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection', 'AllowDeviceNameInTelemetry', 0, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection', 'MicrosoftEdgeDataOptIn', 0, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection', 'AllowWUfBCloudProcessing', 0, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection', 'AllowUpdateComplianceProcessing', 0, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection', 'AllowCommercialDataPipeline', 0, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection', 'DisableOneSettingsDownloads', 1, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection', 'DoNotShowFeedbackNotifications', 1, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\SQMClient\Windows', 'CEIPEnable', 0, 'DWord'),
            @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection', 'AllowTelemetry', 0, 'DWord')
        )
        Svc = @(
            @('DiagTrack', 'disabled'),
            @('dmwappushservice', 'disabled')
        )
        Task = @(
            @('\Microsoft\Windows\Customer Experience Improvement Program\', 'Consolidator'),
            @('\Microsoft\Windows\Customer Experience Improvement Program\', 'KernelCeipTask'),
            @('\Microsoft\Windows\Customer Experience Improvement Program\', 'UsbCeip'),
            @('\Microsoft\Windows\Application Experience\', 'Microsoft Compatibility Appraiser'),
            @('\Microsoft\Windows\Application Experience\', 'Microsoft Compatibility Appraiser Exp'),
            @('\Microsoft\Windows\Application Experience\', 'ProgramDataUpdater'),
            @('\Microsoft\Windows\Application Experience\', 'StartupAppTask'),
            @('\Microsoft\Windows\Application Experience\', 'PcaPatchDbTask'),
            @('\Microsoft\Windows\Application Experience\', 'MareBackup'),
            @('\Microsoft\Windows\Autochk\', 'Proxy'),
            @('\Microsoft\Windows\DiskDiagnostic\', 'Microsoft-Windows-DiskDiagnosticDataCollector'),
            @('\Microsoft\Windows\Feedback\Siuf\', 'DmClient'),
            @('\Microsoft\Windows\Feedback\Siuf\', 'DmClientOnScenarioDownload')
        )
        Feat = @()
    },
    @{
        Id = 'tel_wer'; Group = 'Télémétrie et diagnostics'; Risk = 'safe'; Default = $true; Reboot = $false
        Label = 'Rapports d''erreurs : ne plus les envoyer à Microsoft'
        Desc = 'Désactive l''envoi des rapports de plantage. Les journaux et vidages mémoire locaux restent disponibles pour diagnostiquer un écran bleu.'
        Fn = ''
        Needs = @()
        Reg = @(
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting', 'Disabled', 1, 'DWord'),
            @('HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting', 'Disabled', 1, 'DWord'),
            @('HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting', 'DontSendAdditionalData', 1, 'DWord'),
            @('HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting', 'LoggingDisabled', 1, 'DWord')
        )
        Svc = @(,@('WerSvc', 'demand'))
        Task = @(,@('\Microsoft\Windows\Windows Error Reporting\', 'QueueReporting'))
        Feat = @()
    },
    @{
        Id = 'tel_activity'; Group = 'Télémétrie et diagnostics'; Risk = 'safe'; Default = $true; Reboot = $false
        Label = 'Historique d''activité et suivi des applications lancées'
        Desc = 'Désactive la chronologie d''activité, sa synchronisation, et le suivi des programmes les plus utilisés dans le menu Démarrer.'
        Fn = ''
        Needs = @()
        Reg = @(
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\System', 'PublishUserActivities', 0, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\System', 'UploadUserActivities', 0, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\System', 'EnableActivityFeed', 0, 'DWord'),
            @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced', 'Start_TrackProgs', 0, 'DWord'),
            @('HKCU:\Software\Policies\Microsoft\Windows\EdgeUI', 'DisableMFUTracking', 1, 'DWord')
        )
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'tel_feedback'; Group = 'Télémétrie et diagnostics'; Risk = 'safe'; Default = $true; Reboot = $false
        Label = 'Demandes d''avis Windows (Feedback)'
        Desc = 'Supprime les notifications qui demandent de donner son avis sur Windows.'
        Fn = ''
        Needs = @()
        Reg = @(,@('HKCU:\SOFTWARE\Microsoft\Siuf\Rules', 'NumberOfSIUFInPeriod', 0, 'DWord'))
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'tel_input'; Group = 'Télémétrie et diagnostics'; Risk = 'safe'; Default = $true; Reboot = $false
        Label = 'Saisie et écriture manuscrite : aucune collecte'
        Desc = 'Empêche la collecte implicite de ce que vous tapez ou écrivez, et les rapports d''erreurs de reconnaissance d''écriture.'
        Fn = ''
        Needs = @()
        Reg = @(
            @('HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization', 'RestrictImplicitInkCollection', 1, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization', 'RestrictImplicitTextCollection', 1, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\HandwritingErrorReports', 'PreventHandwritingErrorReports', 1, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\TabletPC', 'PreventHandwritingDataSharing', 1, 'DWord'),
            @('HKCU:\SOFTWARE\Microsoft\InputPersonalization\TrainedDataStore', 'HarvestContacts', 0, 'DWord')
        )
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'tel_media'; Group = 'Télémétrie et diagnostics'; Risk = 'safe'; Default = $true; Reboot = $false
        Label = 'Windows Media : DRM en ligne et métadonnées'
        Desc = 'Bloque l''accès Internet du DRM Windows Media et la récupération automatique des informations de CD, musiques et radios.'
        Fn = ''
        Needs = @()
        Reg = @(
            @('HKLM:\SOFTWARE\Policies\Microsoft\WMDRM', 'DisableOnline', 1, 'DWord'),
            @('HKCU:\SOFTWARE\Microsoft\MediaPlayer\Preferences', 'UsageTracking', 0, 'DWord'),
            @('HKCU:\Software\Policies\Microsoft\WindowsMediaPlayer', 'PreventCDDVDMetadataRetrieval', 1, 'DWord'),
            @('HKCU:\Software\Policies\Microsoft\WindowsMediaPlayer', 'PreventMusicFileMetadataRetrieval', 1, 'DWord'),
            @('HKCU:\Software\Policies\Microsoft\WindowsMediaPlayer', 'PreventRadioPresetsRetrieval', 1, 'DWord')
        )
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'tel_speech'; Group = 'Télémétrie et diagnostics'; Risk = 'warn'; Default = $false; Reboot = $false
        Label = 'Reconnaissance vocale en ligne'
        Desc = 'Désactive l''envoi de la voix aux serveurs Microsoft. La dictée vocale de Windows (Win+H) cesse alors de fonctionner.'
        Fn = ''
        Needs = @()
        Reg = @(,@('HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy', 'HasAccepted', 0, 'DWord'))
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'ads_all'; Group = 'Publicités, recherche et suggestions'; Risk = 'safe'; Default = $true; Reboot = $false
        Label = 'Publicités ciblées, contenus sponsorisés et applications suggérées'
        Desc = 'Identifiant publicitaire, expériences personnalisées, suggestions du menu Démarrer et des Paramètres, installation automatique d''applications sponsorisées.'
        Fn = ''
        Needs = @()
        Reg = @(
            @('HKCU:\Control Panel\International\User Profile', 'HttpAcceptLanguageOptOut', 1, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent', 'DisableSoftLanding', 1, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent', 'DisableWindowsConsumerFeatures', 1, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent', 'DisableTailoredExperiencesWithDiagnosticData', 1, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent', 'DisableCloudOptimizedContent', 1, 'DWord'),
            @('HKCU:\Software\Policies\Microsoft\Windows\CloudContent', 'DisableTailoredExperiencesWithDiagnosticData', 1, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo', 'DisabledByGroupPolicy', 1, 'DWord'),
            @('HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo', 'Enabled', 0, 'DWord'),
            @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy', 'TailoredExperiencesWithDiagnosticDataEnabled', 0, 'DWord'),
            @('HKLM:\Software\Microsoft\Windows\CurrentVersion\SystemSettings\AccountNotifications', 'EnableAccountNotifications', 0, 'DWord'),
            @('HKCU:\Software\Microsoft\Windows\CurrentVersion\SystemSettings\AccountNotifications', 'EnableAccountNotifications', 0, 'DWord'),
            @('HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'ContentDeliveryAllowed', 0, 'DWord'),
            @('HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SubscribedContentEnabled', 0, 'DWord'),
            @('HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'OemPreInstalledAppsEnabled', 0, 'DWord'),
            @('HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'PreInstalledAppsEnabled', 0, 'DWord'),
            @('HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'PreInstalledAppsEverEnabled', 0, 'DWord'),
            @('HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SilentInstalledAppsEnabled', 0, 'DWord'),
            @('HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SystemPaneSuggestionsEnabled', 0, 'DWord'),
            @('HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'FeatureManagementEnabled', 0, 'DWord'),
            @('HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SoftLandingEnabled', 0, 'DWord'),
            @('HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SubscribedContent-338393Enabled', 0, 'DWord'),
            @('HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SubscribedContent-353694Enabled', 0, 'DWord'),
            @('HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SubscribedContent-353696Enabled', 0, 'DWord'),
            @('HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SubscribedContent-338387Enabled', 0, 'DWord'),
            @('HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SubscribedContent-338388Enabled', 0, 'DWord'),
            @('HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SubscribedContent-338389Enabled', 0, 'DWord'),
            @('HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SubscribedContent-353698Enabled', 0, 'DWord'),
            @('HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SubscribedContent-310093Enabled', 0, 'DWord')
        )
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'ads_spotlight'; Group = 'Publicités, recherche et suggestions'; Risk = 'warn'; Default = $false; Reboot = $false
        Label = 'Windows à la une (Spotlight) : images et astuces de l''écran de verrouillage'
        Desc = 'Supprime les images changeantes et les astuces de l''écran de verrouillage. Le fond de l''écran de verrouillage reste fixe.'
        Fn = ''
        Needs = @()
        Reg = @(,@('HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent', 'DisableWindowsSpotlightFeatures', 1, 'DWord'))
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'search_web'; Group = 'Publicités, recherche et suggestions'; Risk = 'safe'; Default = $true; Reboot = $false
        Label = 'Recherche Windows : sans Bing, sans cloud'
        Desc = 'La recherche du menu Démarrer ne consulte plus Internet, la localisation ni le compte Microsoft. L''index local des fichiers est conservé.'
        Fn = ''
        Needs = @()
        Reg = @(
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search', 'ConnectedSearchPrivacy', 3, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search', 'AllowSearchToUseLocation', 0, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search', 'EnableDynamicContentInWSB', 0, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search', 'ConnectedSearchUseWeb', 0, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search', 'ConnectedSearchUseWebOverMeteredConnections', 0, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search', 'DisableWebSearch', 1, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search', 'PreventRemoteQueries', 1, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search', 'AllowCloudSearch', 0, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer', 'DisableSearchBoxSuggestions', 1, 'DWord'),
            @('HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings', 'IsDynamicSearchBoxEnabled', 0, 'DWord'),
            @('HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings', 'IsMSACloudSearchEnabled', 0, 'DWord'),
            @('HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings', 'IsAADCloudSearchEnabled', 0, 'DWord'),
            @('HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings', 'IsDeviceSearchHistoryEnabled', 0, 'DWord'),
            @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Search', 'BingSearchEnabled', 0, 'DWord'),
            @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Search', 'DeviceHistoryEnabled', 0, 'DWord'),
            @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Search', 'HistoryViewEnabled', 0, 'DWord'),
            @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Search', 'VoiceShortcut', 0, 'DWord'),
            @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced', 'Start_IrisRecommendations', 0, 'DWord')
        )
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'maps'; Group = 'Publicités, recherche et suggestions'; Risk = 'safe'; Default = $true; Reboot = $false
        Label = 'Cartes hors connexion : aucun téléchargement automatique'
        Desc = 'Empêche Windows de télécharger et de mettre à jour les cartes en arrière-plan.'
        Fn = ''
        Needs = @()
        Reg = @(
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\Maps', 'AutoDownloadAndUpdateMapData', 0, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\Maps', 'AllowUntriggeredNetworkTrafficOnSettingsPage', 0, 'DWord')
        )
        Svc = @(,@('MapsBroker', 'demand'))
        Task = @(
            @('\Microsoft\Windows\Maps\', 'MapsUpdateTask'),
            @('\Microsoft\Windows\Maps\', 'MapsToastTask')
        )
        Feat = @()
    },
    @{
        Id = 'ai_copilot'; Group = 'IA et Copilot'; Risk = 'safe'; Default = $true; Reboot = $false
        Label = 'Copilot : masquer le bouton et appliquer la stratégie'
        Desc = 'Depuis Windows 11 24H2, Copilot est une application : pour la retirer complètement, utilisez la liste des applications préinstallées (page Applications). La stratégie couvre les versions antérieures.'
        Fn = ''
        Needs = @()
        Reg = @(
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot', 'TurnOffWindowsCopilot', 1, 'DWord'),
            @('HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot', 'TurnOffWindowsCopilot', 1, 'DWord'),
            @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced', 'ShowCopilotButton', 0, 'DWord'),
            @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings', 'AutoOpenCopilotLargeScreens', 0, 'DWord')
        )
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'ai_recall'; Group = 'IA et Copilot'; Risk = 'safe'; Default = $true; Reboot = $false
        Label = 'Recall et analyse des données par l''IA'
        Desc = 'Bloque l''analyse IA de l''activité et désactive la fonctionnalité Recall si elle est présente (PC Copilot+ uniquement).'
        Fn = ''
        Needs = @()
        Reg = @(
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI', 'DisableAIDataAnalysis', 1, 'DWord'),
            @('HKCU:\Software\Policies\Microsoft\Windows\WindowsAI', 'DisableAIDataAnalysis', 1, 'DWord')
        )
        Svc = @()
        Task = @()
        Feat = @(,@('feature', 'Recall'))
    },
    @{
        Id = 'ai_notepad'; Group = 'IA et Copilot'; Risk = 'safe'; Default = $true; Reboot = $false
        Label = 'Bloc-notes : fonctions IA (Réécrire)'
        Desc = 'Retire les fonctions d''intelligence artificielle du Bloc-notes.'
        Fn = ''
        Needs = @()
        Reg = @(
            @('HKLM:\SOFTWARE\Policies\WindowsNotepad', 'DisableAIFeatures', 1, 'DWord'),
            @('HKCU:\Software\Microsoft\Notepad', 'ShowRewriteButton', 0, 'DWord')
        )
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'app_edge'; Group = 'Navigateurs et logiciels tiers'; Risk = 'safe'; Default = $true; Reboot = $false
        Label = 'Edge : retirer les fonctions superflues (stratégies)'
        Desc = 'Désactive recommandations, boutique, collections, achats, barre latérale, démarrage anticipé et télémétrie. Edge affichera « géré par votre organisation » : c''est normal avec les stratégies.'
        Fn = ''
        Needs = @()
        Reg = @(
            @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'EdgeEnhanceImagesEnabled', 0, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'PersonalizationReportingEnabled', 0, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'ShowRecommendationsEnabled', 0, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'HideFirstRunExperience', 1, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'UserFeedbackAllowed', 0, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'ConfigureDoNotTrack', 1, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'AlternateErrorPagesEnabled', 0, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'EdgeCollectionsEnabled', 0, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'EdgeShoppingAssistantEnabled', 0, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'MicrosoftEdgeInsiderPromotionEnabled', 0, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'RelatedMatchesCloudServiceEnabled', 0, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'ShowMicrosoftRewards', 0, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'MetricsReportingEnabled', 0, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'StartupBoostEnabled', 0, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'SendSiteInfoToImproveServices', 0, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'SpotlightExperiencesAndRecommendationsEnabled', 0, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'DiagnosticData', 0, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'EdgeAssetDeliveryServiceEnabled', 0, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'HubsSidebarEnabled', 0, 'DWord')
        )
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'app_brave'; Group = 'Navigateurs et logiciels tiers'; Risk = 'safe'; Default = $true; Reboot = $false
        Label = 'Brave : retirer Rewards, Wallet, Chat IA et télémétrie'
        Desc = 'Appliqué seulement si Brave est installé.'
        Fn = ''
        Needs = @('C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe', 'C:\Program Files (x86)\BraveSoftware\Brave-Browser\Application\brave.exe', '%LOCALAPPDATA%\BraveSoftware\Brave-Browser\Application\brave.exe')
        Reg = @(
            @('HKLM:\SOFTWARE\Policies\BraveSoftware\Brave', 'BraveRewardsDisabled', 1, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\BraveSoftware\Brave', 'BraveWalletDisabled', 1, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\BraveSoftware\Brave', 'BraveAIChatEnabled', 0, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\BraveSoftware\Brave', 'BraveStatsPingEnabled', 0, 'DWord')
        )
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'app_office'; Group = 'Navigateurs et logiciels tiers'; Risk = 'safe'; Default = $true; Reboot = $false
        Label = 'Microsoft Office : télémétrie'
        Desc = 'Appliqué seulement si Office a déjà été utilisé sur ce compte.'
        Fn = ''
        Needs = @('HKCU:\SOFTWARE\Microsoft\Office')
        Reg = @(
            @('HKCU:\SOFTWARE\Microsoft\Office\15.0\Outlook\Options\Mail', 'EnableLogging', 0, 'DWord'),
            @('HKCU:\SOFTWARE\Microsoft\Office\15.0\Outlook\Options\Calendar', 'EnableCalendarLogging', 0, 'DWord'),
            @('HKCU:\SOFTWARE\Microsoft\Office\15.0\Word\Options', 'EnableLogging', 0, 'DWord'),
            @('HKCU:\SOFTWARE\Policies\Microsoft\Office\15.0\OSM', 'EnableLogging', 0, 'DWord'),
            @('HKCU:\SOFTWARE\Policies\Microsoft\Office\15.0\OSM', 'EnableUpload', 0, 'DWord'),
            @('HKCU:\SOFTWARE\Microsoft\Office\15.0\Common', 'QMEnable', 0, 'DWord'),
            @('HKCU:\SOFTWARE\Microsoft\Office\15.0\Common\Feedback', 'Enabled', 0, 'DWord'),
            @('HKCU:\SOFTWARE\Microsoft\Office\16.0\Outlook\Options\Mail', 'EnableLogging', 0, 'DWord'),
            @('HKCU:\SOFTWARE\Microsoft\Office\16.0\Outlook\Options\Calendar', 'EnableCalendarLogging', 0, 'DWord'),
            @('HKCU:\SOFTWARE\Microsoft\Office\16.0\Word\Options', 'EnableLogging', 0, 'DWord'),
            @('HKCU:\SOFTWARE\Policies\Microsoft\Office\16.0\OSM', 'EnableLogging', 0, 'DWord'),
            @('HKCU:\SOFTWARE\Policies\Microsoft\Office\16.0\OSM', 'EnableUpload', 0, 'DWord'),
            @('HKCU:\SOFTWARE\Microsoft\Office\16.0\Common', 'QMEnable', 0, 'DWord'),
            @('HKCU:\SOFTWARE\Microsoft\Office\16.0\Common\Feedback', 'Enabled', 0, 'DWord'),
            @('HKCU:\SOFTWARE\Microsoft\Office\Common\ClientTelemetry', 'DisableTelemetry', 1, 'DWord'),
            @('HKCU:\SOFTWARE\Microsoft\Office\16.0\Common\ClientTelemetry', 'DisableTelemetry', 1, 'DWord'),
            @('HKCU:\SOFTWARE\Microsoft\Office\Common\ClientTelemetry', 'VerboseLogging', 0, 'DWord'),
            @('HKCU:\SOFTWARE\Microsoft\Office\16.0\Common\ClientTelemetry', 'VerboseLogging', 0, 'DWord')
        )
        Svc = @()
        Task = @(
            @('\Microsoft\Office\', 'OfficeTelemetryAgentFallBack'),
            @('\Microsoft\Office\', 'OfficeTelemetryAgentLogOn'),
            @('\Microsoft\Office\', 'OfficeTelemetryAgentFallBack2016'),
            @('\Microsoft\Office\', 'OfficeTelemetryAgentLogOn2016'),
            @('\Microsoft\Office\', 'Office 15 Subscription Heartbeat'),
            @('\Microsoft\Office\', 'Office 16 Subscription Heartbeat')
        )
        Feat = @()
    },
    @{
        Id = 'app_nvidia'; Group = 'Navigateurs et logiciels tiers'; Risk = 'safe'; Default = $true; Reboot = $false
        Label = 'NVIDIA : télémétrie'
        Desc = 'Désactive la collecte NVIDIA et ses tâches planifiées. Le pilote graphique et l''application NVIDIA ne sont pas touchés. Appliqué seulement si un pilote NVIDIA est installé.'
        Fn = ''
        Needs = @('HKLM:\SOFTWARE\NVIDIA Corporation')
        Reg = @(
            @('HKLM:\SOFTWARE\NVIDIA Corporation\NvControlPanel2\Client', 'OptInOrOutPreference', 0, 'DWord'),
            @('HKLM:\SOFTWARE\NVIDIA Corporation\Global\FTS', 'EnableRID44231', 0, 'DWord'),
            @('HKLM:\SOFTWARE\NVIDIA Corporation\Global\FTS', 'EnableRID64640', 0, 'DWord'),
            @('HKLM:\SOFTWARE\NVIDIA Corporation\Global\FTS', 'EnableRID66610', 0, 'DWord'),
            @('HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global\Startup', 'SendTelemetryData', 0, 'DWord')
        )
        Svc = @(,@('NvTelemetryContainer', 'disabled'))
        Task = @(
            @('\', 'NvTmMon_{B2FE1952-0186-46C3-BAEC-A80AA35AC5B8}'),
            @('\', 'NvTmRep_{B2FE1952-0186-46C3-BAEC-A80AA35AC5B8}'),
            @('\', 'NvTmRepOnLogon_{B2FE1952-0186-46C3-BAEC-A80AA35AC5B8}')
        )
        Feat = @()
    },
    @{
        Id = 'app_vs'; Group = 'Navigateurs et logiciels tiers'; Risk = 'safe'; Default = $true; Reboot = $false
        Label = 'Visual Studio : télémétrie et retours'
        Desc = 'Appliqué seulement si Visual Studio est installé.'
        Fn = ''
        Needs = @('HKLM:\SOFTWARE\Wow6432Node\Microsoft\VSCommon')
        Reg = @(
            @('HKLM:\SOFTWARE\Wow6432Node\Microsoft\VSCommon\14.0\SQM', 'OptIn', 0, 'DWord'),
            @('HKLM:\SOFTWARE\Wow6432Node\Microsoft\VSCommon\15.0\SQM', 'OptIn', 0, 'DWord'),
            @('HKLM:\SOFTWARE\Wow6432Node\Microsoft\VSCommon\16.0\SQM', 'OptIn', 0, 'DWord'),
            @('HKLM:\SOFTWARE\Wow6432Node\Microsoft\VSCommon\17.0\SQM', 'OptIn', 0, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\VisualStudio\SQM', 'OptIn', 0, 'DWord'),
            @('HKCU:\Software\Microsoft\VisualStudio\Telemetry', 'TurnOffSwitch', 1, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\VisualStudio\Feedback', 'DisableFeedbackDialog', 1, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\VisualStudio\Feedback', 'DisableEmailInput', 1, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\VisualStudio\Feedback', 'DisableScreenshotCapture', 1, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\VisualStudio\IntelliCode', 'DisableRemoteAnalysis', 1, 'DWord'),
            @('HKCU:\SOFTWARE\Microsoft\VSCommon\16.0\IntelliCode', 'DisableRemoteAnalysis', 1, 'DWord'),
            @('HKCU:\SOFTWARE\Microsoft\VSCommon\17.0\IntelliCode', 'DisableRemoteAnalysis', 1, 'DWord')
        )
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'app_ccleaner'; Group = 'Navigateurs et logiciels tiers'; Risk = 'safe'; Default = $true; Reboot = $false
        Label = 'CCleaner : surveillance et télémétrie'
        Desc = 'Appliqué seulement si CCleaner est installé.'
        Fn = ''
        Needs = @('HKCU:\Software\Piriform\CCleaner', 'HKLM:\Software\Piriform\CCleaner')
        Reg = @(
            @('HKCU:\Software\Piriform\CCleaner', 'Monitoring', 0, 'DWord'),
            @('HKCU:\Software\Piriform\CCleaner', 'HelpImproveCCleaner', 0, 'DWord'),
            @('HKCU:\Software\Piriform\CCleaner', 'SystemMonitoring', 0, 'DWord'),
            @('HKCU:\Software\Piriform\CCleaner', 'UpdateAuto', 0, 'DWord'),
            @('HKCU:\Software\Piriform\CCleaner', 'UpdateCheck', 0, 'DWord'),
            @('HKCU:\Software\Piriform\CCleaner', 'CheckTrialOffer', 0, 'DWord'),
            @('HKLM:\Software\Piriform\CCleaner', '(Cfg)HealthCheck', 0, 'DWord'),
            @('HKLM:\Software\Piriform\CCleaner', '(Cfg)QuickClean', 0, 'DWord'),
            @('HKLM:\Software\Piriform\CCleaner', '(Cfg)QuickCleanIpm', 0, 'DWord'),
            @('HKLM:\Software\Piriform\CCleaner', '(Cfg)GetIpmForTrial', 0, 'DWord'),
            @('HKLM:\Software\Piriform\CCleaner', '(Cfg)SoftwareUpdater', 0, 'DWord'),
            @('HKLM:\Software\Piriform\CCleaner', '(Cfg)SoftwareUpdaterIpm', 0, 'DWord')
        )
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'app_dev'; Group = 'Navigateurs et logiciels tiers'; Risk = 'safe'; Default = $true; Reboot = $true
        Label = 'PowerShell et .NET : télémétrie désactivée'
        Desc = 'Variables d''environnement système POWERSHELL_TELEMETRY_OPTOUT et DOTNET_CLI_TELEMETRY_OPTOUT. Effet à la prochaine ouverture de session.'
        Fn = ''
        Needs = @()
        Reg = @(
            @('HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment', 'POWERSHELL_TELEMETRY_OPTOUT', '1', 'String'),
            @('HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment', 'DOTNET_CLI_TELEMETRY_OPTOUT', '1', 'String')
        )
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'perm_location'; Group = 'Autorisations des applications'; Risk = 'warn'; Default = $false; Reboot = $false
        Label = 'Localisation'
        Desc = 'Refuse l''accès à la position. Désactive aussi le fuseau horaire automatique et la météo locale.'
        Fn = ''
        Needs = @()
        Reg = @(,@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location', 'Value', 'Deny', 'String'))
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'perm_camera'; Group = 'Autorisations des applications'; Risk = 'warn'; Default = $false; Reboot = $false
        Label = 'Caméra'
        Desc = 'Refuse la caméra à toutes les applications : visioconférence impossible tant que ce réglage est actif.'
        Fn = ''
        Needs = @()
        Reg = @(,@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam', 'Value', 'Deny', 'String'))
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'perm_mic'; Group = 'Autorisations des applications'; Risk = 'warn'; Default = $false; Reboot = $false
        Label = 'Microphone'
        Desc = 'Refuse le microphone à toutes les applications : visioconférence et dictée impossibles.'
        Fn = ''
        Needs = @()
        Reg = @(,@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone', 'Value', 'Deny', 'String'))
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'perm_files'; Group = 'Autorisations des applications'; Risk = 'warn'; Default = $false; Reboot = $false
        Label = 'Documents, images, vidéos et système de fichiers'
        Desc = 'Refuse l''accès aux bibliothèques aux applications du Store.'
        Fn = ''
        Needs = @()
        Reg = @(
            @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\documentsLibrary', 'Value', 'Deny', 'String'),
            @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\picturesLibrary', 'Value', 'Deny', 'String'),
            @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\videosLibrary', 'Value', 'Deny', 'String'),
            @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\broadFileSystemAccess', 'Value', 'Deny', 'String')
        )
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'perm_account'; Group = 'Autorisations des applications'; Risk = 'warn'; Default = $false; Reboot = $false
        Label = 'Informations de compte'
        Desc = 'Nom, image et informations du compte Microsoft.'
        Fn = ''
        Needs = @()
        Reg = @(,@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\userAccountInformation', 'Value', 'Deny', 'String'))
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'perm_contacts'; Group = 'Autorisations des applications'; Risk = 'safe'; Default = $false; Reboot = $false
        Label = 'Contacts'
        Desc = ''
        Fn = ''
        Needs = @()
        Reg = @(,@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\contacts', 'Value', 'Deny', 'String'))
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'perm_calendar'; Group = 'Autorisations des applications'; Risk = 'safe'; Default = $false; Reboot = $false
        Label = 'Calendrier'
        Desc = ''
        Fn = ''
        Needs = @()
        Reg = @(,@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\appointments', 'Value', 'Deny', 'String'))
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'perm_calls'; Group = 'Autorisations des applications'; Risk = 'safe'; Default = $false; Reboot = $false
        Label = 'Historique des appels'
        Desc = ''
        Fn = ''
        Needs = @()
        Reg = @(,@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\phoneCallHistory', 'Value', 'Deny', 'String'))
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'perm_messages'; Group = 'Autorisations des applications'; Risk = 'safe'; Default = $false; Reboot = $false
        Label = 'Messagerie (SMS/MMS)'
        Desc = ''
        Fn = ''
        Needs = @()
        Reg = @(,@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\chat', 'Value', 'Deny', 'String'))
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'perm_email'; Group = 'Autorisations des applications'; Risk = 'safe'; Default = $false; Reboot = $false
        Label = 'Courrier électronique'
        Desc = ''
        Fn = ''
        Needs = @()
        Reg = @(,@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\email', 'Value', 'Deny', 'String'))
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'perm_tasks'; Group = 'Autorisations des applications'; Risk = 'safe'; Default = $false; Reboot = $false
        Label = 'Tâches'
        Desc = ''
        Fn = ''
        Needs = @()
        Reg = @(,@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\userDataTasks', 'Value', 'Deny', 'String'))
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'perm_notif'; Group = 'Autorisations des applications'; Risk = 'safe'; Default = $false; Reboot = $false
        Label = 'Accès aux notifications'
        Desc = 'Empêche les applications de lire vos notifications.'
        Fn = ''
        Needs = @()
        Reg = @(,@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\userNotificationListener', 'Value', 'Deny', 'String'))
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'perm_diag'; Group = 'Autorisations des applications'; Risk = 'safe'; Default = $false; Reboot = $false
        Label = 'Diagnostics des applications'
        Desc = 'Empêche les applications de lire les informations des autres applications.'
        Fn = ''
        Needs = @()
        Reg = @(,@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\appDiagnostics', 'Value', 'Deny', 'String'))
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'perm_motion'; Group = 'Autorisations des applications'; Risk = 'safe'; Default = $false; Reboot = $false
        Label = 'Mouvement et activité'
        Desc = ''
        Fn = ''
        Needs = @()
        Reg = @(,@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\activity', 'Value', 'Deny', 'String'))
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'perm_radio'; Group = 'Autorisations des applications'; Risk = 'warn'; Default = $false; Reboot = $false
        Label = 'Radios (Bluetooth, Wi-Fi)'
        Desc = 'Certaines applications ne pourront plus activer ou désactiver le Bluetooth.'
        Fn = ''
        Needs = @()
        Reg = @(,@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\radios', 'Value', 'Deny', 'String'))
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'perm_capture'; Group = 'Autorisations des applications'; Risk = 'warn'; Default = $false; Reboot = $false
        Label = 'Captures d''écran sans bordure et enregistrements programmatiques'
        Desc = 'Peut gêner certains logiciels d''enregistrement ou de partage d''écran.'
        Fn = ''
        Needs = @()
        Reg = @(
            @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\graphicsCaptureWithoutBorder', 'Value', 'Deny', 'String'),
            @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\graphicsCaptureProgrammatic', 'Value', 'Deny', 'String')
        )
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'perm_ai'; Group = 'Autorisations des applications'; Risk = 'safe'; Default = $false; Reboot = $false
        Label = 'Modèles d''IA du système'
        Desc = ''
        Fn = ''
        Needs = @()
        Reg = @(,@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\systemAIModels', 'Value', 'Deny', 'String'))
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'perm_voice'; Group = 'Autorisations des applications'; Risk = 'safe'; Default = $false; Reboot = $false
        Label = 'Activation vocale des applications'
        Desc = ''
        Fn = ''
        Needs = @()
        Reg = @(,@('HKCU:\Software\Microsoft\Speech_OneCore\Settings\VoiceActivation\UserPreferenceForAllApps', 'AgentActivationEnabled', 0, 'DWord'))
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'perm_trusted'; Group = 'Autorisations des applications'; Risk = 'safe'; Default = $false; Reboot = $false
        Label = 'Appareils de confiance'
        Desc = ''
        Fn = ''
        Needs = @()
        Reg = @(,@('HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeviceAccess\Global\{C1D23ACC-752B-43E5-8448-8D0E519CD6D6}', 'Value', 'Deny', 'String'))
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'perm_phone'; Group = 'Autorisations des applications'; Risk = 'safe'; Default = $false; Reboot = $false
        Label = 'Téléphone (stratégie)'
        Desc = 'Refuse aux applications l''accès aux appels téléphoniques.'
        Fn = ''
        Needs = @()
        Reg = @(,@('HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy', 'LetAppsAccessPhone', 2, 'DWord'))
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'ui_endtask'; Group = 'Interface et Explorateur'; Risk = 'safe'; Default = $true; Reboot = $false
        Label = 'Terminer la tâche dans le menu de la barre des tâches'
        Desc = 'Clic droit sur une application de la barre des tâches : « Terminer la tâche ».'
        Fn = ''
        Needs = @()
        Reg = @(,@('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings', 'TaskbarEndTask', 1, 'DWord'))
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'ui_classic'; Group = 'Interface et Explorateur'; Risk = 'safe'; Default = $false; Reboot = $false
        Label = 'Menu contextuel classique (clic droit complet)'
        Desc = 'Rétablit le menu complet sans devoir cliquer sur « Afficher plus d''options ». Se défait depuis le Journal.'
        Fn = 'Enable-ClassicContextMenu'
        Needs = @()
        Reg = @()
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'ui_hidden'; Group = 'Interface et Explorateur'; Risk = 'safe'; Default = $false; Reboot = $false
        Label = 'Afficher les fichiers cachés'
        Desc = ''
        Fn = ''
        Needs = @()
        Reg = @(,@('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced', 'Hidden', 1, 'DWord'))
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'ui_fileext'; Group = 'Interface et Explorateur'; Risk = 'safe'; Default = $true; Reboot = $false
        Label = 'Afficher les extensions de fichiers'
        Desc = 'Évite d''ouvrir par erreur un fichier piégé (facture.pdf.exe) et facilite le dépannage.'
        Fn = ''
        Needs = @()
        Reg = @(,@('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced', 'HideFileExt', 0, 'DWord'))
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'ui_startdelay'; Group = 'Interface et Explorateur'; Risk = 'safe'; Default = $true; Reboot = $false
        Label = 'Applications de démarrage sans délai artificiel'
        Desc = 'Supprime l''attente que Windows impose avant de lancer les programmes de démarrage. Effet à la prochaine session.'
        Fn = ''
        Needs = @()
        Reg = @(,@('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize', 'StartupDelayInMSec', 0, 'DWord'))
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'ui_homegallery'; Group = 'Interface et Explorateur'; Risk = 'safe'; Default = $false; Reboot = $false
        Label = 'Retirer Accueil et Galerie du volet de navigation'
        Desc = 'L''Explorateur s''ouvre sur « Ce PC ».'
        Fn = ''
        Needs = @()
        Reg = @(
            @('HKCU:\Software\Classes\CLSID\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}', 'System.IsPinnedToNameSpaceTree', 0, 'DWord'),
            @('HKCU:\Software\Classes\CLSID\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}', 'System.IsPinnedToNameSpaceTree', 0, 'DWord'),
            @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced', 'LaunchTo', 1, 'DWord')
        )
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'ui_recent'; Group = 'Interface et Explorateur'; Risk = 'safe'; Default = $false; Reboot = $false
        Label = 'Masquer les applications récemment ajoutées du menu Démarrer'
        Desc = ''
        Fn = ''
        Needs = @()
        Reg = @(,@('HKCU:\Software\Microsoft\Windows\CurrentVersion\Start', 'ShowRecentList', 0, 'DWord'))
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'ui_snap'; Group = 'Interface et Explorateur'; Risk = 'safe'; Default = $false; Reboot = $false
        Label = 'Désactiver le menu d''ancrage au survol du bouton Agrandir'
        Desc = 'Supprime le menu de placement qui s''affiche au survol.'
        Fn = ''
        Needs = @()
        Reg = @(,@('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced', 'EnableSnapAssistFlyout', 0, 'DWord'))
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'ui_left'; Group = 'Interface et Explorateur'; Risk = 'safe'; Default = $false; Reboot = $false
        Label = 'Icônes de la barre des tâches alignées à gauche'
        Desc = ''
        Fn = ''
        Needs = @()
        Reg = @(,@('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced', 'TaskbarAl', 0, 'DWord'))
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'ui_widgets'; Group = 'Interface et Explorateur'; Risk = 'safe'; Default = $false; Reboot = $true
        Label = 'Widgets et fil d''actualités désactivés'
        Desc = 'Stratégie système : le bouton Widgets disparaît (redémarrage de session conseillé).'
        Fn = ''
        Needs = @()
        Reg = @(
            @('HKLM:\SOFTWARE\Policies\Microsoft\Dsh', 'AllowNewsAndInterests', 0, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds', 'EnableFeeds', 0, 'DWord')
        )
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'ui_taskview'; Group = 'Interface et Explorateur'; Risk = 'safe'; Default = $false; Reboot = $false
        Label = 'Masquer le bouton Vue des tâches'
        Desc = ''
        Fn = ''
        Needs = @()
        Reg = @(,@('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced', 'ShowTaskViewButton', 0, 'DWord'))
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'ui_transp'; Group = 'Interface et Explorateur'; Risk = 'safe'; Default = $false; Reboot = $false
        Label = 'Désactiver les effets de transparence'
        Desc = 'Interface plus lisible et un peu plus légère pour le GPU.'
        Fn = ''
        Needs = @()
        Reg = @(,@('HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize', 'EnableTransparency', 0, 'DWord'))
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'ui_delay'; Group = 'Interface et Explorateur'; Risk = 'safe'; Default = $false; Reboot = $false
        Label = 'Menus et infobulles instantanés'
        Desc = 'Supprime le délai d''ouverture des menus (400 ms) et de survol.'
        Fn = ''
        Needs = @()
        Reg = @(
            @('HKCU:\Control Panel\Desktop', 'MenuShowDelay', '0', 'String'),
            @('HKCU:\Control Panel\Mouse', 'MouseHoverTime', '0', 'String')
        )
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'ui_sticky'; Group = 'Interface et Explorateur'; Risk = 'safe'; Default = $true; Reboot = $false
        Label = 'Touches rémanentes : plus de fenêtre au 5e appui sur Maj'
        Desc = ''
        Fn = ''
        Needs = @()
        Reg = @(,@('HKCU:\Control Panel\Accessibility\StickyKeys', 'Flags', '58', 'String'))
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'ui_numlock'; Group = 'Interface et Explorateur'; Risk = 'safe'; Default = $false; Reboot = $false
        Label = 'Pavé numérique activé à l''ouverture de session'
        Desc = 'Avec le démarrage rapide, l''état peut être conservé de la session précédente.'
        Fn = ''
        Needs = @()
        Reg = @(,@('HKCU:\Control Panel\Keyboard', 'InitialKeyboardIndicators', '2', 'String'))
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'ui_bsod'; Group = 'Démarrage et diagnostic'; Risk = 'safe'; Default = $true; Reboot = $false
        Label = 'Écran bleu détaillé'
        Desc = 'Affiche les paramètres du code d''arrêt (utile pour le diagnostic).'
        Fn = ''
        Needs = @()
        Reg = @(,@('HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl', 'DisplayParameters', 1, 'DWord'))
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'ui_verbose'; Group = 'Démarrage et diagnostic'; Risk = 'safe'; Default = $true; Reboot = $false
        Label = 'Messages détaillés à l''ouverture et à la fermeture de session'
        Desc = 'Affiche ce que Windows est en train de faire plutôt que « Veuillez patienter ».'
        Fn = ''
        Needs = @()
        Reg = @(,@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System', 'VerboseStatus', 1, 'DWord'))
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'ui_gamebar'; Group = 'Barre de jeu et capture'; Risk = 'warn'; Default = $false; Reboot = $false
        Label = 'Désactiver complètement la barre de jeu Xbox et la capture (stratégie)'
        Desc = 'Avec une manette Xbox, Windows peut afficher un message « ms-gamingoverlay » : réactivez ce réglage depuis le Journal si cela arrive.'
        Fn = ''
        Needs = @()
        Reg = @(
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR', 'AllowGameDVR', 0, 'DWord'),
            @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR', 'AppCaptureEnabled', 0, 'DWord'),
            @('HKCU:\SOFTWARE\Microsoft\GameBar', 'ShowStartupPanel', 0, 'DWord')
        )
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'ui_notif'; Group = 'Interface et Explorateur'; Risk = 'warn'; Default = $false; Reboot = $false
        Label = 'Désactiver le centre de notifications'
        Desc = 'Les notifications n''apparaissent plus et le panneau est inaccessible.'
        Fn = ''
        Needs = @()
        Reg = @(,@('HKCU:\Software\Policies\Microsoft\Windows\Explorer', 'DisableNotificationCenter', 1, 'DWord'))
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'ui_utc'; Group = 'Démarrage et diagnostic'; Risk = 'warn'; Default = $false; Reboot = $false
        Label = 'Horloge matérielle en UTC (double démarrage avec Linux)'
        Desc = 'À n''utiliser que si Linux est installé en double démarrage. Sinon, l''heure sera décalée jusqu''à la prochaine synchronisation.'
        Fn = ''
        Needs = @()
        Reg = @(,@('HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation', 'RealTimeIsUniversal', 1, 'DWord'))
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'upd_defer'; Group = 'Mises à jour Windows'; Risk = 'safe'; Default = $false; Reboot = $false
        Label = 'Reporter les mises à jour de fonctionnalités d''un an'
        Desc = 'Les mises à jour de sécurité et de qualité continuent d''être installées normalement. Seules les grandes versions (24H2, 25H2…) sont retardées.'
        Fn = ''
        Needs = @()
        Reg = @(
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate', 'DeferFeatureUpdates', 1, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate', 'DeferFeatureUpdatesPeriodInDays', 365, 'DWord')
        )
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'upd_do'; Group = 'Mises à jour Windows'; Risk = 'safe'; Default = $true; Reboot = $false
        Label = 'Optimisation de la distribution : pas de partage entre PC'
        Desc = 'Mode « HTTP seul » : Windows ne partage plus les mises à jour avec d''autres PC d''Internet.'
        Fn = ''
        Needs = @()
        Reg = @(,@('HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization', 'DODownloadMode', 0, 'DWord'))
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'upd_drivers'; Group = 'Mises à jour Windows'; Risk = 'warn'; Default = $false; Reboot = $false
        Label = 'Ne pas installer de pilotes via Windows Update'
        Desc = 'Évite que Windows remplace un pilote graphique ou chipset récent. Vous devrez mettre à jour les pilotes vous-même.'
        Fn = ''
        Needs = @()
        Reg = @(
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate', 'ExcludeWUDriversInQualityUpdate', 1, 'DWord'),
            @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching', 'SearchOrderConfig', 0, 'DWord')
        )
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'upd_store'; Group = 'Mises à jour Windows'; Risk = 'warn'; Default = $false; Reboot = $false
        Label = 'Mises à jour automatiques du Microsoft Store désactivées'
        Desc = 'Les applications du Store ne seront plus mises à jour seules (winget peut s''en charger).'
        Fn = ''
        Needs = @()
        Reg = @(,@('HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore', 'AutoDownload', 2, 'DWord'))
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'upd_pause'; Group = 'Mises à jour Windows'; Risk = 'warn'; Default = $false; Reboot = $false
        Label = 'Prolonger la durée maximale de suspension à 20 ans'
        Desc = 'Ne suspend rien en soi : permet seulement de suspendre ensuite les mises à jour pour plus de 5 semaines. À éviter sur un PC connecté.'
        Fn = ''
        Needs = @()
        Reg = @(,@('HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings', 'FlightSettingsMaxPauseDays', 7300, 'DWord'))
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'sec_defender'; Group = 'Sécurité'; Risk = 'safe'; Default = $true; Reboot = $false
        Label = 'Defender : limiter l''analyse à 25 % du processeur'
        Desc = 'Les analyses planifiées gênent moins. La protection en temps réel n''est pas modifiée.'
        Fn = ''
        Needs = @()
        Reg = @(,@('HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Scan', 'AvgCPULoadFactor', 25, 'DWord'))
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'sec_lockcam'; Group = 'Sécurité'; Risk = 'safe'; Default = $true; Reboot = $false
        Label = 'Caméra de l''écran de verrouillage désactivée'
        Desc = ''
        Fn = ''
        Needs = @()
        Reg = @(,@('HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization', 'NoLockScreenCamera', 1, 'DWord'))
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'sec_wpbt'; Group = 'Sécurité'; Risk = 'safe'; Default = $false; Reboot = $false
        Label = 'Empêcher le BIOS d''installer des logiciels dans Windows (WPBT)'
        Desc = 'Bloque l''exécution des programmes injectés par le firmware au démarrage. Certains fabricants (ASUS Armoury Crate) s''installent ainsi : cela ne les empêche pas de fonctionner une fois installés.'
        Fn = ''
        Needs = @()
        Reg = @(,@('HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager', 'DisableWpbtExecution', 1, 'DWord'))
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'sec_bitlocker'; Group = 'Sécurité'; Risk = 'warn'; Default = $false; Reboot = $false
        Label = 'Empêcher le chiffrement automatique de l''appareil'
        Desc = 'Ne déchiffre rien. Évite seulement que Windows chiffre le disque tout seul à la première connexion avec un compte Microsoft.'
        Fn = ''
        Needs = @()
        Reg = @(,@('HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker', 'PreventDeviceEncryption', 1, 'DWord'))
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'sec_sync'; Group = 'Télémétrie et diagnostics'; Risk = 'warn'; Default = $false; Reboot = $false
        Label = 'Synchronisation des paramètres Windows avec le compte Microsoft désactivée'
        Desc = 'Thèmes, mots de passe Wi-Fi, langue et préférences ne sont plus synchronisés entre vos PC.'
        Fn = ''
        Needs = @()
        Reg = @(
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync', 'DisableSettingSync', 2, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync', 'DisableSettingSyncUserOverride', 1, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync', 'DisableCredentialsSettingSync', 2, 'DWord'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync', 'DisableCredentialsSettingSyncUserOverride', 1, 'DWord')
        )
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'sec_ipv4'; Group = 'Pile réseau'; Risk = 'safe'; Default = $false; Reboot = $true
        Label = 'Préférer IPv4 à IPv6'
        Desc = 'Windows essaie IPv4 en premier. IPv6 reste actif (c''est la méthode recommandée plutôt que de le désactiver).'
        Fn = ''
        Needs = @()
        Reg = @(,@('HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters', 'DisabledComponents', 32, 'DWord'))
        Svc = @()
        Task = @()
        Feat = @()
    },
    @{
        Id = 'feat_ie'; Group = 'Fonctionnalités Windows facultatives'; Risk = 'safe'; Default = $false; Reboot = $false
        Label = 'Internet Explorer (mode hérité)'
        Desc = 'Retire le composant s''il est encore présent. Réactivable depuis le Journal.'
        Fn = ''
        Needs = @()
        Reg = @()
        Svc = @()
        Task = @()
        Feat = @(,@('feature', 'Internet-Explorer-Optional-amd64'))
    },
    @{
        Id = 'feat_fax'; Group = 'Fonctionnalités Windows facultatives'; Risk = 'safe'; Default = $false; Reboot = $false
        Label = 'Télécopie et numérisation Windows'
        Desc = ''
        Fn = ''
        Needs = @()
        Reg = @()
        Svc = @()
        Task = @()
        Feat = @(,@('feature', 'FaxServicesClientPackage'))
    },
    @{
        Id = 'feat_wmp'; Group = 'Fonctionnalités Windows facultatives'; Risk = 'safe'; Default = $false; Reboot = $false
        Label = 'Windows Media Player (version héritée)'
        Desc = 'Retire l''ancien lecteur. Le nouveau lecteur multimédia n''est pas concerné. Réactivation depuis le Journal (nécessite Internet).'
        Fn = ''
        Needs = @()
        Reg = @()
        Svc = @()
        Task = @()
        Feat = @(
            @('feature', 'WindowsMediaPlayer'),
            @('cap', 'Media.WindowsMediaPlayer*')
        )
    }
)

# ---------------------------------------------------------------- Application des réglages
function Get-Tuples {
    # Normalise une liste de n-uplets. La virgule devant le retour empêche PowerShell d'aplatir
    # une liste qui ne contient qu'un seul n-uplet.
    param($Items)
    $list = @($Items)
    if ($list.Count -eq 0) { return , @() }
    if ($list[0] -is [string]) { return , @(, $list) }
    return , $list
}

function Test-AnyPath {
    param($Paths)
    foreach ($p in @($Paths)) {
        if (-not $p) { continue }
        $e = [Environment]::ExpandEnvironmentVariables([string]$p)
        if (Test-Path -LiteralPath $e) { return $true }
    }
    return $false
}

function Set-OptionalItem {
    # Désactive une fonctionnalité Windows facultative (feature) ou une capacité (cap), avec retour arrière.
    param([string]$Kind, [string]$Name)
    try {
        if ($Kind -eq 'feature') {
            $f = $null
            try { $f = Get-WindowsOptionalFeature -Online -FeatureName $Name -ErrorAction Stop } catch { $f = $null }
            if (-not $f -or [string]$f.State -ne 'Enabled') { Write-Log "Fonctionnalité absente de ce Windows ou déjà désactivée : $Name"; return }
            Add-Orig "feature|$Name" @{ Type = 'feature'; Name = $Name }
            Disable-WindowsOptionalFeature -Online -FeatureName $Name -NoRestart -ErrorAction Stop | Out-Null
            Write-Log "Fonctionnalité désactivée : $Name (redémarrage nécessaire)" 'OK'
            $Script:RebootNeeded = $true
        } elseif ($Kind -eq 'cap') {
            $caps = @(Get-WindowsCapability -Online -ErrorAction Stop | Where-Object { $_.Name -like $Name -and [string]$_.State -eq 'Installed' })
            if ($caps.Count -eq 0) { Write-Log "Capacité absente ou déjà retirée : $Name"; return }
            foreach ($c in $caps) {
                Add-Orig "cap|$($c.Name)" @{ Type = 'cap'; Name = [string]$c.Name }
                Remove-WindowsCapability -Online -Name $c.Name -ErrorAction Stop | Out-Null
                Write-Log "Capacité retirée : $($c.Name)" 'OK'
            }
        }
    } catch {
        Write-Log "Fonctionnalité $Name : $($_.Exception.Message)" 'WARN'
    }
}

function Enable-ClassicContextMenu {
    # Menu contextuel complet de Windows 10 : une clé vide suffit. Annulable (type 'regkey').
    $k   = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}'
    $sub = "$k\InprocServer32"
    if (Test-Path -LiteralPath $sub) { Write-Log 'Menu contextuel classique déjà actif'; return }
    $created = if (Test-Path -LiteralPath $k) { $sub } else { $k }
    Add-Orig "regkey|$created" @{ Type = 'regkey'; Path = $created }
    try {
        New-Item -Path $sub -Force -Value '' -ErrorAction Stop | Out-Null
        Write-Log 'Menu contextuel classique activé (fermez puis rouvrez l''Explorateur ou la session)' 'OK'
    } catch { Write-Log "Menu contextuel : $($_.Exception.Message)" 'WARN' }
}

function Set-Tweaks {
    param([string[]]$Ids)
    $ok = 0; $skipped = 0
    foreach ($id in $Ids) {
        $t = $Script:TweakCatalog | Where-Object { $_.Id -eq $id } | Select-Object -First 1
        if (-not $t) { Write-Log "Réglage inconnu, ignoré : $id" 'WARN'; $skipped++; continue }
        if (@($t.Needs).Count -gt 0 -and -not (Test-AnyPath $t.Needs)) { Write-Log "Ignoré (logiciel non installé) : $($t.Label)"; $skipped++; continue }
        Write-Log "--- $($t.Label)"
        try {
            foreach ($r in (Get-Tuples $t.Reg))  { Set-Reg ([string]$r[0]) ([string]$r[1]) $r[2] ([string]$r[3]) }
            foreach ($s in (Get-Tuples $t.Svc))  { Set-SvcMode ([string]$s[0]) ([string]$s[1]) }
            foreach ($k in (Get-Tuples $t.Task)) { Disable-TaskSafe ([string]$k[0]) ([string]$k[1]) }
            foreach ($f in (Get-Tuples $t.Feat)) { Set-OptionalItem ([string]$f[0]) ([string]$f[1]) }
            if ($t.Fn) { & $t.Fn }
            if ($t.Reboot) { $Script:RebootNeeded = $true }
            $ok++
        } catch { Write-Log "$($t.Label) : $($_.Exception.Message)" 'WARN' }
    }
    Write-Log ("{0} réglage(s) appliqué(s), {1} ignoré(s). Annulation possible depuis la page Journal." -f $ok, $skipped) 'OK'
}

# ---------------------------------------------------------------- DNS : autres fournisseurs
$Script:DnsPresets = @{
    cloudflare = @{ Name = 'Cloudflare'; V4 = @('1.1.1.1', '1.0.0.1'); V6 = @('2606:4700:4700::1111', '2606:4700:4700::1001'); Doh = 'https://cloudflare-dns.com/dns-query' }
    google     = @{ Name = 'Google';     V4 = @('8.8.8.8', '8.8.4.4'); V6 = @('2001:4860:4860::8888', '2001:4860:4860::8844'); Doh = 'https://dns.google/dns-query' }
    quad9      = @{ Name = 'Quad9';      V4 = @('9.9.9.9', '149.112.112.112'); V6 = @('2620:fe::fe', '2620:fe::9'); Doh = 'https://dns.quad9.net/dns-query' }
    adguard    = @{ Name = 'AdGuard';    V4 = @('94.140.14.14', '94.140.15.15'); V6 = @('2a10:50c0::ad1:ff', '2a10:50c0::ad2:ff'); Doh = 'https://dns.adguard-dns.com/dns-query' }
    opendns    = @{ Name = 'OpenDNS';    V4 = @('208.67.222.222', '208.67.220.220'); V6 = @('2620:119:35::35', '2620:119:53::53'); Doh = 'https://doh.opendns.com/dns-query' }
}

function Set-DnsPreset {
    # DNS chiffré (DoH) avec repli UDP autorisé : si le fournisseur est injoignable, la résolution continue.
    param([string]$Provider)
    $p = $Script:DnsPresets[$Provider]
    if (-not $p) { Write-Log "Fournisseur DNS inconnu : $Provider" 'WARN'; return }
    $adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
    if ($adapters.Count -eq 0) { Write-Log 'Aucune carte physique active détectée' 'WARN'; return }
    $addrs = @($p.V4) + @($p.V6)
    foreach ($a in $adapters) {
        $k4 = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($a.InterfaceGuid)"
        $k6 = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters\Interfaces\$($a.InterfaceGuid)"
        Add-Orig "dns|$($a.Name)" @{ Type = 'dns'; Adapter = $a.Name; Index = $a.ifIndex; Static4 = [string](Get-RegValue $k4 'NameServer'); Static6 = [string](Get-RegValue $k6 'NameServer') }
        try {
            Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses $addrs -ErrorAction Stop
            Write-Log "DNS de $($a.Name) : $($p.Name) ($($addrs -join ', '))" 'OK'
        } catch { Write-Log "DNS de $($a.Name) : $($_.Exception.Message)" 'WARN' }
    }
    foreach ($ip in $addrs) { Invoke-Native 'netsh.exe' "dns add encryption server=$ip dohtemplate=$($p.Doh) autoupgrade=yes udpfallback=yes" }
    Invoke-Native 'ipconfig.exe' '/flushdns'
    Write-Log "DNS $($p.Name) configuré avec chiffrement (DoH). Retour possible avec « Revenir au DNS d'origine »." 'OK'
}

# ---------------------------------------------------------------- Plans d'alimentation Windows intégrés
function Set-BuiltinPowerPlan {
    param([string]$Mode)
    $src = switch ($Mode) {
        'balanced' { '381b4222-f694-41f0-9685-ff5bb260df2e' }
        'high'     { '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' }
        'ultimate' { 'e9a42b02-d5df-448d-aa00-03f14749eb61' }
        default    { $null }
    }
    if (-not $src) { Write-Log "Mode d'alimentation inconnu : $Mode" 'WARN'; return }
    $prev = Get-ActivePlanGuid
    $created = ''
    $target = $src
    $list = & powercfg.exe /list | Out-String
    if ($list -notmatch [regex]::Escape($src)) {
        $o = (& powercfg.exe -duplicatescheme $src $src 2>&1 | Out-String)
        if ($o -notmatch $Script:GuidRegex) { $o = (& powercfg.exe -duplicatescheme $src 2>&1 | Out-String) }
        if ($o -notmatch $Script:GuidRegex) {
            Write-Log "Ce mode n'est pas disponible sur ce PC (certains portables en veille moderne ne l'offrent pas)." 'WARN'
            return
        }
        $created = $Matches[1]
        $target = $created
    }
    if ($prev) { Add-Orig "power|builtin|$Mode" @{ Type = 'power'; OriginalGuid = $prev; NewGuid = $created } }
    & powercfg.exe /setactive $target | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Log "Plan d'alimentation actif : $Mode ($target)" 'OK' }
    else { Write-Log "Activation du plan impossible (code $LASTEXITCODE)" 'WARN' }
}
