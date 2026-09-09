@echo off
chcp 65001 >nul
REM =====================================================================
REM  VirtualBox E_FAIL (0x80004005) / "The VM session was aborted" 해결
REM
REM  원인: Windows 의 Hyper-V 계열 기능이 CPU 가상화를 먼저 점유해서
REM        VirtualBox 가 그것을 쓰지 못하는 상태.
REM        한 PC 에서 두 하이퍼바이저가 동시에 CPU 가상화를 쓸 수 없다.
REM
REM  사용법: 이 파일을 마우스 우클릭 → "관리자 권한으로 실행"
REM =====================================================================

echo.
echo ============================================================
echo   VirtualBox 시작 실패 (E_FAIL 0x80004005) 해결 스크립트
echo ============================================================
echo.

REM ---- 관리자 권한 확인 ----
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo [오류] 관리자 권한이 필요합니다.
    echo.
    echo   이 파일을 마우스 우클릭 - "관리자 권한으로 실행" 하세요.
    echo.
    pause
    exit /b 1
)
echo [확인] 관리자 권한 OK
echo.

REM ---- 현재 상태 진단 ----
echo ------------------------------------------------------------
echo  1. 현재 상태 확인
echo ------------------------------------------------------------
systeminfo | findstr /C:"Hyper-V" /C:"하이퍼바이저"
echo.
echo   위에 "하이퍼바이저가 검색되었습니다" 가 보이면 원인이 맞습니다.
echo.

REM ---- 조치 ----
echo ------------------------------------------------------------
echo  2. 하이퍼바이저 자동 시작 끄기
echo ------------------------------------------------------------
bcdedit /set hypervisorlaunchtype off
echo.

echo ------------------------------------------------------------
echo  3. VBS (가상화 기반 보안) 끄기
echo     ★ hypervisorlaunchtype off 만으로 안 되는 진짜 원인이 보통 여기.
echo       VBS 는 별도 경로로 하이퍼바이저를 올립니다.
echo ------------------------------------------------------------
bcdedit /set vsmlaunchtype off
reg add "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard" /v EnableVirtualizationBasedSecurity /t REG_DWORD /d 0 /f
reg add "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard" /v RequirePlatformSecurityFeatures /t REG_DWORD /d 0 /f
reg add "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" /v Enabled /t REG_DWORD /d 0 /f
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Lsa" /v LsaCfgFlags /t REG_DWORD /d 0 /f
echo.

echo ------------------------------------------------------------
echo  4. Hyper-V 관련 기능 끄기
echo     ("기능을 찾을 수 없습니다" 는 원래 꺼져 있다는 뜻 - 무시)
echo ------------------------------------------------------------
DISM /Online /Disable-Feature:Microsoft-Hyper-V-All /NoRestart
DISM /Online /Disable-Feature:HypervisorPlatform /NoRestart
DISM /Online /Disable-Feature:VirtualMachinePlatform /NoRestart
DISM /Online /Disable-Feature:Containers-DisposableClientVM /NoRestart
echo.

echo ------------------------------------------------------------
echo  5. 적용 결과 확인
echo ------------------------------------------------------------
bcdedit | findstr /I "hypervisorlaunchtype vsmlaunchtype"
echo.
echo   ^> 둘 다 Off 로 보이면 정상입니다.
echo.

echo ============================================================
echo   자동 조치 완료
echo ============================================================
echo.
echo  [수동으로 하나 더 해주세요]
echo.
echo    Windows 보안 - 장치 보안 - 코어 격리 세부 정보
echo      - "메모리 무결성" 을 [끔] 으로
echo.
echo    ※ 회색으로 비활성화돼 눌리지 않으면, 위 레지스트리 조치가
echo       재부팅 후 대신 적용됩니다.
echo.
echo  [그다음 반드시 재부팅]
echo.
echo    재부팅해야 적용됩니다.
echo    재부팅 후 VirtualBox 에서 VM 을 다시 시작하세요.
echo.
echo  [그래도 안 되면]
echo    diag_virtualbox.bat 를 관리자 권한으로 실행해서
echo    결과를 그대로 보내주세요. 무엇이 남았는지 알 수 있습니다.
echo.
echo  [참고] WSL2 / Docker Desktop 을 쓰신다면 그것들이 Hyper-V 를
echo         다시 켭니다. VirtualBox 와 동시 사용은 어렵습니다.
echo         WSL 은 1 로 낮추면 공존 가능:  wsl --set-default-version 1
echo.
pause
