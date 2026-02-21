; Inno Setup script for Inferno Windows installer.
; Compile with: iscc inferno.iss

[Setup]
AppName=Inferno
AppVersion=1.0.0
AppPublisher=Inferno
DefaultDirName={autopf}\Inferno
DefaultGroupName=Inferno
OutputDir=.
OutputBaseFilename=Inferno-Setup
Compression=lzma2/ultra64
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
SetupIconFile=inferno.ico
UninstallDisplayIcon={app}\inferno.exe

[Files]
Source: "inferno.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "libsodium.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "inferno.bat"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\Inferno"; Filename: "{app}\inferno.bat"; IconFilename: "{app}\inferno.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\Inferno"; Filename: "{app}\inferno.bat"; IconFilename: "{app}\inferno.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop icon"; GroupDescription: "Additional icons:"

[Run]
Filename: "{app}\inferno.bat"; Description: "Launch Inferno"; Flags: nowait postinstall skipifsilent shellexec
