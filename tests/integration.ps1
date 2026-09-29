$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$workRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot 'work'))
$testRoot = [IO.Path]::GetFullPath((Join-Path $workRoot ('farfile-test-' + [guid]::NewGuid().ToString('N'))))
if (-not $testRoot.StartsWith($workRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Test directory escaped the intended work directory.'
}
New-Item -ItemType Directory -Path $workRoot -Force | Out-Null
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

$previousConfig = $env:FARFILE_CONFIG
$broker = $null
$secondBroker = $null
try {
    $brokerProject = Join-Path $projectRoot 'src\FarFile.Broker\FarFile.Broker.csproj'
    $clientProject = Join-Path $projectRoot 'src\FarFile.Client\FarFile.Client.csproj'
    & dotnet build $brokerProject -c Release -v quiet | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Broker build failed.' }
    & dotnet build $clientProject -c Release -v quiet | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Client build failed.' }

    $brokerDll = Join-Path $projectRoot 'src\FarFile.Broker\bin\Release\net10.0\FarFile.Broker.dll'
    $clientDll = Join-Path $projectRoot 'src\FarFile.Client\bin\Release\net10.0\FarFile.Client.dll'

    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port

    $secondListener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $secondListener.Start()
    $secondPort = ([Net.IPEndPoint]$secondListener.LocalEndpoint).Port
    $listener.Stop()
    $secondListener.Stop()

    $endpoint = "http://127.0.0.1:$port/"
    $secondEndpoint = "http://127.0.0.1:$secondPort/"
    $configPath = Join-Path $testRoot 'machines.json'
    @{ work = $endpoint; home = $secondEndpoint } | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding utf8
    $env:FARFILE_CONFIG = $configPath

    $broker = Start-Process -FilePath dotnet -ArgumentList "`"$brokerDll`" --listen 127.0.0.1:$port" `
        -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $testRoot 'broker.out') `
        -RedirectStandardError (Join-Path $testRoot 'broker.err')
    $secondBroker = Start-Process -FilePath dotnet -ArgumentList "`"$brokerDll`" --listen 127.0.0.1:$secondPort" `
        -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $testRoot 'second-broker.out') `
        -RedirectStandardError (Join-Path $testRoot 'second-broker.err')

    $ready = $false
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        if ($broker.HasExited -or $secondBroker.HasExited) { throw 'Broker exited during startup.' }
        try {
            Invoke-WebRequest -Uri ($endpoint + 'v1/stat?path=%2F') -TimeoutSec 1 | Out-Null
            Invoke-WebRequest -Uri ($secondEndpoint + 'v1/stat?path=%2F') -TimeoutSec 1 | Out-Null
            $ready = $true
            break
        } catch {
            Start-Sleep -Milliseconds 100
        }
    }
    if (-not $ready) { throw 'Broker did not start.' }

    function Invoke-FarFile([string[]]$arguments) {
        $result = & dotnet $clientDll @arguments
        if ($LASTEXITCODE -ne 0) { throw "Client failed: $($arguments -join ' ')" }
        return $result
    }
    function Assert($condition, [string]$message) {
        if (-not $condition) { throw $message }
    }

    $remoteDir = (Join-Path $testRoot 'remote').Replace('\', '/')
    $sourceRemote = "$remoteDir/тест.bin"
    $copyRemote = "$remoteDir/copy.bin"
    $renamedRemote = "$remoteDir/renamed.bin"
    $localSource = Join-Path $testRoot 'source.bin'
    $localDownload = Join-Path $testRoot 'download.bin'
    $localCopy = Join-Path $testRoot 'relay.bin'
    $bytes = [byte[]]::new(1024 * 1024 + 17)
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    [IO.File]::WriteAllBytes($localSource, $bytes)

    Invoke-FarFile @('mkdir', 'work', $remoteDir) | Out-Null
    Invoke-FarFile @('put', 'work', $localSource, $sourceRemote) | Out-Null

    $listed = Invoke-FarFile @('ls', 'work', $remoteDir, '--json') | ConvertFrom-Json
    Assert ($listed.Count -eq 1 -and $listed[0].name -eq 'тест.bin' -and
        $listed[0].kind -eq 'file' -and $listed[0].size -eq $bytes.Length) 'List metadata mismatch.'
    $stat = Invoke-FarFile @('stat', 'work', $sourceRemote, '--json') | ConvertFrom-Json
    Assert ($stat.size -eq $bytes.Length -and $stat.mtime -gt 0) 'Stat metadata mismatch.'

    Invoke-FarFile @('get', 'work', $sourceRemote, $localDownload) | Out-Null
    Assert ((Get-FileHash -LiteralPath $localSource).Hash -eq (Get-FileHash -LiteralPath $localDownload).Hash) 'Download differs.'

    $readInfo = [Diagnostics.ProcessStartInfo]::new()
    $readInfo.FileName = 'dotnet'
    $readInfo.UseShellExecute = $false
    $readInfo.CreateNoWindow = $true
    $readInfo.RedirectStandardOutput = $true
    $readInfo.RedirectStandardError = $true
    foreach ($argument in @($clientDll, 'read', 'work', $sourceRemote, '--offset', '123', '--length', '4')) {
        $readInfo.ArgumentList.Add($argument)
    }
    $readProcess = [Diagnostics.Process]::Start($readInfo)
    if (-not $readProcess.WaitForExit(10000)) { $readProcess.Kill(); throw 'Binary read timed out.' }
    $readBytes = [byte[]]::new(4)
    $actual = $readProcess.StandardOutput.BaseStream.Read($readBytes, 0, 4)
    Assert ($readProcess.ExitCode -eq 0 -and $actual -eq 4 -and
        [Convert]::ToHexString($readBytes) -eq [Convert]::ToHexString($bytes[123..126])) 'Range read differs.'

    $copied = Invoke-FarFile @('cp', 'work', $sourceRemote, 'home', $copyRemote)
    Assert ([long]$copied -eq $bytes.Length) 'Relay reported wrong byte count.'
    Invoke-FarFile @('get', 'home', $copyRemote, $localCopy) | Out-Null
    Assert ((Get-FileHash -LiteralPath $localSource).Hash -eq (Get-FileHash -LiteralPath $localCopy).Hash) 'Relay copy differs.'

    $writeInfo = [Diagnostics.ProcessStartInfo]::new()
    $writeInfo.FileName = 'dotnet'
    $writeInfo.UseShellExecute = $false
    $writeInfo.CreateNoWindow = $true
    $writeInfo.RedirectStandardInput = $true
    $writeInfo.RedirectStandardError = $true
    foreach ($argument in @($clientDll, 'write', 'home', $copyRemote, '--offset', '123', '--length', '4')) {
        $writeInfo.ArgumentList.Add($argument)
    }
    $writeProcess = [Diagnostics.Process]::Start($writeInfo)
    $replacement = [byte[]](0, 1, 2, 255)
    $writeProcess.StandardInput.BaseStream.Write($replacement, 0, $replacement.Length)
    $writeProcess.StandardInput.BaseStream.Flush()
    # The stdin pipe remains open: --length must let the client complete anyway.
    if (-not $writeProcess.WaitForExit(10000)) { $writeProcess.Kill(); throw 'Fixed-length write waited for stdin EOF.' }
    $writeProcess.StandardInput.Close()
    Assert ($writeProcess.ExitCode -eq 0) ('Range write failed: ' + $writeProcess.StandardError.ReadToEnd())
    Invoke-FarFile @('get', 'home', $copyRemote, $localCopy) | Out-Null
    $written = [IO.File]::ReadAllBytes($localCopy)
    Assert ($written.Length -eq $bytes.Length -and
        [Convert]::ToHexString($written[123..126]) -eq [Convert]::ToHexString($replacement)) 'Range write differs.'

    Invoke-FarFile @('mv', 'home', $copyRemote, $renamedRemote) | Out-Null
    Invoke-FarFile @('mtime', 'home', $renamedRemote, '1700000000') | Out-Null
    $changed = Invoke-FarFile @('stat', 'home', $renamedRemote, '--json') | ConvertFrom-Json
    Assert ([math]::Abs($changed.mtime - 1700000000) -lt 1) 'Mtime update failed.'

    Invoke-FarFile @('mkdir', 'work', "$remoteDir/nested/sub") | Out-Null
    & dotnet $clientDll rmdir work $remoteDir 2>$null | Out-Null
    Assert ($LASTEXITCODE -ne 0) 'Nonempty rmdir unexpectedly succeeded.'
    Invoke-FarFile @('rmdir-all', 'work', "$remoteDir/nested") | Out-Null
    Assert (-not (Test-Path -LiteralPath (Join-Path $testRoot 'remote\nested'))) 'Recursive removal failed.'

    Invoke-FarFile @('rm', 'work', $sourceRemote) | Out-Null
    Invoke-FarFile @('rm', 'home', $renamedRemote) | Out-Null
    Invoke-FarFile @('rmdir', 'work', $remoteDir) | Out-Null
    Assert (-not (Test-Path -LiteralPath (Join-Path $testRoot 'remote'))) 'Directory removal failed.'

    Write-Host 'FarFile integration tests passed.'
}
finally {
    $env:FARFILE_CONFIG = $previousConfig
    if ($broker -and -not $broker.HasExited) {
        Stop-Process -Id $broker.Id -Force
        $broker.WaitForExit()
    }
    if ($secondBroker -and -not $secondBroker.HasExited) {
        Stop-Process -Id $secondBroker.Id -Force
        $secondBroker.WaitForExit()
    }
    if ($testRoot.StartsWith($workRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $testRoot)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
