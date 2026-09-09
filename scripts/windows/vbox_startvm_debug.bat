@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion
REM =====================================================================
REM  VM 을 명령줄로 직접 띄워서 "실시간 오류 메시지" 를 받아낸다.
REM
REM  ★ 왜 필요한가
REM    VBox.log / VBoxHardening.log 가 둘 다 5일 전 것 그대로였다.
REM    = 이번 실패는 로그 파일을 만들지도 못하고 죽는다는 뜻이다.
REM    GUI 는 "E_FAIL" 이라는 껍데기 코드만 보여주고 원인을 숨긴다.
REM    VBoxManage 로 직접 띄우면 진짜 원인이 화면에 그대로 찍힌다.
REM
REM  ★ 커널 드라이버 상태도 함께 본다
REM    VirtualBox 는 VBoxDrv 라는 커널 드라이버 위에서 동작한다.
REM    Hyper-V 를 끄고 재부팅하는 과정에서 이 드라이버가 로드되지
REM    않으면, VM 은 시작 즉시 죽고 로그도 남지 않는다.
REM
REM  사용법: 마우스 우클릭 - "관리자 권한으로 실행"
REM =====================================================================

echo.
echo ============================================================
echo   VM 직접 실행 디버그
echo ============================================================
echo.

REM ---------------- VBoxManage 찾기 ----------------
set "VBOX="
if defined VBOX_MSI_INSTALL_PATH if exist "%VBOX_MSI_INSTALL_PATH%VBoxManage.exe" set "VBOX=%VBOX_MSI_INSTALL_PATH%VBoxManage.exe"
if not defined VBOX (
    for /f "tokens=2,*" %%A in ('reg query "HKLM\SOFTWARE\Oracle\VirtualBox" /v InstallDir 2^>nul ^| findstr InstallDir') do (
        if exist "%%B\VBoxManage.exe" set "VBOX=%%B\VBoxManage.exe"
    )
)
if not defined VBOX (
    for %%P in (
        "D:\Virtualbox\VBoxManage.exe"
        "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
        "E:\Virtualbox\VBoxManage.exe"
    ) do if not defined VBOX if exist %%P set "VBOX=%%~P"
)
if not defined VBOX (
    echo   [!] VBoxManage.exe 를 찾지 못했습니다. 경로를 끌어다 놓으세요.
    set /p VBOX="   경로: "
    set VBOX=!VBOX:"=!
)
echo   VBoxManage: %VBOX%
echo.

echo ------------------------------------------------------------
echo  [1] 커널 드라이버 상태  ^<-- 로그조차 안 남는 경우의 주범
echo ------------------------------------------------------------
sc query VBoxDrv 2>nul | findstr /I "STATE SERVICE_NAME"
if errorlevel 1 (
    echo   [!] VBoxDrv 서비스가 없습니다 ^(드라이버 미설치^)
) 
echo.
sc query VBoxSup 2>nul | findstr /I "STATE SERVICE_NAME"
echo.
echo   ^> STATE 가 4 RUNNING 이어야 정상입니다.
echo     1 STOPPED 이거나 서비스가 없으면 그것이 원인입니다.
echo.

echo   드라이버 시작을 시도합니다...
sc start VBoxDrv 2>&1 | findstr /I "SERVICE_NAME STATE FAILED 오류 실패"
echo.

echo ------------------------------------------------------------
echo  [2] 설치 무결성 확인
echo ------------------------------------------------------------
"%VBOX%" --version
echo.

echo ------------------------------------------------------------
echo  [3] VM 목록
echo ------------------------------------------------------------
"%VBOX%" list vms
echo.

set "VM=testVM"
"%VBOX%" showvminfo "%VM%" >nul 2>&1
if errorlevel 1 (
    set /p VM="   VM 이름을 입력하세요: "
    set VM=!VM:"=!
)

echo ------------------------------------------------------------
echo  [4] 현재 VM 상태
echo ------------------------------------------------------------
for /f "tokens=2 delims==" %%S in ('"%VBOX%" showvminfo "!VM!" --machinereadable ^| findstr /B "VMState="') do set "STATE=%%~S"
echo   상태: !STATE!
if /I "!STATE!"=="saved" (
    echo.
    echo   [!] 저장된 상태입니다. Hyper-V 로 돌던 시절의 CPU 상태라
    echo       지금 환경에서는 복원이 불가능할 수 있습니다.
    set /p D="   저장 상태를 버릴까요? (y 입력): "
    if /I "!D!"=="y" "%VBOX%" discardstate "!VM!"
)
echo.

echo ------------------------------------------------------------
echo  [5] VM 직접 시작  ^<-- 진짜 오류 메시지가 여기 나옵니다
echo ------------------------------------------------------------
echo   실행: VBoxManage startvm "!VM!" --type gui
echo.
"%VBOX%" startvm "!VM!" --type gui
echo.
echo   ^(종료 코드: %errorlevel%^)
echo.

echo ============================================================
echo   위 [1] 과 [5] 의 내용을 복사해서 보내주세요
echo ============================================================
echo.
pause
