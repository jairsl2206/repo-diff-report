@echo off
rem ============================================================
rem  release.bat - Compila y publica release en GitHub
rem  Uso:   release.bat 1.3.1
rem  Sin argumentos: usa el ultimo tag git + 1 patch
rem  Requisitos: gh CLI (winget install GitHub.cli) o token
rem ============================================================
cd /d "%~dp0"
setlocal enabledelayedexpansion

rem --- Version ---
set "VER=%~1"
if not "%VER%"=="" goto :have_ver

rem Intentar deducir del ultimo tag
for /f "delims=" %%i in ('git tag --sort=-v:refname 2^>nul') do (
    set "TAG=%%i"
    goto :parse_tag
)
echo ERROR: No hay tags en el repo. Especifica version: release.bat 1.3.0
pause
exit /b 1

:parse_tag
set "VER=!TAG:v=!"
for /f "tokens=1-3 delims=." %%a in ("!VER!") do (
    set "MAJ=%%a" & set "MIN=%%b" & set /a "PAT=%%c+1"
)
set "VER=!MAJ!.!MIN!.!PAT!"
echo Version deducida del tag !TAG!: v!VER!
echo Si no es correcta, usa: release.bat X.Y.Z

:have_ver
echo.
echo === v%VER%: Compilando ===
call "%~dp0build.bat"
if errorlevel 1 (
    echo ERROR: Fallo la compilacion.
    pause
    exit /b 1
)

set "EXE=%~dp0ReporteCambios.exe"
if not exist "%EXE%" (
    echo ERROR: No se encontro %EXE%
    pause
    exit /b 1
)

rem --- SHA256 ---
for /f "delims=" %%h in ('powershell -NoProfile -Command "(Get-FileHash -LiteralPath '%EXE%' -Algorithm SHA256).Hash"') do set "SHA=%%h"
echo SHA256: %SHA%

rem --- ZIP ---
set "ZIP=%~dp0ReporteCambios_v%VER%.zip"
if exist "%ZIP%" del "%ZIP%"
set "ZIPLIST="
if exist "%~dp0logo-napse-totvs.png" set "ZIPLIST=%ZIPLIST%,'%~dp0logo-napse-totvs.png'"
if exist "%~dp0ReporteCambiosSVN.ico"  set "ZIPLIST=%ZIPLIST%,'%~dp0ReporteCambiosSVN.ico'"
if exist "%~dp0README.md"              set "ZIPLIST=%ZIPLIST%,'%~dp0README.md'"
powershell -NoProfile -Command "Compress-Archive -LiteralPath '%EXE%'%ZIPLIST% -DestinationPath '%ZIP%' -Force"
if errorlevel 1 (
    echo ADVERTENCIA: No se pudo crear el ZIP, continuando...
) else (
    echo ZIP: %ZIP%
)

rem --- Git tag ---
echo.
git rev-parse "v%VER%" >nul 2>&1
if errorlevel 1 (
    echo === Creando tag v%VER% ===
    git tag -a "v%VER%" -m "v%VER%"
    git push origin "v%VER%"
    if errorlevel 1 (
        echo ERROR: No se pudo pushear el tag.
        pause
        exit /b 1
    )
) else (
    echo Tag v%VER% ya existe, usando existente.
)

rem --- GitHub Release ---
echo.
echo === Publicando release en GitHub ===
set "NOTAS=%TEMP%\rn_%VER%.txt"
set "PSFILE=%TEMP%\rn_gen.ps1"
echo $out = git log -1 --pretty=format:"## Cambios en v%VER%%%n%%n%B" > "%PSFILE%"
echo [IO.File]::WriteAllText('%NOTAS%', $out, [Text.Encoding]::UTF8^) >> "%PSFILE%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%PSFILE%"
del "%PSFILE%" 2>nul

set "GH_REPO=jairsl2206/repo-diff-report"

where gh >nul 2>&1
if errorlevel 1 (
    echo ERROR: gh CLI no encontrado. Instalalo con: winget install GitHub.cli
    echo Luego autenticate con: gh auth login
    echo.
    echo El ZIP esta listo para subir manualmente: %ZIP%
    del "%NOTAS%" 2>nul
    pause
    exit /b 1
)

rem --- gh CLI: crear release ---
set "GH_ASSETS=%EXE%"
if exist "%ZIP%" set "GH_ASSETS=%EXE% %ZIP%"
gh release create "v%VER%" %GH_ASSETS% ^
    --repo "%GH_REPO%" ^
    --title "v%VER%" ^
    --notes-file "%NOTAS%" ^
    --draft=false

if errorlevel 1 (
    echo ERROR: Fallo gh release create.
    del "%NOTAS%" 2>nul
    pause
    exit /b 1
)

del "%NOTAS%" 2>nul

echo.
echo ==============================================
echo  Release v%VER% publicada
echo  Exe:    %EXE%
echo  Zip:    %ZIP%
echo  SHA256: %SHA%
echo ==============================================
endlocal
pause
