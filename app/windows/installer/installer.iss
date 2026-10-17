; Inno Setup script — установщик приложения:
; - ставит приложение в Program Files;
; - создаёт ярлыки в Пуск и (опционально) на Рабочем столе;
; - регистрирует приложение в "Установка и удаление программ" со своим
;   деинсталлятором;
; - т.к. приложению требуются права администратора (UAC — см.
;   windows/runner/runner.exe.manifest, requireAdministrator), сам
;   установщик тоже запрашивается с правами администратора
;   (PrivilegesRequired=admin), иначе он не смог бы писать в Program Files.
;
; Собирается локально через Inno Setup (https://jrsoftware.org/isinfo.php,
; ISCC.exe) либо автоматически в CI — см. .github/workflows/build-windows.yml.
; Ожидает, что `flutter build windows --release` уже отработал и папка
; ..\..\build\windows\x64\runner\Release существует и содержит .exe + все
; .dll + подпапку data\ (и, если положены заранее, sing-box\).

#define MyAppName "VPNonLine"
; Версию подставляет сборка (/DMyAppVersion=1.0.<номер>), без неё — 1.0.0.
#ifndef MyAppVersion
  #define MyAppVersion "1.0.0"
#endif
#define MyAppPublisher "VPNonLine"
#define MyAppExeName "vpnonline_app.exe"
; Папка со собранным релизом относительно этого .iss-файла.
#define ReleaseDir "..\..\build\windows\x64\runner\Release"

[Setup]
AppId={{4E7F2C9B-6A3D-4C8E-9C1F-6E8B2E5F9A11}}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
; Ставим по одному .exe-установщику вместо папки/zip.
OutputDir=..\..\..\installer-output
OutputBaseFilename=VPNonLine-Setup
Compression=lzma2
SolidCompression=yes
; TUN-адаптеру (wintun) и sing-box.exe для поднятия туннеля нужны права
; администратора — сам runner.exe.manifest уже требует их у самого
; приложения, поэтому и установщик просит их сразу, иначе установка в
; Program Files тоже не пройдёт без UAC-запроса на каждый файл.
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\{#MyAppExeName}
WizardStyle=modern
; Обновление ставится поверх работающего приложения (его запускает само
; приложение, без окон: /VERYSILENT). Занятые файлы закрываем без вопросов.
CloseApplications=force
RestartApplications=no

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
; Всё содержимое собранного релиза (.exe, .dll, data\, и sing-box\, если он
; был положен в windows/sing-box/ перед сборкой) — рекурсивно, один пункт.
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent
; Автообновление идёт без окон — после него приложение открываем сами.
Filename: "{app}\{#MyAppExeName}"; Flags: nowait postinstall skipifnotsilent

[UninstallDelete]
; sing-box.exe/wintun.dll на первом подключении может докачаться и/или
; оставить временные конфиги рядом с exe (см. singbox_runtime_windows.dart)
; — подчищаем всю папку установки при удалении, чтобы не оставлять мусор.
Type: filesandordirs; Name: "{app}"

[Code]
// Перед установкой гасим ядро VPN и само приложение: их файлы заняты, пока
// они работают, и поверх них новую версию не поставить. Приложение без /T:
// установщик при автообновлении — его дочерний процесс, и убийство дерева
// закрыло бы и его.
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
begin
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM sing-box.exe /T', '',
    SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM {#MyAppExeName}', '',
    SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Sleep(1000);
  Result := '';
end;
