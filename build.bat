@echo off
rem ============================================================
rem  Compila ReporteCambiosSVN.exe usando el compilador C# que
rem  viene incluido en Windows (.NET Framework 4.x).
rem  No requiere Visual Studio ni ninguna instalacion adicional.
rem ============================================================
setlocal
set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
if not exist "%CSC%" set CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe
if not exist "%CSC%" (
    echo ERROR: no se encontro csc.exe de .NET Framework 4.x
    exit /b 1
)
"%CSC%" /nologo /optimize+ /target:winexe /platform:anycpu ^
    /out:"%~dp0ReporteCambiosSVN.exe" ^
    /win32icon:"%~dp0ReporteCambiosSVN.ico" ^
    /r:System.dll /r:System.Core.dll /r:System.Xml.dll ^
    /r:System.Windows.Forms.dll /r:System.Drawing.dll ^
    /r:System.IO.Compression.dll /r:System.IO.Compression.FileSystem.dll ^
    "%~dp0ReporteCambiosSVN.cs"
if errorlevel 1 (
    echo ERROR de compilacion.
    exit /b 1
)
echo OK: %~dp0ReporteCambiosSVN.exe generado.
