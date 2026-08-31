; Elixir Gestion — Client (application de gestion / caisse)
#define AppVersion "0.1.4"

[Setup]
AppId={{8E7A4A2E-11D1-4D3B-9B6A-ELIXIRCLI001}
AppName=Elixir Gestion
AppVersion={#AppVersion}
AppPublisher=Elixir
DefaultDirName={commonpf64}\Elixir\Client
DisableProgramGroupPage=yes
OutputDir=..\dist
OutputBaseFilename=ElixirGestion-Setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
CloseApplications=yes

[Languages]
Name: "french"; MessagesFile: "compiler:Languages\French.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\app\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Elixir Gestion"; Filename: "{app}\elixir_app.exe"
Name: "{autodesktop}\Elixir Gestion"; Filename: "{app}\elixir_app.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\elixir_app.exe"; Description: "Lancer Elixir Gestion"; Flags: nowait postinstall skipifsilent
