@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul

REM ===== 生成时间戳（去掉空格和冒号）=====
for /f %%i in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss"') do set TIMESTAMP=%%i
set LOG_FILE=%~dp0start_haif_services_%TIMESTAMP%.log

REM ===== 写日志头 =====
(
    echo =========================================
    echo   Haif Service Controller Starting...
    echo   %DATE% %TIME%
    echo =========================================
) > "%LOG_FILE%" 2>&1

REM ===== 主逻辑 =====
call :MAIN >> "%LOG_FILE%" 2>&1
goto :EOF


:MAIN
set "BASE_SERVICES=haif-mysql haif-redis haif-nginx haif-nacos"
set "BIZ_SERVICES=haif-gateway haif-base haif-wes"
set "MAX_RETRY=10"
set "WAIT_SECONDS=5"

REM ----- 定义服务对应端口 -----
REM 这里根据你的实际配置修改
set "PORT_nacos=8848"
set "PORT_mysql=3306"
set "PORT_redis=6379"
set "PORT_nginx=80"

REM ----- 启动基础服务 -----
for %%S in (%BASE_SERVICES%) do (
    call :CHECK_AND_START %%S
)

REM ----- 检查 Nacos 登录 -----
echo [INFO] Waiting extra 5 seconds for Nacos to be fully ready...
timeout /t 5 /nobreak >nul

set /a count=0
:LOGIN_LOOP
for /f "delims=" %%i in ('
    curl -s -X POST "http://127.0.0.1:8848/nacos/v1/auth/login" ^
    -H "Content-Type: application/x-www-form-urlencoded" ^
    -d "username=haif&password=haifeng123"
') do set "RESULT=%%i"

echo Response: %RESULT%

echo %RESULT% | findstr /C:"accessToken" >nul
if errorlevel 1 (
    set /a count+=1
    if !count! geq %MAX_RETRY% (
        echo [ERROR] Nacos login failed after %MAX_RETRY% retries.
        exit /b 1
    )
    echo [INFO] Nacos login not ready, retry !count!/%MAX_RETRY% in %WAIT_SECONDS% seconds...
    timeout /t %WAIT_SECONDS% /nobreak >nul
    goto LOGIN_LOOP
) else (
    echo [OK] Nacos login successful.
)

REM ----- 启动业务服务 -----
for %%S in (%BIZ_SERVICES%) do (
    call :CHECK_AND_START %%S
)

echo =========================================
echo   All services started successfully.
echo =========================================
goto :EOF


:CHECK_AND_START
set "SERVICE=%~1"
REM 检查是否运行
sc query "%SERVICE%" | findstr /I "RUNNING" >nul
if %errorlevel%==0 (
    echo [SKIP] %SERVICE% is already running.
    goto :WAIT_FOR_PORT
)

echo [INFO] Starting %SERVICE%...
net start "%SERVICE%"
call :WAIT_FOR_SERVICE %SERVICE%
goto :WAIT_FOR_PORT


:WAIT_FOR_SERVICE
set "SERVICE=%~1"
set /a count=0
:WAIT_LOOP
sc query "%SERVICE%" | findstr /I "RUNNING" >nul
if %errorlevel% neq 0 (
    set /a count+=1
    if !count! geq %MAX_RETRY% (
        echo [ERROR] Service %SERVICE% failed to start within %MAX_RETRY% retries.
        exit /b 1
    )
    echo [INFO] Waiting for %SERVICE%... Retry !count!/%MAX_RETRY%
    timeout /t %WAIT_SECONDS% /nobreak
    goto WAIT_LOOP
)
echo [OK] %SERVICE% is RUNNING.
goto :EOF


:WAIT_FOR_PORT
set "SERVICE=%~1"
set "PORT_VAR=PORT_%SERVICE:haif-=%"
call set "PORT=%%%PORT_VAR%%%"

if not defined PORT (
    echo [INFO] %SERVICE% has no port mapping, skip port check.
    goto :EOF
)

set /a count=0
:PORT_LOOP
netstat -ano | findstr ":%PORT% " >nul
if %errorlevel% neq 0 (
    set /a count+=1
    if !count! geq %MAX_RETRY% (
        echo [ERROR] %SERVICE% port %PORT% not ready after %MAX_RETRY% retries.
        exit /b 1
    )
    echo [INFO] Waiting for %SERVICE% port %PORT%... Retry !count!/%MAX_RETRY%
    timeout /t %WAIT_SECONDS% /nobreak
    goto PORT_LOOP
)
echo [OK] %SERVICE% port %PORT% is listening.
goto :EOF
