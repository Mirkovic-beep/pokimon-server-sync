. (Join-Path $PSScriptRoot 'Snapshot.ps1')

function Assert-GitHubRepository([string]$Repository) {
    if($Repository -notmatch '^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$') {throw 'Repositorio no valido; usar propietario/nombre.'}
}
function Invoke-PokimonGh([string]$GhPath,[string[]]$Arguments) {
    if(-not (Test-Path -LiteralPath $GhPath)) {throw 'No se encuentra GitHub CLI.'}
    $previousPreference=$ErrorActionPreference
    try {
        $ErrorActionPreference='Continue'
        $output=& $GhPath @Arguments 2>&1
        $exitCode=$LASTEXITCODE
    } finally {$ErrorActionPreference=$previousPreference}
    $message=(@($output | ForEach-Object {[string]$_}) -join "`n")
    if($exitCode -ne 0) {throw ('GitHub CLI no completo la operacion: '+$message)}
    return $message
}
function Invoke-PokimonApi([string]$GhPath,[string]$Endpoint,[string]$Method='GET',[string]$InputFile) {
    $arguments=@('api','--hostname','github.com',$Endpoint,'--method',$Method,'-H','Accept: application/vnd.github+json','-H','X-GitHub-Api-Version: 2022-11-28')
    if($InputFile) {$arguments+=@('--input',$InputFile)}
    $response=Invoke-PokimonGh $GhPath $arguments
    if($response.Trim()) {return ($response | ConvertFrom-Json)}
}
function Publish-PokimonSnapshot([string]$Directory,[string]$Repository,[string]$GhPath) {
    Assert-GitHubRepository $Repository
    $manifest=Test-PokimonSnapshot $Directory
    $statusPath=Join-Path $Directory 'publication.json'
    $repo=Invoke-PokimonApi $GhPath ('repos/'+$Repository)
    if($repo.full_name -ine $Repository -or $repo.private -ne $false) {throw 'El destino no es el repositorio publico configurado.'}
    if(-not $repo.permissions.push) {throw 'La cuenta conectada no tiene permiso de escritura en este repositorio.'}
    if(Test-Path -LiteralPath $statusPath) {
        $status=Read-SyncJson $statusPath
        if($status.repository -ine $Repository -or $status.snapshot -ne $manifest.id) {throw 'Esta copia pertenece a otra publicacion.'}
    } else {
        $status=[pscustomobject]@{repository=$Repository;snapshot=$manifest.id;releaseId=$null;published=$false;url=$null;verifiedUtc=$null}
        Write-SyncJson $statusPath $status
    }
    if(-not $status.releaseId) {
        $specPath=Join-Path $Directory 'release-request.json'
        $notes="Copia completa del mundo y datos externos de mods. Creada despues de apagar el servidor. Incluye manifest.json con SHA-256 de cada archivo y de las partes. Los mods y los mapas personales del cliente se conservan por separado."
        Write-SyncJson $specPath ([pscustomobject]@{tag_name=$manifest.id;target_commitish=$repo.default_branch;name=('Partida '+$manifest.createdUtc);body=$notes;draft=$true;prerelease=$false})
        try {$release=Invoke-PokimonApi $GhPath ('repos/'+$Repository+'/releases/tags/'+$manifest.id)}
        catch {if($_.Exception.Message -notmatch 'HTTP 404') {throw};$release=$null}
        if(-not $release) {$release=Invoke-PokimonApi $GhPath ('repos/'+$Repository+'/releases') 'POST' $specPath}
        $status.releaseId=$release.id
        Write-SyncJson $statusPath $status
    }
    $release=Invoke-PokimonApi $GhPath ('repos/'+$Repository+'/releases/'+$status.releaseId)
    if($release.tag_name -ne $manifest.id) {throw 'No coincide la version remota.'}
    $assets=@($manifest.parts | ForEach-Object {[pscustomobject]@{name=$_.name;bytes=$_.bytes;sha256=$_.sha256}})
    $manifestPath=Join-Path $Directory 'manifest.json'
    $assets+=([pscustomobject]@{name='manifest.json';bytes=(Get-Item -LiteralPath $manifestPath).Length;sha256=(Get-SyncHash $manifestPath)})
    foreach($asset in $assets) {
        $existing=@($release.assets | Where-Object {$_.name -eq $asset.name})
        if($existing.Count -gt 1) {throw 'Hay adjuntos duplicados en la version remota.'}
        if($existing.Count -eq 1) {
            if($release.draft -and $existing[0].state -eq 'starter' -and -not $existing[0].digest) {
                Invoke-PokimonApi $GhPath ('repos/'+$Repository+'/releases/assets/'+$existing[0].id) 'DELETE' | Out-Null
                $existing=@()
            }
        }
        if($existing.Count -eq 1) {
            if($existing[0].size -ne $asset.bytes -or $existing[0].digest -ne ('sha256:'+$asset.sha256) -or $existing[0].state -ne 'uploaded') {throw ('Adjunto remoto incompleto o distinto: '+$asset.name+'. La version sigue sin completarse.')}
            continue
        }
        if(-not $release.draft) {throw 'Faltan adjuntos en una version ya publicada; no se modifica.'}
        Write-Host ('Subiendo '+$asset.name+' ('+[Math]::Round($asset.bytes/1MB)+' MB)...')
        Invoke-PokimonGh $GhPath @('release','upload',$manifest.id,(Join-Path $Directory $asset.name),'--repo',('https://github.com/'+$Repository)) | Out-Null
    }
    $release=Invoke-PokimonApi $GhPath ('repos/'+$Repository+'/releases/'+$status.releaseId)
    if(@($release.assets).Count -ne $assets.Count) {throw 'No coincide el numero de adjuntos remotos.'}
    foreach($asset in $assets) {
        $remote=@($release.assets | Where-Object {$_.name -eq $asset.name})
        if($remote.Count -ne 1 -or $remote[0].size -ne $asset.bytes -or $remote[0].digest -ne ('sha256:'+$asset.sha256) -or $remote[0].state -ne 'uploaded') {throw ('No se ha verificado el adjunto '+$asset.name+'. La copia no se anuncia como completa.')}
    }
    if($release.draft) {
        $publishPath=Join-Path $Directory 'publish-request.json'
        Write-SyncJson $publishPath ([pscustomobject]@{draft=$false;make_latest='true'})
        $release=Invoke-PokimonApi $GhPath ('repos/'+$Repository+'/releases/'+$status.releaseId) 'PATCH' $publishPath
    }
    if($release.draft) {throw 'GitHub no ha confirmado la publicacion.'}
    $status.published=$true;$status.url=$release.html_url;$status.verifiedUtc=[DateTime]::UtcNow.ToString('o')
    Write-SyncJson $statusPath $status
    return $status
}
function Receive-PokimonSnapshot([string]$Repository,[string]$GhPath,[string]$DownloadDirectory,[string]$Destination,[string]$Tag,[string]$ManifestSha256) {
    Assert-GitHubRepository $Repository
    if(Test-Path -LiteralPath $Destination) {throw 'La carpeta de restauracion debe ser nueva.'}
    $endpoint='repos/'+$Repository+'/releases/latest'
    if($Tag) {
        if($Tag -notmatch '^snapshot-\d{8}-\d{6}-[a-f0-9]{8}$') {throw 'Version de partida no valida.'}
        $endpoint='repos/'+$Repository+'/releases/tags/'+$Tag
    }
    $release=Invoke-PokimonApi $GhPath $endpoint
    if($release.draft -or $release.tag_name -notmatch '^snapshot-\d{8}-\d{6}-[a-f0-9]{8}$') {throw 'La ultima version no es una copia completa de Pokimon.'}
    $manifestAsset=@($release.assets | Where-Object {$_.name -eq 'manifest.json'})
    if($manifestAsset.Count -ne 1) {throw 'No se encuentra el manifiesto remoto.'}
    [IO.Directory]::CreateDirectory($DownloadDirectory) | Out-Null
    $manifestFile=Join-Path $DownloadDirectory 'manifest.json'
    if($ManifestSha256 -and $manifestAsset[0].digest -ne ('sha256:'+$ManifestSha256)) {throw 'El manifiesto no coincide con la partida anunciada en el estado compartido.'}
    Invoke-PokimonGh $GhPath @('release','download',$release.tag_name,'--pattern','manifest.json','--output',$manifestFile,'--clobber','--repo',('https://github.com/'+$Repository)) | Out-Null
    if($manifestAsset[0].digest -ne ('sha256:'+(Get-SyncHash $manifestFile))) {throw 'No coincide el manifiesto descargado.'}
    $manifest=Read-PokimonManifest $DownloadDirectory
    if($manifest.id -ne $release.tag_name) {throw 'El manifiesto pertenece a otra version.'}
    $drive=New-Object IO.DriveInfo([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Destination)))
    if($drive.AvailableFreeSpace -lt ($manifest.totalFileBytes+$manifest.archiveBytes*2+512MB)) {throw 'No hay espacio libre suficiente para descargar y verificar la partida. Las copias locales anteriores se conservan.'}
    foreach($part in $manifest.parts) {
        $asset=@($release.assets | Where-Object {$_.name -eq $part.name})
        if($asset.Count -ne 1 -or $asset[0].size -ne $part.bytes -or $asset[0].digest -ne ('sha256:'+$part.sha256)) {throw 'La copia remota esta incompleta.'}
        $partPath=Join-Path $DownloadDirectory $part.name
        if((Test-Path -LiteralPath $partPath) -and (Get-Item -LiteralPath $partPath).Length -eq $part.bytes -and (Get-SyncHash $partPath) -eq $part.sha256) {continue}
        Write-Host ('Descargando '+$part.name+' ('+[Math]::Round($part.bytes/1MB)+' MB)...')
        Invoke-PokimonGh $GhPath @('release','download',$release.tag_name,'--pattern',$part.name,'--output',$partPath,'--clobber','--repo',('https://github.com/'+$Repository)) | Out-Null
    }
    return (Expand-PokimonSnapshot $DownloadDirectory $Destination)
}
