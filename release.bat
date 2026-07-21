@echo off
rem ============================================================
rem  release.bat - Compila y publica release en GitHub
rem  Uso: release.bat [version]
rem    Ej: release.bat 1.3.0
rem  Requisitos: git en el PATH, acceso al repo remoto
rem ============================================================
setlocal enabledelayedexpansion

rem --- Version (primer argumento, o desde el tag actual) ---
set "VER=%~1"
if "%VER%"=="" (
    for /f "tokens=2 delims=()" %%i in ('git tag --sort=-v:refname ^| findstr /r "^v[0-9]"') do set "VER=%%i"
    if "%VER%"=="" (
        for /f "delims=" %%i in ('git describe --tags --abbrev^=0 2^>nul') do set "VER=%%i"
        set "VER=!VER:v=!"
    )
)
if "%VER%"=="" (
    echo ERROR: No se pudo determinar la version. Usa: release.bat 1.3.0
    exit /b 1
)
echo Version: v%VER%

rem --- Construir ---
echo.
echo === Compilando ReporteCambios.exe ===
call "%~dp0build.bat"
if errorlevel 1 (
    echo ERROR: Fallo la compilacion.
    exit /b 1
)

set "EXE=%~dp0ReporteCambios.exe"
if not exist "%EXE%" (
    echo ERROR: No se encontro %EXE%
    exit /b 1
)

rem --- Empaquetar ZIP con el .exe y logo ---
set "ZIP=%~dp0ReporteCambios_v%VER%.zip"
if exist "%ZIP%" del "%ZIP%"
powershell -NoProfile -Command "Compress-Archive -LiteralPath '%EXE%','%~dp0logo-napse-totvs.png','%~dp0ReporteCambiosSVN.ico','%~dp0README.md' -DestinationPath '%ZIP%' -Force"
if errorlevel 1 (
    echo ERROR: No se pudo crear el ZIP.
    exit /b 1
)
echo ZIP creado: %ZIP%

rem --- SHA256 ---
echo.
for /f "delims=" %%h in ('powershell -NoProfile -Command "(Get-FileHash -LiteralPath '%EXE%' -Algorithm SHA256).Hash"') do set "SHA=%%h"
echo SHA256: %SHA%

rem --- Git tag (si no existe) ---
git rev-parse "v%VER%" >nul 2>&1
if errorlevel 1 (
    echo.
    echo === Creando tag v%VER% ===
    git tag -a "v%VER%" -m "v%VER%"
    git push origin "v%VER%"
    if errorlevel 1 (
        echo ERROR: No se pudo crear/pushear el tag.
        exit /b 1
    )
)

rem --- GitHub Release ---
echo.
echo === Creando release en GitHub ===
set "NOTAS=%TEMP%\release_notes_%VER%.txt"
git log -1 --pretty=format:"## Cambios en v%VER%%n%n%B" > "%NOTAS%"

set "GH_REPO=jairsl2206/repo-diff-report"
set "TAG=v%VER%"
set "RELEASE_NAME=v%VER%"

for /f "delims=" %%t in ('powershell -NoProfile -Command "try { $h=git config --get github.token; if($h){$h}else{''} } catch { '' }"') do set "TOKEN=%%t"

if "%TOKEN%"=="" (
    echo No se encontro token de GitHub. Intenta con gh CLI...
    where gh >nul 2>&1
    if errorlevel 1 (
        echo ERROR: No se encontro gh CLI ni github.token en git config.
        echo.
        echo Opciones:
        echo   1. Instalar gh CLI: winget install GitHub.cli
        echo   2. O configurar token: git config --global github.token TU_TOKEN
        echo.
        echo El ZIP esta listo para subir manualmente: %ZIP%
        exit /b 0
    )
    rem --- Usar gh CLI ---
    gh release create "%TAG%" "%EXE%" "%ZIP%" --repo "%GH_REPO%" --title "%RELEASE_NAME%" --notes-file "%NOTAS%"
    if errorlevel 1 (
        echo ERROR: Fallo gh release create.
        exit /b 1
    )
) else (
    rem --- Usar token manual con API de GitHub ---
    powershell -NoProfile -Command ^
        "$token='%TOKEN%'; $repo='%GH_REPO%'; $tag='%TAG%'; $name='%RELEASE_NAME%'; $body=Get-Content '%NOTAS%' -Raw; " ^
        "$headers=@{Authorization='token '+$token;Accept='application/vnd.github.v3+json'}; " ^
        "$release=Invoke-RestMethod -Uri https://api.github.com/repos/$repo/releases -Method Post -Headers $headers -Body (ConvertTo-Json @{tag_name=$tag;name=$name;body=$body;draft=$false;prerelease=$false}); " ^
        "Invoke-RestMethod -Uri $release.upload_url.Replace('{?name,label}','?name='+[Uri]::EscapeDataString((Split-Path '%EXE%' -Leaf))) -Method Post -Headers @{Authorization='token '+$token;'Content-Type'='application/octet-stream'} -InFile '%EXE%'; " ^
        "Write-Host 'Release creada: ' + $release.html_url"
)

del "%NOTAS%" 2>nul

echo.
echo === Release v%VER% completa ===
echo Exe: %EXE%
echo Zip: %ZIP%
echo SHA256: %SHA%
