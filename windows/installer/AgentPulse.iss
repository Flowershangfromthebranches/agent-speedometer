; AgentPulse Windows 安装程序（Inno Setup 6）
; 先用 PyInstaller 生成 windows\dist\AgentPulse\，再运行：
;   ISCC /DAppVersion=1.0.3 windows\installer\AgentPulse.iss
; 输出：windows\dist\AgentPulse-Setup-<版本>.exe

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
AppId={{6B2D6A9E-6E0B-4C77-9C2B-5A1E4F0D7A31}
AppName=AgentPulse
AppVersion={#AppVersion}
AppVerName=AgentPulse {#AppVersion}
AppPublisher=AgentPulse
AppPublisherURL=https://github.com/Flowershangfromthebranches/agent-speedometer
DefaultDirName={localappdata}\Programs\AgentPulse
DefaultGroupName=AgentPulse
DisableProgramGroupPage=yes
; 装在用户目录，不需要管理员权限
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=..\dist
OutputBaseFilename=AgentPulse-Setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\AgentPulse.exe
CloseApplications=yes

[Languages]
#if FileExists(CompilerPath + "Languages\ChineseSimplified.isl")
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
#endif
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"
Name: "startup"; Description: "开机时自动启动 AgentPulse"; GroupDescription: "其他选项:"; Flags: unchecked

[Files]
Source: "..\dist\AgentPulse\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\AgentPulse"; Filename: "{app}\AgentPulse.exe"
Name: "{group}\{cm:UninstallProgram,AgentPulse}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\AgentPulse"; Filename: "{app}\AgentPulse.exe"; Tasks: desktopicon
Name: "{userstartup}\AgentPulse"; Filename: "{app}\AgentPulse.exe"; Tasks: startup

[Run]
Filename: "{app}\AgentPulse.exe"; Description: "{cm:LaunchProgram,AgentPulse}"; Flags: nowait postinstall skipifsilent
