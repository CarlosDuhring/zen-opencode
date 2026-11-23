@echo off
setlocal
set "S=%~dp0"
set "PS=powershell -NoProfile -ExecutionPolicy Bypass"

if /i "%~1"=="warp"      ( %PS% -File "%S%zen_warp.ps1" & exit /b %errorlevel% )
if /i "%~1"=="auto"      ( %PS% -File "%S%zen_auto.ps1" on & exit /b %errorlevel% )
if /i "%~1"=="autooff"   ( %PS% -File "%S%zen_auto.ps1" off & exit /b %errorlevel% )
if /i "%~1"=="autostatus" ( %PS% -File "%S%zen_auto.ps1" status & exit /b %errorlevel% )
if /i "%~1"=="backup"    ( %PS% -File "%S%zen_auto.ps1" backup & exit /b %errorlevel% )
if /i "%~1"=="restore"   ( %PS% -File "%S%zen_auto.ps1" restore & exit /b %errorlevel% )
if /i "%~1"=="rotate"    ( %PS% -File "%S%zen_auto.ps1" rotate & exit /b %errorlevel% )
if /i "%~1"=="resume"    ( %PS% -File "%S%zen_auto.ps1" resume %2 & exit /b %errorlevel% )
if /i "%~1"=="status" (
  "C:\Program Files\Cloudflare\Cloudflare WARP\warp-cli.exe" status
  echo   seu IP:
  curl.exe -s -m 10 --noproxy "*" https://api.ipify.org
  echo.
  echo   egress do app:
  curl.exe -s -m 10 --noproxy "*" -x http://127.0.0.1:8899 https://api.ipify.org
  echo.
  %PS% -File "%S%zen_auto.ps1" status
  exit /b 0
)
echo uso: zen warp ^| auto ^| autooff ^| autostatus ^| backup ^| restore ^| rotate ^| resume ^| status
exit /b 1
