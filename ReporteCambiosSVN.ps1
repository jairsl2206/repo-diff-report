<#
.SYNOPSIS
    Genera un reporte HTML de cambios SVN por modulo, con diffs lado a lado (antes/despues),
    resumen heuristico por archivo y metadatos (revision, fecha, version, autor, descripcion).

.DESCRIPTION
    Herramienta autocontenida para Windows. Dependencias: SOLO svn.exe en el PATH.
    Todo lo demas es nativo (Windows PowerShell 5.1 + .NET / WinForms).

    - Sin parametros (o con -Gui): abre interfaz grafica.
    - Con parametros: modo consola (automatizable).

    El "Resumen" por archivo es 100% heuristico (expresiones regulares sobre el diff);
    NO depende de IA ni de programas externos. Puede omitirse con -SinResumen.

.PARAMETER ProjectPath
    URL del proyecto SVN (ej. https://servidor/svn/repo/trunk) o ruta local de un working copy.

.PARAMETER Desde
    Inicio del rango: fecha YYYY-MM-DD o numero de revision.

.PARAMETER Hasta
    Fin del rango: fecha YYYY-MM-DD, numero de revision o HEAD (default: HEAD).

.PARAMETER Archivos
    Lista de archivos a identificar, separados por coma. Ej: "SUBTSPAG,USRTTLOG,USRTDUMP"
    Vacio/omitido = se incluyen TODOS los archivos modificados.
    (-Modulos se acepta como alias por compatibilidad).

.PARAMETER Extensiones
    Extensiones a filtrar, separadas por coma (ej: "BAS,DAT"). Vacio = cualquier extension.

.PARAMETER Salida
    Ruta del archivo HTML a generar (default: autogenerado en el escritorio).

.PARAMETER SinResumen
    Omite el bloque "Resumen" heuristico por archivo.

.PARAMETER AbrirAlTerminar
    Abre el HTML en el navegador al finalizar.

.PARAMETER Pdf
    Exporta ademas una copia en PDF usando Microsoft Edge (incluido en Windows 10/11)
    en modo headless. Si Edge no esta disponible, el HTML se genera igual y se avisa.

.PARAMETER SalidaPdf
    Ruta del PDF (default: mismo nombre que el HTML con extension .pdf). Implica -Pdf.

.PARAMETER Autor
    Nombre que aparecera como Autor en la portada del reporte.

.PARAMETER Vcs
    Tipo de repositorio: auto (default), svn o git.
    SVN: URL o working copy. Git: carpeta local del repositorio clonado
    (en Git el rango de commits es desde..hasta, exclusivo del inicial).

.PARAMETER Orden
    Orden de las revisiones por fecha: asc (antiguas primero, default) o desc (recientes primero).

.PARAMETER ExcluirMvnRelease
    Omite commits del maven-release-plugin '[maven-release-plugin] prepare release ...'.

.PARAMETER ExcluirMvnPrepare
    Omite commits '[maven-release-plugin] prepare for next development iteration'.

.PARAMETER Zip
    Genera un archivo .zip junto a la salida, con el HTML y (si se exporto) el PDF.

.PARAMETER Gui
    Fuerza la interfaz grafica.

.EXAMPLE
    .\ReporteCambiosSVN.ps1

.EXAMPLE
    .\ReporteCambiosSVN.ps1 -ProjectPath "https://dev.napse.global/svn/46xx/proyectos/46xx-suburbia/trunk" `
        -Desde 2025-08-01 -Hasta HEAD -Archivos "SUBTSPAG,SUBTSCOB,USRTTLOG" -AbrirAlTerminar
#>
[CmdletBinding()]
param(
    [string]$ProjectPath,
    [string]$Desde,
    [string]$Hasta = 'HEAD',
    [Alias('Modulos')]
    [string[]]$Archivos,
    [string[]]$Extensiones = @(),
    [string]$Salida,
    [switch]$SinResumen,
    [switch]$AbrirAlTerminar,
    [switch]$Pdf,
    [string]$SalidaPdf = '',
    [string]$Autor = '',
    [string]$Vcs = 'auto',
    [string]$Orden = 'asc',
    [switch]$ExcluirMvnRelease,
    [switch]$ExcluirMvnPrepare,
    [switch]$Zip,
    [switch]$Gui
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

# ============================================================================
#  UTILIDADES BASE
# ============================================================================

function Test-SvnDisponible {
    $cmd = Get-Command svn -ErrorAction SilentlyContinue
    return ($null -ne $cmd)
}

function Test-GitDisponible {
    $cmd = Get-Command git -ErrorAction SilentlyContinue
    return ($null -ne $cmd)
}

function Invoke-ProcRaw {
    # Ejecuta un proceso y devuelve stdout como BYTES (sin recodificar) + stderr como texto.
    param([string]$Exe, [string[]]$Argumentos)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $quoted = foreach ($a in $Argumentos) {
        if ($a -match '[\s"]') { '"' + ($a -replace '"','\"') + '"' } else { $a }
    }
    $psi.Arguments = ($quoted -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $errTask = $proc.StandardError.ReadToEndAsync()
    $ms = New-Object System.IO.MemoryStream
    $proc.StandardOutput.BaseStream.CopyTo($ms)
    $proc.WaitForExit()
    return New-Object PSObject -Property @{
        ExitCode = $proc.ExitCode
        Bytes    = $ms.ToArray()
        StdErr   = $errTask.Result
    }
}

function Invoke-SvnRaw {
    param([string[]]$Argumentos)
    return Invoke-ProcRaw -Exe 'svn' -Argumentos $Argumentos
}

function Invoke-GitRaw {
    param([string[]]$Argumentos)
    return Invoke-ProcRaw -Exe 'git' -Argumentos $Argumentos
}

function Convert-BytesToText {
    # UTF-8 estricto; si falla, heuristica CP437 vs CP1252 (tipico en fuentes 4690 BASIC).
    param([byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return '' }
    try {
        $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
        return $utf8.GetString($Bytes)
    } catch {
        $latin = [System.Text.Encoding]::GetEncoding(28591).GetString($Bytes)
        $c437  = [regex]::Matches($latin, "[\x81\x82\x8A\x90\x9A\xA0-\xA5]").Count
        $c1252 = [regex]::Matches($latin, "[\xE1\xE9\xED\xF3\xFA\xF1\xC1\xC9\xCD\xD3\xDA\xD1]").Count
        $cp = 1252
        if ($c437 -gt $c1252) { $cp = 437 }
        return [System.Text.Encoding]::GetEncoding($cp).GetString($Bytes)
    }
}

function ConvertTo-RevExpr {
    # "31102" -> 31102 | "HEAD" -> HEAD | "2025-08-01" -> {2025-08-01}
    param([string]$Valor)
    $v = ('' + $Valor).Trim()
    if ($v -eq '') { throw 'Valor de fecha/revision vacio.' }
    if ($v -match '^\d+$') { return $v }
    if ($v -match '^(?i)(HEAD|BASE|COMMITTED|PREV)$') { return $v.ToUpper() }
    if ($v -match '^\{.+\}$') { return $v }
    if ($v -match '^\d{4}-\d{2}-\d{2}([ T]\d{2}:\d{2}(:\d{2})?)?$') { return '{' + $v + '}' }
    throw ('Valor de fecha/revision no valido: "' + $v + '". Use YYYY-MM-DD, un numero de revision o HEAD.')
}

function Test-EsFecha {
    param([string]$Valor)
    return (('' + $Valor).Trim() -match '^\d{4}-\d{2}-\d{2}([ T]\d{2}:\d{2}(:\d{2})?)?$')
}

# Commits generados por el maven-release-plugin.
function Test-CommitMavenRelease {
    param([string]$Msg)
    return (('' + $Msg) -match '(?i)\[maven-release-plugin\]\s*prepare\s+release')
}

function Test-CommitMavenPrepare {
    param([string]$Msg)
    return (('' + $Msg) -match '(?i)\[maven-release-plugin\]\s*prepare\s+for\s+next\s+development\s+iteration')
}

function Get-VcsTipo {
    # Devuelve 'svn' o 'git' segun el objetivo y la preferencia del usuario.
    param([string]$Objetivo, [string]$Preferencia)
    $p = ('' + $Preferencia).Trim().ToLower()
    if ($p -eq 'svn') { return 'svn' }
    if ($p -eq 'git') { return 'git' }
    if ($Objetivo -match '^[A-Za-z][A-Za-z0-9+.\-]*://') { return 'svn' }
    if (Test-Path -LiteralPath $Objetivo) {
        if (Test-Path -LiteralPath (Join-Path $Objetivo '.svn')) { return 'svn' }
        if (Test-GitDisponible) {
            $r = Invoke-GitRaw -Argumentos @('-C', $Objetivo, 'rev-parse', '--is-inside-work-tree')
            if ($r.ExitCode -eq 0) { return 'git' }
        }
    }
    return 'svn'
}

function HtmlEnc {
    param([string]$s)
    if ($null -eq $s -or $s.Length -eq 0) { return '' }
    return [System.Net.WebUtility]::HtmlEncode($s)
}

function Split-Lista {
    # Acepta @('A,B','C') o 'A, B, C' y devuelve lista limpia y unica.
    param([string[]]$Valores)
    $out = New-Object System.Collections.ArrayList
    foreach ($v in @($Valores)) {
        foreach ($p in (('' + $v) -split ',')) {
            $t = $p.Trim()
            if ($t -ne '' -and -not ($out -contains $t)) { [void]$out.Add($t) }
        }
    }
    return ,@($out)
}

# ============================================================================
#  SVN: INFO / LOG / DIFF
# ============================================================================

function Get-SvnInfoXml {
    param([string]$Target)
    $r = Invoke-SvnRaw -Argumentos @('info','--xml','--non-interactive',$Target)
    if ($r.ExitCode -ne 0) { throw ("svn info fallo para '" + $Target + "':`n" + $r.StdErr) }
    $xml = New-Object System.Xml.XmlDocument
    $ms = New-Object System.IO.MemoryStream(,$r.Bytes)
    $xml.Load($ms)
    return New-Object PSObject -Property @{
        Url  = $xml.info.entry.url
        Root = $xml.info.entry.repository.root
    }
}

function Get-LogEntradas {
    param([string]$Url, [string]$Rango, [System.Text.RegularExpressions.Regex]$Patron)
    $r = Invoke-SvnRaw -Argumentos @('log','-v','--xml','--non-interactive','-r',$Rango,$Url)
    if ($r.ExitCode -ne 0) { throw ("svn log fallo:`n" + $r.StdErr) }
    $xml = New-Object System.Xml.XmlDocument
    $ms = New-Object System.IO.MemoryStream(,$r.Bytes)
    $xml.Load($ms)
    $entradas = New-Object System.Collections.ArrayList
    $logNode = $xml.SelectSingleNode('log')
    if ($null -eq $logNode) { return ,@($entradas) }
    foreach ($le in @($logNode.SelectNodes('logentry'))) {
        $msgNode = $le.SelectSingleNode('msg')
        $msg = ''
        if ($null -ne $msgNode) { $msg = ('' + $msgNode.InnerText).Trim() }
        $dateNode = $le.SelectSingleNode('date')
        $fecha = ''
        if ($null -ne $dateNode) {
            try { $fecha = ([datetime]$dateNode.InnerText).ToLocalTime().ToString('yyyy-MM-dd HH:mm') }
            catch { $fecha = ('' + $dateNode.InnerText).Substring(0,16).Replace('T',' ') }
        }
        $authorNode = $le.SelectSingleNode('author')
        $autor = ''
        if ($null -ne $authorNode) { $autor = ('' + $authorNode.InnerText).Trim() }
        $targets = New-Object System.Collections.ArrayList
        $otros   = New-Object System.Collections.ArrayList
        foreach ($p in @($le.SelectNodes('paths/path'))) {
            $ruta = '' + $p.InnerText
            $esDir = (('' + $p.GetAttribute('kind')) -eq 'dir')
            $item = New-Object PSObject -Property @{ Action = ('' + $p.GetAttribute('action')); Path = $ruta }
            if (-not $esDir -and $Patron.IsMatch($ruta)) { [void]$targets.Add($item) } else { [void]$otros.Add($item) }
        }
        [void]$entradas.Add((New-Object PSObject -Property @{
            Rev     = ('' + $le.GetAttribute('revision'))
            FullRev = ('' + $le.GetAttribute('revision'))
            Author  = $autor
            Date    = $fecha
            Msg     = $msg
            Targets = @($targets)
            Others  = @($otros)
        }))
    }
    return ,@($entradas)
}

function Get-DiffRevision {
    param([string]$Root, [string]$Rev, [object[]]$Targets)
    $urls = New-Object System.Collections.ArrayList
    foreach ($t in @($Targets)) {
        if ($t.Action -ne 'D') { [void]$urls.Add(($Root + $t.Path + '@' + $Rev)) }
    }
    if ($urls.Count -eq 0) { return '' }
    $r = Invoke-SvnRaw -Argumentos (@('diff','--non-interactive','-c',$Rev) + @($urls))
    if ($r.ExitCode -ne 0 -and $r.Bytes.Length -eq 0) {
        return ('@@ERROR@@' + $r.StdErr)
    }
    return (Convert-BytesToText -Bytes $r.Bytes)
}

# ============================================================================
#  GIT: LOG / DIFF
# ============================================================================

function Get-GitLogEntradas {
    param([string]$Dir, [string]$DesdeV, [string]$HastaV, [System.Text.RegularExpressions.Regex]$Patron)
    $args = New-Object System.Collections.ArrayList
    [void]$args.AddRange(@('-c','core.quotepath=off','-C',$Dir,'log','--reverse','--no-color','--date=iso-strict','--name-status',
        '--pretty=format:%x1e%h%x1f%H%x1f%an%x1f%ad%x1f%B%x1f'))
    $d = ('' + $DesdeV).Trim()
    $h = ('' + $HastaV).Trim()
    $rangoRev = $null
    if ($d -ne '' -and -not (Test-EsFecha $d)) {
        $fin = 'HEAD'
        if ($h -ne '' -and -not (Test-EsFecha $h)) { $fin = $h }
        $rangoRev = ($d + '..' + $fin)
    } elseif ($d -ne '') {
        [void]$args.Add('--since=' + $d)
    }
    if (Test-EsFecha $h) { [void]$args.Add('--until=' + $h) }
    elseif ($null -eq $rangoRev -and $h -ne '' -and $h.ToUpper() -ne 'HEAD') { $rangoRev = $h }
    if ($null -ne $rangoRev) { [void]$args.Add($rangoRev) }

    $r = Invoke-GitRaw -Argumentos @($args)
    if ($r.ExitCode -ne 0) { throw ("git log fallo:`n" + $r.StdErr) }
    $texto = Convert-BytesToText -Bytes $r.Bytes

    $lista = New-Object System.Collections.ArrayList
    foreach ($rec in $texto.Split([char]0x1e)) {
        if ($rec.Trim().Length -eq 0) { continue }
        $partes = $rec.Split([char[]]@([char]0x1f), 6)
        if ($partes.Count -lt 6) { continue }
        $fecha = ('' + $partes[3]).Trim()
        try {
            $fecha = [datetime]::Parse($fecha, [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime().ToString('yyyy-MM-dd HH:mm')
        } catch { }
        $targets = New-Object System.Collections.ArrayList
        $otros   = New-Object System.Collections.ArrayList
        foreach ($ln in [regex]::Split(('' + $partes[5]), "\r?\n")) {
            $t = $ln.Trim()
            if ($t.Length -eq 0) { continue }
            $cols = $t.Split("`t")
            if ($cols.Count -lt 2) { continue }
            $st = ('' + $cols[0]).Trim()
            if ($st.Length -eq 0) { continue }
            $acc = $st.Substring(0,1).ToUpper()
            if ('MADRC'.IndexOf($acc) -lt 0) { continue }
            $ruta = ('' + $cols[$cols.Count - 1]).Trim()
            $item = New-Object PSObject -Property @{ Action = $acc; Path = ('/' + $ruta.Replace('\','/')) }
            if ($Patron.IsMatch($item.Path)) { [void]$targets.Add($item) } else { [void]$otros.Add($item) }
        }
        [void]$lista.Add((New-Object PSObject -Property @{
            Rev     = ('' + $partes[0]).Trim()
            FullRev = ('' + $partes[1]).Trim()
            Author  = ('' + $partes[2]).Trim()
            Date    = $fecha
            Msg     = ('' + $partes[4]).Trim()
            Targets = @($targets)
            Others  = @($otros)
        }))
    }
    return ,@($lista)
}

function Get-GitDiffCommit {
    param([string]$Dir, [string]$FullRev, [object[]]$Targets)
    $rutas = New-Object System.Collections.ArrayList
    foreach ($t in @($Targets)) {
        if ($t.Action -ne 'D') { [void]$rutas.Add($t.Path.TrimStart('/')) }
    }
    if ($rutas.Count -eq 0) { return '' }
    $args = @('-c','core.quotepath=off','-C',$Dir,'diff','--no-color','--unified=3',($FullRev + '^'),$FullRev,'--') + @($rutas)
    $r = Invoke-GitRaw -Argumentos $args
    if ($r.ExitCode -ne 0) {
        $args2 = @('-c','core.quotepath=off','-C',$Dir,'show','--no-color','--unified=3','--format=',$FullRev,'--') + @($rutas)
        $r = Invoke-GitRaw -Argumentos $args2
        if ($r.ExitCode -ne 0 -and $r.Bytes.Length -eq 0) {
            return ('@@ERROR@@' + $r.StdErr)
        }
    }
    return (Convert-BytesToText -Bytes $r.Bytes)
}

function Split-SeccionesGit {
    # Divide la salida de git diff en secciones por "diff --git a/X b/X".
    param([string]$DiffTexto)
    $secciones = @{}
    $actual = $null
    $buf = $null
    $reHdr = [regex]'^diff --git a/(.+) b/(.+)$'
    foreach ($linea in [regex]::Split($DiffTexto, "\r?\n")) {
        $m = $reHdr.Match($linea)
        if ($m.Success) {
            if ($null -ne $actual) { $secciones[$actual] = $buf }
            $partes = $m.Groups[2].Value.Trim() -split '[\\/]'
            $actual = $partes[$partes.Length - 1]
            $buf = New-Object System.Collections.ArrayList
        } elseif ($null -ne $actual) {
            if ($linea.StartsWith('Binary files ') -or $linea.StartsWith('GIT binary patch')) {
                [void]$buf.Add('Cannot display: archivo binario.')
            } else {
                [void]$buf.Add($linea)
            }
        }
    }
    if ($null -ne $actual) { $secciones[$actual] = $buf }
    return $secciones
}

# ============================================================================
#  PARSEO DE DIFFS
# ============================================================================

function Split-Secciones {
    # Divide la salida de svn diff en secciones por "Index: <archivo>".
    param([string]$DiffTexto)
    $secciones = @{}
    $actual = $null
    $buf = $null
    foreach ($linea in [regex]::Split($DiffTexto, "\r?\n")) {
        if ($linea.StartsWith('Index: ')) {
            if ($null -ne $actual) { $secciones[$actual] = $buf }
            $nombre = $linea.Substring(7).Trim()
            $partes = $nombre -split '[\\/]'
            $actual = $partes[$partes.Length - 1]
            $buf = New-Object System.Collections.ArrayList
        } elseif ($null -ne $actual) {
            [void]$buf.Add($linea)
        }
    }
    if ($null -ne $actual) { $secciones[$actual] = $buf }
    return $secciones
}

function ConvertTo-Hunks {
    # Convierte lineas de una seccion en hunks con filas pareadas para vista lado a lado.
    # Fila: @(tipo, numIzq, textoIzq, numDer, textoDer)  tipo: ctx|rep|del|add
    param([System.Collections.ArrayList]$Lineas)
    $hunks = New-Object System.Collections.ArrayList
    $binario = $false
    $i = 0
    $reHdr = [regex]'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@'
    while ($i -lt $Lineas.Count) {
        $ln = '' + $Lineas[$i]
        if ($ln.StartsWith('Cannot display:')) { $binario = $true; break }
        if ($ln.StartsWith('Property changes on:')) { break }
        $m = $reHdr.Match($ln)
        if ($m.Success) {
            $oldNo = [int]$m.Groups[1].Value
            $newNo = [int]$m.Groups[3].Value
            $rows = New-Object System.Collections.ArrayList
            $dq = New-Object System.Collections.ArrayList
            $aq = New-Object System.Collections.ArrayList
            $hdrTxt = $ln
            $i++
            while ($i -lt $Lineas.Count) {
                $l2 = '' + $Lineas[$i]
                if ($l2.StartsWith('@@') -or $l2.StartsWith('Index: ') -or $l2.StartsWith('Property changes on:') -or $l2.StartsWith('Cannot display:')) { break }
                if ($l2.StartsWith('\')) { $i++; continue }
                if ($l2.StartsWith('-')) {
                    [void]$dq.Add(@($oldNo, $l2.Substring(1))); $oldNo++
                } elseif ($l2.StartsWith('+')) {
                    [void]$aq.Add(@($newNo, $l2.Substring(1))); $newNo++
                } else {
                    # contexto -> vaciar colas pareadas
                    $n = [Math]::Max($dq.Count, $aq.Count)
                    for ($k = 0; $k -lt $n; $k++) {
                        $L = $null; $R = $null
                        if ($k -lt $dq.Count) { $L = $dq[$k] }
                        if ($k -lt $aq.Count) { $R = $aq[$k] }
                        if ($null -ne $L -and $null -ne $R) { [void]$rows.Add(@('rep', $L[0], $L[1], $R[0], $R[1])) }
                        elseif ($null -ne $L)               { [void]$rows.Add(@('del', $L[0], $L[1], '', '')) }
                        else                                { [void]$rows.Add(@('add', '', '', $R[0], $R[1])) }
                    }
                    $dq.Clear(); $aq.Clear()
                    $txt = $l2
                    if ($l2.StartsWith(' ')) { $txt = $l2.Substring(1) }
                    [void]$rows.Add(@('ctx', $oldNo, $txt, $newNo, $txt))
                    $oldNo++; $newNo++
                }
                $i++
            }
            $n = [Math]::Max($dq.Count, $aq.Count)
            for ($k = 0; $k -lt $n; $k++) {
                $L = $null; $R = $null
                if ($k -lt $dq.Count) { $L = $dq[$k] }
                if ($k -lt $aq.Count) { $R = $aq[$k] }
                if ($null -ne $L -and $null -ne $R) { [void]$rows.Add(@('rep', $L[0], $L[1], $R[0], $R[1])) }
                elseif ($null -ne $L)               { [void]$rows.Add(@('del', $L[0], $L[1], '', '')) }
                else                                { [void]$rows.Add(@('add', '', '', $R[0], $R[1])) }
            }
            [void]$hunks.Add((New-Object PSObject -Property @{ Header = $hdrTxt; Rows = $rows }))
        } else {
            $i++
        }
    }
    return New-Object PSObject -Property @{
        Hunks    = $hunks
        Binario  = $binario
        SoloProp = ($hunks.Count -eq 0 -and -not $binario)
    }
}

# ============================================================================
#  RESUMEN HEURISTICO (regex puro, sin IA)
# ============================================================================

function New-ResumenArchivo {
    param([System.Collections.ArrayList]$Hunks)
    $adds = 0; $dels = 0
    $sbA = New-Object System.Text.StringBuilder
    $sbR = New-Object System.Text.StringBuilder
    $addedLines = New-Object System.Collections.ArrayList
    foreach ($h in @($Hunks)) {
        foreach ($r in @($h.Rows)) {
            $tipo = $r[0]
            if ($tipo -eq 'rep' -or $tipo -eq 'del') { $dels++; [void]$sbR.AppendLine('' + $r[2]) }
            if ($tipo -eq 'rep' -or $tipo -eq 'add') { $adds++; [void]$sbA.AppendLine('' + $r[4]); [void]$addedLines.Add('' + $r[4]) }
        }
    }
    $A = $sbA.ToString(); $R = $sbR.ToString(); $AR = $A + "`n" + $R
    $partes = New-Object System.Collections.ArrayList
    [void]$partes.Add(('{0} linea(s) agregadas, {1} eliminadas en {2} bloque(s)' -f $adds, $dels, $Hunks.Count))

    $fnA = @{}; $fnR = @{}
    foreach ($m in [regex]::Matches($A, '\bDEF\s+(FN[\w\.\$]+)', 'IgnoreCase')) { $fnA[$m.Groups[1].Value] = $true }
    foreach ($m in [regex]::Matches($R, '\bDEF\s+(FN[\w\.\$]+)', 'IgnoreCase')) { $fnR[$m.Groups[1].Value] = $true }
    $nuevas   = @($fnA.Keys | Where-Object { -not $fnR.ContainsKey($_) } | Sort-Object)
    $borradas = @($fnR.Keys | Where-Object { -not $fnA.ContainsKey($_) } | Sort-Object)
    if ($nuevas.Count -gt 0) {
        $txt = ($nuevas | Select-Object -First 4) -join ', '
        if ($nuevas.Count -gt 4) { $txt += '...' }
        [void]$partes.Add('nuevas funciones: ' + $txt)
    }
    if ($borradas.Count -gt 0) {
        $txt = ($borradas | Select-Object -First 4) -join ', '
        if ($borradas.Count -gt 4) { $txt += '...' }
        [void]$partes.Add('funciones eliminadas: ' + $txt)
    }

    $callA = @{}; $callR = @{}
    foreach ($m in [regex]::Matches($A, '\bCALL\s+([A-Z0-9\.\$]{4,})', 'IgnoreCase')) { $callA[$m.Groups[1].Value.ToLower()] = $m.Groups[1].Value }
    foreach ($m in [regex]::Matches($R, '\bCALL\s+([A-Z0-9\.\$]{4,})', 'IgnoreCase')) { $callR[$m.Groups[1].Value.ToLower()] = $true }
    $callsNuevas = @($callA.Keys | Where-Object { -not $callR.ContainsKey($_) } | ForEach-Object { $callA[$_] } | Sort-Object)
    if ($callsNuevas.Count -gt 0) {
        $txt = ($callsNuevas | Select-Object -First 4) -join ', '
        if ($callsNuevas.Count -gt 4) { $txt += '...' }
        [void]$partes.Add('nuevas llamadas: ' + $txt)
    }

    if ([regex]::IsMatch($AR, '%\s*include', 'IgnoreCase')) { [void]$partes.Add('cambios en %INCLUDE') }

    $temas = New-Object System.Collections.ArrayList
    if ([regex]::IsMatch($A, '(PRINT|TICKET|VOUCHER|IMPRE)', 'IgnoreCase'))      { [void]$temas.Add('impresion ticket/voucher') }
    if ([regex]::IsMatch($A, '(ENMASC|MASK|X{4,}|ASTERIS)', 'IgnoreCase'))       { [void]$temas.Add('enmascaramiento de datos') }
    if ([regex]::IsMatch($A, '(TLOG|STRING\s*\d)', 'IgnoreCase'))                { [void]$temas.Add('registro TLOG/strings') }
    if ([regex]::IsMatch($A, '(WS\.|HTTP|CICS|SOCKET)', 'IgnoreCase'))           { [void]$temas.Add('web service/comunicaciones') }
    if ([regex]::IsMatch($A, '(TRAINING|ENTRENA)', 'IgnoreCase'))                { [void]$temas.Add('modo entrenamiento') }
    if ([regex]::IsMatch($A, '(CASH\s*ADV|WALLET)', 'IgnoreCase'))               { [void]$temas.Add('cash advance/wallet') }
    if ([regex]::IsMatch($A, 'TOKA', 'IgnoreCase'))                              { [void]$temas.Add('TOKA Pay') }
    if ($temas.Count -gt 0) { [void]$partes.Add('temas: ' + ($temas -join ', ')) }

    $vers = New-Object System.Collections.ArrayList
    foreach ($m in [regex]::Matches($A, '\b(\d+\.\d{2}\.\d{2})\b')) {
        if (-not ($vers -contains $m.Groups[1].Value)) { [void]$vers.Add($m.Groups[1].Value) }
    }
    if ($vers.Count -gt 0) { [void]$partes.Add('version(es) referenciada(s): ' + (@($vers | Select-Object -First 3) -join ', ')) }

    if ($adds -gt 0) {
        $soloComentarios = $true
        foreach ($t in $addedLines) {
            $tt = ('' + $t).Trim()
            if ($tt -ne '' -and -not $tt.StartsWith('!')) { $soloComentarios = $false; break }
        }
        if ($soloComentarios) { [void]$partes.Add('solo comentarios/documentacion') }
    }
    return (($partes -join '; ') + '.')
}

function Get-VersionesDeMensaje {
    param([string]$Msg)
    $out = New-Object System.Collections.ArrayList
    foreach ($m in [regex]::Matches($Msg, 'versi[oó]n\s+v?\.?\s*(\d+(?:\.\d+){1,3})', 'IgnoreCase')) {
        $v = $m.Groups[1].Value
        if (-not ($out -contains $v)) { [void]$out.Add($v) }
    }
    return ,@($out)
}

# Version de proyectos Maven: <project><version> (o la del <parent>) en pom.xml.
function Get-PomVersion {
    param([string]$XmlTexto)
    try {
        $XmlTexto = ('' + $XmlTexto).TrimStart([char]0xFEFF, ' ', "`r", "`n", "`t")
        $doc = New-Object System.Xml.XmlDocument
        $doc.LoadXml($XmlTexto)
        $root = $doc.DocumentElement
        if ($null -eq $root -or $root.LocalName -ne 'project') { return '' }
        $vParent = ''
        foreach ($n in $root.ChildNodes) {
            if ($n.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
            if ($n.LocalName -eq 'version') {
                $v = ('' + $n.InnerText).Trim()
                if ($v -ne '') { return $v }
            }
            if ($n.LocalName -eq 'parent') {
                foreach ($c in $n.ChildNodes) {
                    if ($c.NodeType -eq [System.Xml.XmlNodeType]::Element -and $c.LocalName -eq 'version') {
                        $vParent = ('' + $c.InnerText).Trim()
                    }
                }
            }
        }
        return $vParent
    } catch { return '' }
}

function Get-PomVersionGit {
    param([string]$Dir, [string]$FullRev)
    $r = Invoke-GitRaw -Argumentos @('-c','core.quotepath=off','-C',$Dir,'show',($FullRev + ':pom.xml'))
    if ($r.ExitCode -ne 0) { return '' }
    return (Get-PomVersion -XmlTexto (Convert-BytesToText -Bytes $r.Bytes))
}

function Get-PomVersionSvn {
    param([string]$Url, [string]$Rev)
    $r = Invoke-SvnRaw -Argumentos @('cat','--non-interactive','-r',$Rev,($Url + '/pom.xml@' + $Rev))
    if ($r.ExitCode -ne 0) { return '' }
    return (Get-PomVersion -XmlTexto (Convert-BytesToText -Bytes $r.Bytes))
}

function Get-DescripcionCorta {
    param([string]$Msg, [int]$Max = 110)
    foreach ($l in ($Msg -split "\r?\n")) {
        $t = $l.Trim()
        if ($t -ne '') {
            if ($t.Length -gt $Max) { return ($t.Substring(0, $Max) + '...') }
            return $t
        }
    }
    return ''
}

# ============================================================================
#  EXPORTACION A PDF (Microsoft Edge integrado en Windows 10/11)
# ============================================================================

function Find-Edge {
    $candidatos = New-Object System.Collections.ArrayList
    $pf86 = ${env:ProgramFiles(x86)}
    $pf   = $env:ProgramFiles
    if ($pf86) { [void]$candidatos.Add((Join-Path $pf86 'Microsoft\Edge\Application\msedge.exe')) }
    if ($pf)   { [void]$candidatos.Add((Join-Path $pf   'Microsoft\Edge\Application\msedge.exe')) }
    try {
        $reg = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe' -ErrorAction SilentlyContinue
        if ($null -ne $reg -and $reg.'(default)') { [void]$candidatos.Add($reg.'(default)') }
    } catch { }
    foreach ($c in $candidatos) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    return $null
}

function Wait-ArchivoPdf {
    param([string]$PdfPath, [int]$TimeoutMs)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $ultimo = -1
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        try {
            if (Test-Path -LiteralPath $PdfPath) {
                $len = (Get-Item -LiteralPath $PdfPath).Length
                if ($len -gt 0 -and $len -eq $ultimo) {
                    try {
                        $fs = [System.IO.File]::Open($PdfPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
                        $fs.Close()
                        return $true
                    } catch { }
                }
                $ultimo = $len
            }
        } catch { }
        Start-Sleep -Milliseconds 500
    }
    return ((Test-Path -LiteralPath $PdfPath) -and ((Get-Item -LiteralPath $PdfPath).Length -gt 0))
}

# Inserta /PageLayout /OneColumn en el catalogo del PDF (actualizacion incremental)
# para que los visores abran el documento en modo de desplazamiento continuo.
function Set-PdfScrollContinuo {
    param([string]$PdfPath)
    try {
        $lat = [System.Text.Encoding]::GetEncoding(28591)
        $bytes = [System.IO.File]::ReadAllBytes($PdfPath)
        $t = $lat.GetString($bytes)
        if ($t.Contains('/PageLayout')) { return }

        $sxPos = $t.LastIndexOf('startxref')
        if ($sxPos -lt 0) { return }
        $mSx = [regex]::Match($t.Substring($sxPos), 'startxref\s+(\d+)')
        if (-not $mSx.Success) { return }
        $prevXref = $mSx.Groups[1].Value

        $rootNum = $null
        foreach ($m in [regex]::Matches($t, '/Root\s+(\d+)\s+0\s+R')) { $rootNum = $m.Groups[1].Value }
        if ($null -eq $rootNum) { return }
        $size = $null
        foreach ($m in [regex]::Matches($t, '/Size\s+(\d+)')) { $size = $m.Groups[1].Value }
        if ($null -eq $size) { return }
        $info = $null
        foreach ($m in [regex]::Matches($t, '/Info\s+\d+\s+0\s+R')) { $info = $m.Value }

        $objM = $null
        foreach ($m in [regex]::Matches($t, ('(^|[\r\n])' + $rootNum + ' 0 obj\b'))) { $objM = $m }
        if ($null -eq $objM) { return }
        $objPos = $objM.Index + $objM.Groups[1].Length
        $dictPos = $t.IndexOf('<<', $objPos)
        $endPos = $t.IndexOf('endobj', $objPos)
        if ($dictPos -lt 0 -or $endPos -lt 0 -or $dictPos -gt $endPos) { return }
        $cuerpo = $t.Substring($dictPos + 2, $endPos - $dictPos - 2).TrimEnd()

        $prefijo = ''
        if ($bytes.Length -gt 0 -and $bytes[$bytes.Length - 1] -ne 10) { $prefijo = "`n" }
        $nuevoObj = ($prefijo + $rootNum + " 0 obj`n<< /PageLayout /OneColumn " + $cuerpo + "`nendobj`n")
        $objOffset = $bytes.Length + $prefijo.Length
        $xrefOffset = $bytes.Length + $nuevoObj.Length

        $infoTxt = ''
        if ($null -ne $info) { $infoTxt = ' ' + $info }
        $tail = ($nuevoObj + "xref`n" + $rootNum + " 1`n" + $objOffset.ToString('D10') + " 00000 n`r`n" +
                 "trailer`n<< /Size " + $size + ' /Root ' + $rootNum + ' 0 R' + $infoTxt + ' /Prev ' + $prevXref + " >>`n" +
                 "startxref`n" + $xrefOffset + "`n%%EOF`n")
        $fs = [System.IO.File]::Open($PdfPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write)
        try {
            $tb = $lat.GetBytes($tail)
            $fs.Write($tb, 0, $tb.Length)
        } finally { $fs.Close() }
    } catch { }
}

function Export-HtmlAPdf {
    param([string]$HtmlPath, [string]$PdfPath)
    $edge = Find-Edge
    if ($null -eq $edge) {
        throw 'No se encontro Microsoft Edge (incluido en Windows 10/11). Abra el HTML en un navegador y use Ctrl+P -> Guardar como PDF.'
    }
    $dir = Split-Path -Parent $PdfPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (Test-Path -LiteralPath $PdfPath) { Remove-Item -LiteralPath $PdfPath -Force }
    try {
        foreach ($d in @(Get-ChildItem ([System.IO.Path]::GetTempPath()) -Directory -Filter 'RepCambiosEdge_*' -ErrorAction SilentlyContinue)) {
            if ($d.CreationTimeUtc -lt (Get-Date).ToUniversalTime().AddHours(-6)) {
                Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    } catch { }
    $uri = ([System.Uri](Resolve-Path -LiteralPath $HtmlPath).Path).AbsoluteUri
    $ultimoErr = ''
    $modos = @('--headless','--headless=old')
    for ($intento = 0; $intento -lt $modos.Count; $intento++) {
        # Perfil temporal UNICO por intento: evita bloqueos de instancias previas.
        $perfil = Join-Path ([System.IO.Path]::GetTempPath()) ('RepCambiosEdge_' + [Guid]::NewGuid().ToString('N'))
        $timedOut = $false
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $edge
        $psi.Arguments = ($modos[$intento] + ' --disable-gpu --disable-extensions --no-first-run --no-default-browser-check ' +
                          '--user-data-dir="' + $perfil + '" --no-pdf-header-footer --print-to-pdf-no-header ' +
                          '--print-to-pdf="' + $PdfPath + '" "' + $uri + '"')
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $errTask = $proc.StandardError.ReadToEndAsync()
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        if (-not $proc.WaitForExit(300000)) {
            try { $proc.Kill() } catch { }
            $ultimoErr = 'Tiempo de espera agotado (5 min).'
            $timedOut = $true
        } else {
            $errTxt = ''
            try { $errTxt = ('' + $errTask.Result).Trim() } catch { }
            $ultimoErr = ('Codigo de salida ' + $proc.ExitCode)
            if ($errTxt -ne '') { $ultimoErr += '. ' + $errTxt }
        }
        # Edge puede delegar la impresion a un proceso hijo y salir de inmediato
        # (codigo 0): esperar a que el PDF aparezca y termine de escribirse.
        $esperaMs = 30000
        if ($timedOut) { $esperaMs = 5000 } elseif ($intento -eq 0) { $esperaMs = 60000 }
        $ok = Wait-ArchivoPdf -PdfPath $PdfPath -TimeoutMs $esperaMs
        try { Remove-Item -LiteralPath $perfil -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        if ($ok) {
            Set-PdfScrollContinuo -PdfPath $PdfPath
            return
        }
    }
    if ($ultimoErr.Length -gt 500) { $ultimoErr = $ultimoErr.Substring(0, 500) + '...' }
    throw ('Edge no pudo generar el PDF. Detalle: ' + $ultimoErr)
}

# ============================================================================
#  MOTOR PRINCIPAL
# ============================================================================

function New-SvnChangeReport {
    param(
        [string]$ProjectPath,
        [string]$Desde,
        [string]$Hasta,
        [string[]]$Modulos,
        [string[]]$Extensiones,
        [string]$Salida,
        [bool]$IncluirResumen = $true,
        [bool]$ExportarPdf = $false,
        [string]$RutaPdf = '',
        [string]$AutorReporte = '',
        [string]$Vcs = 'auto',
        [string]$OrdenRev = 'asc',
        [bool]$ExclMvnRelease = $false,
        [bool]$ExclMvnPrepare = $false,
        [bool]$ExportarZip = $false,
        [scriptblock]$OnProgress,
        [scriptblock]$ShouldCancel
    )

    $mods = Split-Lista -Valores $Modulos
    $exts = Split-Lista -Valores $Extensiones

    $ordenN = ('' + $OrdenRev).Trim().ToLower()
    if ($ordenN -ne 'asc' -and $ordenN -ne 'desc') {
        throw ('Valor de -Orden no valido: "' + $OrdenRev + '". Use asc (antiguas primero) o desc (recientes primero).')
    }

    $objetivo = ('' + $ProjectPath).Trim()
    if ($objetivo -eq '') { throw 'Debe indicar la URL o ruta del proyecto (SVN o Git).' }
    if ($objetivo -notmatch '^[A-Za-z][A-Za-z0-9+\.\-]*://') {
        if (Test-Path -LiteralPath $objetivo) { $objetivo = (Resolve-Path -LiteralPath $objetivo).Path }
    }

    $kind = Get-VcsTipo -Objetivo $objetivo -Preferencia $Vcs
    $url = ''; $root = ''; $dirGit = ''
    if ($kind -eq 'svn') {
        if (-not (Test-SvnDisponible)) { throw 'No se encontro svn.exe en el PATH. Instale un cliente SVN de linea de comandos.' }
        if ($null -ne $OnProgress) { & $OnProgress 0 1 'Consultando informacion del repositorio (SVN)...' }
        $info = Get-SvnInfoXml -Target $objetivo
        $url = $info.Url
        $root = $info.Root
    } else {
        if ($objetivo -match '^[A-Za-z][A-Za-z0-9+\.\-]*://') { throw 'Para repositorios Git indique la carpeta local del clon (no una URL).' }
        if (-not (Test-GitDisponible)) { throw 'No se encontro git.exe en el PATH. Instale Git para Windows.' }
        if ($null -ne $OnProgress) { & $OnProgress 0 1 'Consultando informacion del repositorio (Git)...' }
        $rt = Invoke-GitRaw -Argumentos @('-C', $objetivo, 'rev-parse', '--show-toplevel')
        if ($rt.ExitCode -ne 0) { throw ("La carpeta no es un repositorio Git valido:`n" + $rt.StdErr) }
        $dirGit = (Convert-BytesToText -Bytes $rt.Bytes).Trim()
        $rr = Invoke-GitRaw -Argumentos @('-C', $objetivo, 'config', '--get', 'remote.origin.url')
        $remoto = ''
        if ($rr.ExitCode -eq 0) { $remoto = (Convert-BytesToText -Bytes $rr.Bytes).Trim() }
        if ($remoto -ne '') { $url = $remoto } else { $url = $dirGit.Replace('\','/') }
    }

    $modPat = (@($mods | ForEach-Object { [regex]::Escape($_) }) -join '|')
    $extPat = (@($exts | ForEach-Object { [regex]::Escape($_) }) -join '|')
    if ($mods.Count -gt 0 -and $exts.Count -gt 0) {
        $patron = New-Object System.Text.RegularExpressions.Regex ("/($modPat)\.($extPat)$", 'IgnoreCase')
    } elseif ($mods.Count -gt 0) {
        $patron = New-Object System.Text.RegularExpressions.Regex ("/($modPat)(\.[A-Za-z0-9]+)?$", 'IgnoreCase')
    } elseif ($exts.Count -gt 0) {
        $patron = New-Object System.Text.RegularExpressions.Regex ("\.($extPat)$", 'IgnoreCase')
    } else {
        $patron = New-Object System.Text.RegularExpressions.Regex ('.', 'IgnoreCase')  # todos los archivos
    }
    $patronOtraX = New-Object System.Text.RegularExpressions.Regex ("/($modPat)\.([A-Za-z0-9]+)$", 'IgnoreCase')

    $vcsNombre = 'SVN'
    $prefRev = 'r'
    if ($kind -eq 'git') { $vcsNombre = 'Git'; $prefRev = '' }
    if ($null -ne $OnProgress) { & $OnProgress 0 1 ('Consultando log ' + $vcsNombre + '...') }
    if ($kind -eq 'git') {
        $entradas = Get-GitLogEntradas -Dir $dirGit -DesdeV $Desde -HastaV $Hasta -Patron $patron
    } else {
        $rangoExpr = (ConvertTo-RevExpr -Valor $Desde) + ':' + (ConvertTo-RevExpr -Valor $Hasta)
        $entradas = Get-LogEntradas -Url $url -Rango $rangoExpr -Patron $patron
    }
    $matched = @($entradas | Where-Object { $_.Targets.Count -gt 0 })
    if ($ExclMvnRelease) { $matched = @($matched | Where-Object { -not (Test-CommitMavenRelease -Msg $_.Msg) }) }
    if ($ExclMvnPrepare) { $matched = @($matched | Where-Object { -not (Test-CommitMavenPrepare -Msg $_.Msg) }) }
    if ($ordenN -eq 'desc' -and $matched.Count -gt 1) { [array]::Reverse($matched) }

    # --- Descarga de diffs (secuencial) ---
    $parsedPorRev = @{}
    $modCount = @{}
    $totArchivos = 0
    $totHunks = 0
    $idx = 0
    $svnPomFallos = 0
    foreach ($e in $matched) {
        $idx++
        if ($null -ne $ShouldCancel -and (& $ShouldCancel)) { throw (New-Object System.OperationCanceledException 'Operacion cancelada por el usuario.') }
        if ($null -ne $OnProgress) { & $OnProgress $idx $matched.Count ('Descargando diff ' + $prefRev + $e.Rev + '  (' + $idx + '/' + $matched.Count + ')') }

        # Version: primero del mensaje del commit; si no hay, del pom.xml (Maven).
        $vers = Get-VersionesDeMensaje -Msg $e.Msg
        if ($vers.Count -eq 0) {
            $vPom = ''
            if ($kind -eq 'git') {
                $fullRevV = $e.Rev
                if (('' + $e.FullRev).Trim() -ne '') { $fullRevV = $e.FullRev }
                $vPom = Get-PomVersionGit -Dir $dirGit -FullRev $fullRevV
            } elseif ($svnPomFallos -lt 2) {
                $vPom = Get-PomVersionSvn -Url $url -Rev $e.Rev
                if ($vPom -eq '') { $svnPomFallos++ }
            }
            if ($vPom -ne '') { $vers = @($vPom) }
        }
        $e | Add-Member -NotePropertyName Versiones -NotePropertyValue @($vers) -Force

        if ($kind -eq 'git') {
            $fullRev = $e.Rev
            if (('' + $e.FullRev).Trim() -ne '') { $fullRev = $e.FullRev }
            $texto = Get-GitDiffCommit -Dir $dirGit -FullRev $fullRev -Targets $e.Targets
        } else {
            $texto = Get-DiffRevision -Root $root -Rev $e.Rev -Targets $e.Targets
        }
        $errRev = $null
        $secciones = @{}
        if ($texto.StartsWith('@@ERROR@@')) { $errRev = $texto.Substring(9) }
        elseif ($kind -eq 'git') { $secciones = Split-SeccionesGit -DiffTexto $texto }
        else { $secciones = Split-Secciones -DiffTexto $texto }

        $archivos = New-Object System.Collections.Specialized.OrderedDictionary
        foreach ($t in @($e.Targets | Sort-Object { $_.Path.Split('/')[-1] })) {
            $base = $t.Path.Split('/')[-1]
            $modNombre = $base.Split('.')[0].ToUpper()
            if ($modCount.ContainsKey($modNombre)) { $modCount[$modNombre] = $modCount[$modNombre] + 1 } else { $modCount[$modNombre] = 1 }
            $totArchivos++

            $infoArch = @{
                Action = $t.Action; Path = $t.Path; Deleted = $false; Missing = $false
                Err = $null; Binario = $false; SoloProp = $false; Hunks = $null; Resumen = ''
            }
            if ($t.Action -eq 'D') {
                $infoArch.Deleted = $true
            } else {
                $sec = $null
                foreach ($k in $secciones.Keys) {
                    if ($k -ieq $base) { $sec = $secciones[$k]; break }
                }
                if ($null -eq $sec) {
                    $infoArch.Missing = $true
                    $infoArch.Err = $errRev
                } else {
                    $res = ConvertTo-Hunks -Lineas $sec
                    $infoArch.Hunks = $res.Hunks
                    $infoArch.Binario = $res.Binario
                    $infoArch.SoloProp = $res.SoloProp
                    $totHunks += $res.Hunks.Count
                    if ($IncluirResumen -and $res.Hunks.Count -gt 0) {
                        $infoArch.Resumen = New-ResumenArchivo -Hunks $res.Hunks
                    }
                }
            }
            $archivos[$base] = $infoArch
        }
        $parsedPorRev[$e.Rev] = $archivos
    }

    if ($null -ne $OnProgress) { & $OnProgress $matched.Count $matched.Count 'Generando documento HTML...' }

    # --- HTML ---
    $css = @'
body{font-family:'Segoe UI',Arial,sans-serif;margin:0;background:#f0f2f5;color:#1f2328}
.wrap{max-width:1500px;margin:0 auto;padding:18px}
h1{font-size:22px;margin:8px 0}
h2{font-size:17px;margin:0}
.meta{color:#57606a;font-size:12px}
.cover{background:#fff;border:1px solid #d0d7de;border-radius:8px;padding:18px 22px;margin:14px 0}
.coverrow{display:flex;justify-content:space-between;align-items:flex-start;gap:18px}
.coverlogo{width:84px;height:84px;object-fit:contain;flex:0 0 auto}
.cover .brand{font-size:11px;letter-spacing:3px;color:#57606a;text-transform:uppercase;font-weight:700}
.cover h1{margin:6px 0 2px 0;font-size:24px}
.cover .sub{color:#57606a;font-size:13px;margin-bottom:10px}
table.info{border-collapse:collapse;font-size:12.5px;margin-top:6px}
table.info td{border:1px solid #d0d7de;padding:5px 10px}
table.info td:first-child{background:#f6f8fa;font-weight:600;width:170px;white-space:nowrap}
.card{background:#fff;border:1px solid #d0d7de;border-radius:8px;margin:16px 0;overflow:hidden}
.card>.hd{padding:10px 14px;background:#f6f8fa;border-bottom:1px solid #d0d7de;display:flex;flex-wrap:wrap;gap:10px;align-items:baseline}
.badge{display:inline-block;background:#0969da;color:#fff;border-radius:12px;padding:1px 10px;font-size:12px;font-weight:600}
.badge.ver{background:#8250df}
.badge.aut{background:#57606a}
.msg{white-space:pre-wrap;background:#fffbe6;border:1px solid #d4a72c66;border-radius:6px;margin:10px 14px;padding:8px 12px;font-size:13px}
.expl{background:#ddf4ff;border:1px solid #54aeff66;border-radius:6px;margin:8px 14px;padding:6px 10px;font-size:12.5px}
table.toc{width:100%;border-collapse:collapse;background:#fff;font-size:12.5px}
table.toc th,table.toc td{border:1px solid #d0d7de;padding:5px 8px;text-align:left;vertical-align:top}
table.toc th{background:#f6f8fa}
table.diff{width:100%;border-collapse:collapse;table-layout:fixed;font-family:Consolas,'Courier New',monospace;font-size:11.5px}
table.diff td{border:0;padding:1px 6px;vertical-align:top;word-wrap:break-word;overflow-wrap:anywhere;white-space:pre-wrap}
td.num{width:44px;min-width:44px;color:#8c959f;text-align:right;background:#f6f8fa;border-right:1px solid #d0d7de;user-select:none}
td.del{background:#ffebe9}
td.add{background:#e6ffec}
td.empty{background:#f0f2f5}
td.ctx{background:#fff}
tr.hunkhdr td{background:#ddf4ff;color:#0550ae;padding:3px 8px;font-weight:600;border-top:1px solid #d0d7de;border-bottom:1px solid #d0d7de}
details.file{margin:10px 14px;border:1px solid #d0d7de;border-radius:6px;overflow:hidden}
details.file>summary{cursor:pointer;background:#f6f8fa;padding:7px 12px;font-weight:600;font-size:13px}
.small{font-size:11px;color:#57606a}
.filehalf{background:#fafbfc;border-bottom:1px solid #d0d7de;padding:3px 10px;font-size:11px;color:#57606a;display:flex}
.filehalf div{flex:1}
.btns{position:sticky;top:0;z-index:9;background:#f0f2f5;padding:8px 0}
button{background:#0969da;color:#fff;border:0;border-radius:6px;padding:6px 12px;font-size:12.5px;cursor:pointer;margin-right:8px}
.nochange{background:#fff;border:1px dashed #d0d7de;border-radius:8px;padding:10px 14px;font-size:13px}
a{color:#0969da;text-decoration:none} a:hover{text-decoration:underline}
@page{size:landscape;margin:8mm}
@media print{ .btns{display:none} body{background:#fff} .card{page-break-before:always} details.file{page-break-inside:auto} details.file>summary{page-break-after:avoid} .filehalf{page-break-after:avoid} .expl{page-break-after:avoid} .msg{page-break-inside:avoid} table.diff tr{page-break-inside:avoid} table.toc tr{page-break-inside:avoid} }
'@
    $js = ('function setAll(open){document.querySelectorAll("details.file").forEach(function(d){d.open=open;});}' +
           'function invertirOrden(){' +
           'var t=document.getElementById("idxrev");' +
           'if(t&&t.rows.length>2){var b=t.tBodies[0];var rs=Array.prototype.slice.call(b.rows,1);var mk=document.createComment("x");b.appendChild(mk);rs.reverse().forEach(function(r){b.insertBefore(r,mk);});b.removeChild(mk);}' +
           'var cs=Array.prototype.slice.call(document.querySelectorAll("div.card"));' +
           'if(cs.length>1){var p=cs[0].parentNode;var m2=document.createComment("y");p.insertBefore(m2,cs[0]);cs.reverse().forEach(function(c){p.insertBefore(c,m2);});p.removeChild(m2);}' +
           '}' +
           'window.addEventListener("beforeprint",function(){document.querySelectorAll("details").forEach(function(d){d.setAttribute("data-wasopen",d.open?"1":"0");d.open=true;});});' +
           'window.addEventListener("afterprint",function(){document.querySelectorAll("details").forEach(function(d){if(d.getAttribute("data-wasopen")==="0"){d.open=false;}d.removeAttribute("data-wasopen");});});')

    $logoB64 = @(
'iVBORw0KGgoAAAANSUhEUgAAAF4AAABgCAYAAACUosWzAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAACxIAAAsSAdLdfvwAAAlhSURB',
'VHhe7Z1pjF5VGcd/722ndOpAS5kybHYLUK20DbhgpbVxZ0cTDZsWCFhECCr94JIoJMZW0UZZglErEcMeFSiaWBUqJAQDSqAFWiylWlu6UDp1pkBnOu87fnne',
'ePt47nLOPXeb8Zf8P/T03vOc+9wz557lOedtUD0awETgJGAOMAuYARwLTAEmAZ1AB9AEBoB+YA+wHdgCbALWA8/Kvw9oI2XT0AklMRFYCHwC+DBwIjBWX+TI',
'HuBJ4BHgD8AGeWGjli7gfOBhYD8wXIBawGZgOTBPF2ik8w7gZmCvwTFFqgU8B3weeJsu5EihAbwfWCUPrJ1QtnYDNwCTdcHrzDzgtxV1uFYfcD1wmH6IOtEN',
'/AQYMjxg1bUDWAwE+qGqzoXAa4YHqpselx5W5ekGHjA8QJ31JnBNlWv/ImCboeAjRauAI/RDl0kD+LKMDnVhR5o2AydrB5RBB/BTQwFHst4APqkdUSSd0k3U',
'BRsNGgKWaIcUQRfwqKFAo0lN4CvaMXnSKRNOuiBZ1F/T/n4LuE47KA865OuuC5BFW4FDpSv6EWApcAewrsDJsyxqAVdoR/mkAdxmMJxVN2hDITqBBfIy7pe5',
'dX1/FXQAOF0X3hdfNBj0oVO0oQTeLiPj24C1FerG7gXeqQublfnAoMFYVu0DDtHGLJkMnAl8D/iLjDS1naK0QZpNLxwO/NNgxIc2amMe6JKVrBuBp4C3DHbz',
'1L26QK7cacjcl9ZoYznQBZwF/EiapqahHL61WBfClnMNmfrU/dpgAXQDFwEr5S85j3WCXuAYbTgthwL/MmTqUyu10RKYBVwNPCgL47qMrvq1NpSW5YbMfOsW',
'bbRkxgGnAcuAv2XsULTkW2PF9IIGL9/XhivGZOCzwF3Aq4byJ+l5YIzONI6fGzLJQzdqwxUmkDHHcssm6XKdURQzM/6J2ajqNT6KHuBpw/OYtNkUnGVazloq',
'czJFYLJfB3YCn5IBYBLTgc/pRM1kmejXby0v3aoLUDNuMjyTSWt1uKSucYuBCSotinXAVTI4ORO4GPiqfB+ekqF7ElmnC8rmQZ0QwRzggzqxTQN40fC2ojRX',
'Z6AYC7xHFgtWRYTs3aVvqhndFiPhyGd9t+HiKO2XobgN4yQieAXwdynwQ/qimtGQ6DPtH5P6oybQvmu4OEpb9M2WNOTP7zrg1KgC1YSNBv9E6WJ9cwC8Yrgw',
'So/pDByZL/kNygfox8Blsinhf7pgFeWvBv9E6QF98yzLyaJf6gwcOcWQd1v9wGpZofp4hf8q1hjKHqVe3VW/ynBRnJaHb87Auwx5R2kIeEa6cJ8BjtZdtJL4',
'naGscVpIqDv5oYPzSuRVneDIfp0QwxiJ4rpWppO3ykf6VgkwOlzfUBA2z4As6IM8kO0E0AUH5+XMcYa8XTUI/FlezDRtKEfuNpQlTqvbNx5l2b4PAx892LYz',
'RzrYTqMW8ISEXdh2e235hcF+nHYCjUC6dbZt5V6d4MiQOMk3DeADwM9kMec7OTZFtjsIjwR6AmC2/p8U9OkER5o5OT7MJOAbwEvAefo/PWDreIC5AXC8Tk1g',
'OOU8TBryqvEmpgC/kS2ePhnSCSk4IQCm6tQU2H7JoyjS8UgvboXnwZlLjZ8aOK6GD+oER4poajTHSG+qTI4OZIbNhmHHt2yiDMc3PDvetmMC0B3IOQK2+HL8',
'sER6FU2PTsiAXtNIw8TAcTu5y1uOogzHT9IJGXBx/ITA8UPzf8f/FxfHd7jc1HB8WVGU4XifM51OgQGB4yE643RCBnyNCWzwOY3g4osDgeODuxiLoowa79Px',
'LjX+jQD4t05NoCFbZHyxUycUgE/Hu1TCvkDOarElbQhIGv6oEwrAp+PH64QUvBY4Lmr4/DjdJwsaReLT8S6VcHsgwfm2uAy6otgPnCMrSkXhMnaJwiWvLQHw',
'sk5Ngc9+MFLj5wE/lPnzvHGppVG4OH5jIOcz2pLH2V17JM5mmiyCL5VlMpdeVxI+He9yjNY6HJf+vqlzypFOWWr8gcd9rT6bNdsg3x3tkf8YhwN+btLWC6QH',
'uEQWmW0X6dva5TjU13Q4nMHw+3AG9xouiNPd4ZtLZIwEz35dAovSbi7u9TTtcZhF0Gpb14cz+ILhgjj9KXxzhZgAnC2b2jYYyt2Wjx3lODbTC8IZnGiZwQvh',
'myvMdOBK2fq4O1T+AU+j75kG38Rpj55iCOQEan1hlHZ7nhougg7gfRKL+YSncI95Bt/Eybj31WZfq0t8fNV4WaJ3r5ZTN1w+tosMvonThToDEiJ3tVqe1y3L',
'4B/qebYBt0uPaYa+OAKbYN++qMpquxXnNJ1BzVhveKawtklvb6mcaX+U9ISCUABt+OUl6U5dgDDXGm6IUuIWwopjU8na2ie/ymCzwbityM1nyAdnn+Emk+KO',
'tKoDSTXep55L0xm5xXCjSQMSDOp7wqwobHpxWXWJNm5ihuWW+r3yAo7VGVWcXYZnyUOv2IySVxoySNKgBIWe67gqUySBRZOaVZdp43FMy3iW1+uyRWaR45pk',
'3nRJU6nL7VtrbY9NAfi2ISMX7ZZtlGd4ngfPQo/lFImLmsDHtOE0dOVwwOab0hwtcQwP98VcQ9l861faqA3n5FwznpflvrM9r+MmcZ6hLD71umwHzcQdhozz',
'0IAc2LlMzvLyMYkVxdcM9n2pJcdpZWainDKkDeStAdlQvEIO5TkuzSAkJfcZ7PlS7NSALacW1AuIU0vWSu+RqY35UZNOCbjs602r9Y5RB7HYrlIVoaYMx2+X',
'l7FQRtJxU7y2c+hp1StnQninIX1zbbBqakpszmqJTFgi44mp0p292XBPVg3IQRe5MVa6g9pwXfSWQ1RAkprApdpReXCIBJrqAoxGtaSJK4wJOfxOSN3UBL6k',
'HVMEnXKmmC7QaNBg3r8LksRY+cmIPEe3VVOfjOgrwTUV6OcXoU1y2kmlWCADHF3YkaKHqrzadoQE7YykpmefxN74mq7IlfNlNV4/RN30qMOxMqUzSRZAbNZv',
'q6KtcjhnLWp5FLOlfaxD89MLfKtCK2VeeK+8ANt48iK0S+LWK/vx9MEJsqOk7B9Tb8qvHlw+0mp4EuOBT8sZ7GlPpM6qlsyZL8vjd/lsqMrHY7wEhp4uc+qz',
'PYaF7JAfElgDPBw6vLpUquJ4TaeEjc+RxYWZcpbYFGmHO2W6oiUj5n4JJN0ukRGbpGY/HRrUVYr/AJVhOL78Kt9fAAAAAElFTkSuQmCC'
) -join ''
    $nl = "`n"
    $sb = New-Object System.Text.StringBuilder (4MB)
    $ahora = (Get-Date).ToString('yyyy-MM-dd HH:mm')

    [void]$sb.Append("<!DOCTYPE html><html lang='es'><head><meta charset='utf-8'>$nl")
    [void]$sb.Append("<title>Reporte de cambios por archivo - Napse Global &middot; TOTVS</title>$nl")
    [void]$sb.Append("<style>$css</style><script>$js</script></head><body><div class='wrap'>$nl")
    $extsTxt = '(cualquier extensi&oacute;n)'
    if ($exts.Count -gt 0) { $extsTxt = '(.' + (HtmlEnc ($exts -join ' / .')) + ')' }
    $modsTxt = '(todos los archivos)'
    if ($mods.Count -gt 0) { $modsTxt = HtmlEnc ($mods -join ', ') }
    [void]$sb.Append("<div class='cover'><div class='coverrow'><div>$nl")
    [void]$sb.Append("<div class='brand'>Napse Global &middot; TOTVS</div>$nl")
    [void]$sb.Append("<h1>Reporte de cambios por archivo</h1>$nl")
    [void]$sb.Append(("<div class='sub'>Control de cambios sobre repositorio {0}</div>$nl" -f $vcsNombre))
    [void]$sb.Append("<table class='info'>$nl")
    [void]$sb.Append(("<tr><td>Repositorio</td><td>{0}</td></tr>$nl" -f (HtmlEnc $url)))
    [void]$sb.Append(("<tr><td>Rango analizado</td><td>{0} &rarr; {1}</td></tr>$nl" -f (HtmlEnc $Desde), (HtmlEnc $Hasta)))
    [void]$sb.Append(("<tr><td>Filtro de archivos</td><td>{0} &nbsp;{1}</td></tr>$nl" -f $modsTxt, $extsTxt))
    $excl = New-Object System.Collections.ArrayList
    if ($ExclMvnRelease) { [void]$excl.Add('commits de mvn release ([maven-release-plugin] prepare release)') }
    if ($ExclMvnPrepare) { [void]$excl.Add('commits de mvn prepare (prepare for next development iteration)') }
    if ($excl.Count -gt 0) {
        [void]$sb.Append(("<tr><td>Exclusiones</td><td>{0}</td></tr>$nl" -f (HtmlEnc ($excl -join '; '))))
    }
    [void]$sb.Append(("<tr><td>Fecha de generaci&oacute;n</td><td>{0}</td></tr>$nl" -f $ahora))
    $autorTxt = '&mdash;'
    if (('' + $AutorReporte).Trim() -ne '') { $autorTxt = HtmlEnc ($AutorReporte.Trim()) }
    [void]$sb.Append(("<tr><td>Autor</td><td>{0}</td></tr>$nl" -f $autorTxt))
    [void]$sb.Append("<tr><td>Compa&ntilde;&iacute;a</td><td>Napse Global</td></tr>$nl")
    [void]$sb.Append("</table></div>$nl")
    [void]$sb.Append("<img class='coverlogo' src='data:image/png;base64,$logoB64' alt='TOTVS'>$nl")
    [void]$sb.Append("</div></div>$nl")
    [void]$sb.Append("<div class='btns'><button onclick='setAll(true)'>Expandir todo</button><button onclick='setAll(false)'>Colapsar todo</button><button onclick='invertirOrden()'>Invertir orden</button></div>$nl")

    [void]$sb.Append(("<h2 style='margin-top:14px'>Resumen general</h2><p class='meta'>{0} revisiones afectan los archivos listados. Total de cambios por archivo:</p>$nl" -f $matched.Count))
    [void]$sb.Append("<table class='toc'><tr><th>Archivo</th><th># Revisiones que lo modifican</th></tr>$nl")
    foreach ($k in @($modCount.Keys | Sort-Object { -$modCount[$_] })) {
        [void]$sb.Append(("<tr><td>{0}</td><td>{1}</td></tr>$nl" -f (HtmlEnc $k), $modCount[$k]))
    }
    [void]$sb.Append("</table>$nl")

    $sinCambios = @($mods | Where-Object { -not $modCount.ContainsKey($_.ToUpper()) })
    if ($sinCambios.Count -gt 0) {
        $extsNota = ''
        if ($exts.Count -gt 0) { $extsNota = ' (.' + (HtmlEnc ($exts -join '/.')) + ')' }
        [void]$sb.Append(("<p class='nochange'><b>Archivos sin cambios{0} en el periodo:</b> {1}" -f $extsNota, (HtmlEnc ($sinCambios -join ', '))))
        if ($exts.Count -gt 0) {
            $notas = New-Object System.Collections.ArrayList
            foreach ($e in $entradas) {
                foreach ($o in @($e.Others)) {
                    $m2 = $patronOtraX.Match($o.Path)
                    if ($m2.Success) {
                        $modU = $m2.Groups[1].Value.ToUpper()
                        $extU = $m2.Groups[2].Value.ToUpper()
                        $esExtFiltrada = $false
                        foreach ($x in $exts) { if ($x -ieq $extU) { $esExtFiltrada = $true; break } }
                        $esSinCambio = $false
                        foreach ($x in $sinCambios) { if ($x -ieq $modU) { $esSinCambio = $true; break } }
                        if ($esSinCambio -and -not $esExtFiltrada) {
                            $nota = ('{0}.{1} (r{2})' -f $modU, $m2.Groups[2].Value, $e.Rev)
                            if (-not ($notas -contains $nota)) { [void]$notas.Add($nota) }
                        }
                    }
                }
            }
            if ($notas.Count -gt 0) {
                [void]$sb.Append(("<br><span class='small'>Nota: hubo cambios con otra extensi&oacute;n (fuera del filtro): {0}</span>" -f (HtmlEnc (@($notas | Sort-Object) -join ', '))))
            }
        }
        [void]$sb.Append("</p>$nl")
    }

    [void]$sb.Append("<h2>&Iacute;ndice de revisiones</h2>$nl")
    $colRev = 'Revisi&oacute;n'
    if ($kind -eq 'git') { $colRev = 'Commit' }
    [void]$sb.Append("<table class='toc' id='idxrev'><tr><th style='width:80px'>$colRev</th><th style='width:110px'>Fecha</th><th style='width:90px'>Versi&oacute;n</th><th style='width:110px'>Autor</th><th>Archivos afectados (del filtro)</th><th>Descripci&oacute;n</th></tr>$nl")
    foreach ($e in $matched) {
        $vs = @($e.Versiones)
        $vsTxt = '&mdash;'
        if ($vs.Count -gt 0) { $vsTxt = HtmlEnc ($vs -join ', ') }
        $modsRev = @($e.Targets | ForEach-Object { $_.Path.Split('/')[-1] } | Sort-Object -Unique) -join ', '
        [void]$sb.Append(("<tr><td><a href='#r{0}'>{6}{0}</a></td><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td><td>{5}</td></tr>$nl" -f $e.Rev, $e.Date.Substring(0,10), $vsTxt, (HtmlEnc $e.Author), (HtmlEnc $modsRev), (HtmlEnc (Get-DescripcionCorta -Msg $e.Msg)), $prefRev))
    }
    [void]$sb.Append("</table>$nl")

    foreach ($e in $matched) {
        $vs = @($e.Versiones)
        [void]$sb.Append(("<div class='card' id='r{0}'><div class='hd'>$nl" -f $e.Rev))
        [void]$sb.Append(("<span class='badge'>{1}{0}</span>$nl" -f $e.Rev, $prefRev))
        foreach ($v in $vs) { [void]$sb.Append(("<span class='badge ver'>v{0}</span>$nl" -f (HtmlEnc $v))) }
        [void]$sb.Append(("<span class='badge aut'>{0}</span>$nl" -f (HtmlEnc $e.Author)))
        [void]$sb.Append(("<h2>{0}</h2></div>$nl" -f (HtmlEnc $e.Date)))
        $msgHtml = '(sin mensaje)'
        if ($e.Msg -ne '') { $msgHtml = HtmlEnc $e.Msg }
        [void]$sb.Append(("<div class='msg'><b>Descripci&oacute;n del commit:</b>$nl{0}</div>$nl" -f $msgHtml))

        $archivos = $parsedPorRev[$e.Rev]
        foreach ($base in $archivos.Keys) {
            $ia = $archivos[$base]
            $accion = $ia.Action
            switch ($ia.Action) {
                'M' { $accion = 'Modificado' }
                'A' { $accion = 'Agregado' }
                'D' { $accion = 'Eliminado' }
                'R' { $accion = 'Reemplazado' }
            }
            [void]$sb.Append(("<details class='file' open><summary>{0} <span class='small'>({1} &mdash; {2})</span></summary>$nl" -f (HtmlEnc $base), $accion, (HtmlEnc $ia.Path)))
            if ($ia.Deleted) {
                [void]$sb.Append("<div class='expl'>Archivo eliminado en esta revisi&oacute;n.</div>$nl")
            } elseif ($ia.Missing) {
                $msgErr = 'No se obtuvo diff (posible cambio solo de propiedades).'
                if ($null -ne $ia.Err -and ('' + $ia.Err).Trim() -ne '') { $msgErr = '' + $ia.Err }
                [void]$sb.Append(("<div class='expl'>&#9888; {0}</div>$nl" -f (HtmlEnc $msgErr)))
            } elseif ($ia.Binario) {
                [void]$sb.Append("<div class='expl'>Archivo binario: no es posible mostrar diff textual.</div>$nl")
            } elseif ($ia.SoloProp) {
                [void]$sb.Append("<div class='expl'>Solo cambios de propiedades SVN (sin cambios de contenido).</div>$nl")
            } else {
                if ($IncluirResumen -and $ia.Resumen -ne '') {
                    [void]$sb.Append(("<div class='expl'><b>Resumen:</b> {0}</div>$nl" -f (HtmlEnc $ia.Resumen)))
                }
                [void]$sb.Append("<div class='filehalf'><div>&#9664; ANTES (izquierda)</div><div>DESPU&Eacute;S (derecha) &#9654;</div></div>$nl")
                [void]$sb.Append("<table class='diff'><colgroup><col style='width:44px'><col><col style='width:44px'><col></colgroup>$nl")
                foreach ($h in @($ia.Hunks)) {
                    [void]$sb.Append(("<tr class='hunkhdr'><td colspan='4'>{0}</td></tr>$nl" -f (HtmlEnc $h.Header)))
                    foreach ($r in @($h.Rows)) {
                        $tipo = $r[0]
                        $on = '' + $r[1]; $ot = HtmlEnc ('' + $r[2])
                        $nn = '' + $r[3]; $nt = HtmlEnc ('' + $r[4])
                        if ($tipo -eq 'ctx') {
                            [void]$sb.Append("<tr><td class='num'>$on</td><td class='ctx'>$ot</td><td class='num'>$nn</td><td class='ctx'>$nt</td></tr>$nl")
                        } elseif ($tipo -eq 'rep') {
                            [void]$sb.Append("<tr><td class='num'>$on</td><td class='del'>$ot</td><td class='num'>$nn</td><td class='add'>$nt</td></tr>$nl")
                        } elseif ($tipo -eq 'del') {
                            [void]$sb.Append("<tr><td class='num'>$on</td><td class='del'>$ot</td><td class='num'></td><td class='empty'></td></tr>$nl")
                        } else {
                            [void]$sb.Append("<tr><td class='num'></td><td class='empty'></td><td class='num'>$nn</td><td class='add'>$nt</td></tr>$nl")
                        }
                    }
                }
                [void]$sb.Append("</table>$nl")
            }
            [void]$sb.Append("</details>$nl")
        }

        if ($e.Others.Count -gt 0) {
            [void]$sb.Append(("<details class='file'><summary class='small'>Otras rutas modificadas en esta revisi&oacute;n (fuera del filtro): {0}</summary><div style='padding:8px 12px;font-size:11.5px'>$nl" -f $e.Others.Count))
            foreach ($o in @($e.Others)) {
                [void]$sb.Append(("<div>[{0}] {1}</div>$nl" -f (HtmlEnc $o.Action), (HtmlEnc $o.Path)))
            }
            [void]$sb.Append("</div></details>$nl")
        }
        [void]$sb.Append("</div>$nl")
    }

    $cmdTxt = 'svn log --xml + svn diff -c REV'
    if ($kind -eq 'git') { $cmdTxt = 'git log --name-status + git diff commit^..commit' }
    [void]$sb.Append(("<p class='small'>Documento generado con ReporteCambiosSVN.ps1 ({0}). Para una &quot;captura&quot; imprimible: Ctrl+P &rarr; Guardar como PDF.</p>$nl" -f $cmdTxt))
    [void]$sb.Append("<p class='small'>Autor: Jair Salda&ntilde;a &middot; Napse Global &mdash; <b>Napse ahora es TOTVS</b>.</p>$nl")
    [void]$sb.Append("</div></body></html>")

    # --- Salida ---
    $rutaSalida = ('' + $Salida).Trim()
    if ($rutaSalida -eq '') {
        $segs = @(($url -split '/') | Where-Object { $_ -ne '' })
        $proy = 'proyecto'
        if ($segs.Count -ge 2) { $proy = ($segs[$segs.Count-2] + '_' + $segs[$segs.Count-1]) }
        elseif ($segs.Count -ge 1) { $proy = $segs[$segs.Count-1] }
        $nombre = ('REPORTE_CAMBIOS_{0}_{1}_a_{2}.html' -f $proy, $Desde, $Hasta) -replace '[^\w\-\.]', '_'
        $rutaSalida = Join-Path ([Environment]::GetFolderPath('Desktop')) $nombre
    }
    $dir = Split-Path -Parent $rutaSalida
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($rutaSalida, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))

    $pdfGenerado = ''
    $pdfError = $null
    if ($ExportarPdf) {
        if ($null -ne $OnProgress) { & $OnProgress $matched.Count ([Math]::Max(1,$matched.Count)) 'Exportando a PDF (Microsoft Edge integrado)...' }
        $rutaPdfFinal = ('' + $RutaPdf).Trim()
        if ($rutaPdfFinal -eq '') { $rutaPdfFinal = [System.IO.Path]::ChangeExtension($rutaSalida, '.pdf') }
        try {
            Export-HtmlAPdf -HtmlPath $rutaSalida -PdfPath $rutaPdfFinal
            $pdfGenerado = $rutaPdfFinal
        } catch {
            $pdfError = $_.Exception.Message
        }
    }

    $zipGenerado = ''
    $zipError = $null
    if ($ExportarZip) {
        if ($null -ne $OnProgress) { & $OnProgress $matched.Count ([Math]::Max(1,$matched.Count)) 'Comprimiendo salida (ZIP)...' }
        $zipPath = [System.IO.Path]::ChangeExtension($rutaSalida, '.zip')
        try {
            if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
            $rutasZip = @($rutaSalida)
            if ($pdfGenerado -ne '' -and (Test-Path -LiteralPath $pdfGenerado)) { $rutasZip += $pdfGenerado }
            Compress-Archive -LiteralPath $rutasZip -DestinationPath $zipPath -Force
            $zipGenerado = $zipPath
        } catch {
            $zipError = $_.Exception.Message
        }
    }

    return New-Object PSObject -Property @{
        Salida     = $rutaSalida
        SalidaPdf  = $pdfGenerado
        PdfError   = $pdfError
        SalidaZip  = $zipGenerado
        ZipError   = $zipError
        Revisiones = $matched.Count
        Archivos   = $totArchivos
        Bloques    = $totHunks
        SinCambios = @($sinCambios)
    }
}

# ============================================================================
#  INTERFAZ GRAFICA (WinForms)
# ============================================================================

function Show-ReportGui {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $ttProj = "URL del repositorio SVN (https://...), carpeta de un working copy SVN`r`no carpeta local de un repositorio Git (clonado). Se detecta automaticamente.`r`nEjemplo: https://servidor/svn/repo/trunk  |  C:\repos\mi-proyecto"
    $ttDesde = "Inicio del rango a analizar.`r`nSVN: fecha (YYYY-MM-DD) o numero de revision.`r`nGit: fecha o commit/tag (el commit inicial no se incluye: rango desde..hasta).`r`nEjemplos: 2025-08-01  |  31490  |  1f95ed4"
    $ttHasta = "Fin del rango a analizar.`r`nSVN: fecha, numero de revision o HEAD.`r`nGit: fecha, commit/tag o HEAD."
    $ttArchivos = "Nombres de los archivos a identificar, separados por coma (sin ruta).`r`nEjemplo: SUBTSPAG,USRTTLOG,USRTDUMP`r`nVacio = se incluyen TODOS los archivos modificados.`r`nSe combinan con Extensiones; si escribe el nombre con extension (ej. VENTAS.BAS), deje Extensiones vacio."
    $ttExts = "Extensiones a considerar, separadas por coma. Ejemplo: BAS,DAT`r`nVacio = cualquier extension."
    $ttResumen = "Agrega a cada archivo un resumen del cambio generado localmente con reglas de texto (expresiones regulares):`r`nlineas agregadas/eliminadas, funciones nuevas o eliminadas, llamadas nuevas y temas detectados.`r`nNo usa IA ni servicios externos: el resultado es determinista."
    $ttSalida = "Ruta del archivo HTML a generar.`r`nVacio = se crea automaticamente en el Escritorio."
    $ttAutor = "Nombre que aparecera como Autor en la portada del reporte.`r`nSe recuerda para la proxima ejecucion."
    $ttOrden = "Orden de las revisiones en el reporte, por fecha.`r`nDentro del HTML tambien puedes cambiarlo con el boton 'Invertir orden'."
    $ttExclRel = "Omite los commits generados por el maven-release-plugin al hacer el release:`r`nmensajes '[maven-release-plugin] prepare release ...'."
    $ttExclPrep = "Omite los commits del maven-release-plugin que saltan a la siguiente version SNAPSHOT:`r`nmensajes '[maven-release-plugin] prepare for next development iteration'."
    $ttAbrir = "Al terminar, abre el PDF (si se exporto) o el HTML."
    $ttPdf = "Ademas del HTML, genera un PDF en hoja apaisada.`r`nUsa Microsoft Edge incluido en Windows 10/11 en modo oculto.`r`nSi Edge no esta disponible, el HTML se genera igual y se muestra un aviso."
    $ttZip = "Genera un archivo .zip junto a la salida, con el HTML y (si se exporto) el PDF.`r`nUtil para adjuntar o compartir el reporte completo."
    $ttEstado = 'Requisito: svn.exe (repos SVN) y/o git.exe (repos Git) en el PATH.'

    if (-not ('RepGui.Native' -as [type])) {
        Add-Type -Namespace RepGui -Name Native -MemberDefinition '[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, string lParam);'
    }
    $script:phArchivos = 'Vacio = todos los archivos. Ej: SUBTSPAG,USRTTLOG,USRTDUMP'
    $script:cfgPath = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'ReporteCambiosSVN\ultima_config.txt'

    function Set-Cue([System.Windows.Forms.TextBox]$t, [string]$texto) {
        [void][RepGui.Native]::SendMessage($t.Handle, 0x1501, [IntPtr]1, $texto)
    }
    function Get-TextoReal([System.Windows.Forms.TextBox]$t) {
        if ($t.ForeColor -eq [System.Drawing.Color]::Gray) { return '' } else { return $t.Text }
    }
    function Set-TextoReal([System.Windows.Forms.TextBox]$t, [string]$valor, [string]$ph) {
        if (('' + $valor).Trim() -ne '') { $t.ForeColor = [System.Drawing.SystemColors]::WindowText; $t.Text = $valor }
        else { $t.ForeColor = [System.Drawing.Color]::Gray; $t.Text = $ph }
    }

    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Reporte de cambios SVN por modulo'
    $f.Size = New-Object System.Drawing.Size(720, 679)
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false
    $f.StartPosition = 'CenterScreen'
    $f.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $tips = New-Object System.Windows.Forms.ToolTip
    $tips.AutoPopDelay = 30000
    $tips.InitialDelay = 350
    $tips.ReshowDelay = 100

    function New-Lbl([string]$txt, [int]$x, [int]$y, [int]$w) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $txt; $l.Location = New-Object System.Drawing.Point($x, $y)
        $l.Size = New-Object System.Drawing.Size($w, 18); $l.AutoSize = $false
        return $l
    }

    $y = 15
    $lProj = New-Lbl 'Proyecto SVN:' 15 $y 500
    $f.Controls.Add($lProj)
    $y += 20
    $txtProj = New-Object System.Windows.Forms.TextBox
    $txtProj.Location = New-Object System.Drawing.Point(15, $y); $txtProj.Size = New-Object System.Drawing.Size(580, 23)
    $f.Controls.Add($txtProj)
    $btnDir = New-Object System.Windows.Forms.Button
    $btnDir.Text = 'Carpeta...'; $btnDir.Location = New-Object System.Drawing.Point(605, ($y - 1)); $btnDir.Size = New-Object System.Drawing.Size(85, 25)
    $f.Controls.Add($btnDir)
    $tips.SetToolTip($lProj, $ttProj)
    $tips.SetToolTip($txtProj, $ttProj)
    $tips.SetToolTip($btnDir, 'Seleccionar la carpeta de un working copy local.')
    Set-Cue $txtProj 'https://servidor/svn/repo/trunk  o  C:\ruta\repo (SVN o Git)'

    $y += 38
    $lDesde = New-Lbl 'Desde:' 15 $y 280
    $f.Controls.Add($lDesde)
    $lHasta = New-Lbl 'Hasta:' 320 $y 280
    $f.Controls.Add($lHasta)
    $y += 20
    $txtDesde = New-Object System.Windows.Forms.TextBox
    $txtDesde.Location = New-Object System.Drawing.Point(15, $y); $txtDesde.Size = New-Object System.Drawing.Size(280, 23)
    $f.Controls.Add($txtDesde)
    $txtHasta = New-Object System.Windows.Forms.TextBox
    $txtHasta.Location = New-Object System.Drawing.Point(320, $y); $txtHasta.Size = New-Object System.Drawing.Size(280, 23)
    $txtHasta.Text = 'HEAD'
    $f.Controls.Add($txtHasta)
    $tips.SetToolTip($lDesde, $ttDesde)
    $tips.SetToolTip($txtDesde, $ttDesde)
    $tips.SetToolTip($lHasta, $ttHasta)
    $tips.SetToolTip($txtHasta, $ttHasta)
    Set-Cue $txtDesde 'Fecha YYYY-MM-DD o revision. Ej: 2025-08-01 | 31490'
    Set-Cue $txtHasta 'Fecha YYYY-MM-DD, revision o HEAD'

    $y += 38
    $lArch = New-Lbl 'Archivos a identificar:' 15 $y 500
    $f.Controls.Add($lArch)
    $y += 20
    $txtMods = New-Object System.Windows.Forms.TextBox
    $txtMods.Location = New-Object System.Drawing.Point(15, $y); $txtMods.Size = New-Object System.Drawing.Size(675, 62)
    $txtMods.Multiline = $true; $txtMods.ScrollBars = 'Vertical'
    $f.Controls.Add($txtMods)
    $tips.SetToolTip($lArch, $ttArchivos)
    $tips.SetToolTip($txtMods, $ttArchivos)
    $txtMods.Add_GotFocus({
        if ($txtMods.ForeColor -eq [System.Drawing.Color]::Gray) {
            $txtMods.Text = ''; $txtMods.ForeColor = [System.Drawing.SystemColors]::WindowText
        }
    })
    $txtMods.Add_LostFocus({
        if ($txtMods.Text.Trim() -eq '') {
            $txtMods.ForeColor = [System.Drawing.Color]::Gray; $txtMods.Text = $script:phArchivos
        }
    })
    Set-TextoReal $txtMods '' $script:phArchivos

    $y += 75
    $lExts = New-Lbl 'Extensiones:' 15 $y 280
    $f.Controls.Add($lExts)
    $y += 20
    $txtExts = New-Object System.Windows.Forms.TextBox
    $txtExts.Location = New-Object System.Drawing.Point(15, $y); $txtExts.Size = New-Object System.Drawing.Size(280, 23)
    $f.Controls.Add($txtExts)
    $tips.SetToolTip($lExts, $ttExts)
    $tips.SetToolTip($txtExts, $ttExts)
    Set-Cue $txtExts 'Vacio = todas. Ej: BAS,DAT'
    $chkResumen = New-Object System.Windows.Forms.CheckBox
    $chkResumen.Text = 'Incluir resumen por archivo'
    $chkResumen.Location = New-Object System.Drawing.Point(320, ($y - 2)); $chkResumen.Size = New-Object System.Drawing.Size(370, 23)
    $chkResumen.Checked = $true
    $f.Controls.Add($chkResumen)
    $tips.SetToolTip($chkResumen, $ttResumen)

    $y += 38
    $lAutor = New-Lbl 'Autor del reporte:' 15 $y 280
    $f.Controls.Add($lAutor)
    $lOrden = New-Lbl 'Orden de revisiones:' 320 $y 280
    $f.Controls.Add($lOrden)
    $y += 20
    $txtAutor = New-Object System.Windows.Forms.TextBox
    $txtAutor.Location = New-Object System.Drawing.Point(15, $y); $txtAutor.Size = New-Object System.Drawing.Size(280, 23)
    $f.Controls.Add($txtAutor)
    $tips.SetToolTip($lAutor, $ttAutor)
    $tips.SetToolTip($txtAutor, $ttAutor)
    Set-Cue $txtAutor 'Nombre de quien genera el reporte'
    $cboOrden = New-Object System.Windows.Forms.ComboBox
    $cboOrden.Location = New-Object System.Drawing.Point(320, $y); $cboOrden.Size = New-Object System.Drawing.Size(280, 23)
    $cboOrden.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    [void]$cboOrden.Items.Add('Mas antiguas primero (ascendente)')
    [void]$cboOrden.Items.Add('Mas recientes primero (descendente)')
    $cboOrden.SelectedIndex = 0
    $f.Controls.Add($cboOrden)
    $tips.SetToolTip($lOrden, $ttOrden)
    $tips.SetToolTip($cboOrden, $ttOrden)

    $y += 28
    $chkExclRel = New-Object System.Windows.Forms.CheckBox
    $chkExclRel.Text = 'Excluir commits de mvn release'
    $chkExclRel.Location = New-Object System.Drawing.Point(15, $y); $chkExclRel.Size = New-Object System.Drawing.Size(300, 23)
    $f.Controls.Add($chkExclRel)
    $tips.SetToolTip($chkExclRel, $ttExclRel)
    $chkExclPrep = New-Object System.Windows.Forms.CheckBox
    $chkExclPrep.Text = 'Excluir commits de mvn prepare'
    $chkExclPrep.Location = New-Object System.Drawing.Point(320, $y); $chkExclPrep.Size = New-Object System.Drawing.Size(370, 23)
    $f.Controls.Add($chkExclPrep)
    $tips.SetToolTip($chkExclPrep, $ttExclPrep)

    $y += 38
    $lSalida = New-Lbl 'Archivo de salida:' 15 $y 500
    $f.Controls.Add($lSalida)
    $y += 20
    $txtSalida = New-Object System.Windows.Forms.TextBox
    $txtSalida.Location = New-Object System.Drawing.Point(15, $y); $txtSalida.Size = New-Object System.Drawing.Size(580, 23)
    $f.Controls.Add($txtSalida)
    $btnSalida = New-Object System.Windows.Forms.Button
    $btnSalida.Text = 'Guardar...'; $btnSalida.Location = New-Object System.Drawing.Point(605, ($y - 1)); $btnSalida.Size = New-Object System.Drawing.Size(85, 25)
    $f.Controls.Add($btnSalida)
    $tips.SetToolTip($lSalida, $ttSalida)
    $tips.SetToolTip($txtSalida, $ttSalida)
    $tips.SetToolTip($btnSalida, 'Elegir donde guardar el HTML.')
    Set-Cue $txtSalida 'Vacio = autogenerado en el Escritorio'

    $y += 34
    $chkAbrir = New-Object System.Windows.Forms.CheckBox
    $chkAbrir.Text = 'Abrir el reporte al terminar'
    $chkAbrir.Location = New-Object System.Drawing.Point(15, $y); $chkAbrir.Size = New-Object System.Drawing.Size(300, 23)
    $chkAbrir.Checked = $true
    $f.Controls.Add($chkAbrir)
    $tips.SetToolTip($chkAbrir, $ttAbrir)
    $chkPdf = New-Object System.Windows.Forms.CheckBox
    $chkPdf.Text = 'Exportar tambien a PDF'
    $chkPdf.Location = New-Object System.Drawing.Point(320, $y); $chkPdf.Size = New-Object System.Drawing.Size(370, 23)
    $f.Controls.Add($chkPdf)
    $tips.SetToolTip($chkPdf, $ttPdf)

    $y += 28
    $chkZip = New-Object System.Windows.Forms.CheckBox
    $chkZip.Text = 'Comprimir salida en ZIP (HTML + PDF)'
    $chkZip.Location = New-Object System.Drawing.Point(15, $y); $chkZip.Size = New-Object System.Drawing.Size(300, 23)
    $f.Controls.Add($chkZip)
    $tips.SetToolTip($chkZip, $ttZip)

    $y += 32
    $pb = New-Object System.Windows.Forms.ProgressBar
    $pb.Location = New-Object System.Drawing.Point(15, $y); $pb.Size = New-Object System.Drawing.Size(675, 20)
    $pb.Minimum = 0; $pb.Maximum = 100
    $f.Controls.Add($pb)
    $y += 24
    $lblEstado = New-Lbl 'Listo.' 15 $y 675
    $f.Controls.Add($lblEstado)
    $tips.SetToolTip($lblEstado, $ttEstado)

    $y += 28
    $btnGo = New-Object System.Windows.Forms.Button
    $btnGo.Text = 'Generar reporte'; $btnGo.Location = New-Object System.Drawing.Point(15, $y); $btnGo.Size = New-Object System.Drawing.Size(140, 30)
    $f.Controls.Add($btnGo)
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Cancelar'; $btnCancel.Location = New-Object System.Drawing.Point(165, $y); $btnCancel.Size = New-Object System.Drawing.Size(100, 30)
    $btnCancel.Enabled = $false
    $f.Controls.Add($btnCancel)
    $btnCerrar = New-Object System.Windows.Forms.Button
    $btnCerrar.Text = 'Cerrar'; $btnCerrar.Location = New-Object System.Drawing.Point(590, $y); $btnCerrar.Size = New-Object System.Drawing.Size(100, 30)
    $f.Controls.Add($btnCerrar)

    $script:guiCancel = $false

    $btnDir.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Seleccione la carpeta del working copy SVN'
        if ($dlg.ShowDialog($f) -eq [System.Windows.Forms.DialogResult]::OK) { $txtProj.Text = $dlg.SelectedPath }
    })
    $btnSalida.Add_Click({
        $dlg = New-Object System.Windows.Forms.SaveFileDialog
        $dlg.Filter = 'Documento HTML (*.html)|*.html'
        $dlg.FileName = 'REPORTE_CAMBIOS.html'
        if ($dlg.ShowDialog($f) -eq [System.Windows.Forms.DialogResult]::OK) { $txtSalida.Text = $dlg.FileName }
    })
    $btnCancel.Add_Click({ $script:guiCancel = $true; $lblEstado.Text = 'Cancelando...' })
    $btnCerrar.Add_Click({ $f.Close() })

    function Save-ConfigGui {
        try {
            $dirCfg = Split-Path -Parent $script:cfgPath
            if (-not (Test-Path -LiteralPath $dirCfg)) { New-Item -ItemType Directory -Path $dirCfg -Force | Out-Null }
            $lineas = @(
                ('proyecto=' + $txtProj.Text.Trim()),
                ('desde=' + $txtDesde.Text.Trim()),
                ('hasta=' + $txtHasta.Text.Trim()),
                ('archivos=' + (Get-TextoReal $txtMods).Trim()),
                ('extensiones=' + $txtExts.Text.Trim()),
                ('salida=' + $txtSalida.Text.Trim()),
                ('autor=' + $txtAutor.Text.Trim()),
                ('orden=' + $(if ($cboOrden.SelectedIndex -eq 1) { 'desc' } else { 'asc' })),
                ('exclrelease=' + $(if ($chkExclRel.Checked) { '1' } else { '0' })),
                ('exclprepare=' + $(if ($chkExclPrep.Checked) { '1' } else { '0' })),
                ('zip=' + $(if ($chkZip.Checked) { '1' } else { '0' })),
                ('resumen=' + $(if ($chkResumen.Checked) { '1' } else { '0' })),
                ('abrir=' + $(if ($chkAbrir.Checked) { '1' } else { '0' })),
                ('pdf=' + $(if ($chkPdf.Checked) { '1' } else { '0' }))
            )
            [System.IO.File]::WriteAllLines($script:cfgPath, $lineas, (New-Object System.Text.UTF8Encoding($true)))
        } catch { }
    }
    function Load-ConfigGui {
        try {
            if (-not (Test-Path -LiteralPath $script:cfgPath)) { return }
            $cfg = @{}
            foreach ($ln in [System.IO.File]::ReadAllLines($script:cfgPath, [System.Text.Encoding]::UTF8)) {
                $p = $ln.IndexOf('=')
                if ($p -gt 0) { $cfg[$ln.Substring(0, $p)] = $ln.Substring($p + 1) }
            }
            if ($cfg.ContainsKey('proyecto')) { $txtProj.Text = $cfg['proyecto'] }
            if ($cfg.ContainsKey('desde')) { $txtDesde.Text = $cfg['desde'] }
            if ($cfg.ContainsKey('hasta') -and ('' + $cfg['hasta']).Trim() -ne '') { $txtHasta.Text = $cfg['hasta'] }
            if ($cfg.ContainsKey('archivos')) { Set-TextoReal $txtMods $cfg['archivos'] $script:phArchivos }
            if ($cfg.ContainsKey('extensiones')) { $txtExts.Text = $cfg['extensiones'] }
            if ($cfg.ContainsKey('salida')) { $txtSalida.Text = $cfg['salida'] }
            if ($cfg.ContainsKey('autor')) { $txtAutor.Text = $cfg['autor'] }
            if ($cfg.ContainsKey('orden')) { if ($cfg['orden'] -eq 'desc') { $cboOrden.SelectedIndex = 1 } else { $cboOrden.SelectedIndex = 0 } }
            if ($cfg.ContainsKey('exclrelease')) { $chkExclRel.Checked = ($cfg['exclrelease'] -eq '1') }
            if ($cfg.ContainsKey('exclprepare')) { $chkExclPrep.Checked = ($cfg['exclprepare'] -eq '1') }
            if ($cfg.ContainsKey('zip')) { $chkZip.Checked = ($cfg['zip'] -eq '1') }
            if ($cfg.ContainsKey('resumen')) { $chkResumen.Checked = ($cfg['resumen'] -ne '0') }
            if ($cfg.ContainsKey('abrir')) { $chkAbrir.Checked = ($cfg['abrir'] -ne '0') }
            if ($cfg.ContainsKey('pdf')) { $chkPdf.Checked = ($cfg['pdf'] -eq '1') }
        } catch { }
    }

    $btnGo.Add_Click({
        $script:guiCancel = $false
        $btnGo.Enabled = $false; $btnCancel.Enabled = $true; $btnCerrar.Enabled = $false
        $pb.Value = 0
        try {
            if ($txtProj.Text.Trim() -eq '') { throw 'Indique la URL o carpeta del proyecto (SVN o Git).' }
            if ($txtDesde.Text.Trim() -eq '') { throw 'Indique el valor "Desde" (fecha o revision).' }

            Save-ConfigGui

            $res = New-SvnChangeReport `
                -ProjectPath $txtProj.Text `
                -Desde $txtDesde.Text.Trim() `
                -Hasta $txtHasta.Text.Trim() `
                -Modulos @((Get-TextoReal $txtMods)) `
                -Extensiones @($txtExts.Text) `
                -Salida $txtSalida.Text `
                -IncluirResumen $chkResumen.Checked `
                -ExportarPdf $chkPdf.Checked `
                -AutorReporte $txtAutor.Text.Trim() `
                -OrdenRev $(if ($cboOrden.SelectedIndex -eq 1) { 'desc' } else { 'asc' }) `
                -ExclMvnRelease $chkExclRel.Checked `
                -ExclMvnPrepare $chkExclPrep.Checked `
                -ExportarZip $chkZip.Checked `
                -OnProgress {
                    param($i, $t, $m)
                    if ($t -gt 0) { $pb.Value = [Math]::Min(100, [int](100 * $i / $t)) }
                    $lblEstado.Text = $m
                    [System.Windows.Forms.Application]::DoEvents()
                } `
                -ShouldCancel { return $script:guiCancel }

            $pb.Value = 100
            $lblEstado.Text = ('Listo: ' + $res.Salida)
            $detalle = ('Reporte generado.' + [Environment]::NewLine +
                        'Revisiones: ' + $res.Revisiones + [Environment]::NewLine +
                        'Archivos con diff: ' + $res.Archivos + [Environment]::NewLine +
                        'Bloques de cambio: ' + $res.Bloques + [Environment]::NewLine + [Environment]::NewLine +
                        $res.Salida)
            if ($res.SalidaPdf -ne '') { $detalle += [Environment]::NewLine + 'PDF: ' + $res.SalidaPdf }
            if ($res.SalidaZip -ne '') { $detalle += [Environment]::NewLine + 'ZIP: ' + $res.SalidaZip }
            [void][System.Windows.Forms.MessageBox]::Show($f, $detalle, 'Reporte SVN', 'OK', 'Information')
            if ($null -ne $res.PdfError) {
                [void][System.Windows.Forms.MessageBox]::Show($f, ('El HTML se genero correctamente, pero fallo la exportacion a PDF:' + [Environment]::NewLine + $res.PdfError), 'PDF', 'OK', 'Warning')
            }
            if ($null -ne $res.ZipError) {
                [void][System.Windows.Forms.MessageBox]::Show($f, ('El reporte se genero, pero fallo la creacion del ZIP:' + [Environment]::NewLine + $res.ZipError), 'ZIP', 'OK', 'Warning')
            }
            if ($chkAbrir.Checked) {
                $abrir = $res.Salida
                if ($res.SalidaPdf -ne '') { $abrir = $res.SalidaPdf }
                Invoke-Item -LiteralPath $abrir
            }
        } catch [System.OperationCanceledException] {
            $lblEstado.Text = 'Operacion cancelada.'
            $pb.Value = 0
        } catch {
            $lblEstado.Text = 'Error.'
            [void][System.Windows.Forms.MessageBox]::Show($f, $_.Exception.Message, 'Error', 'OK', 'Error')
        } finally {
            $btnGo.Enabled = $true; $btnCancel.Enabled = $false; $btnCerrar.Enabled = $true
        }
    })

    Load-ConfigGui
    $f.Add_FormClosing({ Save-ConfigGui })
    [void]$f.ShowDialog()
}

# ============================================================================
#  PUNTO DE ENTRADA
# ============================================================================

$tieneParamsCli = ($PSBoundParameters.ContainsKey('ProjectPath') -or $PSBoundParameters.ContainsKey('Archivos') -or $PSBoundParameters.ContainsKey('Desde'))
$usarGui = ($Gui.IsPresent -or -not $tieneParamsCli)

if ($usarGui) {
    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
        Start-Process -FilePath 'powershell.exe' -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -STA -File "{0}"' -f $PSCommandPath)
        return
    }
    Show-ReportGui
    return
}

# --- Modo CLI ---
if (('' + $ProjectPath).Trim() -eq '') { throw 'Falta -ProjectPath (URL o carpeta local del proyecto SVN).' }
if (('' + $Desde).Trim() -eq '')       { throw 'Falta -Desde (fecha YYYY-MM-DD o revision).' }

$resultado = New-SvnChangeReport `
    -ProjectPath $ProjectPath `
    -Desde $Desde.Trim() `
    -Hasta $Hasta.Trim() `
    -Modulos $Archivos `
    -Extensiones $Extensiones `
    -Salida $Salida `
    -IncluirResumen (-not $SinResumen.IsPresent) `
    -ExportarPdf ($Pdf.IsPresent -or ('' + $SalidaPdf).Trim() -ne '') `
    -RutaPdf $SalidaPdf `
    -AutorReporte $Autor `
    -Vcs $Vcs `
    -OrdenRev $Orden `
    -ExclMvnRelease $ExcluirMvnRelease.IsPresent `
    -ExclMvnPrepare $ExcluirMvnPrepare.IsPresent `
    -ExportarZip $Zip.IsPresent `
    -OnProgress {
        param($i, $t, $m)
        $pct = 0
        if ($t -gt 0) { $pct = [Math]::Min(100, [int](100 * $i / $t)) }
        Write-Progress -Activity 'Generando reporte de cambios SVN' -Status $m -PercentComplete $pct
    }

Write-Progress -Activity 'Generando reporte de cambios SVN' -Completed
Write-Host ('Reporte generado : ' + $resultado.Salida)
Write-Host ('Revisiones       : ' + $resultado.Revisiones)
Write-Host ('Archivos con diff: ' + $resultado.Archivos)
Write-Host ('Bloques de cambio: ' + $resultado.Bloques)
if ($resultado.SalidaPdf -ne '') { Write-Host ('PDF generado     : ' + $resultado.SalidaPdf) }
if ($null -ne $resultado.PdfError) { Write-Host ('ADVERTENCIA PDF  : ' + $resultado.PdfError) }
if ($resultado.SalidaZip -ne '') { Write-Host ('ZIP generado     : ' + $resultado.SalidaZip) }
if ($null -ne $resultado.ZipError) { Write-Host ('ADVERTENCIA ZIP  : ' + $resultado.ZipError) }
if (@($resultado.SinCambios).Count -gt 0) {
    Write-Host ('Sin cambios      : ' + ($resultado.SinCambios -join ', '))
}
if ($AbrirAlTerminar.IsPresent) {
    $abrirRuta = $resultado.Salida
    if ($resultado.SalidaPdf -ne '') { $abrirRuta = $resultado.SalidaPdf }
    Invoke-Item -LiteralPath $abrirRuta
}
$resultado
