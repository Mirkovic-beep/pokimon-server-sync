param([string]$InstallDirectory=(Join-Path $env:USERPROFILE 'Games\Pokimon-Compartido'),[string]$ProfileDirectory,[string]$JavaPath,[switch]$PrepareOnly)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Installer.ps1')
$repository='Mirkovic-beep/pokimon-server-sync'
$runtime=Read-SyncJson (Join-Path $PSScriptRoot 'runtime.json')
$install=[IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\')
$server=Join-Path $install 'server'
$state=Join-Path $install 'sync-state'
$scripts=Join-Path $install 'app'
if($install.StartsWith(([IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase)) {throw 'Instala fuera de la carpeta del ZIP descargado.'}
$profile=Find-PokimonProfile $ProfileDirectory
$java=Find-PokimonJava $JavaPath
$ram=[Math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory/1GB)
$memory=if($ram -ge 24){12}elseif($ram -ge 16){6}else{4}
Write-Host ('Instancia encontrada: '+$profile)
Write-Host ('RAM del PC: '+$ram+' GB. Servidor: '+$memory+' GB.')
if($ram -lt 16) {Write-Host 'Con menos de 16 GB, abrir el servidor y el juego juntos puede ir lento. Cierra otros programas.' -ForegroundColor Yellow}
[IO.Directory]::CreateDirectory($state) | Out-Null
[IO.Directory]::CreateDirectory($scripts) | Out-Null
Assert-ServerStopped $server
$guard=[IO.File]::Open((Join-Path $state 'launcher.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try {
    $appFiles=@('Snapshot.ps1','GitHub.ps1','Shared.ps1','Start-SharedServer.ps1','Installer.ps1','Install-Pokimon.ps1','Client-ServerEntry.ps1','runtime.json','README.md','LEEME-PRIMERO.txt')
    foreach($name in $appFiles) {
        $source=Join-Path $PSScriptRoot $name;$target=Join-Path $scripts $name
        if([IO.Path]::GetFullPath($source) -ine [IO.Path]::GetFullPath($target)) {Copy-Item -LiteralPath $source -Destination $target -Force}
    }
    $cliDir=Join-Path $install ('tools\gh-'+$runtime.githubCli.version)
    $gh=Join-Path $cliDir 'bin\gh.exe'
    if(-not (Test-Path -LiteralPath $gh)) {
        $zipPath=Join-Path $install 'tools\gh.zip'
        Write-Host 'Instalando GitHub CLI desde su distribucion oficial...'
        Get-VerifiedDownload $runtime.githubCli.url $zipPath $runtime.githubCli.sha256
        [IO.Directory]::CreateDirectory($cliDir) | Out-Null
        [IO.Compression.ZipFile]::ExtractToDirectory($zipPath,$cliDir)
    }
    Install-PokimonRuntime $server $profile $runtime
    $settingsPath=Join-Path $state 'settings.local.json'
    if(Test-Path -LiteralPath $settingsPath) {
        $settings=Read-SyncJson $settingsPath
        if($settings.repository -ne $repository -or $settings.serverDirectory -ine $server) {throw 'Ya hay una instalacion diferente en esa carpeta.'}
    } else {
        $settings=[pscustomobject]@{enabled=$true;mode='shared-host';repository=$repository;serverDirectory=$server;stateDirectory=$state;ghPath=$gh;javaPath=$java;memoryGB=$memory;deviceId=[Guid]::NewGuid().ToString('N');profileDirectory=$profile}
        Write-SyncJson $settingsPath $settings
    }
    if($PrepareOnly) {Write-Host 'Archivos preparados. Falta conectar GitHub, aceptar EULA y descargar la partida.';return}
    $connected=$false
    try {Invoke-PokimonApi $gh 'user' | Out-Null;$connected=$true} catch {}
    if(-not $connected) {
        Write-Host 'Conecta TU cuenta de GitHub y autoriza GitHub CLI. Copia el codigo que aparezca.'
        & $gh auth login --hostname github.com --git-protocol https --web
        if($LASTEXITCODE -ne 0) {throw 'No se completo el inicio de sesion de GitHub.'}
    }
    $repo=Invoke-PokimonApi $gh ('repos/'+$repository)
    if(-not $repo.permissions.push) {throw 'Tu cuenta necesita permiso de escritura. Pide a Mirkovic-beep que te anada como colaborador, acepta la invitacion y vuelve a abrir Instalar Pokimon.'}
    $eula=Join-Path $server 'eula.txt'
    if(-not (Test-Path -LiteralPath $eula) -or [IO.File]::ReadAllText($eula) -notmatch '(?m)^eula=true\s*$') {
        Write-Host 'Minecraft EULA: https://aka.ms/MinecraftEULA'
        $accept=Read-Host 'Para instalar tu servidor debes aceptar la EULA de Minecraft. Escribe SI para aceptar'
        if($accept.Trim().ToUpperInvariant() -notin @('SI','S')) {throw 'No se acepto la EULA. El servidor no se ha iniciado.'}
        [IO.File]::WriteAllText($eula,"# https://aka.ms/MinecraftEULA`neula=true`n")
    }
    Install-PokimonShortcuts $settings $settingsPath $scripts
    . (Join-Path $PSScriptRoot 'Client-ServerEntry.ps1')
    Add-PokimonClientEntry $profile $state
} finally {$guard.Dispose()}
& (Join-Path $scripts 'Start-SharedServer.ps1') -SettingsPath $settingsPath -SyncOnly
Write-Host ''
Write-Host 'INSTALADO. Usa Iniciar servidor Pokimon en el escritorio y espera a que termine de arrancar.' -ForegroundColor Green
Write-Host 'Abre tu COBBLEVERSE habitual en Modrinth > Multijugador > Pokimon - partida compartida.'
Write-Host 'Al terminar: stop en la consola, espera LISTO y ya puede jugar el otro PC.'
