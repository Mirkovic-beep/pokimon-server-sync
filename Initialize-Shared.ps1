param([Parameter(Mandatory=$true)][string]$SettingsPath,[Parameter(Mandatory=$true)][string]$SnapshotDirectory,[Parameter(Mandatory=$true)][string]$JavaPath,[int]$MemoryGB=12)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Installer.ps1')
$settings=Read-SyncJson $SettingsPath
$manifest=Read-PokimonManifest $SnapshotDirectory
$publication=Read-SyncJson (Join-Path $SnapshotDirectory 'publication.json')
if(-not $publication.published -or $publication.snapshot -ne $manifest.id -or $publication.repository -ne $settings.repository) {throw 'Primero hay que terminar la subida inicial.'}
$release=Invoke-PokimonApi $settings.ghPath ('repos/'+$settings.repository+'/releases/'+$publication.releaseId)
if($release.draft -or $release.tag_name -ne $manifest.id) {throw 'La copia inicial aun no esta publicada.'}
Assert-LocalBaseline $settings.serverDirectory $manifest
Assert-ServerMods $settings.serverDirectory $manifest
$repo=Invoke-PokimonApi $settings.ghPath ('repos/'+$settings.repository)
if(-not $repo.permissions.push) {throw 'Falta permiso de escritura.'}
try {$branch=Invoke-PokimonApi $settings.ghPath ('repos/'+$settings.repository+'/git/ref/heads/'+$script:SharedBranch)}
catch {
    if($_.Exception.Message -notmatch 'HTTP 404'){throw}
    $main=Invoke-PokimonApi $settings.ghPath ('repos/'+$settings.repository+'/git/ref/heads/'+$repo.default_branch)
    $request=Join-Path $settings.stateDirectory 'create-state-branch.json'
    Write-SyncJson $request ([pscustomobject]@{ref=('refs/heads/'+$script:SharedBranch);sha=$main.object.sha})
    Invoke-PokimonApi $settings.ghPath ('repos/'+$settings.repository+'/git/refs') 'POST' $request | Out-Null
}
$manifestHash=Get-SyncHash (Join-Path $SnapshotDirectory 'manifest.json')
try {$remote=Get-SharedState $settings}
catch {if($_.Exception.Message -notmatch 'HTTP 404'){throw};$remote=$null}
if($remote) {
    if($remote.value.owner -or $remote.value.snapshot -ne $manifest.id -or $remote.value.manifestSha256 -ne $manifestHash) {throw 'Ya hay un estado compartido diferente. No se reinicializa.'}
} else {
    $value=[pscustomobject]@{format='pokimon-shared';schema=1;snapshot=$manifest.id;manifestSha256=$manifestHash;generation=0;owner=$null;updatedUtc=[DateTime]::UtcNow.ToString('o')}
    Set-SharedState $settings $null $value 'Publish initial shared Pokimon world' | Out-Null
}
$settings | Add-Member -NotePropertyName javaPath -NotePropertyValue $JavaPath -Force
$settings | Add-Member -NotePropertyName memoryGB -NotePropertyValue $MemoryGB -Force
if(-not $settings.deviceId) {$settings | Add-Member -NotePropertyName deviceId -NotePropertyValue ([Guid]::NewGuid().ToString('N'))}
$settings.mode='shared-host';$settings.enabled=$true
Write-SyncJson (Join-Path $settings.stateDirectory 'baseline.local.json') $manifest
Write-SyncJson $SettingsPath $settings
$original=Join-Path $settings.serverDirectory 'Start-Server.ps1'
$backup=Join-Path $settings.stateDirectory 'launchers-before-shared'
[IO.Directory]::CreateDirectory($backup) | Out-Null
if(-not (Test-Path -LiteralPath (Join-Path $backup 'Start-Server.ps1'))) {Copy-Item -LiteralPath $original -Destination (Join-Path $backup 'Start-Server.ps1')}
$runner=(Join-Path $PSScriptRoot 'Start-SharedServer.ps1').Replace("'","''")
$configuration=$SettingsPath.Replace("'","''")
$wrapper="# POKIMON_SHARED_WRAPPER_V1`r`n`$ErrorActionPreference='Stop'`r`n& '$runner' -SettingsPath '$configuration'`r`n"
[IO.File]::WriteAllText($original,$wrapper,(New-Object Text.UTF8Encoding($false)))
Install-PokimonShortcuts $settings $SettingsPath $PSScriptRoot
Write-Host 'Sincronizacion compartida activada. Usa el acceso Iniciar servidor Pokimon del escritorio.' -ForegroundColor Green
