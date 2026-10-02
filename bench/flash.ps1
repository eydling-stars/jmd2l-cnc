# =============================================================================
#  Прошивка платы через avrdude
#
#  На этой плате CH340 не отдаёт avrdude порт сразу:reset по DTR не проходит,
#  и avrdude видит "programmer is not responding". Обходной путь, который
#  работает: вручную дёргаем DTR и RTS, чтобы ATmega328P вошла в бутлоадер
#  (Nordic-подобная последовательность импульсов), затем отпускаем порт и
#  отдаём его avrdude.
#
#  Запуск:  powershell -ExecutionPolicy Bypass -File bench\flash.ps1
# =============================================================================

param(
  [string]$Port = "COM4",
  [switch]$SkipBuild,
  [string]$Cli,
  [string]$Avrdude,
  [string]$BuildPath
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$sketch = Join-Path $root "firmware\jmd2l_cnc"
$fqbn = "arduino:avr:nano:cpu=atmega328old"

# Промежуточные файлы сборки кладём во временную папку, а не рядом со скетчем.
# Программа ставится в Program Files, а туда обычному пользователю писать
# нельзя: сборка из-под простого пользователя падала бы на создании .build.
if (-not $BuildPath) { $BuildPath = Join-Path $env:TEMP "jmd2l-build" }
$build = $BuildPath

# ---- инструменты ищем сами ----------------------------------------------------
# Порядок: явный ключ, потом комплект (install\payload\arduino или папка
# установки), потом система. Комлект — основной случай: он едет в установщике
# и работает без интернета и без Arduino IDE.
# Раньше тут стояли жёсткие пути к Arduino IDE 2 и avrdude 8.0 — они работают
# только на машине, где IDE 2 ставилась вручную. На Windows 7 IDE 2 не
# запускается вовсе, там IDE 1.8 с avrdude в комплекте.
$pf86 = ${env:ProgramFiles(x86)}
$local = $env:LOCALAPPDATA

function Find-Tool([string]$name, [string]$given, [string[]]$paths, [string[]]$globs) {
  if ($given) {
    if (-not (Test-Path $given)) { throw "Указанный путь не найден: $given" }
    return $given
  }
  $cmd = Get-Command $name -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  foreach ($p in $paths) { if ($p -and (Test-Path $p)) { return $p } }
  foreach ($g in $globs) {
    if (-not $g) { continue }
    $hit = Get-ChildItem $g -ErrorAction SilentlyContinue |
           Sort-Object FullName -Descending | Select-Object -First 1
    if ($hit) { return $hit.FullName }
  }
  return $null
}

# Папки с комплектом: исходники проекта (install\payload\arduino) и уже
# установленная программа (arduino рядом с этим скриптом).
$bundle = @(
  (Join-Path $root "install\payload\arduino"),
  (Join-Path (Split-Path -Parent $PSScriptRoot) "arduino")
) | Where-Object { Test-Path $_ }

# Инструмент и его каталог данных берём из ОДНОЙ папки комплекта. Если искать
# по отдельности, arduino-cli может достаться из исходников проекта, а ядро AVR
# arduino-cli будет искать в папке установки - и не найдёт.
$cli = $null
if ($Cli) {
  if (-not (Test-Path $Cli)) { throw "Указанный путь не найден: $Cli" }
  $cli = $Cli
} else {
  $sysCli = Get-Command 'arduino-cli' -ErrorAction SilentlyContinue
  if ($sysCli) { $cli = $sysCli.Source }
}
foreach ($b in $bundle) {
  if ($cli) { break }
  $c = Join-Path $b 'arduino-cli.exe'
  if (Test-Path $c) { $cli = $c }
}
if (-not $cli) {
  foreach ($p in @(
    "$local\Programs\Arduino IDE\resources\app\lib\backend\resources\arduino-cli.exe",
    "${env:ProgramFiles}\Arduino IDE\resources\app\lib\backend\resources\arduino-cli.exe",
    "$local\Arduino15\arduino-cli.exe",
    "$pf86\Arduino\arduino-cli.exe")) {
    if (Test-Path $p) { $cli = $p; break }
  }
}

$avrdudePaths = @()
foreach ($b in $bundle) {
  $avrdudePaths += (Get-ChildItem (Join-Path $b 'data\packages\arduino\tools\avrdude') `
                   -Recurse -Filter 'avrdude.exe' -ErrorAction SilentlyContinue |
                   Select-Object -ExpandProperty FullName)
}
$avrdudePaths += @(
  "$pf86\Arduino\hardware\tools\avr\bin\avrdude.exe",
  "$local\Programs\Arduino IDE\resources\app\lib\backend\resources\avrdude.exe"
)
$avrdude = Find-Tool 'avrdude' $Avrdude $avrdudePaths @("$local\Arduino15\packages\arduino\tools\avrdude\*\bin\avrdude.exe")

# arduino-cli по умолчанию смотрит в Arduino15 текущего пользователя и тогда
# лезет качать индексы в интернет. Если рядом с найденным arduino-cli есть папка
# data - это комплект, и мы указываем cli на неё. Конфиг пишем во временный
# файл: в нём абсолютные пути, привязанные к текущему месту, поэтому лежать
# рядом с комплектом он не может.
$cliCfg = $null
if ($cli) {
  $dataDir = Join-Path (Split-Path -Parent $cli) 'data'
  if (Test-Path $dataDir) {
    $cliCfg = Join-Path $env:TEMP "jmd2l-arduino-cli.yaml"
    [IO.File]::WriteAllText($cliCfg, @"
directories:
  data: $dataDir
  downloads: $dataDir\staging
  user: $dataDir
board_manager:
  additional_urls: []
"@, (New-Object Text.UTF8Encoding $false))
  }
}

# Сборку пропустили - arduino-cli не нужен: он только компилирует. Раньше
# проверка была безусловной, и прошивка готового .hex падала с «arduino-cli не
# найден» у того, у кого IDE не стоит, хотя справка выше предлагает -SkipBuild
# именно как способ прошить без сборки.
if (-not $cli -and -not $SkipBuild) {
  throw @"
arduino-cli не найден.
Нужен для сборки прошивки из исходников. Варианты:
  - поставить Arduino CLI и положить его в PATH;
  - указать путь вручную:  flash.ps1 -Cli <путь>;
  - если прошивка уже собрана, пропустить сборку:  flash.ps1 -SkipBuild
"@
}
# avrdude нужен всегда: -SkipBuild отменяет только компиляцию, запись делает
# именно он. Проверка была привязана к -SkipBuild, и без IDE скрипт доходил до
# "& $null -p m328p" вместо внятного объяснения.
if (-not $avrdude) {
  throw @"
avrdude не найден.
Он записывает прошивку в плату, даже когда сборка пропущена. Варианты:
  - поставить Arduino IDE (1.8 или новее), avrdude.exe лежит в её папке;
  - указать путь вручную:  flash.ps1 -Avrdude <путь к avrdude.exe>
"@
}
Write-Host "arduino-cli: $cli" -ForegroundColor DarkGray
if ($cliCfg)   { Write-Host "конфиг:      $cliCfg" -ForegroundColor DarkGray }
if ($avrdude)  { Write-Host "avrdude:     $avrdude" -ForegroundColor DarkGray }

# ---- 1. сборка ----
$hex = Join-Path $build "jmd2l_cnc.ino.hex"
if (-not $SkipBuild) {
  Write-Host "Сборка..." -ForegroundColor Cyan
  New-Item -ItemType Directory -Force -Path $build | Out-Null
  $cliArgs = @()
  if ($cliCfg) { $cliArgs = @('--config-file', $cliCfg) }
  & $cli @cliArgs compile --fqbn $fqbn --build-path $build $sketch
  # arduino-cli местами отдаёт код 1, даже когда .hex собран. Верим файлу,
  # а не коду возврата.
  if (-not (Test-Path $hex)) { throw "Сборка не удалась: нет $hex" }
}
if (-not (Test-Path $hex)) { throw "Нет файла $hex" }

# ---- 2. ручной reset в бутлоадер ----
# DTR и RTS у CH340 идут на выводыreset платы Arduino как инвертированные
# сигналы. Последовательность ниже - стандартный "двойной клик" по кнопке
# RESET: короткое замыкание DTR, затем RTS, потом отпускаем оба.
Write-Host "Ввод платы в режим загрузчика..." -ForegroundColor Cyan
$p = New-Object System.IO.Ports.SerialPort $Port, 115200, "None", 8, "One"
$p.DtrEnable = $false
$p.RtsEnable = $false
$p.Open()
Start-Sleep -Milliseconds 60
$p.DtrEnable = $true          # RESET вниз
Start-Sleep -Milliseconds 60
$p.DtrEnable = $false
Start-Sleep -Milliseconds 40
$p.RtsEnable = $true          # зажигаем L на OPTIBOOT
Start-Sleep -Milliseconds 60
$p.RtsEnable = $false
Start-Sleep -Milliseconds 40
$p.Close()
Start-Sleep -Milliseconds 120

# ---- 3. прошивка ----
Write-Host "Прошивка..." -ForegroundColor Cyan
# Бутлоадер и lock-биты не трогаем: optiboot на плате уже записан, а запись
# фьюза здесь только риск без выгоды. Заливаем исключительно прошивку.
# Фигурные скобки обязательны: без них "$hex:i" PowerShell читает как
# переменную с областью видимости и подставляет пустую строку.
# avrdude на этой плате отдаёт код 1 и при успешной записи, поэтому признак
# успеха один — строка «N bytes of flash verified».
$avrdudeOut = (& $avrdude -p m328p -c arduino -P $Port -b 115200 -D -U "flash:w:${hex}:i" 2>&1) -join "`n"
Write-Host $avrdudeOut
if ($avrdudeOut -notmatch 'bytes of flash verified') {
  throw "avrdude не подтвердил запись: строки «N bytes of flash verified» в выводе нет."
}

Write-Host ""
Write-Host "Готово. Плата перезагрузится через 2 с." -ForegroundColor Green
