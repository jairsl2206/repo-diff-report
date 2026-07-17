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

function Invoke-SvnRaw {
    # Ejecuta svn y devuelve stdout como BYTES (sin recodificar) + stderr como texto.
    param([string[]]$Argumentos)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'svn'
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
            $item = New-Object PSObject -Property @{ Action = ('' + $p.GetAttribute('action')); Path = $ruta }
            if ($Patron.IsMatch($ruta)) { [void]$targets.Add($item) } else { [void]$otros.Add($item) }
        }
        [void]$entradas.Add((New-Object PSObject -Property @{
            Rev     = ('' + $le.GetAttribute('revision'))
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

function Export-HtmlAPdf {
    param([string]$HtmlPath, [string]$PdfPath)
    $edge = Find-Edge
    if ($null -eq $edge) {
        throw 'No se encontro Microsoft Edge (incluido en Windows 10/11). Abra el HTML en un navegador y use Ctrl+P -> Guardar como PDF.'
    }
    $dir = Split-Path -Parent $PdfPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (Test-Path -LiteralPath $PdfPath) { Remove-Item -LiteralPath $PdfPath -Force }
    $uri = ([System.Uri](Resolve-Path -LiteralPath $HtmlPath).Path).AbsoluteUri
    $ultimoErr = ''
    foreach ($modo in @('--headless','--headless=old')) {
        # Perfil temporal UNICO por intento: evita bloqueos de instancias previas.
        $perfil = Join-Path ([System.IO.Path]::GetTempPath()) ('RepCambiosEdge_' + [Guid]::NewGuid().ToString('N'))
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $edge
            $psi.Arguments = ($modo + ' --disable-gpu --disable-extensions --no-first-run --no-default-browser-check ' +
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
                continue
            }
            $errTxt = ''
            try { $errTxt = ('' + $errTask.Result).Trim() } catch { }
            $ultimoErr = ('Codigo de salida ' + $proc.ExitCode)
            if ($errTxt -ne '') { $ultimoErr += '. ' + $errTxt }
        } finally {
            try { Remove-Item -LiteralPath $perfil -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        }
        if ((Test-Path -LiteralPath $PdfPath) -and (Get-Item -LiteralPath $PdfPath).Length -gt 0) { return }
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
        [scriptblock]$OnProgress,
        [scriptblock]$ShouldCancel
    )

    if (-not (Test-SvnDisponible)) { throw 'No se encontro svn.exe en el PATH. Instale un cliente SVN de linea de comandos.' }

    $mods = Split-Lista -Valores $Modulos
    $exts = Split-Lista -Valores $Extensiones
    if ($mods.Count -eq 0) { throw 'Debe indicar al menos un archivo.' }

    $rangoExpr = (ConvertTo-RevExpr -Valor $Desde) + ':' + (ConvertTo-RevExpr -Valor $Hasta)

    $objetivo = ('' + $ProjectPath).Trim()
    if ($objetivo -eq '') { throw 'Debe indicar la URL o ruta del proyecto SVN.' }
    if ($objetivo -notmatch '^[A-Za-z][A-Za-z0-9+\.\-]*://') {
        if (Test-Path -LiteralPath $objetivo) { $objetivo = (Resolve-Path -LiteralPath $objetivo).Path }
    }
    $info = Get-SvnInfoXml -Target $objetivo
    $url = $info.Url
    $root = $info.Root

    $modPat = (@($mods | ForEach-Object { [regex]::Escape($_) }) -join '|')
    $extPat = (@($exts | ForEach-Object { [regex]::Escape($_) }) -join '|')
    if ($exts.Count -gt 0) {
        $patron = New-Object System.Text.RegularExpressions.Regex ("/($modPat)\.($extPat)$", 'IgnoreCase')
    } else {
        $patron = New-Object System.Text.RegularExpressions.Regex ("/($modPat)(\.[A-Za-z0-9]+)?$", 'IgnoreCase')
    }
    $patronOtraX = New-Object System.Text.RegularExpressions.Regex ("/($modPat)\.([A-Za-z0-9]+)$", 'IgnoreCase')

    if ($null -ne $OnProgress) { & $OnProgress 0 1 'Consultando log SVN...' }
    $entradas = Get-LogEntradas -Url $url -Rango $rangoExpr -Patron $patron
    $matched = @($entradas | Where-Object { $_.Targets.Count -gt 0 })

    # --- Descarga de diffs (secuencial) ---
    $parsedPorRev = @{}
    $modCount = @{}
    $totArchivos = 0
    $totHunks = 0
    $idx = 0
    foreach ($e in $matched) {
        $idx++
        if ($null -ne $ShouldCancel -and (& $ShouldCancel)) { throw (New-Object System.OperationCanceledException 'Operacion cancelada por el usuario.') }
        if ($null -ne $OnProgress) { & $OnProgress $idx $matched.Count ('Descargando diff r' + $e.Rev + '  (' + $idx + '/' + $matched.Count + ')') }

        $texto = Get-DiffRevision -Root $root -Rev $e.Rev -Targets $e.Targets
        $errRev = $null
        $secciones = @{}
        if ($texto.StartsWith('@@ERROR@@')) { $errRev = $texto.Substring(9) }
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
@page{size:landscape;margin:10mm}
@media print{ .btns{display:none} details.file{page-break-inside:avoid} body{background:#fff} }
'@
    $js = 'function setAll(open){document.querySelectorAll("details.file").forEach(function(d){d.open=open;});}'

    $nl = "`n"
    $sb = New-Object System.Text.StringBuilder (4MB)
    $ahora = (Get-Date).ToString('yyyy-MM-dd HH:mm')

    [void]$sb.Append("<!DOCTYPE html><html lang='es'><head><meta charset='utf-8'>$nl")
    [void]$sb.Append("<title>Reporte de cambios por archivo - SVN</title>$nl")
    [void]$sb.Append("<style>$css</style><script>$js</script></head><body><div class='wrap'>$nl")
    [void]$sb.Append(("<h1>Reporte de cambios por archivo &mdash; {0}</h1>$nl" -f (HtmlEnc $url)))
    [void]$sb.Append(("<div class='meta'>Rango: <b>{0} &rarr; {1}</b> &nbsp;|&nbsp; Generado: {2} &nbsp;|&nbsp; Herramienta: ReporteCambiosSVN.ps1 (solo requiere svn.exe)</div>$nl" -f (HtmlEnc $Desde), (HtmlEnc $Hasta), $ahora))
    $extsTxt = '(cualquier extensi&oacute;n)'
    if ($exts.Count -gt 0) { $extsTxt = '(.' + (HtmlEnc ($exts -join ' / .')) + ')' }
    [void]$sb.Append(("<div class='meta'>Filtro de archivos: {0} &nbsp;{1}</div>$nl" -f (HtmlEnc ($mods -join ', ')), $extsTxt))
    [void]$sb.Append("<div class='btns'><button onclick='setAll(true)'>Expandir todo</button><button onclick='setAll(false)'>Colapsar todo</button></div>$nl")

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
    [void]$sb.Append("<table class='toc'><tr><th style='width:70px'>Revisi&oacute;n</th><th style='width:110px'>Fecha</th><th style='width:90px'>Versi&oacute;n</th><th style='width:110px'>Autor</th><th>Archivos afectados (del filtro)</th><th>Descripci&oacute;n</th></tr>$nl")
    foreach ($e in $matched) {
        $vs = Get-VersionesDeMensaje -Msg $e.Msg
        $vsTxt = '&mdash;'
        if ($vs.Count -gt 0) { $vsTxt = HtmlEnc ($vs -join ', ') }
        $modsRev = @($e.Targets | ForEach-Object { $_.Path.Split('/')[-1] } | Sort-Object -Unique) -join ', '
        [void]$sb.Append(("<tr><td><a href='#r{0}'>r{0}</a></td><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td><td>{5}</td></tr>$nl" -f $e.Rev, $e.Date.Substring(0,10), $vsTxt, (HtmlEnc $e.Author), (HtmlEnc $modsRev), (HtmlEnc (Get-DescripcionCorta -Msg $e.Msg))))
    }
    [void]$sb.Append("</table>$nl")

    foreach ($e in $matched) {
        $vs = Get-VersionesDeMensaje -Msg $e.Msg
        [void]$sb.Append(("<div class='card' id='r{0}'><div class='hd'>$nl" -f $e.Rev))
        [void]$sb.Append(("<span class='badge'>r{0}</span>$nl" -f $e.Rev))
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

    [void]$sb.Append("<p class='small'>Documento generado con ReporteCambiosSVN.ps1 (svn log --xml + svn diff -c REV). El resumen por archivo es heur&iacute;stico (regex), sin IA. Para una &quot;captura&quot; imprimible: Ctrl+P &rarr; Guardar como PDF.</p>$nl")
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

    return New-Object PSObject -Property @{
        Salida     = $rutaSalida
        SalidaPdf  = $pdfGenerado
        PdfError   = $pdfError
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

    $ttProj = "URL del repositorio SVN (https://...) o carpeta local de un working copy.`r`nEjemplo: https://servidor/svn/repo/trunk"
    $ttDesde = "Inicio del rango a analizar.`r`nAcepta fecha (YYYY-MM-DD) o numero de revision.`r`nEjemplos: 2025-08-01  |  31490"
    $ttHasta = "Fin del rango a analizar.`r`nAcepta fecha (YYYY-MM-DD), numero de revision o HEAD (ultima revision)."
    $ttArchivos = "Nombres de los archivos a identificar, separados por coma (sin ruta).`r`nEjemplo: SUBTSPAG,USRTTLOG,USRTDUMP`r`nSe combinan con Extensiones; si escribe el nombre con extension (ej. VENTAS.BAS), deje Extensiones vacio."
    $ttExts = "Extensiones a considerar, separadas por coma. Ejemplo: BAS,DAT`r`nVacio = cualquier extension."
    $ttResumen = "Agrega a cada archivo un resumen del cambio generado localmente con reglas de texto (expresiones regulares):`r`nlineas agregadas/eliminadas, funciones nuevas o eliminadas, llamadas nuevas y temas detectados.`r`nNo usa IA ni servicios externos: el resultado es determinista."
    $ttSalida = "Ruta del archivo HTML a generar.`r`nVacio = se crea automaticamente en el Escritorio."
    $ttAbrir = "Al terminar, abre el PDF (si se exporto) o el HTML."
    $ttPdf = "Ademas del HTML, genera un PDF en hoja apaisada.`r`nUsa Microsoft Edge incluido en Windows 10/11 en modo oculto.`r`nSi Edge no esta disponible, el HTML se genera igual y se muestra un aviso."
    $ttEstado = 'Requisito: cliente svn.exe en el PATH.'

    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Reporte de cambios SVN por modulo'
    $f.Size = New-Object System.Drawing.Size(720, 585)
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

    $y += 75
    $lExts = New-Lbl 'Extensiones:' 15 $y 280
    $f.Controls.Add($lExts)
    $y += 20
    $txtExts = New-Object System.Windows.Forms.TextBox
    $txtExts.Location = New-Object System.Drawing.Point(15, $y); $txtExts.Size = New-Object System.Drawing.Size(280, 23)
    $f.Controls.Add($txtExts)
    $tips.SetToolTip($lExts, $ttExts)
    $tips.SetToolTip($txtExts, $ttExts)
    $chkResumen = New-Object System.Windows.Forms.CheckBox
    $chkResumen.Text = 'Incluir resumen por archivo'
    $chkResumen.Location = New-Object System.Drawing.Point(320, ($y - 2)); $chkResumen.Size = New-Object System.Drawing.Size(370, 23)
    $chkResumen.Checked = $true
    $f.Controls.Add($chkResumen)
    $tips.SetToolTip($chkResumen, $ttResumen)

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

    $btnGo.Add_Click({
        $script:guiCancel = $false
        $btnGo.Enabled = $false; $btnCancel.Enabled = $true; $btnCerrar.Enabled = $false
        $pb.Value = 0
        try {
            if (-not (Test-SvnDisponible)) { throw 'No se encontro svn.exe en el PATH.' }
            if ($txtProj.Text.Trim() -eq '') { throw 'Indique la URL o carpeta del proyecto SVN.' }
            if ($txtDesde.Text.Trim() -eq '') { throw 'Indique el valor "Desde" (fecha o revision).' }
            if ($txtMods.Text.Trim() -eq '') { throw 'Indique al menos un archivo.' }

            $res = New-SvnChangeReport `
                -ProjectPath $txtProj.Text `
                -Desde $txtDesde.Text.Trim() `
                -Hasta $txtHasta.Text.Trim() `
                -Modulos @($txtMods.Text) `
                -Extensiones @($txtExts.Text) `
                -Salida $txtSalida.Text `
                -IncluirResumen $chkResumen.Checked `
                -ExportarPdf $chkPdf.Checked `
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
            [void][System.Windows.Forms.MessageBox]::Show($f, $detalle, 'Reporte SVN', 'OK', 'Information')
            if ($null -ne $res.PdfError) {
                [void][System.Windows.Forms.MessageBox]::Show($f, ('El HTML se genero correctamente, pero fallo la exportacion a PDF:' + [Environment]::NewLine + $res.PdfError), 'PDF', 'OK', 'Warning')
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
if ($null -eq $Archivos -or @($Archivos).Count -eq 0) { throw 'Falta -Archivos (lista separada por coma).' }

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
if (@($resultado.SinCambios).Count -gt 0) {
    Write-Host ('Sin cambios      : ' + ($resultado.SinCambios -join ', '))
}
if ($AbrirAlTerminar.IsPresent) {
    $abrirRuta = $resultado.Salida
    if ($resultado.SalidaPdf -ne '') { $abrirRuta = $resultado.SalidaPdf }
    Invoke-Item -LiteralPath $abrirRuta
}
$resultado
