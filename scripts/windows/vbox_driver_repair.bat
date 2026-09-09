@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion
REM =====================================================================
REM  VBoxDrv 커널 드라이버 복구
REM
REM  ★ 확정된 증상
REM      StartService: OpenService FAILED 1060
REM      1060 = ERROR_SERVICE_DOES_NOT_EXIST (서비스가 등록조차 안 됨)
REM
REM    VirtualBox 는 VBoxDrv 라는 커널 드라이버 위에서만 동작한다.
REM    이게 없으면 VM 프로세스가 뜨기 전에 죽으므로
REM    VBox.log 조차 만들어지지 않는다 (실제로 5일 전 로그 그대로였다).
REM
REM  ★ 이 스크립트는 재설치 전에 시도해볼 "가벼운 복구" 다.
REM    VirtualBox 가 제공하는 공식 드라이버 설치 스크립트를 실행한다.
REM    실패하면 재설치가 답이며, 그 방법도 마지막에 안내한다.
REM
REM  사용법: 마우스 우클릭 - "관리자 권한으로 실행"
REM =====================================================================

echo.
echo ============================================================
echo   VBoxDrv 커널 드라이버 복구
echo ============================================================
echo.

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo   [!] 관리자 권한이 필요합니다.
    echo       이 파일을 우클릭 - "관리자 권한으로 실행" 하세요.
    pause
    exit /b 1
)

REM ---------------- 설치 폴더 찾기 ----------------
set "VDIR="
if defined VBOX_MSI_INSTALL_PATH if exist "%VBOX_MSI_INSTALL_PATH%VBoxManage.exe" set "VDIR=%VBOX_MSI_INSTALL_PATH%"
if not defined VDIR (
    for /f "tokens=2,*" %%A in ('reg query "HKLM\SOFTWARE\Oracle\VirtualBox" /v InstallDir 2^>nul ^| findstr InstallDir') do (
        if exist "%%B\VBoxManage.exe" set "VDIR=%%B\"
    )
)
if not defined VDIR (
    for %%P in ("D:\Virtualbox\" "C:\Program Files\Oracle\VirtualBox\" "E:\Virtualbox\") do (
        if not defined VDIR if exist "%%~P\VBoxManage.exe" set "VDIR=%%~P"
    )
)
if not defined VDIR (
    echo   [!] VirtualBox 설치 폴더를 찾지 못했습니다.
    set /p VDIR="   폴더 경로 입력 (끝에 \ 포함): "
    set VDIR=!VDIR:"=!
)
echo   설치 폴더: %VDIR%
echo.

echo ------------------------------------------------------------
echo  [1] 현재 상태
echo ------------------------------------------------------------
sc query VBoxDrv >nul 2>&1
if errorlevel 1 (
    echo   VBoxDrv : 없음  ^<-- 이것이 원인입니다
) else (
    echo   VBoxDrv : 존재함
    sc query VBoxDrv | findstr /I "STATE"
)
echo.

echo ------------------------------------------------------------
echo  [2] 드라이버 파일 확인
echo ------------------------------------------------------------
if exist "%VDIR%drivers\vboxdrv\VBoxDrv.sys" (
    echo   설치본 드라이버 : 있음
) else (
    echo   설치본 드라이버 : 없음  ^<-- 설치가 손상됐습니다. 재설치 필요
)
if exist "%SystemRoot%\System32\drivers\VBoxDrv.sys" (
    echo   시스템 드라이버 : 있음
) else (
    echo   시스템 드라이버 : 없음
)
echo.

echo ------------------------------------------------------------
echo  [3] 공식 설치 스크립트 실행
echo ------------------------------------------------------------
if exist "%VDIR%drivers\vboxdrv\VBoxDrvInst.exe" (
    echo   VBoxDrvInst.exe 로 드라이버를 다시 등록합니다...
    pushd "%VDIR%drivers\vboxdrv"
    VBoxDrvInst.exe install
    popd
) else (
    echo   VBoxDrvInst.exe 가 없습니다.
    echo   INF 방식으로 시도합니다...
    if exist "%VDIR%drivers\vboxdrv\VBoxDrv.inf" (
        pnputil /add-driver "%VDIR%drivers\vboxdrv\VBoxDrv.inf" /install
    ) else (
        echo   [!] INF 도 없습니다 - 재설치가 필요합니다.
    )
)
echo.

echo ------------------------------------------------------------
echo  [4] 드라이버 시작
echo ------------------------------------------------------------
sc start VBoxDrv
echo.

echo ------------------------------------------------------------
echo  [5] 결과 확인
echo ------------------------------------------------------------
sc query VBoxDrv 2>nul | findstr /I "STATE"
if errorlevel 1 (
    echo.
    echo   ============================================
    echo    복구 실패 - 재설치가 필요합니다
    echo   ============================================
    echo.
    echo    [중요] VM 파일은 지워지지 않습니다.
    echo           D:\Virtualbox\VMS\testVM 은 그대로 남습니다.
    echo.
    echo    1^) 제어판 - 프로그램 제거 - Oracle VirtualBox 제거
    echo    2^) 재부팅
    echo    3^) C:\Windows\System32\drivers 에서
    echo       VBox 로 시작하는 .sys 파일이 남아 있으면 삭제
    echo    4^) VirtualBox 7.2.16 재설치 - 설치 중 나오는
    echo       "장치 소프트웨어를 설치하시겠습니까?" 에 반드시 [설치]
    echo    5^) 재부팅
    echo    6^) VirtualBox 실행 - 머신 - 추가 -
    echo       D:\Virtualbox\VMS\testVM\testVM.vbox 선택
    echo.
    echo    ※ 설치 파일은 반드시 우클릭 - "관리자 권한으로 실행"
    echo      일반 실행하면 드라이버 등록이 조용히 실패합니다.
    echo      ^(이번 문제의 원인일 가능성이 높습니다^)
    echo.
) else (
    echo.
    echo   ============================================
    echo    드라이버가 복구되었습니다
    echo   ============================================
    echo.
    echo    이제 VirtualBox 에서 VM 을 시작해 보세요.
    echo    안 되면 재부팅 후 다시 시도하세요.
    echo.
)

pause
