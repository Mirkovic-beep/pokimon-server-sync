param([Parameter(Mandatory=$true)][string]$SettingsPath,[switch]$SyncOnly,[switch]$UploadOnly)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Shared.ps1')
$settings=Read-SyncJson $SettingsPath
if(-not $settings.enabled -or $settings.mode -ne 'shared-host' -or $settings.deviceId -notmatch '^[a-f0-9]{32}$') {throw 'La sincronizacion compartida no esta activada.'}
Assert-GitHubRepository $settings.repository
[IO.Directory]::CreateDirectory($settings.stateDirectory) | Out-Null
$guard=$null
try {
    try {$guard=[IO.File]::Open((Join-Path $settings.stateDirectory 'launcher.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
    catch {throw 'Este PC ya esta abriendo el servidor o subiendo una partida. Espera a que termine.'}
    Assert-ServerStopped $settings.serverDirectory
    Repair-ApplyTransaction $settings
    $repo=Invoke-PokimonApi $settings.ghPath ('repos/'+$settings.repository)
    if(-not $repo.permissions.push) {throw 'Tu cuenta de GitHub necesita permiso de escritura. El propietario debe anadirte como colaborador y debes aceptar la invitacion.'}
    $sessionPath=Join-Path $settings.stateDirectory 'session.local.json'
    $session=$null
    if(Test-Path -LiteralPath $sessionPath) {$session=Read-SyncJson $sessionPath}
    if($session -and $session.phase -in @('saved','snapshot','uploaded')) {
        Write-Host 'Terminando la subida pendiente antes de abrir otra sesion...'
        Complete-SharedSave $settings $session
    }
    if($UploadOnly) {
        if($session -and $session.phase -notin @('idle','reserved')) {throw 'La partida anterior no termino con un guardado limpio. Abre Iniciar servidor y termina escribiendo stop.'}
        Write-Host 'No quedan subidas pendientes.' -ForegroundColor Green
        return
    }
    if(-not $session -or $session.phase -eq 'idle') {
        $session=[pscustomobject]@{schema=1;sessionId=[Guid]::NewGuid().ToString('N');phase='reserved';baseSnapshot=$null;snapshotPath=$null;startedUtc=$null}
        Write-SyncJson $sessionPath $session
    }
    $remote=Enter-SharedSession $settings $session
    if($session.phase -eq 'playing') {
        if($SyncOnly) {throw 'Hay una sesion local que no se cerro correctamente. Usa Iniciar servidor para recuperarla y terminar con stop.'}
        if($session.baseSnapshot -ne $remote.value.snapshot) {throw 'El estado remoto no coincide con la sesion local pendiente.'}
        $baseline=Read-SyncJson (Join-Path $settings.stateDirectory 'baseline.local.json')
        Assert-ServerMods $settings.serverDirectory $baseline
        Write-Host 'Recuperando la sesion anterior de este PC. Se mantienen los avances locales.' -ForegroundColor Yellow
    } else {
        $baseline=Sync-SharedWorld $settings $remote
        $session.baseSnapshot=$baseline.id;$session.phase='ready';Write-SyncJson $sessionPath $session
    }
    if($SyncOnly) {
        Leave-SharedSession $settings $session | Out-Null
        $session.phase='idle';Write-SyncJson $sessionPath $session
        Clear-OldSyncCopies $settings
        Write-Host 'Partida actualizada. Ya puedes usar el acceso del escritorio.' -ForegroundColor Green
        return
    }
    if(-not (Test-Path -LiteralPath $settings.javaPath)) {throw 'No se encuentra Java 21. Ejecuta de nuevo Instalar Pokimon.'}
    if([int]$settings.memoryGB -lt 4 -or [int]$settings.memoryGB -gt 12) {throw 'Memoria configurada no valida.'}
    $remote=Get-SharedState $settings
    Assert-SharedOwner $remote $settings $session
    $session.phase='playing';$session.startedUtc=[DateTime]::UtcNow.ToString('o');Write-SyncJson $sessionPath $session
    Write-Host ''
    Write-Host ('Abriendo Pokimon con '+$settings.memoryGB+' GB. En Modrinth: Multijugador > localhost:25565.') -ForegroundColor Cyan
    Write-Host 'Para terminar, escribe stop AQUI y espera a que termine la subida. No cierres con la X.' -ForegroundColor Yellow
    Push-Location -LiteralPath $settings.serverDirectory
    try {
        & $settings.javaPath -Xms2G ('-Xmx'+$settings.memoryGB+'G') -jar fabric-server-launch.jar nogui
        $serverExitCode=$LASTEXITCODE
    } finally {Pop-Location}
    if(-not (Test-CleanServerExit $settings $session $serverExitCode)) {throw 'El servidor no confirmo un cierre limpio. Los avances y la reserva siguen en este PC. Abre de nuevo el acceso para recuperar la sesion.'}
    $session.phase='saved';Write-SyncJson $sessionPath $session
    Write-Host 'Partida guardada. Preparando y subiendo los avances...'
    Complete-SharedSave $settings $session
    Write-Host 'LISTO: ya puede abrir el servidor el otro PC. Puedes cerrar esta ventana.' -ForegroundColor Green
} catch {
    Write-Host ''
    Write-Host ('NO COMPLETADO: '+$_.Exception.Message) -ForegroundColor Red
    Write-Host 'Los archivos locales se conservan. Si habia una sesion o subida pendiente, vuelve a abrir este mismo acceso.'
    throw
} finally {if($guard){$guard.Dispose()}}
