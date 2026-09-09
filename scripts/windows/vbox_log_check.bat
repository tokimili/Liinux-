@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion
REM =====================================================================
REM  VBox.log 에서 실패 원인만 뽑아낸다.
REM
REM  로그는 수천 줄이라 눈으로 찾기 어렵다. 진짜 원인은 항상
REM  VERR_ / Error / NEM 같은 키워드에 있다.
REM
REM  사용법: 더블클릭 (관리자 권한 불필요)
REM =====================================================================

echo.
echo ============================================================
echo   VBox.log 실패 원인 추출
echo ============================================================
echo.

REM ---- 로그 위치 찾기 ----
set "LOG="
for %%P in (
    "%USERPROFILE%\VirtualBox VMs\testVM\Logs\VBox.log"
    "D:\Virtualbox\VMS\testVM\Logs\VBox.log"
    "D:\Virtualbox\VMs\testVM\Logs\VBox.log"
    "D:\Virtualbox\testVM\Logs\VBox.log"
    "E:\Virtualbox\VMS\testVM\Logs\VBox.log"
) do (
    if not defined LOG if exist %%P set "LOG=%%~P"
)

REM 그래도 없으면 드라이브별로 검색 (설치 위치가 C: 가 아닐 수 있다)
if not defined LOG (
    echo   기본 경로에서 찾지 못했습니다. 검색합니다... 잠시만요.
    for %%D in (C D E F) do (
        if not defined LOG (
            if exist "%%D:\" (
                for /f "delims=" %%F in ('dir /s /b "%%D:\VBox.log" 2^>nul') do (
                    if not defined LOG set "LOG=%%F"
                )
            )
        )
    )
)

if not defined LOG (
    echo.
    echo   [!] VBox.log 를 찾지 못했습니다.
    echo.
    echo   VirtualBox 관리자에서 로그 탭 - 마우스 우클릭 - "폴더 열기"
    echo   로 경로를 확인한 뒤, 그 폴더의 VBox.log 를
    echo   이 창에 끌어다 놓고 Enter 를 누르셔도 됩니다.
    echo.
    set /p LOG="경로 입력: "
)

if not exist "%LOG%" (
    echo   [!] 파일이 없습니다: %LOG%
    pause
    exit /b 1
)

echo   로그 파일: %LOG%
echo.

echo ------------------------------------------------------------
echo  [핵심] VERR_ 로 시작하는 오류  ^<-- 여기가 진짜 원인
echo ------------------------------------------------------------
findstr /C:"VERR_" "%LOG%"
if errorlevel 1 echo   (VERR_ 없음)
echo.

echo ------------------------------------------------------------
echo  [1] NEM 사용 여부  ^<-- 있으면 Hyper-V 가 아직 관여 중
echo ------------------------------------------------------------
findstr /C:"NEM:" "%LOG%" | findstr /V "Destroying"
if errorlevel 1 echo   (NEM 없음 - Hyper-V 문제는 해결된 것)
echo.

echo ------------------------------------------------------------
echo  [2] 실행 엔진 (HM = VT-x 정상 / NEM = Hyper-V 우회)
echo ------------------------------------------------------------
findstr /C:"HM: HMR3Init" /C:"Using VT-x" /C:"Using AMD-V" /C:"NEM: Snoop" /C:"fake" "%LOG%"
if errorlevel 1 echo   (해당 항목 없음)
echo.

echo ------------------------------------------------------------
echo  [3] Guru Meditation / 치명적 오류
echo ------------------------------------------------------------
findstr /C:"Guru" /C:"Fatal" /C:"AssertLogRel" "%LOG%"
if errorlevel 1 echo   (없음)
echo.

echo ------------------------------------------------------------
echo  [4] 마지막 40줄 (중단 직전 상황)
echo ------------------------------------------------------------
powershell -NoProfile -Command "Get-Content -LiteralPath '%LOG%' -Tail 40"
echo.

echo ============================================================
echo   위 내용을 그대로 복사해서 보내주세요
echo   (제목표시줄 우클릭 - 편집 - 모두 선택 - Enter)
echo ============================================================
echo.
pause
