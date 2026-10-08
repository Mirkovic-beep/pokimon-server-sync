$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
$script:SnapshotDirectories=@('world','cobblemon','config','data','datapacks','defaultconfigs','fancymenu_data','legendary-monuments-data','moddata')
$script:SnapshotRootFiles=@('ops.json','whitelist.json','banned-players.json')

function Write-SyncJson([string]$Path,$Value) {
    $encoding=New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 12),$encoding)
}
function Read-SyncJson([string]$Path) {Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json}
function Get-SyncHash([string]$Path) {(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Assert-SnapshotPath([string]$Relative) {
    if([string]::IsNullOrWhiteSpace($Relative) -or $Relative.Contains('\') -or $Relative.Contains(':') -or $Relative.StartsWith('/')) {throw 'Ruta de copia no valida.'}
    $segments=$Relative.Split('/')
    foreach($segment in $segments) {
        if($segment -in @('','.','..') -or $segment.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $segment -match '[. ]$|^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {throw 'Ruta de copia no valida.'}
    }
    if($segments.Count -eq 1) {
        if($Relative -notin $script:SnapshotRootFiles) {throw 'Archivo fuera de la lista de datos del servidor.'}
    } elseif($segments[0] -notin $script:SnapshotDirectories) {throw 'Carpeta fuera de la lista de datos del servidor.'}
    if($Relative -eq 'world/session.lock') {throw 'No se debe incluir el bloqueo del mundo.'}
}
function Get-SnapshotDestination([string]$Root,[string]$Relative) {
    Assert-SnapshotPath $Relative
    $base=[IO.Path]::GetFullPath($Root).TrimEnd('\')+'\'
    $resolved=[IO.Path]::GetFullPath((Join-Path $Root $Relative.Replace('/','\')))
    if(-not $resolved.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)) {throw 'La ruta sale de la carpeta de destino.'}
    return $resolved
}
function Get-SnapshotFiles([string]$ServerDirectory) {
    $base=[IO.Path]::GetFullPath($ServerDirectory).TrimEnd('\')
    $queue=New-Object 'Collections.Generic.Queue[string]'
    foreach($name in $script:SnapshotDirectories) {
        $directory=Join-Path $base $name
        if(Test-Path -LiteralPath $directory) {$queue.Enqueue($directory)}
    }
    while($queue.Count -gt 0) {
        $directory=$queue.Dequeue()
        if((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {throw 'No se siguen enlaces ni uniones en una copia.'}
        foreach($item in (Get-ChildItem -LiteralPath $directory -Force)) {
            if($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {throw 'No se siguen enlaces ni uniones en una copia.'}
            if($item.PSIsContainer) {$queue.Enqueue($item.FullName); continue}
            $relative=$item.FullName.Substring($base.Length+1).Replace('\','/')
            if($relative -eq 'world/session.lock') {continue}
            Assert-SnapshotPath $relative
            [pscustomobject]@{Path=$relative;FullName=$item.FullName;Length=$item.Length;LastWriteTicks=$item.LastWriteTimeUtc.Ticks}
        }
    }
    foreach($name in $script:SnapshotRootFiles) {
        $full=Join-Path $base $name
        if(Test-Path -LiteralPath $full) {
            $item=Get-Item -LiteralPath $full
            if($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {throw 'No se siguen enlaces de archivos.'}
            [pscustomobject]@{Path=$name;FullName=$full;Length=$item.Length;LastWriteTicks=$item.LastWriteTimeUtc.Ticks}
        }
    }
}
function Assert-NoBackupSecrets($Files) {
    foreach($file in $Files) {
        if($file.Length -gt 2MB -or $file.Path -notmatch '\.(json|toml|properties|ya?ml|txt|env)$') {continue}
        $content=[IO.File]::ReadAllText($file.FullName)
        $knownSecret='gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|https://(?:discord(?:app)?\.com)/api/webhooks/[0-9]+/'
        $credentialSetting='(?im)["\x27]?(?:api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|password)["\x27]?\s*[:=]\s*["\x27][^"\x27\r\n]{8,}["\x27]'
        if($content -match $knownSecret -or ($file.Path.StartsWith('config/') -and $content -match $credentialSetting)) {throw ('Posible credencial en '+$file.Path+'. Revisarla antes de una publicacion publica.')}
    }
}
function Copy-StreamWithHash([IO.Stream]$InputStream,[IO.Stream]$OutputStream) {
    $sha=[Security.Cryptography.SHA256]::Create()
    $crypto=New-Object Security.Cryptography.CryptoStream($InputStream,$sha,[Security.Cryptography.CryptoStreamMode]::Read)
    try {
        $crypto.CopyTo($OutputStream,1MB)
        return ([BitConverter]::ToString($sha.Hash)).Replace('-','').ToLowerInvariant()
    } finally {$crypto.Dispose();$sha.Dispose()}
}
function New-PokimonSnapshot {
    param([Parameter(Mandatory=$true)][string]$ServerDirectory,[Parameter(Mandatory=$true)][string]$BackupDirectory,[ValidateRange(1024,1073741824)][long]$PartBytes=1GB)
    $base=[IO.Path]::GetFullPath($ServerDirectory).TrimEnd('\')
    $backup=[IO.Path]::GetFullPath($BackupDirectory).TrimEnd('\')
    if($backup -eq $base -or $backup.StartsWith($base+'\',[StringComparison]::OrdinalIgnoreCase)) {throw 'Las copias deben guardarse fuera de la carpeta del servidor.'}
    if(-not (Test-Path -LiteralPath (Join-Path $base 'world\level.dat'))) {throw 'No se encuentra el mundo del servidor.'}
    if(Test-Path -LiteralPath $backup) {throw 'La carpeta de esta copia ya existe; no se sobrescribe.'}
    # This exclusive open also prevents Minecraft from reopening the world during the snapshot.
    $worldLock=[IO.File]::Open((Join-Path $base 'world\session.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        $files=@(Get-SnapshotFiles $base | Sort-Object Path)
        Assert-NoBackupSecrets $files
        $bytes=($files | Measure-Object -Property Length -Sum).Sum
        $drive=New-Object IO.DriveInfo([IO.Path]::GetPathRoot($backup))
        if($drive.AvailableFreeSpace -lt ($bytes*2.1+512MB)) {throw 'No hay espacio suficiente para comprimir y preparar la copia.'}
        [IO.Directory]::CreateDirectory($backup) | Out-Null
        $zipPath=Join-Path $backup 'snapshot.zip'
        $archiveStream=[IO.File]::Open($zipPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $archive=New-Object IO.Compression.ZipArchive($archiveStream,[IO.Compression.ZipArchiveMode]::Create,$false)
        $manifestFiles=New-Object 'Collections.Generic.List[object]'
        try {
            foreach($file in $files) {
                $entry=$archive.CreateEntry($file.Path,[IO.Compression.CompressionLevel]::Fastest)
                $output=$entry.Open()
                $sourceStream=[IO.File]::Open($file.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
                try {$digest=Copy-StreamWithHash $sourceStream $output} finally {$sourceStream.Dispose();$output.Dispose()}
                $after=Get-Item -LiteralPath $file.FullName
                if($after.Length -ne $file.Length -or $after.LastWriteTimeUtc.Ticks -ne $file.LastWriteTicks) {throw ('Cambio un archivo mientras se copiaba: '+$file.Path)}
                $manifestFiles.Add([pscustomobject]@{path=$file.Path;bytes=[long]$file.Length;sha256=$digest})
            }
        } finally {$archive.Dispose();$archiveStream.Dispose()}
        $mods=@()
        $modsPath=Join-Path $base 'mods'
        if(Test-Path -LiteralPath $modsPath) {
            $mods=@(Get-ChildItem -LiteralPath $modsPath -File -Filter '*.jar' | Sort-Object Name | ForEach-Object {[pscustomobject]@{name=$_.Name;sha256=(Get-SyncHash $_.FullName)}})
        }
    } finally {$worldLock.Dispose()}
    $parts=New-Object 'Collections.Generic.List[object]'
    $sourceStream=[IO.File]::OpenRead($zipPath)
    $buffer=New-Object byte[] (1MB)
    try {
        $number=0
        while($sourceStream.Position -lt $sourceStream.Length) {
            $number++
            $name='snapshot.zip.part{0:D4}' -f $number
            $partPath=Join-Path $backup $name
            $output=[IO.File]::Open($partPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            [long]$written=0
            try {
                while($written -lt $PartBytes -and $sourceStream.Position -lt $sourceStream.Length) {
                    $count=$sourceStream.Read($buffer,0,[int][Math]::Min($buffer.Length,$PartBytes-$written))
                    if($count -le 0) {throw 'Fin inesperado del archivo comprimido.'}
                    $output.Write($buffer,0,$count);$written+=$count
                }
            } finally {$output.Dispose()}
            $parts.Add([pscustomobject]@{name=$name;bytes=$written;sha256=(Get-SyncHash $partPath)})
        }
    } finally {$sourceStream.Dispose()}
    if($parts.Count -ge 999) {throw 'La copia supera el numero admitido de adjuntos por Release.'}
    $id='snapshot-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8)
    $manifest=[pscustomobject]@{format='pokimon-snapshot';schema=1;id=$id;createdUtc=[DateTime]::UtcNow.ToString('o');mode='single-host-backup';archiveBytes=(Get-Item -LiteralPath $zipPath).Length;archiveSha256=(Get-SyncHash $zipPath);totalFileBytes=[long]$bytes;files=@($manifestFiles.ToArray());parts=@($parts.ToArray());mods=$mods;includesClientMaps=$false}
    Write-SyncJson (Join-Path $backup 'manifest.json') $manifest
    return $manifest
}
function Read-PokimonManifest([string]$Directory) {
    $manifest=Read-SyncJson (Join-Path $Directory 'manifest.json')
    if($manifest.format -ne 'pokimon-snapshot' -or $manifest.schema -ne 1 -or $manifest.id -notmatch '^snapshot-\d{8}-\d{6}-[a-f0-9]{8}$' -or $manifest.archiveSha256 -notmatch '^[a-f0-9]{64}$') {throw 'Manifiesto de copia no valido.'}
    $seen=@{};[long]$total=0
    foreach($file in $manifest.files) {
        Assert-SnapshotPath $file.path
        if($seen.ContainsKey($file.path) -or $file.sha256 -notmatch '^[a-f0-9]{64}$' -or $file.bytes -lt 0) {throw 'Archivo repetido o no valido en el manifiesto.'}
        $seen[$file.path]=$true;$total+=[long]$file.bytes
    }
    if(-not $seen.ContainsKey('world/level.dat') -or $total -ne $manifest.totalFileBytes) {throw 'El manifiesto no describe un mundo completo.'}
    $number=0;[long]$partTotal=0
    foreach($part in $manifest.parts) {
        $number++
        if($part.name -ne ('snapshot.zip.part{0:D4}' -f $number) -or $part.sha256 -notmatch '^[a-f0-9]{64}$' -or $part.bytes -le 0 -or $part.bytes -ge 2GB) {throw 'Parte no valida en el manifiesto.'}
        $partTotal+=[long]$part.bytes
    }
    if($number -lt 1 -or $number -ge 999 -or $partTotal -ne $manifest.archiveBytes) {throw 'Tamano total de las partes no valido.'}
    return $manifest
}
function Test-PokimonSnapshot([string]$Directory) {
    $manifest=Read-PokimonManifest $Directory
    $hash=[Security.Cryptography.SHA256]::Create();$buffer=New-Object byte[] (1MB)
    try {
        foreach($part in $manifest.parts) {
            $file=Join-Path $Directory $part.name
            if((Get-Item -LiteralPath $file).Length -ne $part.bytes -or (Get-SyncHash $file) -ne $part.sha256) {throw ('Parte corrupta o incompleta: '+$part.name)}
            $sourceStream=[IO.File]::OpenRead($file)
            try {while(($count=$sourceStream.Read($buffer,0,$buffer.Length)) -gt 0){$hash.TransformBlock($buffer,0,$count,$buffer,0) | Out-Null}} finally {$sourceStream.Dispose()}
        }
        $hash.TransformFinalBlock((New-Object byte[] 0),0,0) | Out-Null
        $whole=([BitConverter]::ToString($hash.Hash)).Replace('-','').ToLowerInvariant()
        if($whole -ne $manifest.archiveSha256) {throw 'El archivo reconstruido no coincide con su SHA-256.'}
    } finally {$hash.Dispose()}
    return $manifest
}
function Expand-PokimonSnapshot([string]$Directory,[string]$Destination) {
    $manifest=Test-PokimonSnapshot $Directory
    if(Test-Path -LiteralPath $Destination) {throw 'El destino de restauracion debe ser una carpeta nueva.'}
    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    $zipPath=Join-Path $Directory ('restore-'+[Guid]::NewGuid().ToString('N')+'.zip')
    $joined=[IO.File]::Open($zipPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try {foreach($part in $manifest.parts){$sourceStream=[IO.File]::OpenRead((Join-Path $Directory $part.name));try{$sourceStream.CopyTo($joined)}finally{$sourceStream.Dispose()}}}finally{$joined.Dispose()}
    $expected=@{};foreach($file in $manifest.files){$expected[$file.path]=$file}
    $archive=[IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $seen=@{}
        foreach($entry in $archive.Entries) {
            Assert-SnapshotPath $entry.FullName
            if($seen.ContainsKey($entry.FullName) -or -not $expected.ContainsKey($entry.FullName) -or $entry.Length -ne $expected[$entry.FullName].bytes) {throw 'El ZIP contiene entradas inesperadas o duplicadas.'}
            if((($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) {throw 'El ZIP contiene un enlace simbolico.'}
            $seen[$entry.FullName]=$true
        }
        if($seen.Count -ne $expected.Count) {throw 'Faltan archivos en el ZIP.'}
        foreach($entry in $archive.Entries) {
            $outputPath=Get-SnapshotDestination $Destination $entry.FullName
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($outputPath)) | Out-Null
            $sourceStream=$entry.Open();$output=[IO.File]::Open($outputPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try {$digest=Copy-StreamWithHash $sourceStream $output}finally{$sourceStream.Dispose();$output.Dispose()}
            if($digest -ne $expected[$entry.FullName].sha256) {throw ('No coincide el contenido restaurado: '+$entry.FullName)}
        }
    } finally {$archive.Dispose()}
    Write-SyncJson (Join-Path $Destination 'restoration-verified.json') ([pscustomobject]@{snapshot=$manifest.id;verifiedUtc=[DateTime]::UtcNow.ToString('o');files=$expected.Count;allFileHashesVerified=$true})
    return $manifest
}
