# =============================================================================
#  Подготовка комплекта установщика: кладёт инструменты прошивки в
#  install\payload\arduino
#
#  Зачем: плата прошивается один раз, но на офлайн-машине с Windows 7 для этого
#  нет ни Arduino IDE, ни компилятора. Поэтому в комплект едут:
#    * arduino-cli.exe        - сборка .ino в .hex (36 МБ)
#    * avr-gcc               - компилятор ATmega (209 МБ)
#    * ядро AVR 1.8.8        - boards.txt, cores, варианты плат (2,6 МБ)
#    * avrdude 8.0           - заливка .hex в плату (6,7 МБ)
#    * индексы пакетов       - иначе arduino-cli лезет в интернет за ними
#  Итого около 275 МБ.
#
#  Запуск (один раз, на машине разработчика, нужен интернет):
#     powershell -ExecutionPolicy Bypass -File install\fetch-arduino.ps1
#
#  Инструменты берутся из уже установленной Arduino IDE и её кэша Arduino15.
#  Своими бинарниками не покупаем - лицензия и происхождение те же, что у
#  обычной установки Arduino.
# =============================================================================

param(
  [string]$OutDir
)

$ErrorActionPreference = "Stop"

if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot "payload\arduino" }

function Say($t, $c = "Gray") { Write-Host $t -ForegroundColor $c }
function Die($t) { Say $t "Red"; throw $t }

# ---- где искать установленную Arduino -----------------------------------------
$local  = $env:LOCALAPPDATA
$pf86   = ${env:ProgramFiles(x86)}
$data   = Join-Path $local "Arduino15"

$cliCandidates = @(
  "$local\Programs\Arduino IDE\resources\app\lib\backend\resources\arduino-cli.exe",
  "${env:ProgramFiles}\Arduino IDE\resources\app\lib\backend\resources\arduino-cli.exe",
  "$local\Arduino15\arduino-cli.exe",
  "$pf86\Arduino\arduino-cli.exe"
)
$cli = $cliCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $cli) {
  Die @"
arduino-cli не найден. Поставьте Arduino IDE (1.8 или новее) и запустите скрипт
снова. Искали:
  $($cliCandidates -join "`n  ")
"@
}
Say "arduino-cli: $cli" "DarkGray"

if (-not (Test-Path (Join-Path $data 'packages\arduino\hardware\avr'))) {
  Die @"
Ядро Arduino AVR не найдено в $data
В Arduino IDE откройте «Инструменты» → «Плата» → «Arduino Nano» и дождитесь, пока
 IDE скажет «Установлено». Потом запустите скрипт снова.
"@
}

# ---- что копируем --------------------------------------------------------------
# Версии берём из уже установленного кэша: перечисленные номера не хардкодим,
# иначе скрипт сломается после обновления Arduino.
$avrCore = Get-ChildItem (Join-Path $data 'packages\arduino\hardware\avr') -Directory |
           Sort-Object Name -Descending | Select-Object -First 1
$gccDir  = Get-ChildItem (Join-Path $data 'packages\arduino\tools\avr-gcc') -Directory |
           Sort-Object Name -Descending | Select-Object -First 1
$dudeDir = Get-ChildItem (Join-Path $data 'packages\arduino\tools\avrdude') -Directory |
           Sort-Object Name -Descending | Select-Object -First 1
if (-not ($avrCore -and $gccDir -and $dudeDir)) {
  Die "В $data нет ядра AVR, avr-gcc или avrdude. Откройте Arduino IDE и дождитесь установки платы."
}
Say "Ядро AVR:  $($avrCore.Name)"
Say "avr-gcc:   $($gccDir.Name)"
Say "avrdude:   $($dudeDir.Name)"

if (Test-Path $OutDir) { Remove-Item $OutDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path (Join-Path $OutDir 'data\packages\arduino\hardware') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $OutDir 'data\packages\arduino\tools')    | Out-Null

Say "Копирую arduino-cli.exe..."
Copy-Item $cli (Join-Path $OutDir 'arduino-cli.exe') -Force

Say "Копирую ядро AVR..."
robocopy $avrCore.FullName (Join-Path $OutDir "data\packages\arduino\hardware\avr\$($avrCore.Name)") `
  /E /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { Die "robocopy (ядро) код $LASTEXITCODE" }

Say "Копирую avr-gcc, это долго (около 209 МБ)..."
robocopy $gccDir.FullName (Join-Path $OutDir "data\packages\arduino\tools\avr-gcc\$($gccDir.Name)") `
  /E /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { Die "robocopy (avr-gcc) код $LASTEXITCODE" }

Say "Копирую avrdude..."
robocopy $dudeDir.FullName (Join-Path $OutDir "data\packages\arduino\tools\avrdude\$($dudeDir.Name)") `
  /E /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { Die "robocopy (avrdude) код $LASTEXITCODE" }

# firmware/ и drivers/ из ядра весят 20 МБ и для сборки ATmega328P не нужны:
# это прошивки для плат на ESP32/ARM и USB-драйверы. Убираем.
foreach ($junk in @('firmwares', 'drivers')) {
  $p = Join-Path $OutDir "data\packages\arduino\hardware\avr\$($avrCore.Name)\$junk"
  if (Test-Path $p) { Remove-Item $p -Recurse -Force }
}

# ---- индексы пакетов -----------------------------------------------------------
# Пока их нет, arduino-cli при первой сборке лезет качать их в интернет. На
# офлайн-машине сборка не пройдёт, поэтому индексы кладём заранее.
foreach ($idx in @('library_index.json', 'library_index.json.sig',
                   'package_index.json', 'package_index.json.sig')) {
  $p = Join-Path $data $idx
  if (Test-Path $p) { Copy-Item $p (Join-Path $OutDir "data\$idx") -Force }
  else { Say "Индекс $idx в Arduino15 не найден, пропускаю." "Yellow" }
}

# ---- проверка: собираемся ли офлайн ------------------------------------------
# Индексы копируем в отдельный каталог и указываем его arduino-cli: иначе он
# читает настройки текущего пользователя. Проверяем с выключенной сетью через
# мёртвый прокси - так падение будет настоящим, а не случайным успехом.
$probe = Join-Path $env:TEMP "jmd2l-arduino-probe"
if (Test-Path $probe) { Remove-Item $probe -Recurse -Force }
New-Item -ItemType Directory -Force -Path $probe | Out-Null
$probeCfg = Join-Path $probe 'probe.yaml'
[IO.File]::WriteAllText($probeCfg, @"
directories:
  data: $OutDir\data
  downloads: $OutDir\data\staging
  user: $OutDir\data
board_manager:
  additional_urls: []
"@, (New-Object Text.UTF8Encoding $false))

$repo    = Split-Path -Parent $PSScriptRoot
$sketch  = Join-Path $repo 'firmware\jmd2l_cnc'
$build   = Join-Path $probe 'build'
$env:HTTP_PROXY  = "http://127.0.0.1:9"
$env:HTTPS_PROXY = "http://127.0.0.1:9"
try {
  Say "Проверяю сборку без сети..."
  & (Join-Path $OutDir 'arduino-cli.exe') --config-file $probeCfg `
      compile --fqbn "arduino:avr:nano:cpu=atmega328old" --build-path $build $sketch |
    Out-Null
  $probeHex = Join-Path $build 'jmd2l_cnc.ino.hex'
  if (-not (Test-Path $probeHex)) { Die "Пробная сборка не дала .hex" }
  Say "Сборка без сети удалась: $([math]::Round((Get-Item $probeHex).Length/1KB,1)) КБ" "Green"
} catch {
  Die "Пробная сборка не удалась: $($_.Exception.Message)"
} finally {
  Remove-Item Env:\HTTP_PROXY  -ErrorAction SilentlyContinue
  Remove-Item Env:\HTTPS_PROXY -ErrorAction SilentlyContinue
  Remove-Item $probe -Recurse -Force -ErrorAction SilentlyContinue
}

$mb = [math]::Round(((Get-ChildItem $OutDir -Recurse -File -Force | Measure-Object Length -Sum).Sum / 1MB))
Say ""
Say ("Готово: {0} ({1} МБ)" -f $OutDir, $mb) "Green"
Say "Теперь можно запускать install\install.cmd"