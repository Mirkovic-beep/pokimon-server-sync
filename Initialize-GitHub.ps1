param([Parameter(Mandatory=$true)][string]$SettingsPath,[string]$GitPath='git')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'GitHub.ps1')
$settings=Read-SyncJson $SettingsPath
Assert-GitHubRepository $settings.repository
$user=Invoke-PokimonApi $settings.ghPath 'user'
if($user.login -ine $settings.repository.Split('/')[0]) {throw 'La cuenta de GitHub CLI no coincide con el propietario configurado.'}
$expectedFiles=@('README.md','.gitignore','Snapshot.ps1','GitHub.ps1','After-ServerStop.ps1','Retry-Upload.ps1','Download-Latest.ps1','Enable-AutoBackup.ps1','Initialize-GitHub.ps1','Test-Sync.ps1','settings.example.json')
foreach($name in $expectedFiles) {if(-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $name))) {throw 'Faltan archivos del proyecto local.'}}
function Run-Git([string[]]$GitArguments) {& $GitPath -C $PSScriptRoot @GitArguments;if($LASTEXITCODE -ne 0){throw 'No se ha completado la preparacion de Git.'}}
if(-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot '.git'))) {
    Run-Git @('init','--initial-branch=main')
    Run-Git @('config','user.name',$user.login)
    Run-Git @('config','user.email',($user.id.ToString()+'+'+$user.login+'@users.noreply.github.com'))
    Run-Git (@('add','--')+$expectedFiles)
    Run-Git @('commit','-m','Add verified multipart Minecraft server backups')
}
Invoke-PokimonGh $settings.ghPath @('repo','create',$settings.repository,'--public','--source',$PSScriptRoot,'--remote','origin','--push','--description','Herramientas y copias completas de la partida Pokimon mediante GitHub Releases.') | Write-Host
Write-Host 'Repositorio publico creado. Activar el lanzador solo despues de comprobar el acceso y las pruebas.'
