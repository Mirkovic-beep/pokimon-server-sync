. (Join-Path $PSScriptRoot 'GitHub.ps1')
$script:SharedBranch='pokimon-state'
$script:SharedFile='session.json'

function Get-SharedState($Settings) {
    $item=Invoke-PokimonApi $Settings.ghPath ('repos/'+$Settings.repository+'/contents/'+$script:SharedFile+'?ref='+$script:SharedBranch)
    if($item.type -ne 'file' -or $item.encoding -ne 'base64' -or $item.sha -notmatch '^[a-f0-9]{40}$') {throw 'Estado remoto no valido.'}
    $value=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($item.content)) | ConvertFrom-Json
    if($value.format -ne 'pokimon-shared' -or $value.schema -ne 1 -or $value.snapshot -notmatch '^snapshot-\d{8}-\d{6}-[a-f0-9]{8}$' -or $value.manifestSha256 -notmatch '^[a-f0-9]{64}$' -or $value.generation -lt 0) {throw 'No se reconoce el estado de la partida compartida.'}
    if($value.owner -and ($value.owner.deviceId -notmatch '^[a-f0-9]{32}$' -or $value.owner.sessionId -notmatch '^[a-f0-9]{32}$')) {throw 'Reserva de partida no valida.'}
    return [pscustomobject]@{sha=$item.sha;value=$value}
}
function Set-SharedState($Settings,$Expected,$Value,[string]$Message) {
    $Value.updatedUtc=[DateTime]::UtcNow.ToString('o')
    $request=Join-Path $Settings.stateDirectory ('request-'+[Guid]::NewGuid().ToString('N')+'.json')
    $payload=[ordered]@{message=$Message;branch=$script:SharedBranch;content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 8)))}
    if($Expected) {$payload.sha=$Expected.sha}
    Write-SyncJson $request $payload
    try {
        $result=Invoke-PokimonApi $Settings.ghPath ('repos/'+$Settings.repository+'/contents/'+$script:SharedFile) 'PUT' $request
        return [pscustomobject]@{sha=$result.content.sha;value=$Value}
    } finally {[IO.File]::Delete($request)}
}
function Assert-SharedOwner($Remote,$Settings,$Session) {
    if(-not $Remote.value.owner -or $Remote.value.owner.deviceId -ne $Settings.deviceId -or $Remote.value.owner.sessionId -ne $Session.sessionId) {throw 'Este PC no tiene la reserva de la partida. No se descarga ni se sobrescribe el mundo.'}
}
function Enter-SharedSession($Settings,$Session) {
    $remote=Get-SharedState $Settings
    if($remote.value.owner) {
        Assert-SharedOwner $remote $Settings $Session
        return $remote
    }
    $value=$remote.value | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $value.owner=[pscustomobject]@{deviceId=$Settings.deviceId;sessionId=$Session.sessionId;startedUtc=[DateTime]::UtcNow.ToString('o')}
    try {return (Set-SharedState $Settings $remote $value 'Reserve Pokimon session')}
    catch {
        # A timed-out write may have succeeded. Read back; never force or steal a reservation.
        $confirmed=Get-SharedState $Settings
        Assert-SharedOwner $confirmed $Settings $Session
        return $confirmed
    }
}
function Leave-SharedSession($Settings,$Session,[string]$Snapshot,[string]$ManifestSha256) {
    $remote=Get-SharedState $Settings
    Assert-SharedOwner $remote $Settings $Session
    $value=$remote.value | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    if($Snapshot) {$value.snapshot=$Snapshot;$value.manifestSha256=$ManifestSha256;$value.generation=[long]$value.generation+1}
    $value.owner=$null
    return (Set-SharedState $Settings $remote $value 'Complete Pokimon session')
}
function Assert-ServerStopped([string]$ServerDirectory) {
    $world=Join-Path $ServerDirectory 'world'
    if(Test-Path -LiteralPath $world) {
        try {$guard=[IO.File]::Open((Join-Path $world 'session.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$guard.Dispose()}
        catch {throw 'El mundo esta abierto en Minecraft. Apaga el servidor escribiendo stop y espera.'}
    }
}
function Assert-LocalBaseline([string]$ServerDirectory,$Manifest) {
    Assert-ServerStopped $ServerDirectory
    $files=@(Get-SnapshotFiles $ServerDirectory)
    if($files.Count -ne @($Manifest.files).Count) {throw 'Hay cambios locales fuera del lanzador. Se conservan; no se descarga encima de ellos.'}
    $expected=@{};foreach($file in $Manifest.files){$expected[$file.path]=$file}
    foreach($file in $files) {
        if(-not $expected.ContainsKey($file.Path) -or $file.Length -ne $expected[$file.Path].bytes -or (Get-SyncHash $file.FullName) -ne $expected[$file.Path].sha256) {throw ('Hay avances o cambios locales sin sincronizar: '+$file.Path+'. No se sobrescriben.')}
    }
}
function Assert-ServerMods([string]$ServerDirectory,$Manifest) {
    $files=@(Get-ChildItem -LiteralPath (Join-Path $ServerDirectory 'mods') -Filter '*.jar' -File)
    if($files.Count -ne @($Manifest.mods).Count) {throw 'El numero de mods no coincide con la partida. Ejecuta de nuevo Instalar Pokimon.'}
    $expected=@{};foreach($mod in $Manifest.mods){$expected[$mod.name]=$mod.sha256}
    foreach($file in $files) {if(-not $expected.ContainsKey($file.Name) -or (Get-SyncHash $file.FullName) -ne $expected[$file.Name]) {throw ('El mod no coincide: '+$file.Name+'. No se abre el mundo con versiones distintas.')}}
}
function Assert-SyncChild([string]$Root,[string]$Path) {
    $base=[IO.Path]::GetFullPath($Root).TrimEnd('\')+'\'
    $full=[IO.Path]::GetFullPath($Path).TrimEnd('\')
    if(-not $full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)) {throw 'Operacion fuera de la carpeta de trabajo.'}
    return $full
}
function Move-SyncEntry([string]$SourceRoot,[string]$Source,[string]$DestinationRoot,[string]$Destination) {
    $from=Assert-SyncChild $SourceRoot $Source
    $to=Assert-SyncChild $DestinationRoot $Destination
    if(Test-Path -LiteralPath $to) {throw 'El destino de la recuperacion ya existe.'}
    if((Get-Item -LiteralPath $from -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {throw 'No se mueven enlaces en una restauracion.'}
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($to)) | Out-Null
    Move-Item -LiteralPath $from -Destination $to
}
function Remove-SyncGeneratedDirectory([string]$Root,[string]$Path) {
    $full=Assert-SyncChild $Root $Path
    $resolved=(Resolve-Path -LiteralPath $full).ProviderPath
    if($resolved -ine $full) {throw 'La carpeta de trabajo resuelve a otra ubicacion.'}
    $items=@(Get-Item -LiteralPath $full -Force)+@(Get-ChildItem -LiteralPath $full -Force -Recurse)
    if(@($items | Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count -gt 0) {throw 'No se limpia una carpeta con enlaces o uniones.'}
    Remove-Item -LiteralPath $full -Recurse -Force
}
function Clear-OldSyncCopies($Settings) {
    # Only complete archives generated by this launcher are eligible. The imported initial copy stays.
    try {
        $root=Join-Path $Settings.stateDirectory 'backups'
        if(Test-Path -LiteralPath $root) {
            $complete=@(Get-ChildItem -LiteralPath $root -Directory | Where-Object {
                $_.Name -match '^\d{8}-\d{6}-[a-f0-9]{8}$' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.json')) -and (Test-Path -LiteralPath (Join-Path $_.FullName 'publication.json'))
            } | Where-Object {(Read-SyncJson (Join-Path $_.FullName 'publication.json')).published} | Sort-Object Name -Descending)
            foreach($folder in @($complete | Select-Object -Skip 2)) {
                $manifest=Read-PokimonManifest $folder.FullName
                $status=Read-SyncJson (Join-Path $folder.FullName 'publication.json')
                if($status.repository -ne $Settings.repository -or $status.snapshot -ne $manifest.id) {continue}
                $release=Invoke-PokimonApi $Settings.ghPath ('repos/'+$Settings.repository+'/releases/'+$status.releaseId)
                $remoteManifest=@($release.assets | Where-Object {$_.name -eq 'manifest.json'})
                if($release.draft -or $release.tag_name -ne $manifest.id -or $remoteManifest.Count -ne 1 -or $remoteManifest[0].digest -ne ('sha256:'+(Get-SyncHash (Join-Path $folder.FullName 'manifest.json')))) {continue}
                $valid=$true
                foreach($part in $manifest.parts) {$asset=@($release.assets | Where-Object {$_.name -eq $part.name});if($asset.Count -ne 1 -or $asset[0].digest -ne ('sha256:'+$part.sha256) -or $asset[0].size -ne $part.bytes){$valid=$false}}
                if($valid) {Remove-SyncGeneratedDirectory $root $folder.FullName}
            }
        }
        $root=Join-Path $Settings.stateDirectory 'previous'
        if(Test-Path -LiteralPath $root) {
            $previous=@(Get-ChildItem -LiteralPath $root -Directory | Where-Object {$_.Name -match '^\d{8}-\d{6}-[a-f0-9]{8}$' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'baseline.local.json'))} | Sort-Object Name -Descending)
            foreach($folder in @($previous | Select-Object -Skip 1)) {
                $baseline=Read-SyncJson (Join-Path $folder.FullName 'baseline.local.json')
                if($baseline.format -eq 'pokimon-snapshot' -and $baseline.schema -eq 1) {Remove-SyncGeneratedDirectory $root $folder.FullName}
            }
        }
    } catch {Write-Warning ('La partida esta guardada; no se pudo limpiar una copia local antigua: '+$_.Exception.Message)}
}
function Repair-ApplyTransaction($Settings) {
    $journalPath=Join-Path $Settings.stateDirectory 'apply.local.json'
    if(-not (Test-Path -LiteralPath $journalPath)) {return}
    Assert-ServerStopped $Settings.serverDirectory
    $journal=Read-SyncJson $journalPath
    $backup=Assert-SyncChild $Settings.stateDirectory $journal.backup
    $staging=Assert-SyncChild $Settings.stateDirectory $journal.staging
    if($journal.server -ine [IO.Path]::GetFullPath($Settings.serverDirectory)) {throw 'El registro de restauracion pertenece a otra carpeta.'}
    $allowed=@($script:SnapshotDirectories)+@($script:SnapshotRootFiles)
    foreach($name in @($journal.oldNames)+@($journal.newNames)) {if($name -notin $allowed){throw 'Registro de restauracion no valido.'}}
    $rejected=Join-Path $backup ('incomplete-'+[Guid]::NewGuid().ToString('N'))
    foreach($name in $allowed) {
        $current=Join-Path $Settings.serverDirectory $name
        $old=Join-Path $backup $name
        if(Test-Path -LiteralPath $old) {
            if(Test-Path -LiteralPath $current) {Move-SyncEntry $Settings.serverDirectory $current $backup (Join-Path $rejected $name)}
            Move-SyncEntry $backup $old $Settings.serverDirectory $current
        } elseif($name -notin $journal.oldNames -and $name -in $journal.newNames -and (Test-Path -LiteralPath $current) -and -not (Test-Path -LiteralPath (Join-Path $staging $name))) {
            Move-SyncEntry $Settings.serverDirectory $current $backup (Join-Path $rejected $name)
        }
    }
    $baselinePath=Join-Path $Settings.stateDirectory 'baseline.local.json'
    if($journal.hadBaseline) {Copy-Item -LiteralPath (Join-Path $backup 'baseline.local.json') -Destination $baselinePath -Force}
    elseif(Test-Path -LiteralPath $baselinePath) {[IO.File]::Delete($baselinePath)}
    [IO.File]::Delete($journalPath)
    Write-Host 'Restauracion interrumpida recuperada. La copia anterior esta conservada.'
}
function Install-SnapshotData($Settings,[string]$Staging,$Manifest) {
    Assert-ServerStopped $Settings.serverDirectory
    Assert-SyncChild $Settings.stateDirectory $Staging | Out-Null
    Assert-LocalBaseline $Staging $Manifest
    $journalPath=Join-Path $Settings.stateDirectory 'apply.local.json'
    if(Test-Path -LiteralPath $journalPath) {throw 'Hay una restauracion pendiente de recuperar.'}
    $backup=Join-Path $Settings.stateDirectory ('previous\'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
    [IO.Directory]::CreateDirectory($backup) | Out-Null
    $allowed=@($script:SnapshotDirectories)+@($script:SnapshotRootFiles)
    $oldNames=@($allowed | Where-Object {Test-Path -LiteralPath (Join-Path $Settings.serverDirectory $_)})
    $newNames=@($allowed | Where-Object {Test-Path -LiteralPath (Join-Path $Staging $_)})
    $baselinePath=Join-Path $Settings.stateDirectory 'baseline.local.json'
    $hadBaseline=Test-Path -LiteralPath $baselinePath
    if($hadBaseline) {Copy-Item -LiteralPath $baselinePath -Destination (Join-Path $backup 'baseline.local.json')}
    Write-SyncJson $journalPath ([pscustomobject]@{server=[IO.Path]::GetFullPath($Settings.serverDirectory);backup=$backup;staging=$Staging;oldNames=$oldNames;newNames=$newNames;hadBaseline=$hadBaseline})
    try {
        foreach($name in $oldNames) {Move-SyncEntry $Settings.serverDirectory (Join-Path $Settings.serverDirectory $name) $backup (Join-Path $backup $name)}
        foreach($name in $newNames) {Move-SyncEntry $Staging (Join-Path $Staging $name) $Settings.serverDirectory (Join-Path $Settings.serverDirectory $name)}
        Write-SyncJson $baselinePath $Manifest
        [IO.File]::Delete($journalPath)
    } catch {Repair-ApplyTransaction $Settings;throw}
}
function Sync-SharedWorld($Settings,$Remote) {
    $baselinePath=Join-Path $Settings.stateDirectory 'baseline.local.json'
    if(Test-Path -LiteralPath $baselinePath) {
        $baseline=Read-SyncJson $baselinePath
        Write-Host 'Comprobando que no hay avances locales pendientes...'
        Assert-LocalBaseline $Settings.serverDirectory $baseline
        if($baseline.id -eq $Remote.value.snapshot) {Assert-ServerMods $Settings.serverDirectory $baseline;return $baseline}
    } elseif(Test-Path -LiteralPath (Join-Path $Settings.serverDirectory 'world\level.dat')) {
        throw 'Ya existe una partida local sin historial de sincronizacion. Se conserva sin tocarla.'
    }
    $download=Join-Path $Settings.stateDirectory ('downloads\'+$Remote.value.snapshot)
    $staging=Join-Path $Settings.stateDirectory ('staging\'+[Guid]::NewGuid().ToString('N'))
    Write-Host 'Descargando la ultima partida. La primera vez puede tardar bastante...'
    $manifest=Receive-PokimonSnapshot $Settings.repository $Settings.ghPath $download $staging $Remote.value.snapshot $Remote.value.manifestSha256
    Assert-ServerMods $Settings.serverDirectory $manifest
    Install-SnapshotData $Settings $staging $manifest
    try {
        Remove-SyncGeneratedDirectory (Join-Path $Settings.stateDirectory 'downloads') $download
        Remove-SyncGeneratedDirectory (Join-Path $Settings.stateDirectory 'staging') $staging
    } catch {Write-Warning ('La restauracion esta completa; se conservaron archivos temporales: '+$_.Exception.Message)}
    return $manifest
}
function Complete-SharedSave($Settings,$Session) {
    $sessionPath=Join-Path $Settings.stateDirectory 'session.local.json'
    $remote=Get-SharedState $Settings
    # Finish a previous acknowledgement after a network interruption, even if another PC has since acquired the next turn.
    if($Session.snapshotPath -and (Test-Path -LiteralPath (Join-Path $Session.snapshotPath 'manifest.json'))) {
        $manifest=Read-PokimonManifest $Session.snapshotPath
        if($remote.value.snapshot -eq $manifest.id -and $remote.value.manifestSha256 -eq (Get-SyncHash (Join-Path $Session.snapshotPath 'manifest.json'))) {
            Write-SyncJson (Join-Path $Settings.stateDirectory 'baseline.local.json') $manifest
            $Session.phase='idle';Write-SyncJson $sessionPath $Session
            return
        }
    }
    Assert-SharedOwner $remote $Settings $Session
    if($remote.value.snapshot -ne $Session.baseSnapshot) {throw 'La partida remota cambio de forma inesperada. Se conserva la copia local.'}
    Assert-ServerStopped $Settings.serverDirectory
    if(-not $Session.snapshotPath -or -not (Test-Path -LiteralPath (Join-Path $Session.snapshotPath 'manifest.json'))) {
        $Session.snapshotPath=Join-Path $Settings.stateDirectory ('backups\'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
        $Session.phase='saved';Write-SyncJson $sessionPath $Session
        $manifest=New-PokimonSnapshot $Settings.serverDirectory $Session.snapshotPath -Mode shared-host
        $Session.phase='snapshot';Write-SyncJson $sessionPath $Session
    } else {$manifest=Read-PokimonManifest $Session.snapshotPath}
    $remote=Get-SharedState $Settings
    Assert-SharedOwner $remote $Settings $Session
    $published=Publish-PokimonSnapshot $Session.snapshotPath $Settings.repository $Settings.ghPath
    $Session.phase='uploaded';Write-SyncJson $sessionPath $Session
    Leave-SharedSession $Settings $Session $manifest.id (Get-SyncHash (Join-Path $Session.snapshotPath 'manifest.json')) | Out-Null
    Write-SyncJson (Join-Path $Settings.stateDirectory 'baseline.local.json') $manifest
    $Session.phase='idle';Write-SyncJson $sessionPath $Session
    Clear-OldSyncCopies $Settings
    Write-Host ('Copia completa y verificada: '+$published.url) -ForegroundColor Green
}
function Test-CleanServerExit($Settings,$Session,[int]$ExitCode) {
    if($ExitCode -ne 0) {return $false}
    $log=Join-Path $Settings.serverDirectory 'logs\latest.log'
    if(-not (Test-Path -LiteralPath $log)) {return $false}
    if((Get-Item -LiteralPath $log).LastWriteTimeUtc -lt [DateTime]::Parse($Session.startedUtc).ToUniversalTime()) {return $false}
    $content=[IO.File]::ReadAllText($log)
    return ($content -match 'Stopping server' -and $content -match 'All dimensions are saved')
}
