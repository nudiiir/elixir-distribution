; Elixir Gestion — Serveur (installe server.exe comme service Windows)
#define AppVersion "0.1.3"

[Setup]
AppId={{8E7A4A2E-11D1-4D3B-9B6A-ELIXIRSRV001}
AppName=Elixir Serveur
AppVersion={#AppVersion}
AppPublisher=Elixir
DefaultDirName={commonpf64}\Elixir\Server
DisableProgramGroupPage=yes
OutputDir=..\dist
OutputBaseFilename=ElixirServeur-Setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern

[Languages]
Name: "french"; MessagesFile: "compiler:Languages\French.isl"

[Files]
Source: "..\server\server.exe"; DestDir: "{app}"; Flags: ignoreversion

[Run]
; Stop/uninstall a previous service quietly, then (re)install and start it.
Filename: "{app}\server.exe"; Parameters: "-service stop"; Flags: runhidden; StatusMsg: "Arrêt de l'ancien service…"
Filename: "{app}\server.exe"; Parameters: "-service uninstall"; Flags: runhidden
Filename: "{app}\server.exe"; Parameters: "-service install"; Flags: runhidden; StatusMsg: "Installation du service…"
Filename: "netsh"; Parameters: "advfirewall firewall add rule name=""Elixir Serveur"" dir=in action=allow protocol=TCP localport=8543"; Flags: runhidden; StatusMsg: "Règle pare-feu…"
Filename: "{app}\server.exe"; Parameters: "-service start"; Flags: runhidden; StatusMsg: "Démarrage du service…"

[UninstallRun]
Filename: "{app}\server.exe"; Parameters: "-service stop"; Flags: runhidden; RunOnceId: "StopSvc"
Filename: "{app}\server.exe"; Parameters: "-service uninstall"; Flags: runhidden; RunOnceId: "UninstSvc"
Filename: "netsh"; Parameters: "advfirewall firewall delete rule name=""Elixir Serveur"""; Flags: runhidden; RunOnceId: "DelFw"

[UninstallDelete]
; NOTE: the database (data\) and backups are intentionally KEPT on uninstall.
Type: files; Name: "{app}\server.exe"
