$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$packageRoot = Join-Path $root 'dist\tooldock'
$checkRoot = [IO.Path]::GetFullPath((Join-Path $root ('work\tooldock-package-check-' + [guid]::NewGuid().ToString('N'))))
$workRoot = [IO.Path]::GetFullPath((Join-Path $root 'work'))
if (-not $checkRoot.StartsWith($workRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Package check directory escaped work.'
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$broker = $null
$previousConfig = $env:FARFILE_CONFIG

try {
    foreach ($package in @(
        @{ Name = 'broker'; Asset = 'farfile-broker-win-x64.zip'; Program = 'FarFile.Broker.exe'; Catalog = 'server.json' },
        @{ Name = 'client'; Asset = 'farfile-client-win-x64.zip'; Program = 'FarFile.Client.exe'; Catalog = 'client.json' }
    )) {
        $catalog = Get-Content -Raw -LiteralPath (Join-Path $root "tooldock\$($package.Catalog)") | ConvertFrom-Json
        $definition = $catalog.tools."farfile-$($package.Name)"
        if ($definition.repo -cne 'vvladz/FarFile' -or $definition.asset -cne $package.Asset) {
            throw "Catalog does not match $($package.Asset)."
        }
        if ($package.Name -eq 'broker') {
            if ($definition.daemons.farfile.executable -cne $package.Program) { throw 'Broker executable mismatch.' }
        }
        elseif ($definition.commands.farfile.executable -cne $package.Program) { throw 'Client executable mismatch.' }

        $zipPath = Join-Path $packageRoot $package.Asset
        $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $expectedHash = [IO.File]::ReadAllText("$zipPath.sha256").Trim()
        if ($expectedHash -cne "$hash  $($package.Asset)") { throw "SHA-256 mismatch: $($package.Asset)" }

        $archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            $entries = @($archive.Entries | ForEach-Object FullName)
            if ($entries -cnotcontains $package.Program) { throw "ZIP lacks $($package.Program)." }
            if ($entries | Where-Object { $_.StartsWith('/') -or $_.Contains('..') -or $_.Contains('\') }) {
                throw "ZIP contains an unsafe path: $($package.Asset)"
            }
            if ($package.Name -eq 'client' -and $entries -cnotcontains 'yazi/farfile.yazi/main.lua') {
                throw 'Client ZIP lacks the Yazi adapter.'
            }
        }
        finally { $archive.Dispose() }

        $extract = Join-Path $checkRoot $package.Name
        [IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extract)
        & (Join-Path $extract $package.Program) --help | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "$($package.Program) failed to start." }
        Write-Output "OK $($package.Asset) $hash"
    }

    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    $listener.Stop()
    $endpoint = "http://127.0.0.1:$port/"
    $configPath = Join-Path $checkRoot 'machines.json'
    @{ work = $endpoint } | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding utf8
    $env:FARFILE_CONFIG = $configPath
    $brokerPath = Join-Path $checkRoot 'broker\FarFile.Broker.exe'
    $clientPath = Join-Path $checkRoot 'client\FarFile.Client.exe'
    $broker = Start-Process -FilePath $brokerPath -ArgumentList @('--listen', "127.0.0.1:$port") `
        -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $checkRoot 'broker.out') `
        -RedirectStandardError (Join-Path $checkRoot 'broker.err')
    $ready = $false
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        if ($broker.HasExited) { throw 'Packaged broker exited during startup.' }
        try {
            Invoke-WebRequest -Uri ($endpoint + 'v1/stat?path=%2F') -TimeoutSec 1 | Out-Null
            $ready = $true
            break
        }
        catch { Start-Sleep -Milliseconds 100 }
    }
    if (-not $ready) { throw 'Packaged broker did not start.' }
    & $clientPath ls work / --json | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Packaged client could not reach the broker.' }
    Write-Output 'OK packaged broker/client loopback smoke test'
}
finally {
    if ($broker -and -not $broker.HasExited) {
        Stop-Process -Id $broker.Id -Force
        $broker.WaitForExit(10000) | Out-Null
    }
    $env:FARFILE_CONFIG = $previousConfig
    if (Test-Path -LiteralPath $checkRoot) { Remove-Item -LiteralPath $checkRoot -Recurse -Force }
}
