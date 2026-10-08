param([Parameter(Mandatory=$true)][string]$TestDirectory)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Installer.ps1')
. (Join-Path $PSScriptRoot 'Client-ServerEntry.ps1')
if(Test-Path -LiteralPath $TestDirectory){throw 'Las pruebas necesitan una carpeta nueva.'}
[IO.Directory]::CreateDirectory($TestDirectory) | Out-Null
$passed=New-Object 'Collections.Generic.List[string]'
function Check($Condition,[string]$Description){if(-not $Condition){throw ('Fallo: '+$Description)};$passed.Add($Description)}
function Fails([scriptblock]$Action,[string]$Description){$failed=$false;try{& $Action | Out-Null}catch{$failed=$true};Check $failed $Description}
$mockPath=Join-Path $TestDirectory 'mock-gh.ps1'
$mock=@'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$CommandArguments)
$global:LASTEXITCODE=0
$stateFile=Join-Path $PSScriptRoot 'mock.json'
$state=Read-SyncJson $stateFile
function Save-Mock {Write-SyncJson $stateFile $state}
function Flag([string]$Name){$index=[Array]::IndexOf($CommandArguments,$Name);if($index -ge 0){return $CommandArguments[$index+1]}}
function Fail([string]$Message){$global:LASTEXITCODE=1;Write-Output $Message}
if($CommandArguments[0] -eq 'api') {
    $endpoint=$CommandArguments[3];$method=Flag '--method'
    if($endpoint -eq 'repos/test-owner/pokimon'){Write-Output '{"full_name":"test-owner/pokimon","private":false,"default_branch":"main","permissions":{"push":true}}';return}
    if($endpoint -match '/contents/') {
        if($state.offline){Fail 'Simulated network failure';return}
        if($method -eq 'PUT') {
            $spec=Read-SyncJson (Flag '--input')
            if($spec.sha -ne $state.contentSha){Fail 'Conflict (HTTP 409)';return}
            $state.content=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($spec.content)) | ConvertFrom-Json
            $state.contentSha=[Guid]::NewGuid().ToString('N')+'00000000';Save-Mock
            [pscustomobject]@{content=[pscustomobject]@{sha=$state.contentSha}} | ConvertTo-Json;return
        }
        [pscustomobject]@{type='file';encoding='base64';sha=$state.contentSha;content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($state.content | ConvertTo-Json -Depth 8)))} | ConvertTo-Json -Depth 10;return
    }
    if($endpoint -match '/releases$' -and $method -eq 'POST') {
        $spec=Read-SyncJson (Flag '--input');$id=@($state.releases).Count+1
        $release=[pscustomobject]@{id=$id;tag_name=$spec.tag_name;draft=$true;assets=@();html_url=('https://github.com/test-owner/pokimon/releases/tag/'+$spec.tag_name)}
        $state.releases=@($state.releases)+$release;Save-Mock;$release | ConvertTo-Json -Depth 8;return
    }
    $release=$null
    if($endpoint -match '/releases/tags/(.+)$'){$tag=$Matches[1];$release=$state.releases | Where-Object {$_.tag_name -eq $tag}}
    elseif($endpoint -match '/releases/(\d+)$'){$id=[int]$Matches[1];$release=$state.releases | Where-Object {$_.id -eq $id}}
    elseif($endpoint -match '/releases/latest$'){$release=$state.releases | Where-Object {-not $_.draft} | Select-Object -Last 1}
    if(-not $release){Fail 'Not Found (HTTP 404)';return}
    if($method -eq 'PATCH'){$release.draft=$false;Save-Mock}
    $release | ConvertTo-Json -Depth 8;return
}
if($CommandArguments[0] -eq 'release') {
    $tag=$CommandArguments[2];$release=$state.releases | Where-Object {$_.tag_name -eq $tag}
    if($CommandArguments[1] -eq 'upload') {
        if($state.failUpload){$state.failUpload=$false;Save-Mock;Fail 'Simulated interrupted upload';return}
        $path=$CommandArguments[3]
        $asset=[pscustomobject]@{id=@($release.assets).Count+1;name=[IO.Path]::GetFileName($path);size=(Get-Item -LiteralPath $path).Length;digest=('sha256:'+(Get-SyncHash $path));state='uploaded';source=$path}
        $release.assets=@($release.assets)+$asset;Save-Mock;return
    }
    if($CommandArguments[1] -eq 'download'){$name=Flag '--pattern';$asset=$release.assets | Where-Object {$_.name -eq $name};Copy-Item -LiteralPath $asset.source -Destination (Flag '--output') -Force;return}
}
Fail 'Unexpected mock command'
'@
[IO.File]::WriteAllText($mockPath,$mock)
Write-SyncJson (Join-Path $TestDirectory 'mock.json') ([pscustomobject]@{content=$null;contentSha=$null;releases=@();offline=$false;failUpload=$false})
function New-Fixture([string]$Name,[bool]$World) {
    $root=Join-Path $TestDirectory $Name;$server=Join-Path $root 'server';$state=Join-Path $root 'state'
    foreach($path in @($server,$state,(Join-Path $server 'mods'),(Join-Path $server 'logs'))){[IO.Directory]::CreateDirectory($path) | Out-Null}
    [IO.File]::WriteAllText((Join-Path $server 'mods\example.jar'),'known-mod')
    if($World) {
        foreach($name in @('world\playerdata','config')){[IO.Directory]::CreateDirectory((Join-Path $server $name)) | Out-Null}
        [IO.File]::WriteAllText((Join-Path $server 'world\level.dat'),'fixture-NBT')
        [IO.File]::WriteAllText((Join-Path $server 'world\playerdata\player.dat'),'both inventories and pokemon')
        [IO.File]::WriteAllText((Join-Path $server 'config\.hidden.json'),'{"visible":false}')
        (Get-Item -LiteralPath (Join-Path $server 'config\.hidden.json') -Force).Attributes=[IO.FileAttributes]::Hidden
    }
    $java=Join-Path $server 'fake-java.ps1'
    $javaSource=@'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'world\playerdata\player.dat'),('new progress '+[Guid]::NewGuid().ToString('N')))
if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'fail-next')){[IO.File]::Delete((Join-Path $PSScriptRoot 'fail-next'));[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'logs\latest.log'),'server crashed');$global:LASTEXITCODE=1;return}
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'logs\latest.log'),"Stopping server`nAll dimensions are saved`n")
$global:LASTEXITCODE=0
'@
    [IO.File]::WriteAllText($java,$javaSource)
    $settings=[pscustomobject]@{enabled=$true;mode='shared-host';repository='test-owner/pokimon';serverDirectory=$server;stateDirectory=$state;ghPath=$mockPath;javaPath=$java;memoryGB=4;deviceId=[Guid]::NewGuid().ToString('N')}
    Write-SyncJson (Join-Path $root 'settings.local.json') $settings
    return $settings
}
$a=New-Fixture 'pc-a' $true;$b=New-Fixture 'pc-b' $false
$aPath=Join-Path $TestDirectory 'pc-a\settings.local.json';$bPath=Join-Path $TestDirectory 'pc-b\settings.local.json'
$initialDir=Join-Path $TestDirectory 'initial'
$initial=New-PokimonSnapshot $a.serverDirectory $initialDir -Mode shared-host
Check (@($initial.files | Where-Object {$_.path -eq 'config/.hidden.json'}).Count -eq 1) 'Includes hidden mod files in the real Windows filesystem'
Publish-PokimonSnapshot $initialDir $a.repository $mockPath | Out-Null
$state=[pscustomobject]@{format='pokimon-shared';schema=1;snapshot=$initial.id;manifestSha256=(Get-SyncHash (Join-Path $initialDir 'manifest.json'));generation=0;owner=$null;updatedUtc=[DateTime]::UtcNow.ToString('o')}
Set-SharedState $a $null $state 'Initialize test' | Out-Null
Write-SyncJson (Join-Path $a.stateDirectory 'baseline.local.json') $initial
$sessionA=[pscustomobject]@{sessionId=[Guid]::NewGuid().ToString('N')}
$sessionB=[pscustomobject]@{sessionId=[Guid]::NewGuid().ToString('N')}
$stale=Get-SharedState $a
Enter-SharedSession $a $sessionA | Out-Null
Fails {Enter-SharedSession $b $sessionB} 'A second PC cannot acquire an occupied world'
Fails {Set-SharedState $b $stale $stale.value 'Stale write'} 'A stale compare-and-swap cannot overwrite a newer reservation'
Enter-SharedSession $a $sessionA | Out-Null
Check ((Get-SharedState $a).value.owner.sessionId -eq $sessionA.sessionId) 'The owning session can reconnect without stealing a reservation'
Leave-SharedSession $a $sessionA | Out-Null
$mockState=Read-SyncJson (Join-Path $TestDirectory 'mock.json');$mockState.offline=$true;Write-SyncJson (Join-Path $TestDirectory 'mock.json') $mockState
Fails {& (Join-Path $PSScriptRoot 'Start-SharedServer.ps1') -SettingsPath $aPath} 'No connection means no offline launch that could fork the world'
$mockState.offline=$false;Write-SyncJson (Join-Path $TestDirectory 'mock.json') $mockState
& (Join-Path $PSScriptRoot 'Start-SharedServer.ps1') -SettingsPath $aPath
$afterA=Get-SharedState $a
Check (-not $afterA.value.owner -and $afterA.value.snapshot -ne $initial.id -and (Read-SyncJson (Join-Path $a.stateDirectory 'session.local.json')).phase -eq 'idle') 'A complete server session saves, uploads and releases the turn'
& (Join-Path $PSScriptRoot 'Start-SharedServer.ps1') -SettingsPath $bPath -SyncOnly
Check ((Get-SyncHash (Join-Path $b.serverDirectory 'world\playerdata\player.dat')) -eq (Get-SyncHash (Join-Path $a.serverDirectory 'world\playerdata\player.dat'))) 'The second PC downloads exactly the advances from the first PC'
$playerB=Join-Path $b.serverDirectory 'world\playerdata\player.dat';$before=[IO.File]::ReadAllText($playerB);[IO.File]::WriteAllText($playerB,'outside-launcher progress')
Fails {& (Join-Path $PSScriptRoot 'Start-SharedServer.ps1') -SettingsPath $bPath -SyncOnly} 'Unpublished local changes are never overwritten by a download'
Check ([IO.File]::ReadAllText($playerB) -eq 'outside-launcher progress') 'The local conflict leaves player data untouched'
[IO.File]::WriteAllText($playerB,$before)
& (Join-Path $PSScriptRoot 'Start-SharedServer.ps1') -SettingsPath $bPath -SyncOnly
$mockState=Read-SyncJson (Join-Path $TestDirectory 'mock.json');$mockState.failUpload=$true;Write-SyncJson (Join-Path $TestDirectory 'mock.json') $mockState
Fails {& (Join-Path $PSScriptRoot 'Start-SharedServer.ps1') -SettingsPath $aPath} 'An upload interruption is reported without releasing the world'
Check ((Get-SharedState $a).value.owner.deviceId -eq $a.deviceId) 'A failed upload retains the original host reservation'
Fails {& (Join-Path $PSScriptRoot 'Start-SharedServer.ps1') -SettingsPath $bPath -SyncOnly} 'The other PC cannot start while an upload is pending'
& (Join-Path $PSScriptRoot 'Start-SharedServer.ps1') -SettingsPath $aPath -UploadOnly
Check (-not (Get-SharedState $a).value.owner) 'Retry finishes a pending upload and then releases the turn'
[IO.File]::WriteAllText((Join-Path $a.serverDirectory 'fail-next'),'1')
Fails {& (Join-Path $PSScriptRoot 'Start-SharedServer.ps1') -SettingsPath $aPath} 'A server crash is not announced as a completed backup'
Check ((Read-SyncJson (Join-Path $a.stateDirectory 'session.local.json')).phase -eq 'playing') 'Crash recovery remembers that the local world contains unpublished progress'
Fails {& (Join-Path $PSScriptRoot 'Start-SharedServer.ps1') -SettingsPath $bPath -SyncOnly} 'An abrupt server exit keeps the other PC locked out'
& (Join-Path $PSScriptRoot 'Start-SharedServer.ps1') -SettingsPath $aPath
Check (-not (Get-SharedState $a).value.owner) 'Reopening the owning PC resumes its local world and completes a clean save'
Check (@(Get-ChildItem -LiteralPath (Join-Path $a.stateDirectory 'backups') -Directory).Count -eq 2) 'Keeps only the two latest completed local backups after verifying older copies on the remote'
& (Join-Path $PSScriptRoot 'Start-SharedServer.ps1') -SettingsPath $bPath -SyncOnly
Check (@(Get-ChildItem -LiteralPath (Join-Path $b.stateDirectory 'downloads') -Directory).Count -eq 0) 'Removes downloaded parts only after a complete verified restore'
Check (@(Get-ChildItem -LiteralPath (Join-Path $b.stateDirectory 'previous') -Directory | Where-Object {Test-Path -LiteralPath (Join-Path $_.FullName 'world\level.dat')}).Count -ge 1) 'Automatic replacement preserves the previous world in a separate local backup'
$pendingDir=Join-Path $a.stateDirectory 'backups\20000101-000000-aaaaaaaa'
Copy-Item -LiteralPath $initialDir -Destination $pendingDir -Recurse
$pendingStatus=Read-SyncJson (Join-Path $pendingDir 'publication.json');$pendingStatus.published=$false;Write-SyncJson (Join-Path $pendingDir 'publication.json') $pendingStatus
Clear-OldSyncCopies $a
Check (Test-Path -LiteralPath (Join-Path $pendingDir 'manifest.json')) 'Never prunes an unpublished pending local backup'

# Simulate a power loss after moving the old world but before applying all roots.
$baselineB=Read-SyncJson (Join-Path $b.stateDirectory 'baseline.local.json')
$rollback=Join-Path $b.stateDirectory 'previous\power-loss';$staging=Join-Path $b.stateDirectory 'staging\power-loss'
[IO.Directory]::CreateDirectory($rollback) | Out-Null;[IO.Directory]::CreateDirectory($staging) | Out-Null
Copy-Item -LiteralPath (Join-Path $b.stateDirectory 'baseline.local.json') -Destination (Join-Path $rollback 'baseline.local.json')
$oldNames=@((@($script:SnapshotDirectories)+@($script:SnapshotRootFiles)) | Where-Object {Test-Path -LiteralPath (Join-Path $b.serverDirectory $_)})
Write-SyncJson (Join-Path $b.stateDirectory 'apply.local.json') ([pscustomobject]@{server=$b.serverDirectory;backup=$rollback;staging=$staging;oldNames=$oldNames;newNames=@('world','config');hadBaseline=$true})
Move-SyncEntry $b.serverDirectory (Join-Path $b.serverDirectory 'world') $rollback (Join-Path $rollback 'world')
[IO.Directory]::CreateDirectory((Join-Path $b.serverDirectory 'world')) | Out-Null
[IO.File]::WriteAllText((Join-Path $b.serverDirectory 'world\level.dat'),'incomplete replacement')
Repair-ApplyTransaction $b
Assert-LocalBaseline $b.serverDirectory $baselineB
Check (-not (Test-Path -LiteralPath (Join-Path $b.stateDirectory 'apply.local.json'))) 'A interrupted replacement rolls back to the complete previous world'
Check (@(Get-ChildItem -LiteralPath $rollback -Directory | Where-Object {$_.Name -like 'incomplete-*'}).Count -eq 1) 'Incomplete replacement data is preserved for inspection during rollback'
Fails {Assert-SyncChild $b.stateDirectory 'C:\Windows'} 'Restore and cleanup paths cannot escape the installation state directory'
$nbt=[PokimonServerList]::Add($null)
Check ($nbt.Length -gt 0 -and $null -eq [PokimonServerList]::Add($nbt)) 'The Modrinth server entry is valid and is never duplicated'
Fails {[PokimonServerList]::Add([byte[]]@(10,0,0,9,0,7,115))} 'A malformed server list is rejected rather than overwritten'
$report=[pscustomobject]@{passed=$true;testCount=$passed.Count;tests=@($passed.ToArray());usesSyntheticWorlds=$true;liveGitHubTest=$false;at=[DateTime]::UtcNow.ToString('o')}
Write-SyncJson (Join-Path $TestDirectory 'test-result.json') $report
$report | ConvertTo-Json -Depth 5
