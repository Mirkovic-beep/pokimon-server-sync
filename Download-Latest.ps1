param([Parameter(Mandatory=$true)][string]$SettingsPath,[Parameter(Mandatory=$true)][string]$Destination)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'GitHub.ps1')
$settings=Read-SyncJson $SettingsPath
$downloads=Join-Path $settings.stateDirectory ('downloads\'+[Guid]::NewGuid().ToString('N'))
$result=Receive-PokimonSnapshot $settings.repository $settings.ghPath $downloads $Destination
Write-Host ('Copia '+$result.id+' descargada y verificada en '+$Destination)
Write-Host 'La carpeta contiene los datos del servidor. Para usarlos hacen falta las mismas versiones de los mods indicadas en el manifiesto.'
