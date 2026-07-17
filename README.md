# repo-diff-report

Herramienta portable para Windows que genera reportes HTML/PDF de cambios por módulo desde SVN (Git en el futuro): diffs lado a lado, resumen heurístico por archivo y metadatos de cada revisión. Solo requiere el cliente del VCS.

## Características

- **Diffs lado a lado** (antes/después) estilo GitHub, con números de línea y colores, agrupados por revisión y archivo
- **Metadatos por revisión**: número, fecha, autor, versión (extraída del mensaje) y descripción del commit
- **Resumen heurístico por archivo** (100% regex, sin IA): líneas ±, funciones nuevas/eliminadas, llamadas, temas detectados
- **Índice general**: revisiones, módulos afectados y módulos sin cambios en el periodo
- **Exportación a PDF** apaisado usando Microsoft Edge integrado en Windows (headless)
- **GUI** (WinForms) y **modo consola** automatizable en el mismo ejecutable
- Filtro por lista de módulos (separados por coma) y extensiones configurables

## Requisitos

- Windows 8/10/11 (.NET Framework 4.5+, incluido en el sistema)
- `svn.exe` en el `PATH` (cliente SVN de línea de comandos)
- Para PDF: Microsoft Edge (incluido en Windows 10/11)

## Uso

**Interfaz gráfica** — doble clic en `ReporteCambiosSVN.exe`.

**Consola:**

```bat
ReporteCambiosSVN.exe -ProjectPath <url|carpeta> -Desde <fecha|rev> ^
    [-Hasta <fecha|rev|HEAD>] -Modulos "MOD1,MOD2,MOD3" [-Extensiones "BAS,DAT"] ^
    [-Salida reporte.html] [-SinResumen] [-AbrirAlTerminar] [-Pdf] [-SalidaPdf reporte.pdf]
```

Ejemplo:

```bat
ReporteCambiosSVN.exe -ProjectPath "https://servidor/svn/repo/trunk" ^
    -Desde 2025-08-01 -Hasta HEAD -Modulos "SUBTSPAG,USRTTLOG,USRTDUMP" -Pdf
```

## Compilación

No requiere Visual Studio: `build.bat` compila con `csc.exe` del .NET Framework incluido en Windows.

También se incluye la variante en PowerShell puro (`ReporteCambiosSVN.ps1` + lanzador `ReporteCambiosSVN.bat`) con la misma funcionalidad.

## Roadmap

- Soporte para repositorios **Git** (`git log` / `git diff`) con el mismo motor de reporte
