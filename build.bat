@echo off
rem ============================================================
rem  build.bat - Compila ReporteCambios.exe
rem  No requiere Visual Studio ni instalacion adicional.
rem  Output: build\ReporteCambios.exe
rem ============================================================
cd /d "%~dp0"
setlocal

rem --- Limpiar build anterior ---
if exist "build\" rmdir /s /q "build\"

rem --- Crear directorio de salida ---
if not exist "build\" mkdir "build\"

set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
if not exist "%CSC%" set CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe
if not exist "%CSC%" (
    echo ERROR: no se encontro csc.exe de .NET Framework 4.x
    exit /b 1
)
"%CSC%" /nologo /optimize+ /target:winexe /platform:anycpu ^
    /out:"%~dp0build\ReporteCambios.exe" ^
    /win32icon:"%~dp0ReporteCambiosSVN.ico" ^
    /r:System.dll /r:System.Core.dll /r:System.Xml.dll ^
    /r:System.Windows.Forms.dll /r:System.Drawing.dll ^
    /r:System.IO.Compression.dll /r:System.IO.Compression.FileSystem.dll ^
    "%~dp0src\Models.cs" "%~dp0src\Utils.cs" "%~dp0src\PdfExport.cs" "%~dp0src\Engine.cs" "%~dp0src\Gui.cs"
if errorlevel 1 (
    echo ERROR de compilacion.
    exit /b 1
)
echo OK: %~dp0build\ReporteCambios.exe generado.
