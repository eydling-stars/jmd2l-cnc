# =============================================================================
#  Деинсталлятор панели JMD-2L CNC
#
#  Снимает ярлыки и запись из «Программы и компоненты», останавливает сервер,
#  затем удаляет папку программы. Настройки станка (прошивка) не трогает —
#  они живут на плате.
#
#  Запуск: Uninstall.cmd из папки программы
# =============================================================================

param(
  [string]$InstallDir,
  [switch]$KeepFiles,
  [switch]$Unattended,
  [switch]$NoElevate
)

$ErrorActionPreference = "Stop"
$AppName  = "JMD-2L CNC"
$UninstKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$AppName"

# Без -InstallDir считаем папкой программы ту, откуда запущен скрипт:
# Uninstall.cmd лежит рядом с StartPanel.cmd. Свой -InstallDir уважаем
# дословно — подставлять «на всякий случай» Program Files нельзя, так
# сносили бы не ту папку.
if (-not $InstallDir) { $InstallDir = Split-Path -Parent $PSCommandPath }

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
             [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $NoElevate) {
  Write-Host "Нужны права администратора. Спрошу разрешение..." -ForegroundColor Yellow
  try {
    Start-Process powershell -Verb RunAs -Wait -ArgumentList @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
      '-InstallDir', "`"$InstallDir`"", '-Unattended')
    exit $LASTEXITCODE
  } catch { throw "Не удалось получить права администратора: $($_.Exception.Message)" }
}

function Say($t, $c = "Gray") { Write-Host $t -ForegroundColor $c }

Write-Host ""
Write-Host "  Удаление $AppName" -ForegroundColor White
Write-Host "  Папка: $InstallDir" -ForegroundColor DarkGray
Write-Host ""
if (-not $isAdmin) {
  Write-Host "  Прав администратора нет: сниму ярлыки, а папку программы и" -ForegroundColor Yellow
  Write-Host "  запись из «Программы и компоненты» — нет. Запусти от администратора." -ForegroundColor Yellow
  Write-Host ""
}

if (-not $Unattended) {
  $a = Read-Host "  Удалить программу? Настройки станка останутся. (д/н)"
  if ($a -ne "" -and $a -notmatch '^[ддyY]$') { Say "Отменено." "Yellow"; exit 0 }
}

# --- сервер из этой папки ------------------------------------------------------
Get-Process node -ErrorAction SilentlyContinue | Where-Object {
  try { $_.Path -like "$InstallDir\node\*" } catch { $false }
} | ForEach-Object {
  Say "Останавливаю сервер (процесс $($_.Id))..." "Yellow"
  Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Milliseconds 600

# --- ярлыки --------------------------------------------------------------------
$programs = [Environment]::GetFolderPath('Programs')
$startMenuGroup = Join-Path $programs $AppName
foreach ($p in @((Join-Path ([Environment]::GetFolderPath('Desktop')) "$AppName.lnk"),
                 (Join-Path $startMenuGroup "$AppName.lnk"),
                 (Join-Path $programs "$AppName.lnk"))) {
  if (Test-Path $p) { Remove-Item $p -Force -ErrorAction SilentlyContinue; Say "Убран ярлык: $p" }
}
if (Test-Path $startMenuGroup) {
  Remove-Item $startMenuGroup -Recurse -Force -ErrorAction SilentlyContinue
}

# --- реестр --------------------------------------------------------------------
# Запись в HKLM есть только у администратора: без прав её и не было.
if (Test-Path $UninstKey) {
  if ($isAdmin) {
    Remove-Item $UninstKey -Recurse -Force -ErrorAction SilentlyContinue
    Say "Убрана запись из «Программы и компоненты»."
  } else {
    Say "Запись из «Программы и компоненты» без прав администратора не убрать." "Yellow"
  }
}

# --- папка ---------------------------------------------------------------------
if ($KeepFiles) {
  Say "Файлы оставлены: $InstallDir" "Yellow"
} elseif (Test-Path $InstallDir) {
  # cmd.exe держит папку запущенной программы — из-за этого удаление не идёт,
  # поэтому сначала гасим сервер, а потом уже стираем папку.
  Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
  if (Test-Path $InstallDir) {
    Say "Папку удалить не удалось. Закройте окно панели и запустите" "Red"
    Say "удаление от имени администратора." "Red"
    exit 1
  }
  Say "Папка удалена."
}

Say ""
Say "Готово. Прошивка платы не тронута." "Green"
if (-not $Unattended) { Read-Host "  Нажмите Enter" | Out-Null }
exit 0