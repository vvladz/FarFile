[CmdletBinding()]
param(
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root 'dist\tooldock' }
$output = [IO.Path]::GetFullPath($OutputDirectory)
$publishRoot = Join-Path $root 'work\tooldock-publish'
New-Item -ItemType Directory -Path $output, $publishRoot -Force | Out-Null

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Add-ArchiveFile($archive, [string]$source, [string]$name) {
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Missing package file: $source" }
    [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
        $archive, $source, $name, [IO.Compression.CompressionLevel]::Optimal) | Out-Null
}

function New-Package([string]$project, [string]$program, [string]$asset, [hashtable]$extras) {
    $publish = [IO.Path]::GetFullPath((Join-Path $publishRoot $project))
    if (-not $publish.StartsWith($publishRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Publish directory escaped work.'
    }
    if (Test-Path -LiteralPath $publish) { Remove-Item -LiteralPath $publish -Recurse -Force }
    $projectFile = Join-Path $root "src\$project\$project.csproj"
    & dotnet restore $projectFile -r win-x64
    if ($LASTEXITCODE -ne 0) { throw "Restore failed: $project" }
    & dotnet publish $projectFile -c Release -r win-x64 --self-contained false --no-restore `
        -p:PublishSingleFile=false -p:DebugType=None -p:DebugSymbols=false -o $publish
    if ($LASTEXITCODE -ne 0) { throw "Publish failed: $project" }

    $zipPath = Join-Path $output $asset
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    $archive = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in (Get-ChildItem -LiteralPath $publish -File | Sort-Object Name)) {
            Add-ArchiveFile $archive $file.FullName $file.Name
        }
        foreach ($entry in $extras.GetEnumerator()) {
            Add-ArchiveFile $archive (Join-Path $root $entry.Value) $entry.Key
        }
    }
    finally { $archive.Dispose() }

    $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText("$zipPath.sha256", "$hash  $asset`n", [Text.UTF8Encoding]::new($false))
    Write-Output "$asset  $hash"
}

New-Package 'FarFile.Broker' 'FarFile.Broker' 'farfile-broker-win-x64.zip' @{}
New-Package 'FarFile.Client' 'FarFile.Client' 'farfile-client-win-x64.zip' @{
    'machines.json.example' = 'machines.json.example'
    'yazi/farfile.yazi/main.lua' = 'yazi\farfile.yazi\main.lua'
    'yazi/vfs.toml.example' = 'yazi\vfs.toml.example'
}
