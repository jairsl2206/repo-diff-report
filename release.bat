@echo off
rem ============================================================
rem  release.bat - Compila y publica release en GitHub
rem  Uso:   release.bat 1.3.1
rem  Sin argumentos: usa el ultimo tag git + 1 patch
rem  Requisitos: gh CLI autenticado (gh auth login)
rem ============================================================
cd /d "%~dp0"
setlocal enabledelayedexpansion

rem --- Verificar working directory limpio ---
for /f "delims=" %%i in ('git status --porcelain 2^>nul') do (
    echo ERROR: Hay cambios sin commitear. Hace commit o stash antes de liberar.
    git status --short
    pause
    exit /b 1
)

rem --- Version ---
set "VER=%~1"
if not "%VER%"=="" goto :have_ver

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
rem --- Validar formato X.Y.Z ---
echo !VER!| findstr /r "^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$" >nul
if errorlevel 1 (
    echo ERROR: Version invalida "!VER!". Debe ser X.Y.Z ^(ej: 1.3.6^)
    pause
    exit /b 1
)

rem --- Compilar ---
echo.
echo === v!VER!: Compilando ===
call "%~dp0build.bat"
if errorlevel 1 (
    echo ERROR: Fallo la compilacion.
    pause
    exit /b 1
)

set "BUILD_EXE=%~dp0build\ReporteCambios.exe"
if not exist "%BUILD_EXE%" (
    echo ERROR: No se encontro %BUILD_EXE%
    pause
    exit /b 1
)

rem --- Preparar carpeta release ---
set "RELEASE=%~dp0release"
if exist "%RELEASE%" rmdir /s /q "%RELEASE%"
mkdir "%RELEASE%"

copy /y "%BUILD_EXE%" "%RELEASE%\ReporteCambios.exe" >nul
if exist "%~dp0imagen.png" copy /y "%~dp0imagen.png" "%RELEASE%\" >nul
if exist "%~dp0README.md"             copy /y "%~dp0README.md"             "%RELEASE%\" >nul
echo Artefactos copiados a %RELEASE%

rem --- SHA256 ---
set "EXE_RELEASE=%RELEASE%\ReporteCambios.exe"
for /f "delims=" %%h in ('powershell -NoProfile -Command "(Get-FileHash -LiteralPath '%EXE_RELEASE%' -Algorithm SHA256).Hash"') do set "SHA=%%h"
echo SHA256: !SHA!
echo !SHA! > "%RELEASE%\SHA256.txt"

rem --- ZIP ---
set "ZIP=%RELEASE%\ReporteCambios_v!VER!.zip"
powershell -NoProfile -Command "$files = Get-ChildItem -LiteralPath '%RELEASE%' -File -Exclude '*.zip'; if ($files) { Compress-Archive -LiteralPath $files.FullName -DestinationPath '%ZIP%' -Force } else { Write-Error 'Sin archivos para empaquetar' }"
if errorlevel 1 (
    echo ADVERTENCIA: No se pudo crear el ZIP, continuando...
) else (
    echo ZIP: !ZIP!
)

rem --- Git tag ---
echo.
git rev-parse "v!VER!" >nul 2>&1
if errorlevel 1 (
    echo === Creando tag v!VER! ===
    git tag -a "v!VER!" -m "v!VER!"
    git push origin "v!VER!"
    if errorlevel 1 (
        echo ERROR: No se pudo pushear el tag.
        pause
        exit /b 1
    )
) else (
    echo Tag v!VER! ya existe, usando existente.
)

rem --- Release notes ---
set "NOTAS=%TEMP%\rn_!VER!.txt"
set "PSFILE=%TEMP%\rn_gen_!VER!.ps1"
(
echo $body = git log -1 --pretty=format:%%B
echo $notes = "## Cambios en v!VER!`r`n`r`n$body"
echo [IO.File]::WriteAllText($env:NOTAS, $notes, [Text.Encoding]::UTF8^)
) > "%PSFILE%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%PSFILE%"
del "%PSFILE%" 2>nul

rem --- GitHub Release ---
echo.
echo === Publicando release en GitHub ===
set "GH_REPO=jairsl2206/repo-diff-report"

where gh >nul 2>&1
if errorlevel 1 (
    echo ERROR: gh CLI no encontrado. Instalalo con: winget install GitHub.cli
    echo Luego autenticate con: gh auth login
    echo.
    echo Los artefactos estan listos en: %RELEASE%
    del "%NOTAS%" 2>nul
    pause
    exit /b 1
)

rem --- Verificar autenticacion gh ---
gh auth status >nul 2>&1
if errorlevel 1 (
    echo ERROR: gh CLI no autenticado. Ejecuta: gh auth login
    echo Los artefactos estan listos en: %RELEASE%
    del "%NOTAS%" 2>nul
    pause
    exit /b 1
)

set "GH_ASSETS=%EXE_RELEASE%"
if exist "%ZIP%" set "GH_ASSETS=%EXE_RELEASE% %ZIP%"
gh release create "v!VER!" %GH_ASSETS% ^
    --repo "%GH_REPO%" ^
    --title "v!VER!" ^
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
echo  Release v!VER! publicada
echo.
echo  Carpeta: %RELEASE%
echo  Exe:     %EXE_RELEASE%
echo  Zip:     !ZIP!
echo  SHA256:  !SHA!
echo ==============================================
endlocal
pause
