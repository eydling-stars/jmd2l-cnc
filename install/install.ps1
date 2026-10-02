# =============================================================================
#  Установщик панели JMD-2L CNC
#
#  Кладёт рядом Node.js (из install\payload) и не трогает PATH, реестр и
#  системные настройки: внутри своей папки программа полностью самодостаточна.
#  Реестр пишется ровно в одну ветку — запись для «Программы и компоненты»,
#  чтобы оттуда работал деинсталлятор.
#
#  Запуск: install\install.cmd
#  Тихая установка: powershell -ExecutionPolicy Bypass -File install\install.ps1 -Unattended
# =============================================================================

param(
  [string]$InstallDir,
  [string]$SourceDir,
  [string]$Payload,
  [string]$ArduinoPayload,
  [switch]$Unattended,
  [switch]$NoShortcuts,
  [switch]$Force,
  [switch]$NoElevate
)

$ErrorActionPreference = "Stop"
$AppName = "JMD-2L CNC"
$AppKey  = "JMD-2L CNC"
$UninstKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$AppKey"
$NodeVer = "12.22.12"
$NodeSha = "09639bac66d4dc4dd52179968209413ad4b7360e917dcbe8834052a4b936a087"

# ---- куда ставим, если не сказали иначе ---------------------------------------
if (-not $SourceDir)      { $SourceDir      = Split-Path -Parent $PSScriptRoot }
if (-not $Payload)        { $Payload        = Join-Path $PSScriptRoot "payload\node-v$NodeVer-win-x64.zip" }
if (-not $ArduinoPayload) { $ArduinoPayload = Join-Path $PSScriptRoot "payload\arduino" }

# ---- привилегии ---------------------------------------------------------------
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
             [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin -and -not $NoElevate) {
  Write-Host "Нужны права администратора. Спрошу разрешение..." -ForegroundColor Yellow
  $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
         '-SourceDir', "`"$SourceDir`"", '-Payload', "`"$Payload`"", '-NoElevate')
  $a += @('-ArduinoPayload', "`"$ArduinoPayload`"")
  if ($InstallDir)         { $a += @('-InstallDir',   "`"$InstallDir`"") }
  if ($Unattended)         { $a += '-Unattended' }
  if ($NoShortcuts)        { $a += '-NoShortcuts' }
  if ($Force)              { $a += '-Force' }
  try {
    Start-Process powershell -Verb RunAs -ArgumentList $a -Wait
    exit $LASTEXITCODE
  } catch {
    throw "Не удалось получить права администратора: $($_.Exception.Message)"
  }
}

# ---- проверка системы ---------------------------------------------------------
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
if ([double]$cv.CurrentVersion -lt 6.1) {
  throw "Нужна Windows 7 или новее. Здесь: $($cv.ProductName) ($($cv.CurrentVersion))."
}
if (-not $InstallDir) {
  $pf = if ([Environment]::Is64BitOperatingSystem) { $env:ProgramFiles } else { ${env:ProgramFiles(x86)} }
  $InstallDir = Join-Path $pf $AppName
}

$logFile = Join-Path $env:TEMP "jmd2l-install.log"
"=== установка $AppName  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  ===" | Out-File $logFile -Encoding UTF8

function Say($t, $c = "Gray") {
  Write-Host $t -ForegroundColor $c
  "$([DateTime]::Now.ToString('HH:mm:ss'))  $t" | Out-File $logFile -Append -Encoding UTF8
}
function Die($t) { Say $t "Red"; exit 1 }
function Ask($q) {
  if ($Unattended) { return $true }
  $a = Read-Host $q
  return ($a -eq "" -or $a -eq "y" -or $a -eq "Y" -or $a -eq "д" -or $a -eq "Д")
}

$bits = if ([Environment]::Is64BitOperatingSystem) { "64 бита" } else { "32 бита" }
Say "Система: $($cv.ProductName) $($cv.DisplayVersion) ($bits)"
Say "Папка установки: $InstallDir"

# ---- что отдаём ---------------------------------------------------------------
foreach ($need in @('server\server.js', 'web\index.html', 'server\node_modules\serialport\package.json')) {
  if (-not (Test-Path (Join-Path $SourceDir $need))) { Die "Не найдено: $need`nИсточник ($SourceDir) не похож на этот проект." }
}
if (-not (Test-Path $Payload)) {
  Die "Нет комплекта Node.js: $Payload`nВыполните один раз: powershell -ExecutionPolicy Bypass -File install\fetch-node.ps1"
}
Say "Проверяю Node.js v$NodeVer..."
$h = (Get-FileHash $Payload -Algorithm SHA256).Hash.ToLower()
if ($h -ne $NodeSha) { Die "Хеш Node.js не сошёлся. Файл повреждён или подменён: $Payload" }

# ---- уже стоит? ---------------------------------------------------------------
if (Test-Path $InstallDir) {
  if (Test-Path (Join-Path $InstallDir "server\server.js")) {
    if (-not $Force -and -not (Ask "В папке уже есть программа. Переустановить поверх? (д/н)")) {
      Say "Отменено, ничего не менял." "Yellow"; exit 0
    }
  }
  Get-Process node -ErrorAction SilentlyContinue | Where-Object {
    try { $_.Path -like "$InstallDir\node\*" } catch { $false }
  } | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Milliseconds 500
}

# ---- копируем файлы -----------------------------------------------------------
Say "Копирую программу..."
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
foreach ($d in @('server', 'web', 'firmware', 'bench', 'docs')) {
  $src = Join-Path $SourceDir $d
  if (-not (Test-Path $src)) { continue }
  # Папку создаём сами. Copy-Item со списком файлов и ещё не существующим
  # путём назначения склеивает их в один файл: web\*.js превратился бы в файл
  # с именем «web».
  $dst = Join-Path $InstallDir $d
  New-Item -ItemType Directory -Force -Path $dst | Out-Null
  Copy-Item (Join-Path $src '*') $dst -Recurse -Force | Out-Null
}
# Мусор не тащим: локальный порт, артефакты сборки, прошлый прогон стенда.
Get-ChildItem (Join-Path $InstallDir 'firmware') -Recurse -Directory -Force -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -eq '.build' } |
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
foreach ($junk in @('bench\last-run.txt', 'server\config.json', 'docs\build-doc.ps1')) {
  Remove-Item (Join-Path $InstallDir $junk) -Force -ErrorAction SilentlyContinue
}
foreach ($f in @('README.md', 'CONTEXT.md', 'CHANGELOG.md')) {
  $p = Join-Path $SourceDir $f
  if (Test-Path $p) { Copy-Item $p (Join-Path $InstallDir $f) -Force }
}
if (Test-Path (Join-Path $InstallDir "server\node_modules\serialport")) {
  Say "Зависимости сервера: из комплекта (интернет не нужен)" "DarkGray"
} else {
  Say "ВНИМАНИЕ: нет server\node_modules. При первом запуске панель попросит" "Yellow"
  Say "          Node из интернета. Пересоберите комплект на машине с сетью." "Yellow"
}

# ---- инструменты прошивки ------------------------------------------------------
# arduino-cli, avr-gcc, avrdude и ядро AVR: копируются в папку установки, чтобы
# bench\flash.ps1 собирал и заливал прошивку без IDE и без интернета. Копия
# большая (около 275 МБ), поэтому отдельно проверяем, что она вообще есть, и
# не копируем молча повреждённую.
$arduinoSrc = Join-Path $ArduinoPayload 'arduino-cli.exe'
if (Test-Path $arduinoSrc) {
  $toolMb = [math]::Round(((Get-ChildItem $ArduinoPayload -Recurse -File -Force |
              Measure-Object Length -Sum).Sum / 1MB))
  Say "Копирую инструменты прошивки (около $toolMb МБ)..."
  $arduinoDst = Join-Path $InstallDir 'arduino'
  if (Test-Path $arduinoDst) { Remove-Item $arduinoDst -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $arduinoDst | Out-Null
  robocopy $ArduinoPayload $arduinoDst /E /NFL /NDL /NJH /NJS /NP /R:2 /W:1 |
    Out-Null
  # robocopy: код меньше 8 означает успех, >=8 означает ошибку копирования.
  if ($LASTEXITCODE -ge 8) {
    Die "Не удалось скопировать инструменты прошивки (robocopy код $LASTEXITCODE)."
  }
  # Конфиг arduino-cli не кладём: bench\flash.ps1 пишет его сам, исходя из
  # того, где нашёл arduino-cli. В конфиге абсолютные пути, а папка установки
  # при переносе меняется - лежащий рядом файл устареет и собьёт сборку.
  Say "Прошивка: из комплекта (интернет не нужен)" "DarkGray"
} else {
  Say "Инструменты прошивки не найдены в $ArduinoPayload." "Yellow"
  Say "  Прошить плату скриптом bench\flash.ps1 не выйдет. Поставьте Arduino IDE" "Yellow"
  Say "  и прошейте вручную либо выполните: powershell -ExecutionPolicy Bypass" "Yellow"
  Say "  -File install\fetch-arduino.ps1" "Yellow"
}

# ---- распаковываем Node -------------------------------------------------------
Say "Распаковываю Node.js..."
$nodeDir = Join-Path $InstallDir "node"
if (Test-Path $nodeDir) { Remove-Item $nodeDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $nodeDir | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::ExtractToDirectory($Payload, (Join-Path $env:TEMP "jmd2l-node"))
$inner = Get-ChildItem (Join-Path $env:TEMP "jmd2l-node") -Directory | Select-Object -First 1
Copy-Item (Join-Path $inner.FullName '*') $nodeDir -Recurse -Force
Remove-Item (Join-Path $env:TEMP "jmd2l-node") -Recurse -Force -ErrorAction SilentlyContinue
if (-not (Test-Path (Join-Path $nodeDir "node.exe"))) { Die "node.exe не распаковался." }
$ver = (& (Join-Path $nodeDir "node.exe") -v) 2>$null
Say "Node.js внутри: $ver"

# ---- ярлык запуска -----------------------------------------------------------
# Имя лаунчера латиницей: содержимое .cmd читает cmd.exe в системной кодировке,
# а имя файла открывает проводник — так надёжнее на любой локали.
$launcher = @"
@echo off
rem $AppName - launcher
setlocal
cd /d "%~dp0"
if not exist "node\node.exe" (
  echo Node.js not found. Reinstall $AppName.
  pause
  exit /b 1
)
if not exist "server\node_modules\serialport\package.json" (
  echo Missing server dependencies. Reinstall $AppName.
  pause
  exit /b 1
)
start "" "http://localhost:8080"
"node\node.exe" "server\server.js"
echo.
echo Server stopped. Press any key to close.
pause >nul
"@
[IO.File]::WriteAllText((Join-Path $InstallDir "StartPanel.cmd"), $launcher, (New-Object Text.UTF8Encoding $false))

# ---- деинсталлятор -----------------------------------------------------------
Copy-Item (Join-Path $PSScriptRoot "uninstall.ps1") (Join-Path $InstallDir "Uninstall.ps1") -Force
Copy-Item (Join-Path $PSScriptRoot "uninstall.cmd") (Join-Path $InstallDir "Uninstall.cmd") -Force

# ---- ярлыки ------------------------------------------------------------------
if (-not $NoShortcuts) {
  Say "Создаю ярлыки..."
  $shell = New-Object -ComObject WScript.Shell
  $programs = [Environment]::GetFolderPath('Programs')
  $menuGroup = Join-Path $programs $AppName
  # Папку в меню «Пуск» создаём до ярлыка: CreateShortcut в несуществующей
  # папке молча не создаёт файл.
  New-Item -ItemType Directory -Force -Path $menuGroup | Out-Null
  foreach ($dir in @([Environment]::GetFolderPath('Desktop'), $menuGroup, $programs)) {
    $s = $shell.CreateShortcut((Join-Path $dir "$AppName.lnk"))
    $s.TargetPath       = Join-Path $InstallDir "StartPanel.cmd"
    $s.WorkingDirectory = $InstallDir
    $s.Description      = "$AppName — панель управления двух осей"
    $s.Save()
  }
}

# ---- «Программы и компоненты» ------------------------------------------------
$sizeMb = [math]::Round(((Get-ChildItem $InstallDir -Recurse -File -ErrorAction SilentlyContinue |
                Measure-Object Length -Sum).Sum / 1MB))
if ($isAdmin) {
  New-Item -Path $UninstKey -Force | Out-Null
  Set-ItemProperty $UninstKey DisplayName     $AppName
  Set-ItemProperty $UninstKey DisplayVersion  "1.0.0"
  Set-ItemProperty $UninstKey Publisher       "JMD-2L CNC"
  Set-ItemProperty $UninstKey InstallLocation $InstallDir
  Set-ItemProperty $UninstKey UninstallString "`"$env:SystemRoot\System32\cmd.exe`" /c `"`"$InstallDir\Uninstall.cmd`"`""
  Set-ItemProperty $UninstKey DisplayIcon     "$env:SystemRoot\System32\shell32.dll,13"
  Set-ItemProperty $UninstKey NoModify        1
  Set-ItemProperty $UninstKey NoRepair        1
  Set-ItemProperty $UninstKey EstimatedSize   $sizeMb
} else {
  Say "Без прав администратора запись в «Программы и компоненты» не создана." "Yellow"
  Say "Программа работает, но удалить её оттуда будет нельзя." "Yellow"
}

Say "Готово. Занято $sizeMb МБ." "Green"
Say ""
Say "Запуск:  ярлык «$AppName» на рабочем столе, или $InstallDir\StartPanel.cmd" "Green"
Say "Панель:  http://localhost:8080"
Say "Журнал установки: $logFile"
if (-not $Unattended) { Say ""; Say "Нажмите Enter, чтобы закрыть окно." -ForegroundColor DarkGray; Read-Host | Out-Null }
exit 0