@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion
REM =====================================================================
REM  VBoxSup (VirtualBox 7.x 의 핵심 커널 드라이버) 상태 확인 및 복구
REM
REM  ★ 앞선 진단의 정정
REM    VirtualBox 6.1.x 중간부터 핵심 드라이버 이름이 바뀌었다.
REM        구:  VBoxDrv.sys  / 서비스 VBoxDrv
REM        신:  VBoxSup.sys  / 서비스 VBoxSup
REM    7.2.16 에서는 VBoxDrv 가 없는 것이 정상이다.
REM    앞서 "sc query VBoxDrv" 만 보고 드라이버 미설치로 단정했던 것은
REM    잘못된 판단이었다. 실제로 봐야 할 것은 VBoxSup 이다.
REM
REM  ★ 그래서 .sys 파일을 함부로 지우면 안 된다
REM    VBoxSup.sys 는 지금 설치의 핵심 파일이다. 지우면 정상 설치까지
REM    망가져서 반드시 재설치를 해야 하는 상태가 된다.
REM
REM  사용법: 마우스 우클릭 - "관리자 권한으로 실행"
REM =====================================================================

echo.
echo ============================================================
echo   VBoxSup 드라이버 확인 (VirtualBox 7.x 핵심 드라이버)
echo ============================================================
echo.

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo   [!] 관리자 권한이 필요합니다. 우클릭 - 관리자 권한으로 실행
    pause
    exit /b 1
)

echo ------------------------------------------------------------
echo  [1] 서비스 등록 상태
echo ------------------------------------------------------------
echo.
echo   -- VBoxSup (7.x 핵심, 이게 중요) --
sc query VBoxSup 2>&1 | findstr /I "SERVICE_NAME STATE 지정된"
echo.
echo   -- VBoxDrv (6.x 구버전 이름, 없는 게 정상) --
sc query VBoxDrv 2>&1 | findstr /I "SERVICE_NAME STATE 지정된"
echo.
echo   -- VBoxNetLwf / VBoxNetAdp (네트워크) --
sc query VBoxNetLwf 2>&1 | findstr /I "SERVICE_NAME STATE 지정된"
echo.

echo ------------------------------------------------------------
echo  [2] 서비스 상세 (시작 유형 확인)
echo ------------------------------------------------------------
sc qc VBoxSup 2>&1 | findstr /I "BINARY_PATH_NAME START_TYPE 지정된"
echo.
echo   ^> START_TYPE 이 DEMAND_START 면 정상입니다.
echo     DISABLED 면 그것이 원인입니다.
echo.

echo ------------------------------------------------------------
echo  [3] 드라이버 시작 시도
echo ------------------------------------------------------------
sc start VBoxSup 2>&1 | findstr /I "SERVICE_NAME STATE FAILED 오류 이미"
echo.

echo ------------------------------------------------------------
echo  [4] 시작 후 상태
echo ------------------------------------------------------------
sc query VBoxSup 2>&1 | findstr /I "STATE 지정된"
echo.

echo ------------------------------------------------------------
echo  [5] 판정
echo ------------------------------------------------------------
sc query VBoxSup >nul 2>&1
if errorlevel 1 (
    echo   [X] VBoxSup 서비스가 등록되지 않았습니다.
    echo.
    echo       .sys 파일은 있는데 서비스 등록만 안 된 상태입니다.
    echo       아래로 등록을 시도해볼 수 있습니다:
    echo.
    echo         sc create VBoxSup type= kernel start= demand ^
    echo            binPath= "%SystemRoot%\System32\drivers\VBoxSup.sys"
    echo         sc start VBoxSup
    echo.
    echo       그래도 안 되면 재설치가 답입니다.
) else (
    sc query VBoxSup | findstr /I "RUNNING" >nul
    if errorlevel 1 (
        echo   [!] 서비스는 있으나 실행 중이 아닙니다.
        echo       위 [3] 의 오류 메시지를 확인하세요.
        echo       보안 부팅/서명 문제면 재설치가 필요합니다.
    ) else (
        echo   [O] VBoxSup 정상 실행 중입니다.
        echo.
        echo       드라이버는 문제가 없다는 뜻입니다.
        echo       이제 VirtualBox 에서 VM 을 시작해 보세요.
        echo       그래도 실패하면 원인은 VM 설정 쪽입니다
        echo       ^(vm_safe_mode.bat 을 실행해 보세요^)
    )
)
echo.

echo ============================================================
echo   ※ C:\Windows\System32\drivers 의 VBox*.sys 파일을
echo      지금 지우지 마세요. VBoxSup.sys 는 현재 설치의
echo      핵심 파일이라 삭제하면 재설치가 강제됩니다.
echo      삭제는 "제거 후에도 남아 있을 때" 만 하는 것입니다.
echo ============================================================
echo.
pause
