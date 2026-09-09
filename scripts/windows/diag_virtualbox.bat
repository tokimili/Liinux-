@echo off
chcp 65001 >nul
REM =====================================================================
REM  VirtualBox 가 여전히 Hyper-V 에 밀리는 원인 진단
REM
REM  VBox.log 에 "NEM:" 이 보이면 VirtualBox 가 VT-x 를 직접 쓰지 못하고
REM  Hyper-V API 를 통해 우회 실행됐다는 뜻이다.
REM  hypervisorlaunchtype 을 off 로 했는데도 이런 경우가 있는데,
REM  VBS(가상화 기반 보안)가 별도 경로로 하이퍼바이저를 올리기 때문이다.
REM
REM  이 스크립트는 "무엇이 아직 켜져 있는지" 만 보여준다. 아무것도 바꾸지 않는다.
REM  사용법: 마우스 우클릭 → "관리자 권한으로 실행"
REM =====================================================================

echo.
echo ============================================================
echo   VirtualBox / Hyper-V 충돌 진단 (읽기 전용)
echo ============================================================
echo.

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo [오류] 관리자 권한이 필요합니다.
    echo   이 파일을 우클릭 - "관리자 권한으로 실행" 하세요.
    pause
    exit /b 1
)

echo ------------------------------------------------------------
echo  [1] 하이퍼바이저가 실제로 돌고 있는가
echo ------------------------------------------------------------
systeminfo | findstr /C:"하이퍼바이저" /C:"Hyper-V"
echo.
echo   ^> "하이퍼바이저가 검색되었습니다" 가 보이면 아직 살아있는 것.
echo.

echo ------------------------------------------------------------
echo  [2] 부팅 설정 (hypervisorlaunchtype / vsmlaunchtype)
echo ------------------------------------------------------------
bcdedit | findstr /I "hypervisorlaunchtype vsmlaunchtype"
echo.
echo   ^> 둘 다 Off 여야 합니다.
echo   ^> vsmlaunchtype 줄이 아예 없으면 설정된 적 없다는 뜻입니다.
echo.

echo ------------------------------------------------------------
echo  [3] VBS (가상화 기반 보안) 레지스트리
echo ------------------------------------------------------------
reg query "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard" /v EnableVirtualizationBasedSecurity 2>nul
reg query "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" /v Enabled 2>nul
reg query "HKLM\SYSTEM\CurrentControlSet\Control\Lsa" /v LsaCfgFlags 2>nul
echo.
echo   ^> 값이 0 이어야 합니다. 1 이면 그것이 원인입니다.
echo   ^> "찾을 수 없습니다" 는 설정 안 됨 = 대체로 괜찮습니다.
echo.

echo ------------------------------------------------------------
echo  [4] Device Guard 실행 상태 (가장 확실한 지표)
echo ------------------------------------------------------------
powershell -NoProfile -Command "try{$d=Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard -ErrorAction Stop; Write-Host ('  VBS 상태          : ' + $d.VirtualizationBasedSecurityStatus + '   (0=꺼짐, 2=실행중)'); Write-Host ('  실행중인 보안기능 : ' + ($d.SecurityServicesRunning -join ', ') + '   (0=없음)')}catch{Write-Host '  조회 실패 (Home 에디션이면 정상)'}"
echo.

echo ------------------------------------------------------------
echo  [5] Hyper-V 를 다시 켜는 기능들
echo ------------------------------------------------------------
powershell -NoProfile -Command "Get-WindowsOptionalFeature -Online | Where-Object {$_.FeatureName -match 'Hyper-V|HypervisorPlatform|VirtualMachinePlatform|Containers|WindowsSandbox'} | ForEach-Object { '{0,-42} {1}' -f $_.FeatureName, $_.State }"
echo.
echo   ^> Enabled 가 하나라도 있으면 그것이 Hyper-V 를 되살립니다.
echo.

echo ------------------------------------------------------------
echo  [6] WSL 버전
echo ------------------------------------------------------------
wsl --status 2>nul
if %errorLevel% neq 0 echo   WSL 미설치 (좋습니다)
echo.
echo   ^> "기본 버전: 2" 이면 WSL2 가 Hyper-V 를 상시 사용합니다.
echo.

echo ------------------------------------------------------------
echo  [7] 서드파티 가상화 소프트웨어
echo ------------------------------------------------------------
tasklist | findstr /I "vmware vmnat vmnetdhcp docker com.docker vmms vmcompute" 2>nul
if %errorLevel% neq 0 echo   해당 프로세스 없음 (좋습니다)
echo.

echo ============================================================
echo   진단 완료 - 위 내용을 그대로 복사해서 보내주세요
echo ============================================================
echo.
echo  [복사 방법]
echo    이 창 제목표시줄 우클릭 - 편집 - 모두 선택 - Enter
echo.
pause
