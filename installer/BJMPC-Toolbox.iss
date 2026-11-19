; BJMPC Toolbox - installateur (Inno Setup 6)
; Compilé par GitHub Actions : ISCC /DAppVersion=x.y.z /DSourceDir=..\staging [/DSIGN] installer\BJMPC-Toolbox.iss

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir ".."
#endif

[Setup]
AppId={{A3F2B6C1-7D4E-4B8A-9C2F-5E1D0B7A3C94}
AppName=BJMPC Toolbox
AppVersion={#AppVersion}
AppVerName=BJMPC Toolbox {#AppVersion}
AppPublisher=BJMPC Informatique
AppPublisherURL=https://github.com/traekperso-lgtm/BJMPCToolbox
AppCopyright=BJMPC Informatique
VersionInfoVersion={#AppVersion}
VersionInfoCompany=BJMPC Informatique
VersionInfoDescription=Installateur de BJMPC Toolbox
DefaultDirName={autopf}\BJMPC Toolbox
DefaultGroupName=BJMPC Toolbox
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.22000
OutputDir=..\installer-out
OutputBaseFilename=BJMPC-Toolbox-{#AppVersion}-Setup
SetupIconFile=BJMPC-Toolbox.ico
UninstallDisplayIcon={app}\BJMPC-Toolbox.ico
UninstallDisplayName=BJMPC Toolbox
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
#ifdef SIGN
SignTool=bjmpc
SignedUninstaller=yes
#endif

[Languages]
Name: "fr"; MessagesFile: "compiler:Languages\French.isl"

[Tasks]
Name: "desktopicon"; Description: "Créer un raccourci sur le Bureau"; GroupDescription: "Raccourcis :"

[Files]
Source: "{#SourceDir}\BJMPC-*.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\BJMPC-Toolbox.bat"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\LISEZMOI.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\LICENSE.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "BJMPC-Toolbox.ico"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\BJMPC Toolbox"; Filename: "{app}\BJMPC-Toolbox.bat"; WorkingDir: "{app}"; IconFilename: "{app}\BJMPC-Toolbox.ico"; Comment: "Maintenance, réparation et optimisation de Windows 11"
Name: "{group}\Désinstaller BJMPC Toolbox"; Filename: "{uninstallexe}"
Name: "{autodesktop}\BJMPC Toolbox"; Filename: "{app}\BJMPC-Toolbox.bat"; WorkingDir: "{app}"; IconFilename: "{app}\BJMPC-Toolbox.ico"; Tasks: desktopicon

[UninstallDelete]
; versions archivées par la mise à jour intégrée (les journaux et sauvegardes de C:\BJMPC-Logs sont conservés)
Type: filesandordirs; Name: "{app}\_Archive"

[Run]
Filename: "{app}\BJMPC-Toolbox.bat"; Description: "Lancer BJMPC Toolbox"; Flags: postinstall nowait skipifsilent shellexec

[Messages]
fr.FinishedLabel=BJMPC Toolbox est installé.%n%nLes journaux et les sauvegardes de restauration restent dans C:\BJMPC-Logs, même après une désinstallation.
