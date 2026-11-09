@echo off
title BEATSHEET
cd /d "%~dp0"
if not exist node_modules (
  echo Instalando dependencias, primera vez...
  call npm install
)
echo.
echo BEATSHEET arrancando... el navegador se abre solo en http://localhost:5173
echo Cierra esta ventana para apagarlo.
echo.
call npm run dev
pause
