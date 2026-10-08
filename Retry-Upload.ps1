param([Parameter(Mandatory=$true)][string]$SettingsPath)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'GitHub.ps1')
$settings=Read-SyncJson $SettingsPath
if(-not $settings.enabled) {throw 'La publicacion automatica no esta activada.'}
if($settings.mode -ne 'single-host-backup') {throw 'Para la partida compartida usa Reintentar subida Pokimon del escritorio. Este comando antiguo no coordina dos PCs.'}
$jobLock=[IO.File]::Open((Join-Path $settings.stateDirectory 'upload.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try {
    foreach($directory in (Get-ChildItem -LiteralPath (Join-Path $settings.stateDirectory 'backups') -Directory | Sort-Object Name)) {
        if(-not (Test-Path -LiteralPath (Join-Path $directory.FullName 'manifest.json'))) {continue}
        $publicationPath=Join-Path $directory.FullName 'publication.json'
        if((Test-Path -LiteralPath $publicationPath) -and (Read-SyncJson $publicationPath).published) {continue}
        $result=Publish-PokimonSnapshot $directory.FullName $settings.repository $settings.ghPath
        Write-Host ('Copia verificada: '+$result.url)
    }
} finally {$jobLock.Dispose()}
