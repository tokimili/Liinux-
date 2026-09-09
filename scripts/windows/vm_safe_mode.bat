@echo off
chcp 65001 >nul
REM =====================================================================
REM  VM 설정을 "가장 안전한 조합" 으로 낮춘다.
REM
REM  Hyper-V 를 껐는데도 VM 이 시작 직후 중단되는 경우,
REM  가속 옵션(중첩 페이징 / KVM 반가상화 / 3D 등)이 원인인 경우가 많다.
REM  성능은 조금 떨어지지만 일단 "뜨게" 만드는 것이 목적이다.
REM
REM  ★ 되돌릴 수 있도록 현재 설정을 먼저 보여준다.
REM  사용법: 더블클릭 (관리자 권한 불필요, VM 이 꺼져 있어야 함)
REM =====================================================================

setlocal enabledelayedexpansion
set "VM=testVM"

echo.
echo ============================================================
echo   VM 안전 모드 설정  (대상: %VM%)
echo ============================================================
echo.

REM ------------------------------------------------------------------
REM VBoxManage.exe 위치 찾기
REM   설치 경로는 C: 가 아닐 수 있다 (실제로 D:\Virtualbox 사례가 있었다).
REM   1) 환경변수  2) 레지스트리  3) 흔한 경로  4) 드라이브 전체 검색
REM ------------------------------------------------------------------
set "VBOX="

REM 1) VirtualBox 가 설치 시 등록하는 환경변수
if defined VBOX_MSI_INSTALL_PATH (
    if exist "%VBOX_MSI_INSTALL_PATH%VBoxManage.exe" set "VBOX=%VBOX_MSI_INSTALL_PATH%VBoxManage.exe"
)
if not defined VBOX if defined VBOX_INSTALL_PATH (
    if exist "%VBOX_INSTALL_PATH%VBoxManage.exe" set "VBOX=%VBOX_INSTALL_PATH%VBoxManage.exe"
)

REM 2) 레지스트리에서 설치 경로 조회
if not defined VBOX (
    for /f "tokens=2,*" %%A in ('reg query "HKLM\SOFTWARE\Oracle\VirtualBox" /v InstallDir 2^>nul ^| findstr InstallDir') do (
        if exist "%%B\VBoxManage.exe" set "VBOX=%%B\VBoxManage.exe"
    )
)

REM 3) 흔한 설치 경로
if not defined VBOX (
    for %%P in (
        "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
        "D:\Virtualbox\VBoxManage.exe"
        "D:\VirtualBox\VBoxManage.exe"
        "D:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
        "E:\Virtualbox\VBoxManage.exe"
        "E:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
    ) do (
        if not defined VBOX if exist %%P set "VBOX=%%~P"
    )
)

REM 4) 그래도 없으면 각 드라이브를 검색
if not defined VBOX (
    echo   흔한 경로에 없습니다. 드라이브를 검색합니다... 잠시만요.
    for %%D in (C D E F G) do (
        if not defined VBOX (
            if exist "%%D:\" (
                for /f "delims=" %%F in ('dir /s /b "%%D:\VBoxManage.exe" 2^>nul') do (
                    if not defined VBOX set "VBOX=%%F"
                )
            )
        )
    )
)

if not defined VBOX (
    echo.
    echo   [!] VBoxManage.exe 를 찾지 못했습니다.
    echo.
    echo   VirtualBox 설치 폴더에서 VBoxManage.exe 를 찾아
    echo   이 창에 끌어다 놓고 Enter 를 누르세요.
    echo.
    set /p VBOX="경로: "
    REM 드래그하면 따옴표가 붙는데, 그대로 두면 경로가 깨진다
    set VBOX=!VBOX:"=!
)

if not exist "%VBOX%" (
    echo   [!] 파일이 없습니다: %VBOX%
    pause
    exit /b 1
)

echo   VBoxManage: %VBOX%
echo.

REM ------------------------------------------------------------------
REM VM 이름 확인 — 등록된 목록에 없으면 사용자에게 고르게 한다
REM ------------------------------------------------------------------
"%VBOX%" showvminfo "%VM%" >nul 2>&1
if errorlevel 1 (
    echo   [!] "%VM%" 이라는 VM 을 찾지 못했습니다.
    echo.
    echo   등록된 VM 목록:
    "%VBOX%" list vms
    echo.
    set /p VM="   위 목록에서 VM 이름을 따옴표 없이 입력하세요: "
    set VM=!VM:"=!
    "%VBOX%" showvminfo "!VM!" >nul 2>&1
    if errorlevel 1 (
        echo   [!] 여전히 찾을 수 없습니다: !VM!
        pause
        exit /b 1
    )
    set "VM=!VM!"
)

REM 실행 중이면 설정을 바꿀 수 없다
REM ★ 여기부터는 %VM% 이 아니라 !VM! 을 쓴다.
REM   위 블록에서 이름을 새로 입력받았을 수 있는데, %VM% 는 블록 진입
REM   시점의 옛 값으로 고정되어 엉뚱한 VM 을 건드리게 된다.
for /f "tokens=2 delims==" %%S in ('"%VBOX%" showvminfo "!VM!" --machinereadable ^| findstr /B "VMState="') do set "STATE=%%~S"
if /I "!STATE!"=="running" (
    echo   [!] VM 이 실행 중입니다. 먼저 종료한 뒤 다시 실행하세요.
    pause
    exit /b 1
)
if /I "!STATE!"=="paused" (
    echo   [!] VM 이 일시정지 상태입니다. 완전히 종료한 뒤 다시 실행하세요.
    pause
    exit /b 1
)
if /I "!STATE!"=="saved" (
    echo   [!] 저장된 상태^(saved^)가 있습니다.
    echo       이 상태에서는 설정 변경이 거부되거나, 변경해도
    echo       옛 실행 환경으로 복원되어 다시 실패합니다.
    echo.
    echo       저장 상태를 버리고 진행할까요? ^(VM 안의 미저장 작업은 사라집니다^)
    set /p DISCARD="       버리려면 y 입력: "
    if /I "!DISCARD!"=="y" (
        "%VBOX%" discardstate "!VM!"
        echo       저장 상태를 버렸습니다.
    ) else (
        echo       중단합니다.
        pause
        exit /b 1
    )
)
echo   VM 상태: !STATE!
echo.

echo ------------------------------------------------------------
echo  현재 설정 (되돌릴 때 참고하세요)
echo ------------------------------------------------------------
"%VBOX%" showvminfo "!VM!" --machinereadable | findstr /I "nestedpaging paravirtprovider hwvirtex accelerate3d memory= cpus= vram"
echo.

echo ------------------------------------------------------------
echo  안전한 값으로 변경합니다
echo ------------------------------------------------------------

echo   - 반가상화 인터페이스: KVM -^> 없음(none)
"%VBOX%" modifyvm "!VM!" --paravirt-provider none

echo   - 중첩 페이징: 끔
"%VBOX%" modifyvm "!VM!" --nested-paging off

echo   - 3D 가속: 끔
"%VBOX%" modifyvm "!VM!" --accelerate-3d off

echo   - CPU 1개로 축소
"%VBOX%" modifyvm "!VM!" --cpus 1

echo   - 메모리 2048MB 로 축소
"%VBOX%" modifyvm "!VM!" --memory 2048

echo   - 오디오 끔 (드라이버 충돌 회피)
"%VBOX%" modifyvm "!VM!" --audio-enabled off

echo.
echo ------------------------------------------------------------
echo  변경 후 설정
echo ------------------------------------------------------------
"%VBOX%" showvminfo "!VM!" --machinereadable | findstr /I "nestedpaging paravirtprovider hwvirtex accelerate3d memory= cpus="
echo.

echo ============================================================
echo   완료 - VirtualBox 에서 VM 을 다시 시작해 보세요
echo ============================================================
echo.
echo  [뜨면]  원인은 위 가속 옵션 중 하나입니다.
echo          하나씩 되돌리며 범인을 찾을 수 있습니다.
echo          (급하지 않으면 이 상태로 쓰셔도 무방합니다)
echo.
echo  [그래도 안 뜨면]
echo          vbox_log_check.bat 를 실행해서 결과를 보내주세요.
echo.
echo  [되돌리기] 원래대로 (참고용)
echo      "%VBOX%" modifyvm "!VM!" --paravirt-provider kvm
echo      "%VBOX%" modifyvm "!VM!" --nested-paging on
echo      "%VBOX%" modifyvm "!VM!" --cpus 2
echo      "%VBOX%" modifyvm "!VM!" --memory 4080
echo.
pause
