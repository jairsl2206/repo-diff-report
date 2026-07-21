# repo-diff-report

Herramienta portable para Windows que genera reportes HTML/PDF de cambios por archivo desde repositorios **SVN y Git**: diffs lado a lado, resumen por archivo y metadatos de cada revisión/commit. Solo requiere el cliente del VCS (`svn.exe` y/o `git.exe`).

## Características

- **Soporte SVN y Git** con detección automática: SVN por URL o working copy; Git por carpeta local del clon (o fuerza el tipo con `-Vcs svn|git`)
- **Diffs lado a lado** (antes/después) estilo GitHub, con números de línea y colores, agrupados por revisión/commit y archivo
- **Metadatos por revisión**: número/commit, fecha, autor, versión (extraída del mensaje del commit o, si no hay, del `pom.xml` de proyectos Maven) y descripción
- **Resumen por archivo** (100% regex, determinista, sin IA): líneas ±, funciones nuevas/eliminadas, llamadas, temas detectados
- **Índice general**: revisiones, archivos afectados y archivos sin cambios en el periodo
- **Orden por fecha configurable**: ascendente o descendente (`-Orden asc|desc` o combo en la GUI), y botón "Invertir orden" dentro del propio HTML
- **Exclusión de commits del maven-release-plugin**: checks en la GUI o `-ExcluirMvnRelease` / `-ExcluirMvnPrepare` para omitir los commits `prepare release` y `prepare for next development iteration`
- **Salida en ZIP**: check en la GUI o `-Zip` para empaquetar el HTML (y el PDF, si se exportó) en un `.zip` junto a la salida
- **Exportación a PDF** apaisado usando Microsoft Edge integrado en Windows (headless)
- **GUI** (WinForms) con descripciones en tooltips, textos de ayuda en los campos (formato de fecha/revisión) y **memoria de la última configuración** usada (se guarda en `%APPDATA%\ReporteCambiosSVN`)
- Filtro por lista de archivos y extensiones, ambos **opcionales**: vacíos = todos los archivos modificados / cualquier extensión

## Requisitos

- Windows 8/10/11 (.NET Framework 4.5+, incluido en el sistema)
- `svn.exe` en el `PATH` para repos SVN, `git.exe` para repos Git
- Para PDF: Microsoft Edge (incluido en Windows 10/11)

## Uso

**Interfaz gráfica** — doble clic en `ReporteCambios.exe`.

**Consola:**

```bat
ReporteCambios.exe -ProjectPath <url|carpeta> -Desde <fecha|rev> ^
    [-Hasta <fecha|rev|HEAD>] [-Archivos "ARCH1,ARCH2"] [-Extensiones "BAS,DAT"] ^
    [-Salida reporte.html] [-SinResumen] [-AbrirAlTerminar] [-Pdf] [-SalidaPdf reporte.pdf] ^
    [-Autor "Nombre"] [-Vcs auto|svn|git] [-Orden asc|desc] [-ExcluirMvnRelease] [-ExcluirMvnPrepare] [-Zip]
```

Notas: `-Modulos` se acepta como alias de `-Archivos`. Sin `-Archivos` y/o sin `-Extensiones` se incluyen todos los archivos / cualquier extensión. En Git el rango de commits es `desde..hasta` (exclusivo del commit inicial); las fechas funcionan igual que en SVN.

Ejemplo:

```bat
ReporteCambios.exe -ProjectPath "https://servidor/svn/repo/trunk" ^
    -Desde 2025-08-01 -Hasta HEAD -Archivos "SUBTSPAG,USRTTLOG,USRTDUMP" -Extensiones "BAS,DAT" -Pdf
```

## Compilación

No requiere Visual Studio: `build.bat` compila todos los `.cs` con `csc.exe` del .NET Framework incluido en Windows.

Estructura del código fuente (modular):
- `Models.cs` — Modelos de datos y enums
- `Utils.cs` — Ejecución de procesos, wrappers SVN/Git, encoding de texto
- `PdfExport.cs` — Exportación a PDF via Microsoft Edge headless
- `Engine.cs` — Motor principal: logs, diffs, heurísticas, generación HTML
- `Gui.cs` — Interfaz gráfica WinForms + entry point (gui/cli)

## Roadmap

- [x] Soporte para repositorios **Git** (`git log` / `git diff`) con el mismo motor de reporte (v1.2.0)
