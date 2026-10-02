# =============================================================================
#  Подготовка комплекта установщика: кладёт Node.js в install\payload
#
#  Зачем: панель должна ставиться на Windows 7 без интернета. Последняя
#  официально поддерживаемая на Win7 версия Node — 12.22.12, поэтому в
#  установщик кладём именно её.
#
#  Запуск (один раз, на машине разработчика, нужен интернет):
#     powershell -ExecutionPolicy Bypass -File install\fetch-node.ps1
# =============================================================================

param(
  [string]$OutDir
)

$ErrorActionPreference = "Stop"

# Версия и её хеш из официального SHASUMS256.txt, проверенные при сборке.
$Ver      = "12.22.12"
$File     = "node-v$Ver-win-x64.zip"
$Sha256   = "09639bac66d4dc4dd52179968209413ad4b7360e917dcbe8834052a4b936a087"
$BaseUrl  = "https://nodejs.org/dist/v$Ver/"

if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot "payload" }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
$zip = Join-Path $OutDir $File

function Say($t, $c = "Gray") { Write-Host $t -ForegroundColor $c }

if (Test-Path $zip) {
  $h = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
  if ($h -eq $Sha256) { Say "Уже на месте и хеш сходится: $zip" "Green"; exit 0 }
  Say "Файл есть, но хеш не тот — качаю заново." "Yellow"
}

Say "Качаю Node.js v$Ver (win-x64)..."
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
(New-Object Net.WebClient).DownloadFile($BaseUrl + $File, $zip)

$h = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
if ($h -ne $Sha256) {
  throw "Хеш не сошёлся. Ожидал $Sha256, получил $h. Файл: $zip"
}

Say ("Готово: {0} ({1:N1} МБ)" -f $zip, ((Get-Item $zip).Length / 1MB)) "Green"
Say "Теперь можно запускать install\install.cmd"