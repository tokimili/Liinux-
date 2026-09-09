@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion
REM =====================================================================
REM  VirtualBox 때문에 껐던 Windows 보안 기능을 원상 복구한다.
REM
REM  ★ 언제 쓰는가
REM    - VM 실습이 끝나서 VirtualBox 를 더 이상 쓰지 않을 때
REM    - WSL2 / Docker Desktop 을 다시 써야 할 때
REM    - 보안 상태를 원래대로 돌려놓고 싶을 때
REM
REM  ★ 실행하면 VirtualBox 는 다시 작동하지 않는다
REM    Hyper-V 가 CPU 가상화를 도로 가져가기 때문이다.
REM    VM 을 계속 쓸 거라면 이 스크립트를 실행하지 말 것.
REM
REM  사용법: 마우스 우클릭 - "관리자 권한으로 실행"
REM =====================================================================

echo.
echo ============================================================
echo   Windows 보안 기능 원상 복구
echo ============================================================
echo.

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo   [!] 관리자 권한이 필요합니다. 우클릭 - 관리자 권한으로 실행
    pause
    exit /b 1
)

echo   [경고] 이 작업을 하면 VirtualBox 가 작동하지 않습니다.
echo          Hyper-V 가 CPU 가상화를 다시 가져가기 때문입니다.
echo.
echo          VM 을 계속 쓰실 거라면 지금 창을 닫으세요.
echo.
set /p GO="   그래도 복구하시겠습니까? (y 입력): "
if /I not "!GO!"=="y" (
    echo   취소했습니다.
    pause
    exit /b 0
)
echo.

echo ------------------------------------------------------------
echo  1. 하이퍼바이저 자동 시작 복구
echo ------------------------------------------------------------
bcdedit /set hypervisorlaunchtype auto
bcdedit /set vsmlaunchtype auto
echo.

echo ------------------------------------------------------------
echo  2. VBS / 메모리 무결성 레지스트리 복구
echo ------------------------------------------------------------
reg add "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard" /v EnableVirtualizationBasedSecurity /t REG_DWORD /d 1 /f
reg add "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" /v Enabled /t REG_DWORD /d 1 /f
echo.
echo   ※ Credential Guard(LsaCfgFlags)는 기본값이 환경마다 달라
echo      건드리지 않습니다. 필요하면 수동으로 설정하세요.
echo.

echo ------------------------------------------------------------
echo  3. Hyper-V 기능 복구
echo ------------------------------------------------------------
echo   ^(필요한 것만 켜세요. 전부 켤 필요는 없습니다^)
echo.
set /p HV="   Hyper-V 전체를 켤까요? (y/n): "
if /I "!HV!"=="y" DISM /Online /Enable-Feature /FeatureName:Microsoft-Hyper-V-All /All /NoRestart
set /p WS="   WSL2 용 VirtualMachinePlatform 을 켤까요? (y/n): "
if /I "!WS!"=="y" DISM /Online /Enable-Feature /FeatureName:VirtualMachinePlatform /All /NoRestart
echo.

echo ------------------------------------------------------------
echo  4. 확인
echo ------------------------------------------------------------
bcdedit | findstr /I "hypervisorlaunchtype vsmlaunchtype"
echo.

echo ============================================================
echo   복구 완료 - 재부팅해야 적용됩니다
echo ============================================================
echo.
echo   재부팅 후 "메모리 무결성" 이 켜졌는지 확인:
echo     Windows 보안 - 장치 보안 - 코어 격리 세부 정보
echo.
echo   ※ 메모리 무결성이 "호환되지 않는 드라이버" 때문에 안 켜지면
echo      VirtualBox 를 완전히 제거한 뒤 다시 시도하세요.
echo.
pause
