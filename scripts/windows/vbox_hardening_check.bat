@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion
REM =====================================================================
REM  VBoxHardening.log 에서 기동 실패 원인을 뽑는다.
REM
REM  ★ 왜 이 로그인가
REM    VBox.log 는 "VM 이 실제로 돌기 시작한 뒤" 부터 기록된다.
REM    지금처럼 시작하자마자 중단되면 VBox.log 는 갱신조차 되지 않는다
REM    (그래서 3시간 전 옛 로그가 그대로 남아 있었다).
REM
REM    Windows 의 VirtualBox 는 보안을 위해 VM 프로세스에 서명되지 않은
REM    DLL 이 주입되면 기동을 거부한다. 백신, 보안 소프트웨어, 화면 녹화,
REM    입력기(IME), 오버레이 프로그램이 흔한 원인이다.
REM    그 판정 과정은 VBoxHardening.log 에만 남는다.
REM
REM  사용법: 더블클릭 (관리자 권한 불필요)
REM =====================================================================

echo.
echo ============================================================
echo   VBoxHardening.log 분석 (기동 실패 원인)
echo ============================================================
echo.

REM ---- 로그 찾기 ----
set "LOG="
for %%P in (
    "%USERPROFILE%\VirtualBox VMs\testVM\Logs\VBoxHardening.log"
    "D:\Virtualbox\VMS\testVM\Logs\VBoxHardening.log"
    "D:\Virtualbox\VMs\testVM\Logs\VBoxHardening.log"
) do (
    if not defined LOG if exist %%P set "LOG=%%~P"
)

if not defined LOG (
    echo   기본 경로에 없습니다. 검색합니다... 잠시만요.
    for %%D in (C D E F) do (
        if not defined LOG (
            if exist "%%D:\" (
                for /f "delims=" %%F in ('dir /s /b "%%D:\VBoxHardening.log" 2^>nul') do (
                    if not defined LOG set "LOG=%%F"
                )
            )
        )
    )
)

if not defined LOG (
    echo   [!] VBoxHardening.log 를 찾지 못했습니다.
    echo       VirtualBox 관리자 - 로그 탭에 "VBoxHardening.log" 가 있습니다.
    echo       그 파일을 이 창에 끌어다 놓고 Enter 를 누르세요.
    set /p LOG="   경로: "
    set LOG=!LOG:"=!
)

if not exist "%LOG%" (
    echo   [!] 파일이 없습니다: %LOG%
    pause
    exit /b 1
)

echo   로그: %LOG%
for %%A in ("%LOG%") do echo   수정시각: %%~tA
echo.
echo   ^> 수정시각이 "방금" 이 아니면 이 로그도 옛것입니다.
echo     그럴 땐 VM 을 한 번 더 시작해 실패시킨 뒤 다시 실행하세요.
echo.

echo ------------------------------------------------------------
echo  [1] 오류 코드  ^<-- 핵심
echo ------------------------------------------------------------
findstr /C:"Error" /C:"error:" /C:"VERR_" /C:"rc=" "%LOG%" | findstr /V "rc=VINF_SUCCESS" | more +0
echo.

echo ------------------------------------------------------------
echo  [2] 차단된 DLL / 서명 문제  ^<-- 범인이 여기 있을 가능성 높음
echo ------------------------------------------------------------
findstr /I /C:"Not signed" /C:"not trusted" /C:"Denying" /C:"blocked" /C:"unwanted" /C:"suspicious" "%LOG%"
if errorlevel 1 echo   (해당 항목 없음)
echo.

echo ------------------------------------------------------------
echo  [3] 마지막 30줄
echo ------------------------------------------------------------
powershell -NoProfile -Command "Get-Content -LiteralPath '%LOG%' -Tail 30"
echo.

echo ============================================================
echo   위 내용을 복사해서 보내주세요
echo   (제목표시줄 우클릭 - 편집 - 모두 선택 - Enter)
echo ============================================================
echo.
pause
