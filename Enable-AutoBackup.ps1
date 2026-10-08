param([Parameter(Mandatory=$true)][string]$SettingsPath)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'GitHub.ps1')
$settings=Read-SyncJson $SettingsPath
if($settings.mode -ne 'single-host-backup') {throw 'Este lanzador requiere un unico PC anfitrion.'}
Assert-GitHubRepository $settings.repository
$repo=Invoke-PokimonApi $settings.ghPath ('repos/'+$settings.repository)
if($repo.full_name -ine $settings.repository -or $repo.private -ne $false -or -not $repo.permissions.push) {throw 'Falta un repositorio publico accesible con permiso de escritura.'}
$server=[IO.Path]::GetFullPath($settings.serverDirectory).TrimEnd('\')
$launcher=Join-Path $server 'Start-Server.ps1'
$core=Join-Path $server 'Start-Server-without-backup.ps1'
if(Test-Path -LiteralPath $core) {throw 'El lanzador ya tiene una copia anterior. Revisar antes de activar de nuevo.'}
$original=[IO.File]::ReadAllText($launcher)
if($original -notmatch '-jar fabric-server-launch\.jar' -or $original -match 'POKIMON_BACKUP_WRAPPER') {throw 'El lanzador existente no es el esperado.'}
[IO.Directory]::CreateDirectory($settings.stateDirectory) | Out-Null
$settingsLiteral="'"+([IO.Path]::GetFullPath($SettingsPath).Replace("'","''"))+"'"
$afterLiteral="'"+((Join-Path $PSScriptRoot 'After-ServerStop.ps1').Replace("'","''"))+"'"
$wrapper=@'
# POKIMON_BACKUP_WRAPPER_V1
$ErrorActionPreference='Stop'
$settingsPath=__SETTINGS__
$settings=Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
if(-not $settings.enabled) {throw 'La copia automatica esta desactivada; revisar su configuracion.'}
$launchLock=[IO.File]::Open((Join-Path $settings.stateDirectory 'launcher.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try {
    $started=[DateTime]::UtcNow
    & (Join-Path $PSScriptRoot 'Start-Server-without-backup.ps1')
    $serverCode=$LASTEXITCODE
    & __AFTER__ -SettingsPath $settingsPath -ServerExitCode $serverCode -SessionStartedUtc $started
} finally {$launchLock.Dispose()}
'@
$wrapper=$wrapper.Replace('__SETTINGS__',$settingsLiteral).Replace('__AFTER__',$afterLiteral)
$parseTokens=$null;$parseErrors=$null
[Management.Automation.Language.Parser]::ParseInput($wrapper,[ref]$parseTokens,[ref]$parseErrors) | Out-Null
if($parseErrors.Count) {throw 'El lanzador generado no pasa la comprobacion de sintaxis.'}
Copy-Item -LiteralPath $launcher -Destination $core
$settings.enabled=$true
Write-SyncJson $SettingsPath $settings
[IO.File]::WriteAllText($launcher,$wrapper,(New-Object Text.UTF8Encoding($false)))
Write-Host 'Copia automatica activada para el proximo arranque con el acceso habitual. Al terminar con stop, espera el mensaje de subida completa.'
