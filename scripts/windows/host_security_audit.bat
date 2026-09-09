@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion
REM =====================================================================
REM  호스트(Windows) 보안 상태 점검 — 읽기 전용
REM
REM  ★ 왜 필요한가
REM    VirtualBox 를 쓰기 위해 Hyper-V / VBS / 메모리 무결성을 껐다.
REM    이것들은 Windows 의 실제 보안 기능이므로, 무엇이 꺼졌고
REM    무엇이 그대로인지 정확히 알고 있어야 한다.
REM    "껐다는 사실을 잊는 것" 이 가장 위험하다.
REM
REM  ★ 이 스크립트는 아무것도 바꾸지 않는다. 조회만 한다.
REM
REM  사용법: 마우스 우클릭 - "관리자 권한으로 실행"
REM =====================================================================

echo.
echo ============================================================
echo   Windows 호스트 보안 점검 (읽기 전용)
echo ============================================================
echo.

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo   [!] 관리자 권한 필요. 우클릭 - 관리자 권한으로 실행
    pause
    exit /b 1
)

echo ------------------------------------------------------------
echo  [A] 이번 작업으로 "끈" 기능들  ^<-- 트레이드오프 확인
echo ------------------------------------------------------------
echo.
echo   -- 하이퍼바이저 / VBS --
bcdedit | findstr /I "hypervisorlaunchtype vsmlaunchtype"
powershell -NoProfile -Command "try{$d=Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard -EA Stop; Write-Host ('   VBS 상태            : ' + $d.VirtualizationBasedSecurityStatus + '  (0=꺼짐 2=실행중)'); Write-Host ('   메모리무결성(HVCI)  : ' + $(if($d.SecurityServicesRunning -contains 2){'실행중'}else{'꺼짐'}))}catch{Write-Host '   조회 불가'}"
echo.
echo   ^> 이 항목들은 VirtualBox 를 쓰기 위해 의도적으로 끈 것입니다.
echo     끔으로써 잃는 것: 커널 수준 코드 위변조 방지(HVCI),
echo     자격증명 격리(Credential Guard), WSL2/Docker Desktop 사용.
echo     ^(VirtualBox 를 그만 쓸 때 fix_virtualbox 의 반대로 되돌리면 됩니다^)
echo.

echo ------------------------------------------------------------
echo  [B] 그대로 살아있는 핵심 방어  ^<-- 여기가 중요
echo ------------------------------------------------------------
echo.
echo   -- Defender 실시간 보호 --
powershell -NoProfile -Command "try{$m=Get-MpComputerStatus -EA Stop; Write-Host ('   실시간 보호        : ' + $m.RealTimeProtectionEnabled); Write-Host ('   맬웨어 정의 버전   : ' + $m.AntivirusSignatureVersion); Write-Host ('   정의 최종 갱신     : ' + $m.AntivirusSignatureLastUpdated); Write-Host ('   변조 방지          : ' + $m.IsTamperProtected); Write-Host ('   클라우드 보호      : ' + $m.MAPSReporting)}catch{Write-Host '   Defender 조회 실패 (타사 백신 사용 중일 수 있음)'}"
echo.
echo   -- 설치된 백신 제품 --
powershell -NoProfile -Command "try{Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct -EA Stop | ForEach-Object { '   ' + $_.displayName }}catch{Write-Host '   조회 불가'}"
echo.

echo   -- 방화벽 (프로필별) --
netsh advfirewall show allprofiles state
echo.

echo   -- 디스크 암호화 (BitLocker) --
powershell -NoProfile -Command "try{Get-BitLockerVolume -EA Stop | ForEach-Object { '   ' + $_.MountPoint + '  ' + $_.VolumeStatus + '  (' + $_.ProtectionStatus + ')' }}catch{Write-Host '   조회 불가 (Home 에디션이면 미지원)'}"
echo.

echo   -- Windows 업데이트 최근 설치 --
powershell -NoProfile -Command "try{Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 3 | ForEach-Object { '   ' + $_.HotFixID + '  ' + $_.InstalledOn }}catch{Write-Host '   조회 불가'}"
echo.

echo   -- UAC (사용자 계정 컨트롤) --
for /f "tokens=3" %%A in ('reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v EnableLUA 2^>nul ^| findstr EnableLUA') do (
    if "%%A"=="0x1" (echo    UAC : 켜짐) else (echo    UAC : 꺼짐  ^<-- 위험)
)
echo.

echo   -- Secure Boot --
powershell -NoProfile -Command "try{'   Secure Boot : ' + (Confirm-SecureBootUEFI -EA Stop)}catch{Write-Host '   Secure Boot : 조회 불가 또는 레거시 부팅'}"
echo.

echo   -- 드라이버 서명 강제 (꺼져 있으면 위험) --
bcdedit | findstr /I "testsigning nointegritychecks"
if errorlevel 1 echo    testsigning/nointegritychecks : 설정 없음 ^(정상 - 서명 강제 유지^)
echo.

echo ------------------------------------------------------------
echo  [C] 외부 노출면 점검  ^<-- VM 프로젝트와 직접 관련
echo ------------------------------------------------------------
echo.
echo   -- 외부에서 접근 가능한 리스닝 포트 (0.0.0.0 바인딩) --
netstat -ano ^| findstr /R "LISTENING" | findstr "0.0.0.0:" | findstr /V "127.0.0.1"
echo.
echo   ^> 여기에 8080 이 보이면 안 됩니다.
echo     이 프로젝트는 nginx 를 127.0.0.1:8080 에만 묶었고,
echo     외부 공개는 Cloudflare Tunnel^(아웃바운드^)로만 합니다.
echo     즉 공유기에 열어둔 포트가 0개여야 정상입니다.
echo.
echo   -- 2222 (VM SSH 포워딩) 확인 --
netstat -ano | findstr ":2222"
echo.
echo   ^> 127.0.0.1:2222 로만 보여야 합니다.
echo     0.0.0.0:2222 이면 같은 공유기의 다른 기기에서도
echo     VM 의 SSH 에 접근할 수 있다는 뜻입니다.
echo.

echo   -- 원격 데스크톱 (RDP) 활성 여부 --
for /f "tokens=3" %%A in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections 2^>nul ^| findstr fDeny') do (
    if "%%A"=="0x0" (echo    RDP : 켜짐  ^<-- 쓰지 않으면 끄는 편이 안전) else (echo    RDP : 꺼짐  ^(안전^))
)
echo.

echo ============================================================
echo   점검 완료 - 위 내용을 복사해서 보내주세요
echo   (제목표시줄 우클릭 - 편집 - 모두 선택 - Enter)
echo ============================================================
echo.
pause
