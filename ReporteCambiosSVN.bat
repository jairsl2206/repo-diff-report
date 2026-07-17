@echo off
rem ============================================================
rem  Lanzador de ReporteCambiosSVN
rem  - Doble clic (sin argumentos)  : abre la interfaz grafica
rem  - Con argumentos               : modo consola (automatizable)
rem  Requiere: svn.exe en el PATH. Nada mas.
rem ============================================================
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0ReporteCambiosSVN.ps1" %*
if errorlevel 1 pause
