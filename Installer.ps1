. (Join-Path $PSScriptRoot 'Shared.ps1')

function Get-VerifiedDownload([string]$Url,[string]$Path,[string]$Sha256) {
    if($Url -notmatch '^https://' -or $Sha256 -notmatch '^[a-f0-9]{64}$') {throw 'Descarga sin direccion HTTPS o hash valido.'}
    if((Test-Path -LiteralPath $Path) -and (Get-SyncHash $Path) -eq $Sha256) {return}
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
    $partial=$Path+'.download'
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    $client=New-Object Net.WebClient
    $client.Headers['User-Agent']='PokimonServerSync/1.0'
    try {$client.DownloadFile($Url,$partial)} finally {$client.Dispose()}
    if((Get-SyncHash $partial) -ne $Sha256) {throw ('La descarga no coincide con su SHA-256: '+[IO.Path]::GetFileName($Path))}
    if(Test-Path -LiteralPath $Path) {throw 'Hay un archivo diferente en el destino; se conserva sin sobrescribirlo.'}
    [IO.File]::Move($partial,$Path)
}
function Find-PokimonProfile([string]$ProfileDirectory) {
    if($ProfileDirectory) {
        if(-not (Test-Path -LiteralPath (Join-Path $ProfileDirectory 'mods'))) {throw 'La carpeta seleccionada no contiene una instancia de Modrinth con mods.'}
        return [IO.Path]::GetFullPath($ProfileDirectory)
    }
    $profiles=Join-Path $env:APPDATA 'ModrinthApp\profiles'
    $candidates=@()
    if(Test-Path -LiteralPath $profiles) {$candidates=@(Get-ChildItem -LiteralPath $profiles -Directory | Where-Object {$_.Name -like '*COBBLEVERSE*' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'mods'))})}
    if($candidates.Count -eq 1) {return $candidates[0].FullName}
    Add-Type -AssemblyName System.Windows.Forms
    $dialog=New-Object Windows.Forms.FolderBrowserDialog
    $dialog.Description='Selecciona la carpeta de tu instancia COBBLEVERSE de Modrinth (la que contiene mods y config).'
    if(Test-Path -LiteralPath $profiles) {$dialog.SelectedPath=$profiles}
    try {if($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) {throw 'Instalacion cancelada. Instala COBBLEVERSE en Modrinth y vuelve a intentarlo.'};return (Find-PokimonProfile $dialog.SelectedPath)} finally {$dialog.Dispose()}
}
function Find-PokimonJava([string]$JavaPath) {
    $paths=@()
    if($JavaPath) {$paths=@($JavaPath)} else {
        $javaRoot=Join-Path $env:APPDATA 'ModrinthApp\meta\java_versions'
        if(Test-Path -LiteralPath $javaRoot) {$paths=@(Get-ChildItem -LiteralPath $javaRoot -Directory | ForEach-Object {Join-Path $_.FullName 'bin\java.exe'} | Where-Object {Test-Path -LiteralPath $_})}
    }
    foreach($candidate in $paths) {
        $previous=$ErrorActionPreference
        try {$ErrorActionPreference='Continue';$output=& $candidate -XshowSettings:properties -version 2>&1;$code=$LASTEXITCODE} finally {$ErrorActionPreference=$previous}
        if($code -eq 0 -and (@($output) -join "`n") -match 'java.specification.version\s*=\s*21(?:\s|$)') {return $candidate}
    }
    throw 'Falta Java 21 de Modrinth. Abre una vez COBBLEVERSE desde Modrinth, cierralo y ejecuta de nuevo este instalador.'
}
function Install-PokimonRuntime([string]$ServerDirectory,[string]$ProfileDirectory,$Runtime) {
    [IO.Directory]::CreateDirectory((Join-Path $ServerDirectory 'mods')) | Out-Null
    Get-VerifiedDownload $Runtime.fabricDownload.url (Join-Path $ServerDirectory 'fabric-server-launch.jar') $Runtime.fabricDownload.sha256
    $sourceMods=@(Get-ChildItem -LiteralPath (Join-Path $ProfileDirectory 'mods') -File -Filter '*.jar')
    $byHash=@{}
    foreach($source in $sourceMods) {$byHash[(Get-SyncHash $source.FullName)]=$source.FullName}
    $required=@{}
    $count=0
    foreach($mod in $Runtime.mods) {
        if($mod.name -ne [IO.Path]::GetFileName($mod.name) -or $mod.name -notmatch '\.jar$') {throw 'Nombre de mod no valido.'}
        $required[$mod.name]=$true;$count++
        $target=Join-Path (Join-Path $ServerDirectory 'mods') $mod.name
        if(Test-Path -LiteralPath $target) {if((Get-SyncHash $target) -eq $mod.sha256){continue};throw ('Hay otra version de '+$mod.name+' en el servidor. Se conserva sin modificarla.')}
        Write-Host ('Preparando mods: '+$count+' / '+$Runtime.mods.Count+' - '+$mod.name)
        if($byHash.ContainsKey($mod.sha256)) {Copy-Item -LiteralPath $byHash[$mod.sha256] -Destination $target}
        elseif($mod.url) {Get-VerifiedDownload $mod.url $target $mod.sha256}
        else {throw ('Falta '+$mod.name+' en tu Modrinth. Usa la misma version de COBBLEVERSE que en el otro PC.')}
        if((Get-SyncHash $target) -ne $mod.sha256) {throw 'No se pudo verificar un mod copiado.'}
    }
    foreach($mod in (Get-ChildItem -LiteralPath (Join-Path $ServerDirectory 'mods') -File -Filter '*.jar')) {
        if(-not $required.ContainsKey($mod.Name)) {throw ('Mod adicional no previsto: '+$mod.Name+'. No se abre el mundo con una mezcla de mods.')}
    }
    $properties=Join-Path $ServerDirectory 'server.properties'
    if(-not (Test-Path -LiteralPath $properties)) {
        $text=@'
server-ip=
server-port=25565
level-name=world
motd=Pokimon - partida compartida
max-players=2
online-mode=true
white-list=true
enforce-whitelist=true
enforce-secure-profile=false
enable-rcon=false
enable-query=false
view-distance=6
simulation-distance=4
spawn-protection=0
difficulty=normal
gamemode=survival
force-gamemode=false
allow-flight=true
enable-command-block=true
allow-nether=true
sync-chunk-writes=true
op-permission-level=4
'@
        [IO.File]::WriteAllText($properties,$text,(New-Object Text.UTF8Encoding($false)))
    }
}
function Install-PokimonShortcuts($Settings,[string]$SettingsPath,[string]$ScriptsDirectory) {
    $start=Join-Path $ScriptsDirectory 'Start-SharedServer.ps1'
    $mainCmd=Join-Path $Settings.stateDirectory 'Iniciar-Pokimon.cmd'
    $retryCmd=Join-Path $Settings.stateDirectory 'Reintentar-subida.cmd'
    foreach($entry in @(@($mainCmd,''),@($retryCmd,' -UploadOnly'))) {
        $body="@echo off`r`ntitle Pokimon - Servidor compartido`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$start`" -SettingsPath `"$SettingsPath`"$($entry[1])`r`necho.`r`npause`r`n"
        [IO.File]::WriteAllText($entry[0],$body,[Text.Encoding]::Default)
    }
    $desktop=[Environment]::GetFolderPath('Desktop')
    $shell=New-Object -ComObject WScript.Shell
    foreach($entry in @(@('Iniciar servidor Pokimon.lnk',$mainCmd),@('Reintentar subida Pokimon.lnk',$retryCmd))) {
        $link=$shell.CreateShortcut((Join-Path $desktop $entry[0]))
        $link.TargetPath=$entry[1];$link.WorkingDirectory=$Settings.stateDirectory;$link.Description='Pokimon: actualiza al iniciar y sube al terminar con stop.';$link.Save()
    }
}
