param([Parameter(Mandatory=$true)][string]$TestDirectory)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'GitHub.ps1')
if(Test-Path -LiteralPath $TestDirectory) {throw 'Las pruebas requieren una carpeta nueva.'}
[IO.Directory]::CreateDirectory($TestDirectory) | Out-Null
$passed=New-Object 'Collections.Generic.List[string]'
function Assert-Test($Condition,[string]$Description) {if(-not $Condition){throw ('Fallo de prueba: '+$Description)};$passed.Add($Description)}
function Expect-Failure([scriptblock]$Action,[string]$Description) {$failed=$false;try{& $Action | Out-Null}catch{$failed=$true};Assert-Test $failed $Description}
$fixture=Join-Path $TestDirectory 'server'
foreach($relative in @('world\region','world\playerdata','world\dimensions\mod\dimension','mods','config','legendary-monuments-data','logs')) {[IO.Directory]::CreateDirectory((Join-Path $fixture $relative)) | Out-Null}
$random=New-Object byte[] (96KB)
$rng=[Security.Cryptography.RandomNumberGenerator]::Create();$rng.GetBytes($random);$rng.Dispose()
[IO.File]::WriteAllBytes((Join-Path $fixture 'world\region\r.0.0.mca'),$random)
[IO.File]::WriteAllText((Join-Path $fixture 'world\level.dat'),'fixture-level-data')
[IO.File]::WriteAllText((Join-Path $fixture 'world\playerdata\player.dat'),'fixture-inventory-and-pokemon')
[IO.File]::WriteAllText((Join-Path $fixture 'world\dimensions\mod\dimension\data.dat'),'fixture-dimension')
[IO.File]::WriteAllText((Join-Path $fixture 'legendary-monuments-data\progress.json'),'{"progress":9}')
[IO.File]::WriteAllText((Join-Path $fixture 'config\mod.json'),'{"enabled":true}')
[IO.File]::WriteAllText((Join-Path $fixture 'ops.json'),'[]')
[IO.File]::WriteAllText((Join-Path $fixture 'mods\example.jar'),'mod-file-is-fingerprinted-not-published')
[IO.File]::WriteAllText((Join-Path $fixture 'logs\latest.log'),'private log excluded')
[IO.File]::WriteAllText((Join-Path $fixture 'private-router-settings.txt'),'outside allowed backup roots')
$lock=[IO.File]::Open((Join-Path $fixture 'world\session.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try {Expect-Failure {New-PokimonSnapshot $fixture (Join-Path $TestDirectory 'running-world') 4096} 'Refuses to snapshot a world held open by Minecraft'}finally{$lock.Dispose()}
$backup=Join-Path $TestDirectory 'backup'
$manifest=New-PokimonSnapshot $fixture $backup 4096
Assert-Test (@($manifest.parts).Count -gt 2) 'Splits the archive into multiple bounded parts'
Assert-Test (@($manifest.files | Where-Object {$_.path -match 'logs/|private-router|session\.lock|^mods/'}).Count -eq 0) 'Excludes logs, session lock, unrelated files and mod binaries'
Assert-Test (@($manifest.files | Where-Object {$_.path -eq 'legendary-monuments-data/progress.json'}).Count -eq 1) 'Includes persistent mod data outside the world directory'
Assert-Test (@($manifest.mods).Count -eq 1) 'Records the required mod binary fingerprint'
$restore=Join-Path $TestDirectory 'restored'
Expand-PokimonSnapshot $backup $restore | Out-Null
foreach($file in $manifest.files) {
    if((Get-SyncHash (Get-SnapshotDestination $fixture $file.path)) -ne (Get-SyncHash (Get-SnapshotDestination $restore $file.path))) {throw 'El archivo restaurado no coincide con el origen.'}
}
$passed.Add('Restores every included file with its original SHA-256')
Expect-Failure {Expand-PokimonSnapshot $backup $fixture} 'Refuses to overwrite an existing server or directory'
$damaged=Join-Path $TestDirectory 'damaged'
Copy-Item -LiteralPath $backup -Destination $damaged -Recurse
$damagedPart=Join-Path $damaged $manifest.parts[0].name
$damagedBytes=[IO.File]::ReadAllBytes($damagedPart);$damagedBytes[0]=$damagedBytes[0] -bxor 1;[IO.File]::WriteAllBytes($damagedPart,$damagedBytes)
Expect-Failure {Expand-PokimonSnapshot $damaged (Join-Path $TestDirectory 'must-not-exist')} 'Rejects a damaged part before extracting'
Assert-Test (-not (Test-Path -LiteralPath (Join-Path $TestDirectory 'must-not-exist'))) 'Leaves the destination untouched when validation fails'
$malicious=Join-Path $TestDirectory 'malicious'
Copy-Item -LiteralPath $backup -Destination $malicious -Recurse
$maliciousManifest=Read-SyncJson (Join-Path $malicious 'manifest.json')
$maliciousManifest.files[0].path='world/../../outside.txt'
Write-SyncJson (Join-Path $malicious 'manifest.json') $maliciousManifest
Expect-Failure {Expand-PokimonSnapshot $malicious (Join-Path $TestDirectory 'unsafe-output')} 'Rejects paths that escape the restore directory'
[IO.File]::WriteAllText((Join-Path $fixture 'config\credential.json'),'{"api_key":"example-test-credential-only"}')
Expect-Failure {New-PokimonSnapshot $fixture (Join-Path $TestDirectory 'secret-copy') 4096} 'Blocks a public copy containing a credential setting'

# A simulated CLI exercises interruption/resume and publication ordering without a network account.
$mockPath=Join-Path $TestDirectory 'mock-gh.ps1'
$mockSource=@'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$CommandArguments)
$global:LASTEXITCODE=0
$state=Read-SyncJson (Join-Path $PSScriptRoot 'mock-state.json')
function Save-Mock {Write-SyncJson (Join-Path $PSScriptRoot 'mock-state.json') $state}
function Arg-After([string]$Flag) {$index=[Array]::IndexOf($CommandArguments,$Flag);if($index -ge 0){return $CommandArguments[$index+1]}}
if($CommandArguments[0] -eq 'api') {
    $endpoint=$CommandArguments[3];$method=Arg-After '--method'
    if($endpoint -eq 'repos/test-owner/pokimon') {Write-Output '{"full_name":"test-owner/pokimon","private":false,"default_branch":"main","permissions":{"push":true}}';return}
    if($endpoint -match '/releases/tags/' -and (-not $state.release -or $state.release.draft)) {$global:LASTEXITCODE=1;Write-Output 'Not Found (HTTP 404)';return}
    if($endpoint -match '/releases$' -and $method -eq 'POST') {
        $spec=Read-SyncJson (Arg-After '--input')
        $state.release=[pscustomobject]@{id=1;tag_name=$spec.tag_name;draft=$true;assets=@();html_url=('https://github.com/test-owner/pokimon/releases/tag/'+$spec.tag_name)}
        Save-Mock;$state.release | ConvertTo-Json -Depth 6;return
    }
    if($method -eq 'PATCH') {$state.release.draft=$false;$state.publishCalls++;Save-Mock}
    $state.release | ConvertTo-Json -Depth 6;return
}
if($CommandArguments[0] -eq 'release' -and $CommandArguments[1] -eq 'upload') {
    $file=$CommandArguments[3];$name=[IO.Path]::GetFileName($file)
    $state.uploadAttempts=@($state.uploadAttempts)+$name
    if($state.failOnce -and @($state.release.assets).Count -eq 1) {$state.failOnce=$false;Save-Mock;$global:LASTEXITCODE=1;Write-Output 'Simulated transfer interruption';return}
    $asset=[pscustomobject]@{name=$name;size=(Get-Item -LiteralPath $file).Length;digest=('sha256:'+(Get-SyncHash $file));state='uploaded';source=$file}
    $state.release.assets=@($state.release.assets)+$asset
    Save-Mock;return
}
if($CommandArguments[0] -eq 'release' -and $CommandArguments[1] -eq 'download') {
    $name=Arg-After '--pattern';$outputPath=Arg-After '--output';$asset=$state.release.assets | Where-Object {$_.name -eq $name}
    Copy-Item -LiteralPath $asset.source -Destination $outputPath;return
}
$global:LASTEXITCODE=1;Write-Output 'Unexpected simulated CLI command'
'@
[IO.File]::WriteAllText($mockPath,$mockSource,(New-Object Text.UTF8Encoding($false)))
Write-SyncJson (Join-Path $TestDirectory 'mock-state.json') ([pscustomobject]@{release=$null;failOnce=$true;publishCalls=0;uploadAttempts=@()})
Expect-Failure {Publish-PokimonSnapshot $backup 'test-owner/pokimon' $mockPath} 'Surfaces an interrupted upload and keeps the local copy'
$state=Read-SyncJson (Join-Path $TestDirectory 'mock-state.json')
Assert-Test ($state.release.draft -eq $true -and $state.publishCalls -eq 0) 'Never publishes an incomplete upload'
$lostResponseStatus=Read-SyncJson (Join-Path $backup 'publication.json');$lostResponseStatus.releaseId=$null;Write-SyncJson (Join-Path $backup 'publication.json') $lostResponseStatus
$published=Publish-PokimonSnapshot $backup 'test-owner/pokimon' $mockPath
$state=Read-SyncJson (Join-Path $TestDirectory 'mock-state.json')
Assert-Test ($published.published -and $state.publishCalls -eq 1) 'Publishes only after every remote asset hash and size match'
Assert-Test ($state.release.id -eq $published.releaseId) 'Recovers an existing draft even when the tag endpoint returns 404 and the local release id was lost'
Assert-Test (@($state.uploadAttempts | Where-Object {$_ -eq $manifest.parts[0].name}).Count -eq 1) 'Resumes without uploading the already verified first part again'
Receive-PokimonSnapshot 'test-owner/pokimon' $mockPath (Join-Path $TestDirectory 'downloaded') (Join-Path $TestDirectory 'download-restored') | Out-Null
Assert-Test ((Get-SyncHash (Join-Path $TestDirectory 'download-restored\world\region\r.0.0.mca')) -eq (Get-SyncHash (Join-Path $fixture 'world\region\r.0.0.mca'))) 'Downloads and restores a multipart release through the CLI transport'
$state=Read-SyncJson (Join-Path $TestDirectory 'mock-state.json');$state.release.assets[0].digest='sha256:'+('0'*64);Write-SyncJson (Join-Path $TestDirectory 'mock-state.json') $state
Expect-Failure {Publish-PokimonSnapshot $backup 'test-owner/pokimon' $mockPath} 'Rejects a remote attachment whose digest has changed'

# Exercise the installed wrapper with a harmless server stub and the simulated remote.
[IO.File]::WriteAllText((Join-Path $fixture 'config\credential.json'),'{"enabled":true}')
$coreSource=@'
# Test stub for the launch sequence: -jar fabric-server-launch.jar
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'logs\latest.log'),"Stopping server`nAll dimensions are saved`n")
$global:LASTEXITCODE=0
'@
[IO.File]::WriteAllText((Join-Path $fixture 'Start-Server.ps1'),$coreSource)
Write-SyncJson (Join-Path $TestDirectory 'mock-state.json') ([pscustomobject]@{release=$null;failOnce=$false;publishCalls=0;uploadAttempts=@()})
$testSettingsPath=Join-Path $TestDirectory 'settings.local.json'
Write-SyncJson $testSettingsPath ([pscustomobject]@{enabled=$false;mode='single-host-backup';repository='test-owner/pokimon';serverDirectory=$fixture;stateDirectory=(Join-Path $TestDirectory 'wrapper-state');ghPath=$mockPath})
& (Join-Path $PSScriptRoot 'Enable-AutoBackup.ps1') -SettingsPath $testSettingsPath
Assert-Test ([IO.File]::ReadAllText((Join-Path $fixture 'Start-Server-without-backup.ps1')) -eq $coreSource) 'Preserves the original server launcher when activating backups'
& (Join-Path $fixture 'Start-Server.ps1')
$wrapperResult=Read-SyncJson (Join-Path $TestDirectory 'mock-state.json')
Assert-Test ($wrapperResult.publishCalls -eq 1 -and -not $wrapperResult.release.draft) 'The activated launcher publishes after a successful saved server exit'
Expect-Failure {& (Join-Path $PSScriptRoot 'After-ServerStop.ps1') -SettingsPath $testSettingsPath -ServerExitCode 1 -SessionStartedUtc ([DateTime]::UtcNow)} 'Does not automatically publish after an abnormal server exit'
$report=[pscustomobject]@{at=[DateTime]::UtcNow.ToString('o');passed=$true;tests=@($passed.ToArray());testCount=$passed.Count;liveGitHubUploadTested=$false;productionWorldUsed=$false}
Write-SyncJson (Join-Path $TestDirectory 'test-result.json') $report
$report | ConvertTo-Json -Depth 5
