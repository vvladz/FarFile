# FarFile

FarFile is a temporary remote-file backend for Yazi. It has two production programs, `FarFile.Broker` and `FarFile.Client`, plus the `farfile.yazi` custom VFS adapter. It does not use FarShell or implement SSH/SFTP/SCP.

The broker serves the host filesystem over private HTTP/1.1. The client exposes a machine-readable CLI. `ls` includes each entry's kind, size, modification time, and hidden flag in one request. `read`, `write`, `get`, `put`, and `cp` stream bytes without a local temporary file. `cp` relays remote-to-remote data through the client.

## Build

.NET 10 SDK is needed to build. Framework-dependent builds need the ASP.NET Core 10 runtime for the broker and the .NET 10 runtime for the client. There are no NuGet package dependencies.

```powershell
dotnet build .\FarFile.sln -c Release
```

For a convenient standalone executable on Windows, publish each project separately:

```powershell
dotnet publish .\src\FarFile.Broker\FarFile.Broker.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o .\dist\broker
dotnet publish .\src\FarFile.Client\FarFile.Client.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o .\dist\client
```

## Start a broker

```powershell
FarFile.Broker.exe --listen 100.64.0.12:8023
```

Default listener: `127.0.0.1:8023`. To accept connections on every interface, pass `--listen 0.0.0.0:8023` explicitly.

The broker has **no TLS and no authentication** and gives network callers the broker process's filesystem permissions, including delete. Bind it only to a trusted network/interface. It cannot execute commands.

On Windows, `/` is a virtual directory listing ready drives. A drive path is `/C:/Projects` (or `C:\Projects` in the CLI). UNC paths are outside this MVP. On Unix, paths are absolute Unix paths. The broker blocks mutating a filesystem root directly, but any other path accessible to its process can be changed.

## Configure the client

Put a JSON alias map at `~/.farfile/machines.json` on every OS (`C:\Users\<user>\.farfile\machines.json` on Windows). See [machines.json.example](machines.json.example). Alternatively set `FARFILE_CONFIG` or put `--config PATH` before a command. Endpoints must be plain `http://host:port/` URLs.

Place `FarFile.Client.exe` on `PATH` for Yazi, or set `FARFILE_CLIENT` to its full path.

```powershell
FarFile.Client.exe ls work 'C:\Projects' --json
FarFile.Client.exe stat work 'C:\Projects\README.md' --json
FarFile.Client.exe get work 'C:\Projects\README.md' .\README.md
FarFile.Client.exe put work .\README.md 'C:\Projects\copy.md'
FarFile.Client.exe cp work 'C:\Projects\copy.md' home 'D:\Inbox\copy.md'
FarFile.Client.exe mkdir work 'C:\Projects\NewDir'
FarFile.Client.exe mv work 'C:\Projects\copy.md' 'C:\Projects\renamed.md'
FarFile.Client.exe rm work 'C:\Projects\renamed.md'
FarFile.Client.exe rmdir-all work 'C:\Projects\NewDir'
```

`read` writes binary data to stdout and `write` reads binary data from stdin. Both support `--offset N` and `--length N`; `write --offset` writes into an existing file. `get` and `put` accept `-` for stdout/stdin. Errors go to stderr and return nonzero. The `--records` metadata format is private to the Lua adapter.

## Yazi

The adapter targets Yazi **26.9.1**. Copy `yazi/farfile.yazi` to `%APPDATA%\yazi\config\plugins\farfile.yazi` (or `~/.config/yazi/plugins/farfile.yazi` on Unix), and add a section for each machine to your `vfs.toml` as shown in [vfs.toml.example](yazi/vfs.toml.example). The section name must match a client alias.

```powershell
yazi 'farfile://work//C:/Projects'
```

The doubled slash after `work` denotes an absolute remote path in Yazi. `farfile://work//` opens the drive list on a Windows broker. The plugin handles navigation, metadata, preview reads, file writes, mkdir, rename, delete, and copy. Copies within one machine use the client's streaming relay. In Yazi 26.9.1, copies between different VFS domains or between local and remote use Yazi's generic chunked `Read`/`Write` path, which starts a client process per chunk. For large cross-machine transfers, use the direct CLI `cp` command. Link creation, permissions, trash, and file watching are not implemented.

Yazi custom VFS is experimental; the adapter follows the 26.9.1 provider contract. The current [official VFS demo](https://github.com/yazi-rs/plugins/tree/main/vfs-demo.yazi) has since changed its `ReadDir` return type, so copying its latest code into Yazi 26.9.1 does not work. Custom providers were introduced in [Yazi 26.8.15](https://github.com/sxyazi/yazi/blob/main/CHANGELOG.md#v26815).

## Test

```powershell
pwsh -NoProfile -File .\tests\integration.ps1
```

The test starts two loopback brokers and exercises metadata, binary upload/download, fixed-length range reads/writes, relay copy between endpoints, rename, and deletion using a disposable directory under `work/` in this repository. The Yazi adapter was also checked interactively on Yazi 26.9.1: navigation, same-machine relay copy, and a binary copy through its generic `Read`/`Write` path.
