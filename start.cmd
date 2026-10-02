@echo off
rem JMD-2L CNC — лаунчер: ставит зависимости (один раз), запускает сервер
rem и открывает панель. Нужен Node.js LTS (nodejs.org, галочка "Add to PATH").
setlocal
cd /d "%~dp0"

where node >nul 2>nul
if errorlevel 1 (
  echo Установите Node.js LTS: https://nodejs.org  ^(галочка "Add to PATH"^)
  pause
  exit /b 1
)

if not exist server\node_modules (
  echo Ставлю зависимости впервые — нужен интернет...
  cd server
  call npm install --no-audit --no-fund
  if errorlevel 1 ( echo npm install не удался & pause & exit /b 1 )
  cd ..
)

start "" http://localhost:8080
node server\server.js
pause