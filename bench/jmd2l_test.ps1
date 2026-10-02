# =============================================================================
#  Стендовые автотесты прошивки JMD-2L CNC
#  PowerShell + System.IO.Ports.SerialPort. Только ASCII, ответ читаем
#  построчно ReadLine - каждая команда даёт ровно одну строку.
#
#  Запуск:  powershell -ExecutionPolicy Bypass -File bench\jmd2l_test.ps1
#  Порт:    -Port COM4    (по умолчанию ищется единственный USB-порт)
#
#  Моторы подключать НЕ нужно: проверяется логика, таймеры, настройки.
#  Подмена оборотов (RP), тока (CU) и концевиков (L) позволяет проверить
#  защиту целиком без фрезы и без нажатия выключателей.
# =============================================================================

param(
  [string]$Port = "",
  [int]$ShortRunSec = 20,        # длительность прогона под нагрузкой
  [switch]$KeepSettings          # не возвращать настройки к умолчаниям
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ---------- поиск порта ----------
if (-not $Port) {
  $ports = [System.IO.Ports.SerialPort]::GetPortNames()
  if ($ports.Count -eq 0) { throw "COM-портов не найдено. Подключите плату." }
  if ($ports.Count -gt 1) {
    Write-Host "Найдено портов: $($ports -join ', '). Использую первый: $($ports[0])"
  }
  $Port = $ports[0]
}

$sp = New-Object System.IO.Ports.SerialPort $Port, 115200, "None", 8, "One"
$sp.ReadTimeout = 3000
$sp.WriteTimeout = 2000
$sp.DtrEnable = $false
$sp.RtsEnable = $false
$sp.NewLine = "`n"
# Без этого порт читается как us-ascii и ВСЯ кириллица от платы приходит
# знаками «?» — сравнения вроде «ПУТЬ К КОНЦЕВИКУ ЗАКРЫТ» не срабатывают.
# Проверено замером: us-ascii -> MATCH=False, UTF8 -> MATCH=True.
$sp.Encoding = New-Object System.Text.UTF8Encoding($false)

# ---------- счётчики ----------
$script:pass = 0
$script:fail = 0
$script:failNames = @()

function Say($s) { Write-Host $s }
function Ok($name) {
  $script:pass++
  Write-Host ("  [ OK ] " + $name) -ForegroundColor Green
}
function Bad($name, $why) {
  $script:fail++
  $script:failNames += $name
  Write-Host ("  [FAIL] " + $name + " -- " + $why) -ForegroundColor Red
}

# ---------- низкоуровневый обмен ----------
function Reset-Board {
  # CH340 сбрасывает ATmega328P перепадом DTR при открытии порта
  try { $sp.Close() } catch {}
  Start-Sleep -Milliseconds 300
  $sp.Open()
  Start-Sleep -Milliseconds 1800          # ждём загрузку и баннер
  Drain
}

function Drain() {
  $sp.DiscardInBuffer()
}

function Send-Line([string]$cmd) {
  $sp.Write($cmd + "`n")
}

# Строки событий платы ('#' в начале) — не ответ на команду, поэтому их надо
# пропустить и вернуть первую настоящую строку ответа. Их ловит и Cmd.
$script:events = @()

function Events-Clear { $script:events = @() }
function Events-Text { $script:events -join "`n" }

# Ответ одной строки. Сервер железа отвечает на каждую команду ровно
# одной строкой, поэтому ReadLine - надёжнее фиксированной паузы.
function Get-Line([int]$timeoutMs = 3000) {
  $old = $sp.ReadTimeout
  $sp.ReadTimeout = $timeoutMs
  try {
    $deadline = (Get-Date).AddMilliseconds($timeoutMs)
    $sb = ""
    while ((Get-Date) -lt $deadline) {
      $l = $sp.ReadLine()
      if ($null -ne $l) {
        $l = $l.Trim()
        if ($l.StartsWith('#')) { $script:events += $l; continue }
        return $l
      }
    }
    return $null
  } catch [System.TimeoutException] {
    return $null
  } finally { $sp.ReadTimeout = $old }
}

# События, которые плата шлёт сама, без команды: концевик и авария приходят с
# задержкой дебаунса, то есть ПОСЛЕ ответа на команду. Их надо дочитать отдельно.
function Read-Events([int]$ms = 400) {
  $old = $sp.ReadTimeout
  $sp.ReadTimeout = 60
  $deadline = (Get-Date).AddMilliseconds($ms)
  while ((Get-Date) -lt $deadline) {
    try { $l = $sp.ReadLine() } catch { break }
    if ($null -eq $l) { continue }
    $l = $l.Trim()
    if ($l.StartsWith('#')) { $script:events += $l }
  }
  $sp.ReadTimeout = $old
}

# Команда -> строка ответа. Повтор при таймауте: при старте плата ещё грузится.
function Cmd([string]$cmd, [int]$tries = 3) {
  for ($i = 0; $i -lt $tries; $i++) {
    Drain
    Send-Line $cmd
    $r = Get-Line
    if ($null -ne $r) { return $r }
    Start-Sleep -Milliseconds 250
  }
  return $null
}

function Status {
  # Читаем до строки, начинающейся с '{': баннер загрузки и прочий мусор
  # пропускаем, а не считаем ответом.
  for ($i = 0; $i -lt 3; $i++) {
    $r = Cmd "?"
    $script:lastStatusRaw = $r
    if ($null -ne $r -and $r -match '^\{') {
      try { return $r | ConvertFrom-Json } catch {
        $script:lastStatusErr = $_.Exception.Message
        return $null
      }
    }
  }
  return $null
}

function IsOk([string]$r) { return ($null -ne $r) -and (($r -like "OK*") -or ($r -like "PONG*")) }
function ErrOf([string]$r) {
  if ($null -eq $r) { return "<нет ответа>" }
  if ($r.StartsWith("ERR")) { return $r.Substring(4).Trim() }
  return "<не ошибка: $r>"
}

# Включить подмену датчиков и разрешить движение при стоящем шпинделе
function Test-Mode {
  Cmd "T 14 1" | Out-Null    # разрешить движение без шпинделя
  Cmd "T 15 0" | Out-Null    # не контролировать потерю связи
  Cmd "RP 0"    | Out-Null    # обороты 0: защита не взводится, авария не встанет
  Cmd "CU 0"    | Out-Null    # ток 0
  for ($i = 0; $i -lt 4; $i++) { Cmd "L $i -1" | Out-Null }
}

function Test-Cleanup {
  Cmd "RP -1" | Out-Null
  Cmd "CU -1" | Out-Null
  for ($i = 0; $i -lt 4; $i++) { Cmd "L $i -1" | Out-Null }
  Cmd "S 1" | Out-Null
  Cmd "S 2" | Out-Null
  Cmd "X"    | Out-Null
  Cmd "!"    | Out-Null
  # Настройки - по снимку. Список мест, которые меняют тесты, разбросан по
  # всему прогону, и одна забытая строка в нём тихо портит станок: раньше
  # здесь стоял жёсткий T 0 4 + TS, то есть метод защиты выписывался в EEPROM
  # как 4 независимо от того, что стояло у станка.
  if ($null -ne $script:cfg0) {
    $now = (Cmd "T" | ConvertFrom-Json).v
    for ($i = 0; $i -lt $script:cfg0.Count; $i++) {
      if ($now[$i] -ne $script:cfg0[$i]) { Cmd "T $i $($script:cfg0[$i])" | Out-Null }
    }
    # TS пишет в EEPROM ровно то, что сейчас в памяти, то есть снимок.
    if (-not $KeepSettings) { Cmd "TS" | Out-Null }
  } else {
    if (-not $KeepSettings) {
      Cmd "T 14 0"     | Out-Null
      Cmd "T 15 3000"  | Out-Null
    }
    Bad "настройки возвращены к снимку" "снимка не было, откатываться нечем"
  }
}

# =============================================================================
Say ""
Say "=== Автотесты JMD-2L CNC на $Port ==="
Say ""

try {
  $sp.Open()
} catch {
  throw "Не открыть $Port : $($_.Exception.Message)"
}
Reset-Board    # открытие порта роняет DTR -> плата перезагружается:
               # сбрасываем буфер и ждём баннер, иначе он исказит первый ответ

# Снимок настроек ДО проверок. Тесты меняют их в разных местах (метод защиты,
# движение без шпинделя, потерю связи, маску датчиков), и Test-Cleanup обязан
# вернуть станок ровно к тому, что было. Раньше он прописывал метод 4 и сразу
# TS: у станка с методом 5 прогон молча переписывал защиту в EEPROM, и отката
# назад не было. Откатываем по снимку, а не по списку.
$script:cfg0 = $null
$cfgRaw = Cmd "T"
if ($null -ne $cfgRaw -and $cfgRaw -match '"v"\s*:\s*\[') {
  $script:cfg0 = ($cfgRaw | ConvertFrom-Json).v
  Say ("снимок настроек: " + $script:cfg0.Count + " значений, метод защиты " + $script:cfg0[0])
} else {
  Say "!! настройки не прочитались - откат в Test-Cleanup делать нечем, станок останется как есть"
}

# Стартовое состояние датчиков: обороты 0 и ток 0. При нулевых оборотах
# защита не взводится вовсе (взвод ждёт rpm > S_RESTART, а подмена нулями
# делает ровно ноль), поэтому на столе по умолчанию не может встать ни одна
# авария по оборотам или току. Раньше здесь стояло RP 1500 («шпиндель
# крутится»): взвод происходил, и любой сбой в уставке ронял аварию на
# ровном месте. Тесты защиты подмену ставят себе сами - им обороты нужны.
Cmd "RP 0" | Out-Null
Cmd "CU 0" | Out-Null
Cmd "!"   | Out-Null

# ---- 0. связь ----
Say "0. Связь и загрузка"
$boot = $null
for ($i = 0; $i -lt 6; $i++) {
  $r = Cmd "PING"
  if (IsOk $r) { $boot = $r; break }
}
if ($null -eq $boot) { throw "Плата не отвечает на PING. Прошейте прошивку." }
Ok "плата отвечает"

$st = Status
if ($null -eq $st) {
  Bad "статус разбирается" "не JSON: '$script:lastStatusRaw' ош: '$script:lastStatusErr'"
}
else {
  $need = @("fw","ft","lm","ax","sd")
  $miss = @()
  foreach ($k in $need) { if ($st.PSObject.Properties.Name -notcontains $k) { $miss += $k } }
  if ($miss.Count) { Bad "статус разбирается" "нет ключей: $($miss -join ',')" }
  else { Ok "статус разбирается (fw $($st.fw))" }
}

# ---- 1. настройки: чтение, запись, сохранение ----
Say ""
Say "1. Настройки и EEPROM"
$ts = Cmd "T"
if ($null -eq $ts -or $ts -notmatch '"v"\s*:\s*\[') { Bad "T отдаёт массив" "ответ: $ts" }
else {
  $v = ($ts | ConvertFrom-Json).v
  # NSET = 43. 30 - маска датчиков (S_SENS), 31 - страховка взвода (S_ARMWAIT),
  # 32..36 - пресеты хода и ползунок скоростей, 37..38 - длина хода, 42 - взвод
  # без датчиков. Индексы 39..41 заняты бывшим «домашним положением» и оставлены
  # на своих местах: NSET и STORE_VER менять нельзя, иначе не сойдётся CRC и
  # плата возьмёт умолчания целиком, то есть сбросит ВСЕ настройки разом.
  if ($v.Count -ne 43) { Bad "в настройках 43 значения" "пришло $($v.Count)" }
  else { Ok "в настройках 43 значения" }
  # S_SENS = 30: какие датчики реально подключены. Проверяем обе стороны:
  # выключенный датчик плата не читает, подмена всё равно важнее флага.
  Cmd "T 30 0" | Out-Null
  $s0 = Status
  if ($s0.sn -eq 0 -and $s0.sd.co -eq 0 -and $s0.sd.ro -eq 0) {
    Ok "датчики выключены: тока нет, обороты нулевые"
  } else { Bad "датчики выключены" "sn=$($s0.sn) co=$($s0.sd.co) ro=$($s0.sd.ro)" }
  Cmd "RP 900" | Out-Null
  Start-Sleep -Milliseconds 300
  $s1 = Status
  if ($s1.sd.r -eq 900 -and $s1.sd.ro -eq 1) { Ok "подмена оборотов работает и при снятом тахо" }
  else { Bad "подмена оборотов при снятом тахо" "r=$($s1.sd.r) ro=$($s1.sd.ro)" }
  Cmd "RP -1" | Out-Null
  Cmd "T 30 7" | Out-Null
  $s2 = Status
  if ($s2.sn -eq 7) { Ok "S_SENS возвращается к 7 (все датчики)" }
  else { Bad "S_SENS вернулся к 7" "sn=$($s2.sn)" }
}

$was14 = (Cmd "T" | ConvertFrom-Json).v[14]
$r = Cmd "T 14 1"
if (-not (IsOk $r)) { Bad "T меняет значение" "ответ: $r" }
else {
  $now = (Cmd "T" | ConvertFrom-Json).v[14]
  if ($now -eq 1) { Ok "T меняет значение в памяти" } else { Bad "T меняет значение" "стало $now" }
}
Cmd "TS" | Out-Null
Reset-Board
$after = (Cmd "T" | ConvertFrom-Json).v[14]
if ($after -eq 1) { Ok "настройка пережила перезагрузку" }
else { Bad "настройка пережила перезагрузку" "после перезагрузки $after" }
Cmd "T 14 $was14" | Out-Null
Cmd "TS" | Out-Null

# ---- 2. защита по оборотам ----
Say ""
Say "2. Защита по оборотам"
Test-Mode
Cmd "T 0 1"  | Out-Null    # метод 1: только падение оборотов
Cmd "T 1 400" | Out-Null    # уставка
Cmd "T 10 400" | Out-Null   # порог перезапуска
Cmd "T 9 200"  | Out-Null   # задержка пуска 200 мс
Cmd "T 4 300"  | Out-Null   # подтверждение 300 мс
Cmd "!" | Out-Null
Cmd "RP 1500" | Out-Null    # раскрутился -> взвод, ждём задержку
Start-Sleep -Milliseconds 400
$st = Status
if ($st.sd.ar -eq 1) { Ok "защита взвелась после разгона" }
else { Bad "защита взвелась" "ar=$($st.sd.ar)" }

Cmd "RP 500" | Out-Null
Start-Sleep -Milliseconds 700
$st = Status
if ($st.ft -eq 0) { Ok "при 500 об/мин аварии нет" }
else { Bad "при 500 об/мин аварии нет" "ft=$($st.ft)" }

Cmd "RP 350" | Out-Null
Start-Sleep -Milliseconds 900
$st = Status
if ($st.ft -eq 1) { Ok "при 350 об/мин авария РПМ" }
else { Bad "при 350 об/мин авария РПМ" "ft=$($st.ft)" }
if ($st.ax[0].r -eq 0 -and $st.ax[1].r -eq 0) { Ok "авария остановила обе оси" }
else { Bad "авария остановила обе оси" "ось едет" }

Cmd "RP 1500" | Out-Null
$r = Cmd "!"
if (IsOk $r) { Ok "сброс аварии проходит" } else { Bad "сброс аварии" (ErrOf $r) }

# Страховка взвода: порог 2000 об/мин, а шпиндель крутится на 300. Через
# cfg[31] = 600 мс защита обязана взвестись и поднять предупреждение (aw=1).
# Порядок важен: сначала подмена, потом сброс аварии — иначе плата взведётся
# по старому значению оборотов и тест врёт.
Cmd "T 10 2000" | Out-Null
Cmd "T 31 600"  | Out-Null
Cmd "RP 300"    | Out-Null
Cmd "!"        | Out-Null
Start-Sleep -Milliseconds 300
$st = Status
if ($st.sd.ar -eq 0) { Ok "до страховки защита не взвелась (300 < 2000)" }
else { Bad "взвод раньше срока" "ar=$($st.sd.ar)" }
Start-Sleep -Milliseconds 700
$st = Status
if ($st.sd.ar -eq 1 -and $st.sd.aw -eq 1) { Ok "страховка взвела защиту и подняла флаг" }
else { Bad "страховка взвода" "ar=$($st.sd.ar) aw=$($st.sd.aw)" }
if ($st.sd.awm -eq 600) { Ok "статус отдаёт саму страховку" }
else { Bad "статус отдаёт страховку" "awm=$($st.sd.awm)" }
Cmd "T 31 0" | Out-Null     # страховка выключена
Cmd "RP 300" | Out-Null
Cmd "!" | Out-Null
Start-Sleep -Milliseconds 500
$st = Status
if ($st.sd.ar -eq 0) { Ok "при выключенной страховке взвода нет" }
else { Bad "взвод без страховки" "ar=$($st.sd.ar)" }
Cmd "T 10 400" | Out-Null   # порог обратно
Cmd "T 31 3000" | Out-Null
Cmd "RP 1500" | Out-Null

# ---- 3. защита по току ----
Say ""
Say "3. Защита по току"
Cmd "T 0 3"  | Out-Null    # метод: только ТОК
Cmd "T 5 70"  | Out-Null    # 7.0 А
Cmd "T 8 300" | Out-Null    # подтверждение
Cmd "!" | Out-Null
Cmd "RP 1500" | Out-Null
Start-Sleep -Milliseconds 400
Cmd "CU 50" | Out-Null      # 5.0 А - норма
Start-Sleep -Milliseconds 700
$st = Status
if ($st.ft -eq 0) { Ok "при 5.0 А аварии нет" } else { Bad "при 5.0 А аварии нет" "ft=$($st.ft)" }
Cmd "CU 75" | Out-Null      # 7.5 А - закусывание
Start-Sleep -Milliseconds 900
$st = Status
if ($st.ft -eq 3) { Ok "при 7.5 А авария ТОК" } else { Bad "при 7.5 А авария ТОК" "ft=$($st.ft)" }
Cmd "CU -1" | Out-Null
Cmd "!" | Out-Null

# ---- 4. концевики ----
Say ""
Say "4. Концевики"
Cmd "T 0 0" | Out-Null      # защита выключена, тест изолирован
Cmd "!" | Out-Null
# Нажимаем концевик НА ХОДУ: на реальном станке так и происходит, и только
# так ось узнаёт его сторону (limDir) — блокируется та, с которой пришла.
Cmd "D 1 0" | Out-Null
Cmd "V 1 800" | Out-Null
Cmd "G 1" | Out-Null
Start-Sleep -Milliseconds 150
Cmd "L 0 1" | Out-Null      # концевик X-1
Start-Sleep -Milliseconds 400
Cmd "S 1" | Out-Null
$st = Status
if (($st.lm -band 1) -eq 1) { Ok "концевик X1 виден в статусе" }
else { Bad "концевик X1 виден" "lm=$($st.lm)" }
if ($st.ft -eq 4) { Ok "нажатие концевика даёт аварию 4" }
else { Bad "нажатие концевика даёт аварию 4" "ft=$($st.ft)" }

$r = Cmd "!"
if (-not (IsOk $r)) { Ok "сброс заблокирован, пока концевик нажат ($((ErrOf $r)))" }
else { Bad "сброс заблокирован" "прошёл, хотя концевик нажат" }

# путь к концевику закрыт, обратный путь открыт
$r = Cmd "N 1 100"
if (-not (IsOk $r)) { Ok "ход к нажатому концевику отклонён ($((ErrOf $r)))" }
else { Bad "ход к нажатому концевику отклонён" "прошёл" }
$r = Cmd "N 1 -100"
if (IsOk $r) { Ok "ход от концевика разрешён" } else { Bad "ход от концевика разрешён" (ErrOf $r) }
Cmd "S 1" | Out-Null

Cmd "L 0 -1" | Out-Null
Start-Sleep -Milliseconds 200
$r = Cmd "!"
if (IsOk $r) { Ok "после отпускания концевика сброс проходит" }
else { Bad "после отпускания концевика сброс" (ErrOf $r) }

# ---- 5. движение осей ----
Say ""
Say "5. Движение осей и позиция"
Cmd "D 1 0" | Out-Null
# Обнуления на станке нет, поэтому меряем не ноль, а сдвиг: сколько было до хода.
$s0 = Status
$p0 = 0
if ($null -ne $s0) { $p0 = [long]$s0.ax[0].p }
Cmd "V 1 1000" | Out-Null
$r = Cmd "N 1 5000"
if (-not (IsOk $r)) { Bad "ход на 5000 шагов принят" (ErrOf $r) }
else {
  $deadline = (Get-Date).AddSeconds(20)
  $done = $false
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 150
    $s = Status
    if ($null -ne $s -and $s.ax[0].r -eq 0 -and $s.ax[0].g -eq 0) { $done = $true; break }
  }
  if (-not $done) { Bad "ход завершился" "ось не остановилась за 20 с" }
  else {
    $s = Status
    if ($s.ax[0].p -eq ($p0 - 5000)) { Ok "позиция сдвинулась на -5000 шагов (было $p0, стало $($s.ax[0].p))" }
    else { Bad "позиция сошлась" "было $p0, стало $($s.ax[0].p)" }
    if ($s.ax[0].g -eq 0) { Ok "флаг цели снят" } else { Bad "флаг цели снят" "g=$($s.ax[0].g)" }
    # Обнуление счётчика на месте: ось уже стоит с ненулевым p, и это самый
    # дешёвый момент для проверки - двигать ничего не надо, положение само
    # оказалось ненулевым после хода выше.
    $r = Cmd "Z 1"
    if (-not (IsOk $r)) { Bad "обнуление счётчика принято" (ErrOf $r) }
    else {
      Start-Sleep -Milliseconds 200
      $s = Status
      if ($null -ne $s -and $s.ax[0].p -eq 0) { Ok "обнуление обнулило p (было -5000, стало 0)" }
      else { Bad "после обнуления p = 0" "стало $($s.ax[0].p)" }
    }
  }
}

# ---- 6. рампа не превышает заданную частоту ----
Say ""
Say "6. Рампа"
Cmd "T 22 2000" | Out-Null     # ускорение X
Cmd "V 1 3000"  | Out-Null
Cmd "D 1 1"     | Out-Null
Cmd "N 1 60000" | Out-Null
# Обнуление на ходу запрещено: цель задана шагами от pos, и обнуление сдвинуло
# бы её на всю пройденную длину. Проверяем сразу после старта хода, пока ось
# точно едет - ниже, после цикла, она может уже стоять.
$r = Cmd "Z 1"
if (IsOk $r) { Bad "обнуление на ходу отклонено" "плата приняла Z" }
elseif ((ErrOf $r) -like "*СНАЧАЛА СТОП*") { Ok "обнуление на ходу отклонено" }
else { Bad "обнуление на ходу отклонено" (ErrOf $r) }
$maxHz = 0
$over = $false
$deadline = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $deadline) {
  $s = Status
  if ($null -eq $s) { break }
  if ($s.ax[0].n -gt $maxHz) { $maxHz = $s.ax[0].n }
  if ($s.ax[0].n -gt 3100) { $over = $true }
  if ($s.ax[0].r -eq 0 -and $s.ax[0].g -eq 0) { break }
  Start-Sleep -Milliseconds 40
}
Cmd "S 1" | Out-Null
if ($over) { Bad "частота не превышает заданную" "пик $maxHz при задании 3000" }
else { Ok "частота не превышает заданную (пик $maxHz Гц)" }
if ($maxHz -gt 2500) { Ok "разгон реально разгоняет (пик $maxHz Гц)" }
else { Bad "разгон реально разгоняет" "пик всего $maxHz Гц" }

# ---- 7. блокировка пути к концевику ----
Say ""
Say "7. Блокировка пути к концевику"
Cmd "T 14 1" | Out-Null      # ход при стоящем шпинделе разрешён
# Правило общее для обеих осей — значит, и проверяем обе. Нумерация разная: в
# командах ось 1 = X и ось 2 = Y, а бит концевика в L считается по битовой маске
# платы (0 = X-1, 1 = X-2, 2 = Y-1, 3 = Y-2), то есть у Y он вдвое больше
# номера оси минус один.
foreach ($ax in 1, 2) {
  $bit = ($ax - 1) * 2
  $nm = if ($ax -eq 1) { "X" } else { "Y" }
  Say "ось $nm"
  Cmd "!" | Out-Null
  Cmd "D $ax 1" | Out-Null
  Cmd "V $ax 2000" | Out-Null
  Cmd "G $ax" | Out-Null
  Start-Sleep -Milliseconds 300
  # Форсируем концевик на ходу: ось должна упереться и встать.
  Cmd "L $bit 1" | Out-Null
  Start-Sleep -Milliseconds 200
  $s = Status
  if ($s.ax[$ax-1].r -eq 0) { Ok "$nm ось встала у концевика" }
  else { Bad "$nm ось встала у концевика" "ось едет" }
  if ($s.ft -eq 4) { Ok "$nm авария «сработал концевик»" }
  else { Bad "$nm авария «сработал концевик»" "ft=$($s.ft)" }

  # Сторона, с которой ось пришла, закрыта: тот же ход снова не запустится.
  $r = Cmd "G $ax"
  if ($r -match 'ПУТЬ К КОНЦЕВИКУ ЗАКРЫТ') { Ok "$nm путь в сторону концевика закрыт" }
  else { Bad "$nm путь в сторону концевика закрыт" $r }

  # Обратная сторона открыта — отвести можно.
  Cmd "D $ax 0" | Out-Null
  $r = Cmd "G $ax"
  if (IsOk $r) { Ok "$nm отвод в обратную сторону разрешён" }
  else { Bad "$nm отвод в обратную сторону разрешён" (ErrOf $r) }
  Start-Sleep -Milliseconds 200
  Cmd "S $ax" | Out-Null
  Cmd "L $bit -1" | Out-Null
  Start-Sleep -Milliseconds 200
  Cmd "!" | Out-Null

  # Нажатие стоящей оси: сторона неизвестна, и отводить ось было бы нечем — раньше
  # закрывались обе стороны. Теперь первый ход сам задаёт сторону: куда оператор
  # ведёт, там выход, и закрывается обратная.
  Cmd "L $bit 1" | Out-Null
  Start-Sleep -Milliseconds 200
  Cmd "D $ax 0" | Out-Null
  $r = Cmd "G $ax"
  if (IsOk $r) { Ok "$nm отвод от концевика на стоящей оси разрешён" }
  else { Bad "$nm отвод от концевика на стоящей оси разрешён" (ErrOf $r) }
  Start-Sleep -Milliseconds 200
  Cmd "S $ax" | Out-Null
  Cmd "D $ax 1" | Out-Null
  $r = Cmd "G $ax"
  if ($r -match 'ПУТЬ К КОНЦЕВИКУ ЗАКРЫТ') { Ok "$nm после отвода обратная сторона закрыта" }
  else { Bad "$nm после отвода обратная сторона закрыта" $r }
  Cmd "L $bit -1" | Out-Null
  Start-Sleep -Milliseconds 200
  Cmd "!" | Out-Null
}

# ---- 8. потеря связи ----
Say ""
Say "8. Потеря связи"
Cmd "T 15 1200" | Out-Null
Cmd "T 14 1"    | Out-Null
Cmd "!" | Out-Null
Cmd "D 1 1" | Out-Null
Cmd "V 1 2000" | Out-Null
Cmd "G 1" | Out-Null
# Молчим дольше таймаута. Первая же следующая команда вернёт аварию: плата
# проверяет потерю связи ДО разбора команд, поэтому опрос статуса уже не
# успевает продлить связь.
Start-Sleep -Milliseconds 2500
$s = Status
if ($s.ft -eq 5) { Ok "молчание панели привело к аварии связи" }
elseif ($s.ax[0].r -eq 0) { Ok "ось остановлена при пропадании панели" }
else { Bad "потеря связи" "ft=$($s.ft), ось едет" }
Cmd "T 15 0" | Out-Null
Cmd "!" | Out-Null

# ---- 9. задержка основного цикла ----
Say ""
Say "9. Время реакции"
Cmd "W0" | Out-Null
Cmd "V 1 2000" | Out-Null
Cmd "V 2 2000" | Out-Null
Cmd "G 1" | Out-Null
Cmd "G 2" | Out-Null
Start-Sleep -Seconds 5
$rw = Cmd "W"
Cmd "X" | Out-Null
if ($null -eq $rw -or $rw -notmatch '"loop_max_us"') { Bad "отчёт W" "ответ: $rw" }
else {
  $w = $rw | ConvertFrom-Json
  # lost знаковый: +N = потеряно тиков, -N = погрешность привязки millis.
  # Допускаем небольшой модуль (порог 1000 тиков за окно), а не строгий ноль.
  if ([Math]::Abs([long]$w.lost) -lt 1000) { Ok "ISR укладывается в 25 мкс (потерь тиков нет)" }
  else { Bad "ISR укладывается в 25 мкс" "lost=$($w.lost)" }
  if ($w.loop_max_us -lt 5000) { Ok "худшая задержка цикла $($w.loop_max_us) мкс < 5000" }
  else { Bad "худшая задержка цикла" "$($w.loop_max_us) мкс" }
  Say ("        цикл: " + $w.loop_hz + " Гц, ISR: " + $w.isr_hz + " Гц")
}

# ---- 10. прогон под нагрузкой ----
Say ""
Say "10. Прогон $ShortRunSec с обеими осями"
Cmd "!" | Out-Null
Cmd "V 1 2500" | Out-Null
Cmd "V 2 1800" | Out-Null
Cmd "D 1 0" | Out-Null
Cmd "D 2 1" | Out-Null
Cmd "W0" | Out-Null          # диагностика обнуляется ДО прогона
Cmd "G 1" | Out-Null
Cmd "G 2" | Out-Null
$p0 = (Status).ax[0].p
$t0 = Get-Date
$alive = $true
while (((Get-Date) - $t0).TotalSeconds -lt $ShortRunSec) {
  Start-Sleep -Milliseconds 250
  $s = Status
  if ($null -eq $s) { Bad "плата жива под нагрузкой" "нет ответа"; $alive = $false; break }
  if ($s.ft -ne 0) { Bad "аварий под нагрузкой нет" "ft=$($s.ft)"; $alive = $false; break }
}
Cmd "X" | Out-Null
Start-Sleep -Milliseconds 200
$s = Status
$p1 = $s.ax[0].p
$moved = [Math]::Abs($p1 - $p0)
if ($moved -gt 1000) { Ok "ось прошла $moved шагов без зависаний" }
else { Bad "ось прошла $moved шагов" "почти не двигалась" }
# lw (loopMaxUs) сюда не годится: печать статуса ~25 мс ложится в него по
# замыслу (худшая реакция цикла). Настоящие признаки зависания - потеря тиков
# и паузы ISR, их и проверяем.
$rw = Cmd "W"
if ($null -eq $rw -or $rw -notmatch '"lost"') { Bad "отчёт W после прогона" "ответ: $rw" }
else {
  $w = $rw | ConvertFrom-Json
  if ([Math]::Abs([long]$w.lost) -lt 1000) { Ok "потерь тиков за прогон нет (lost=$($w.lost))" }
  else { Bad "потерь тиков за прогон нет" "lost=$($w.lost)" }
  if ($w.isr_gap_us -lt 20000) { Ok "ISR без пауз (gap $($w.isr_gap_us) мкс)" }
  else { Bad "ISR без пауз" "isr_gap_us=$($w.isr_gap_us)" }
}

# ---- 11. журнал событий (строки '#') ----
# Проверяем, что плата объявляет изменения состояния и что стенд их видит:
# Get-Line пропускает событие и возвращает настоящий ответ. Только команды
# без движения.
Say ""
Say "11. Журнал событий"

Events-Clear
$r = Cmd "Z 1"
if (IsOk $r) { Ok "Z 1 вернул OK, а не строку события" }
else { Bad "Z 1 вернул OK, а не строку события" "$r / события: $(Events-Text)" }
if ((Events-Text) -match 'ОБНУЛЕНА X') { Ok "плата объявила обнуление оси" }
else { Bad "плата объявила обнуление оси" "$(Events-Text)" }

Events-Clear
$r = Cmd "S 1"
if (IsOk $r) { Ok "S 1 вернул OK при наличии строки события" }
else { Bad "S 1 вернул OK при наличии строки события" "$r" }
if ((Events-Text) -match 'СТОП X') { Ok "плата объявила стоп по команде" }
else { Bad "плата объявила стоп по команде" "$(Events-Text)" }

# Подмена концевика: событие идёт ДО ответа, а концевик и авария — ПОСЛЕ
# (с задержкой дебаунса), поэтому события дочитываются отдельно.
Events-Clear
$r = Cmd "L 0 1"
if (IsOk $r) { Ok "L 0 1 вернул OK" } else { Bad "L 0 1 вернул OK" "$r" }
if ((Events-Text) -match 'ПОДМЕНА КОНЦЕВИКА X-1 = НАЖАТ') { Ok "плата объявила подмену концевика" }
else { Bad "плата объявила подмену концевика" "$(Events-Text)" }
Read-Events 400
if ((Events-Text) -match 'КОНЦЕВИК X-1 НАЖАТ: ось стояла') { Ok "плата объявила концевик на стоящей оси" }
else { Bad "плата объявила концевик на стоящей оси" "$(Events-Text)" }
if ((Events-Text) -match 'АВАРИЯ 4 концевик') { Ok "плата объявила аварию концевика с номером" }
else { Bad "плата объявила аварию концевика с номером" "$(Events-Text)" }

Events-Clear
$r = Cmd "!"
if ((ErrOf $r) -match 'КОНЦЕВИК') { Ok "сброс при нажатом концевике отвергнут" }
else { Bad "сброс при нажатом концевике отвергнут" "$r" }
if ((Events-Text) -match 'СБРОС ОТКАЗАЛ') { Ok "плата объяснила, почему сброс не прошёл" }
else { Bad "плата объяснила, почему сброс не прошёл" "$(Events-Text)" }

Events-Clear
Cmd "L 0 -1" | Out-Null
Read-Events 400
if ((Events-Text) -match 'КОНЦЕВИК X-1 ОТПУЩЕН') { Ok "плата объявила отпускание концевика" }
else { Bad "плата объявила отпускание концевика" "$(Events-Text)" }

Events-Clear
$r = Cmd "!"
if (IsOk $r) { Ok "авария сброшена" } else { Bad "авария сброшена" "$r" }
if ((Events-Text) -match 'АВАРИЯ СБРОШЕНА') { Ok "плата объявила сброс аварии" }
else { Bad "плата объявила сброс аварии" "$(Events-Text)" }

# ---- 12. пуск привода при висящей аварии ----
# Пока авария не сброшена, привод запускать нельзя: G (джог) и N (ход) должны
# отвечать «СБРОСЬ АВАРИЮ». Раньше они про аварию не спрашивали вовсе.
#
# Движения нет. Ось Y переводится на нулевую скорость, при которой и джог, и ход
# физически не могут сдвинуть стол: плата и до, и после проверки аварии отвечает
# «СКОРОСТЬ НЕ ЗАДАНА» и остаётся на месте. Так отказ проверяется, а сдвинуть
# стол нечем - ровно та же мысль, что в разделе 11 с журналом событий.
Say ""
Say "12. Пуск привода при висящей аварии"

$startMs = 1500
if ($null -ne $script:cfg0) { $startMs = $script:cfg0[9] }   # S_STARTMS

# Авария 3 (ток), а не 4 (концевик): концевик на столе не нажат, но проверять
# надо именно «любая авария», а отвод от концевика проверяет раздел 7.
# Взвод защиты обязателен: на подмене тока без него авария не встаёт, и проверка
# молча прошла бы на пустой плате.
Cmd "T 0 0"  | Out-Null      # снять защиту
Cmd "!"     | Out-Null
Cmd "CU -1"  | Out-Null
Cmd "RP -1"  | Out-Null
Cmd "T 0 5"  | Out-Null      # метод «обороты MIN + ток»
Cmd "RP 600" | Out-Null      # обороты выше порога -> взвод
$armed = $false
$tw = Get-Date
while (((Get-Date) - $tw).TotalMilliseconds -lt 5000) {
  $sa = Status
  if ($null -ne $sa -and $null -ne $sa.sd -and $sa.sd.ar -eq 1) { $armed = $true; break }
  Start-Sleep -Milliseconds 60
}
Start-Sleep -Milliseconds ($startMs + 500)   # переждать задержку после пуска
Cmd "CU 100" | Out-Null      # ток выше уставки -> авария 3
$tw = Get-Date
while (((Get-Date) - $tw).TotalMilliseconds -lt 3000) {
  $sa = Status
  if ($null -ne $sa -and $sa.ft -ne 0) { break }
  Start-Sleep -Milliseconds 60
}
$sa = Status
if ($sa.ft -eq 3) { Ok "авария по току поднялась (взвод=$armed)" }
else { Bad "авария по току поднялась" "ft=$($sa.ft), взвод=$armed - проверять нечего" }

# h - это скорость оси в шаг/с (sp - шаг на мм, его читать нельзя)
$spY = $sa.ax[1].h
Cmd "V 2 0" | Out-Null       # дальше G и N по этой оси не поедут ни при каком ответе
Cmd "D 2 0" | Out-Null
$p0 = (Status).ax[1].p

$r = Cmd "G 2"
if ((ErrOf $r) -match 'СБРОСЬ АВАРИЮ') { Ok "джог при висящей аварии отвергнут" }
else { Bad "джог при висящей аварии отвергнут" $r }
$r = Cmd "N 2 10"
if ((ErrOf $r) -match 'СБРОСЬ АВАРИЮ') { Ok "ход на N шагов при висящей аварии отвергнут" }
else { Bad "ход на N шагов при висящей аварии отвергнут" $r }
$sa = Status
if ($sa.ax[1].r -eq 0 -and $sa.ax[1].p -eq $p0) { Ok "ось Y не сдвинулась" }
else { Bad "ось Y не сдвинулась" "r=$($sa.ax[1].r), p с $p0 на $($sa.ax[1].p)" }

# После сброса те же команды обязаны дойти ДАЛЬШЕ, до проверки скорости. Это и
# есть доказательство, что при висящей аварии их глушил запрет по аварии, а не
# что-то другое: увидим ровно ту следующую ошибку.
$r = Cmd "!"
if (IsOk $r) { Ok "аварию сбросили" } else { Bad "аварию сбросили" $r }
$r = Cmd "G 2"
if ((ErrOf $r) -match 'СКОРОСТЬ НЕ ЗАДАНА') { Ok "после сброса джог доходит до проверки скорости" }
else { Bad "после сброса джог доходит до проверки скорости" $r }
$r = Cmd "N 2 10"
if ((ErrOf $r) -match 'СКОРОСТЬ НЕ ЗАДАНА') { Ok "после сброса ход доходит до проверки скорости" }
else { Bad "после сброса ход доходит до проверки скорости" $r }
$sa = Status
if ($sa.ax[1].r -eq 0 -and $sa.ax[1].p -eq $p0) { Ok "ось Y и после сброса не сдвинулась" }
else { Bad "ось Y и после сброса не сдвинулась" "r=$($sa.ax[1].r), p с $p0 на $($sa.ax[1].p)" }
Cmd "V 2 $spY" | Out-Null    # скорость Y возвращаем ту, что была до раздела

Test-Cleanup
$sp.Close()

Say ""
Say "============================================"
Say ("Пройдено: " + $script:pass + "   Провалено: " + $script:fail)
if ($script:fail -gt 0) {
  Say "Провалились:"
  foreach ($n in $script:failNames) { Say "  - $n" }
  Say "============================================"
  exit 1
}
Say "Все проверки пройдены."
Say "============================================"
exit 0
