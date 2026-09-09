@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion
REM =====================================================================
REM  드라이버 파일 삭제 + 재부팅 이후의 현재 상태 점검
REM
REM  목적: 무엇이 남아 있고 무엇이 사라졌는지 확인해서
REM        (1) VM 파일이 무사한지  ← 가장 중요
REM        (2) 재설치 전에 청소가 더 필요한지
REM        를 판단한다.
REM
REM  사용법: 마우스 우클릭 - "관리자 권한으로 실행"
REM =====================================================================

echo.
echo ============================================================
echo   삭제 후 현재 상태 점검
echo ============================================================
echo.

echo ------------------------------------------------------------
echo  [1] VM 파일 (가장 중요 - 이것만 있으면 다 복구됩니다)
echo ------------------------------------------------------------
set "VMDIR="
for %%P in (
    "D:\Virtualbox\VMS\testVM"
    "D:\Virtualbox\VMs\testVM"
    "%USERPROFILE%\VirtualBox VMs\testVM"
) do if not defined VMDIR if exist "%%~P" set "VMDIR=%%~P"

if not defined VMDIR (
    echo   [!] 기본 경로에서 testVM 폴더를 못 찾았습니다. 검색합니다...
    for %%D in (C D E F) do (
        if not defined VMDIR (
            for /f "delims=" %%F in ('dir /s /b /ad "%%D:\testVM" 2^>nul') do (
                if not defined VMDIR set "VMDIR=%%F"
            )
        )
    )
)

if defined VMDIR (
    echo   폴더: !VMDIR!
    echo.
    if exist "!VMDIR!\testVM.vbox" (
        echo   [O] testVM.vbox        설정 파일 있음
    ) else (
        echo   [X] testVM.vbox        없음
    )
    for %%F in ("!VMDIR!\*.vdi" "!VMDIR!\*.vmdk") do (
        echo   [O] %%~nxF   크기: %%~zF bytes
    )
    echo.
    echo   ^> .vdi 파일이 있으면 VM 내용물^(코드/DB/러너^)은 모두 무사합니다.
) else (
    echo   [!] testVM 폴더를 찾지 못했습니다.
    echo       탐색기에서 직접 확인해 주세요: D:\Virtualbox\VMS
)
echo.

echo ------------------------------------------------------------
echo  [2] 남아 있는 드라이버 파일
echo ------------------------------------------------------------
dir /b "%SystemRoot%\System32\drivers\VBox*.sys" 2>nul
if errorlevel 1 (
    echo   없음 ^(전부 삭제됨 - 재설치 준비 완료 상태^)
) else (
    echo.
    echo   ^> 위 파일들이 아직 남아 있습니다.
    echo     재설치 전에 지우는 것이 좋습니다.
)
echo.

echo ------------------------------------------------------------
echo  [3] 서비스 등록 상태
echo ------------------------------------------------------------
for %%S in (VBoxSup VBoxDrv VBoxNetLwf VBoxNetAdp VBoxUSBMon) do (
    sc query %%S >nul 2>&1
    if errorlevel 1 (
        echo   %%S : 없음
    ) else (
        for /f "tokens=3" %%T in ('sc query %%S ^| findstr /I "STATE"') do echo   %%S : %%T
    )
)
echo.
echo   ^> 전부 "없음" 이면 깨끗한 상태입니다. 바로 재설치하세요.
echo   ^> 남아 있으면 아래로 제거할 수 있습니다:
echo       sc delete VBoxSup
echo.

echo ------------------------------------------------------------
echo  [4] VirtualBox 프로그램 설치 여부
echo ------------------------------------------------------------
set "VDIR="
for /f "tokens=2,*" %%A in ('reg query "HKLM\SOFTWARE\Oracle\VirtualBox" /v InstallDir 2^>nul ^| findstr InstallDir') do set "VDIR=%%B"
if defined VDIR (
    echo   레지스트리 설치 경로: !VDIR!
    if exist "!VDIR!\VBoxManage.exe" (
        echo   [O] VBoxManage.exe 있음 - 프로그램은 아직 설치돼 있습니다
        "!VDIR!\VBoxManage.exe" --version 2>nul
    ) else (
        echo   [X] 실행 파일 없음 - 사실상 제거된 상태
    )
) else (
    echo   레지스트리에 설치 정보 없음
)
echo.

echo ============================================================
echo   다음 할 일
echo ============================================================
echo.
echo   1^) 제어판 - 프로그램 제거 에 "Oracle VirtualBox" 가 남아 있으면
echo      먼저 제거하고 재부팅하세요.
echo   2^) 위 [2] 에 파일이 남아 있으면 삭제하세요.
echo   3^) VirtualBox 를 관리자 권한으로 재설치하세요.
echo      ^(설치 파일 우클릭 - 관리자 권한으로 실행^)
echo   4^) 설치 중 [장치 소프트웨어를 설치하시겠습니까] 창에서 [설치]
echo   5^) 재부팅 후 이 스크립트를 다시 실행해 VBoxSup 이
echo      RUNNING 또는 STOPPED 로 등록됐는지 확인하세요.
echo.
pause
