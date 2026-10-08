param([Parameter(Mandatory=$true)][string]$SettingsPath,[Parameter(Mandatory=$true)][int]$ServerExitCode,[Parameter(Mandatory=$true)][DateTime]$SessionStartedUtc)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'GitHub.ps1')
if($ServerExitCode -ne 0) {throw 'El servidor termino con error. Se conserva la partida local; no se publica automaticamente.'}
$settings=Read-SyncJson $SettingsPath
if(-not $settings.enabled -or $settings.mode -ne 'single-host-backup') {throw 'La copia automatica todavia no esta activada.'}
$latestLog=Join-Path $settings.serverDirectory 'logs\latest.log'
$log=Get-Content -LiteralPath $latestLog -Raw -Encoding UTF8
if((Get-Item -LiteralPath $latestLog).LastWriteTimeUtc -lt $SessionStartedUtc.ToUniversalTime() -or $log -notmatch 'Stopping server|Stopping the server' -or $log -notmatch 'All dimensions are saved') {throw 'No se ha confirmado el guardado completo de esta sesion.'}
[IO.Directory]::CreateDirectory($settings.stateDirectory) | Out-Null
$jobLock=[IO.File]::Open((Join-Path $settings.stateDirectory 'upload.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try {
    $backups=Join-Path $settings.stateDirectory 'backups'
    [IO.Directory]::CreateDirectory($backups) | Out-Null
    $name=[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8)
    Write-Host 'Partida guardada. Preparando la copia para GitHub; espera antes de cerrar esta ventana.'
    $manifest=New-PokimonSnapshot -ServerDirectory $settings.serverDirectory -BackupDirectory (Join-Path $backups $name)
    $pending=@(Get-ChildItem -LiteralPath $backups -Directory | Sort-Object Name | Where-Object {Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.json')})
    foreach($directory in $pending) {
        $publishedPath=Join-Path $directory.FullName 'publication.json'
        if((Test-Path -LiteralPath $publishedPath) -and (Read-SyncJson $publishedPath).published) {continue}
        $publication=Publish-PokimonSnapshot $directory.FullName $settings.repository $settings.ghPath
        Write-Host ('Copia completa y verificada: '+$publication.url)
    }
} catch {
    Write-Warning 'La partida sigue guardada en este PC. La subida no ha terminado; las copias preparadas se conservan para reintentar.'
    throw
} finally {$jobLock.Dispose()}
