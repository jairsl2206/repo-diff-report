<#
.SYNOPSIS
    Publica un release en GitHub con el .exe como asset, usando la API REST.
    No requiere gh CLI: usa el token que git ya tiene guardado (credential manager).

.DESCRIPTION
    Flujo:
      1. Hace push de la rama actual (omitir con -SinPush).
      2. Crea el release para el tag indicado (si ya existe, lo reutiliza).
      3. Sube el asset (si ya hay uno con el mismo nombre, lo reemplaza).
      4. Agrega el SHA256 del asset a las notas.

.EXAMPLE
    .\publicar-release.ps1 -Version v1.1.0 -Notas "Mejoras de UI y PDF robusto"

.EXAMPLE
    .\publicar-release.ps1
    # Modo interactivo: pregunta version y notas.
#>
[CmdletBinding()]
param(
    [string]$Version,
    [string]$Titulo,
    [string]$Notas,
    [string]$Repo = 'jairsl2206/repo-diff-report',
    [string]$Asset,
    [switch]$SinPush
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$dirScript = Split-Path -Parent $MyInvocation.MyCommand.Path
if (('' + $Asset).Trim() -eq '') { $Asset = Join-Path $dirScript 'ReporteCambiosSVN.exe' }

if (('' + $Version).Trim() -eq '') { $Version = Read-Host 'Version del release (ej. v1.1.0)' }
$Version = ('' + $Version).Trim()
if ($Version -eq '') { throw 'Debe indicar una version.' }
if ($Version -notmatch '^[vV]') { $Version = 'v' + $Version }
if (('' + $Titulo).Trim() -eq '') { $Titulo = $Version }
if (('' + $Notas).Trim() -eq '') {
    $Notas = Read-Host 'Notas del release (Enter = texto por defecto)'
    if (('' + $Notas).Trim() -eq '') { $Notas = 'Release ' + $Version + ' de ReporteCambiosSVN.' }
}

if (-not (Test-Path -LiteralPath $Asset)) {
    throw ('No se encontro el asset: ' + $Asset + '. Compile primero con build.bat.')
}
$sha = (Get-FileHash -LiteralPath $Asset -Algorithm SHA256).Hash
$nombreAsset = [System.IO.Path]::GetFileName($Asset)
$Notas = $Notas + "`n`nSHA256 de " + $nombreAsset + ": " + $sha

# --- Token desde el credential manager de git (no se muestra en pantalla) ---
$credOut = "protocol=https`nhost=github.com`n" | git credential fill
$tok = $null
foreach ($l in @($credOut)) { if ($l -like 'password=*') { $tok = $l.Substring(9) } }
if (-not $tok) { throw 'No se pudo obtener el token de GitHub del credential manager de git.' }
$hdr = @{ Authorization = "token $tok"; 'User-Agent' = 'repo-diff-report'; Accept = 'application/vnd.github+json' }

# --- Push previo de la rama actual ---
if (-not $SinPush.IsPresent) {
    Write-Host 'Haciendo push de la rama actual...'
    try { git -C $dirScript push origin HEAD 2>&1 | Out-Null } catch { Write-Warning ('Push fallo: ' + $_.Exception.Message) }
}

# --- Crear release (o reutilizar si el tag ya tiene uno) ---
$body = @{ tag_name = $Version; name = $Titulo; body = $Notas } | ConvertTo-Json
try {
    $rel = Invoke-RestMethod -Method Post -Uri "https://api.github.com/repos/$Repo/releases" -Headers $hdr -Body $body -ContentType 'application/json'
    Write-Host ('Release creado  : ' + $rel.html_url)
} catch {
    $resp = $_.Exception.Response
    if ($null -ne $resp -and [int]$resp.StatusCode -eq 422) {
        $rel = Invoke-RestMethod -Method Get -Uri "https://api.github.com/repos/$Repo/releases/tags/$Version" -Headers $hdr
        Write-Host ('Release existente: ' + $rel.html_url)
    } else {
        throw
    }
}

# --- Reemplazar asset previo con el mismo nombre ---
foreach ($a in @($rel.assets)) {
    if ($null -ne $a -and $a.name -ieq $nombreAsset) {
        Write-Host ('Eliminando asset previo: ' + $a.name)
        Invoke-RestMethod -Method Delete -Uri "https://api.github.com/repos/$Repo/releases/assets/$($a.id)" -Headers $hdr | Out-Null
    }
}

# --- Subir asset ---
Write-Host ('Subiendo ' + $nombreAsset + '...')
$upUri = "https://uploads.github.com/repos/$Repo/releases/$($rel.id)/assets?name=$nombreAsset"
$assetSubido = Invoke-RestMethod -Method Post -Uri $upUri -Headers $hdr -ContentType 'application/octet-stream' -InFile $Asset

Write-Host ''
Write-Host ('Release : ' + $rel.html_url)
Write-Host ('Asset   : ' + $assetSubido.browser_download_url)
Write-Host ('SHA256  : ' + $sha)
