param([Parameter(Mandatory=$true)][string]$SettingsPath,[Parameter(Mandatory=$true)][string]$SnapshotDirectory,[Parameter(Mandatory=$true)][string]$ReportPath)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Shared.ps1')
$settings=Read-SyncJson $SettingsPath
$a=$settings | ConvertTo-Json | ConvertFrom-Json;$b=$settings | ConvertTo-Json | ConvertFrom-Json
$a | Add-Member -NotePropertyName deviceId -NotePropertyValue ([Guid]::NewGuid().ToString('N')) -Force
$b | Add-Member -NotePropertyName deviceId -NotePropertyValue ([Guid]::NewGuid().ToString('N')) -Force
$script:SharedFile='verification/'+[Guid]::NewGuid().ToString('N')+'.json'
$manifest=Read-PokimonManifest $SnapshotDirectory
$repo=Invoke-PokimonApi $settings.ghPath ('repos/'+$settings.repository)
try {Invoke-PokimonApi $settings.ghPath ('repos/'+$settings.repository+'/git/ref/heads/'+$script:SharedBranch) | Out-Null}
catch {
    if($_.Exception.Message -notmatch 'HTTP 404'){throw}
    $main=Invoke-PokimonApi $settings.ghPath ('repos/'+$settings.repository+'/git/ref/heads/'+$repo.default_branch)
    $request=Join-Path $settings.stateDirectory 'test-create-state-branch.json'
    Write-SyncJson $request ([pscustomobject]@{ref=('refs/heads/'+$script:SharedBranch);sha=$main.object.sha})
    Invoke-PokimonApi $settings.ghPath ('repos/'+$settings.repository+'/git/refs') 'POST' $request | Out-Null
}
$value=[pscustomobject]@{format='pokimon-shared';schema=1;snapshot=$manifest.id;manifestSha256=(Get-SyncHash (Join-Path $SnapshotDirectory 'manifest.json'));generation=0;owner=$null;updatedUtc=[DateTime]::UtcNow.ToString('o')}
$sessionA=[pscustomobject]@{sessionId=[Guid]::NewGuid().ToString('N')};$sessionB=[pscustomobject]@{sessionId=[Guid]::NewGuid().ToString('N')}
$stale=Set-SharedState $a $null $value 'Create coordination verification metadata'
Enter-SharedSession $a $sessionA | Out-Null
$secondBlocked=$false;try{Enter-SharedSession $b $sessionB | Out-Null}catch{$secondBlocked=$true}
if(-not $secondBlocked){throw 'La prueba real no bloqueo el segundo PC.'}
$staleBlocked=$false;try{Set-SharedState $b $stale $stale.value 'Stale coordination test' | Out-Null}catch{if($_.Exception.Message -match 'HTTP 409|HTTP 422'){$staleBlocked=$true}else{throw}}
if(-not $staleBlocked){throw 'La prueba real no rechazo una escritura desactualizada.'}
Leave-SharedSession $a $sessionA | Out-Null
Enter-SharedSession $b $sessionB | Out-Null
Leave-SharedSession $b $sessionB | Out-Null
$finished=Get-SharedState $a
if($finished.value.owner){throw 'La prueba dejo una reserva activa.'}
$request=Join-Path $settings.stateDirectory 'delete-coordination-verification.json'
Write-SyncJson $request ([pscustomobject]@{message='Remove completed coordination verification metadata';branch=$script:SharedBranch;sha=$finished.sha})
Invoke-PokimonApi $settings.ghPath ('repos/'+$settings.repository+'/contents/'+$script:SharedFile) 'DELETE' $request | Out-Null
$report=[pscustomobject]@{passed=$true;liveGitHubTest=$true;secondHostBlocked=$secondBlocked;staleWriteRejected=$staleBlocked;turnTransferred=$true;testStateRemoved=$true;productionSessionStateModified=$false;at=[DateTime]::UtcNow.ToString('o')}
Write-SyncJson $ReportPath $report
$report | ConvertTo-Json
