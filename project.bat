@echo off
rem Sandbox helper: builds zengy, installs the plugins listed in projects\<project>\plugins.txt and runs
rem the project headless.
rem
rem   project.bat <project> [ticks] [nobuild]
rem
rem   <project>  folder under projects\ that contains game.toml (e.g. jolt-test)
rem   ticks      headless fixed-update ticks (default 60)
rem   nobuild    skip "zig build -Doptimize=ReleaseSafe" (use the last build)
rem
rem plugins.txt: one plugin spec per line, as accepted by `zengy add` (blank lines and # comments ignored).
rem The CLI builds plugins in ReleaseSafe, so zengy/zengy-runtime are built in ReleaseSafe too
rem (mixed optimize modes break the plugin ABI).
setlocal

for %%I in ("%~dp0.") do set "ROOT=%%~fI"
set "BIN=%ROOT%\zig-out\bin"
set "NAME=%~1"
set "TICKS=%~2"
if "%TICKS%"=="" set "TICKS=60"

if "%NAME%"=="" goto usage
set "PROJ=%ROOT%\projects\%NAME%"
if not exist "%PROJ%\game.toml" (
    echo [test] '%NAME%' is not a project ^(no game.toml in %PROJ%^).
    goto usage
)

if /i not "%~3"=="nobuild" (
    echo [test] zig build -Doptimize=ReleaseSafe
    pushd "%ROOT%"
    zig build -Doptimize=ReleaseSafe
    if errorlevel 1 (
        popd
        echo [test] build failed. Close any running zengy example ^(e.g. visual-ui.exe^) and retry.
        exit /b 1
    )
    popd
)

pushd "%PROJ%"
if exist plugins.txt (
    for /f "usebackq eol=# tokens=* delims=" %%P in ("plugins.txt") do (
        echo [test] zengy add %%P
        "%BIN%\zengy.exe" add "--fork=%ROOT%" "%%P"
        if errorlevel 1 (
            echo [test] FAILED: zengy add %%P
            popd
            exit /b 1
        )
    )
)

echo [test] zengy-runtime --headless --ticks %TICKS%
"%BIN%\zengy-runtime.exe" --headless --ticks %TICKS%
if errorlevel 1 (
    popd
    echo [test] FAILED: runtime exited with a non-zero code
    exit /b 1
)
popd
echo [test] OK
exit /b 0

:usage
echo Usage: project.bat ^<project^> [ticks] [nobuild]
echo Projects:
for /d %%D in ("%ROOT%\projects\*") do if exist "%%D\game.toml" echo   %%~nxD
exit /b 1
