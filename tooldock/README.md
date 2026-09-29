# ToolDock packages

Run `pwsh -NoProfile -File .\scripts\package-tooldock.ps1` from the repository root. It publishes self-contained, single-file Windows x64 programs and writes `farfile-broker-win-x64.zip`, `farfile-client-win-x64.zip`, and SHA-256 files to `dist/tooldock/`. The executables sit at each ZIP root, as required by ToolDock. The client ZIP also carries the Yazi adapter and sample configuration.

Check the archives, hashes, catalog names, and executable startup with `pwsh -NoProfile -File .\tests\tooldock-package.ps1`.

Publish both ZIPs as assets of the same new GitHub release tag. ToolDock reads the latest release of `vvladz/FarFile`; publishing a new tag is how it detects an update. The SHA-256 files are for manual verification; ToolDock does not consume them.

The JSON files in this directory are standalone FarFile catalog examples. Merge their `tools` entries into the corresponding `client.json` and `server.json` of the deployment gist. Keep any existing packages in those files. Add the catalog entries only after the release assets are available.

The broker entry autostarts on `0.0.0.0:8023`. It has no TLS or authentication and exposes the broker user's filesystem access to network callers. Restrict access to a trusted network or change the `--listen` address before deploying.

On the client, create `~/.farfile/machines.json` from the bundled `machines.json.example` and set each machine's HTTP address. ToolDock installs the `farfile` command shim. To use the Yazi adapter, copy the bundled `yazi/farfile.yazi` directory into Yazi's plugins directory and configure `vfs.toml`. Yazi must launch the actual executable, so set `FARFILE_CLIENT` to `<ToolDockInstallRoot>\tools\farfile-client\current\FarFile.Client.exe` in Yazi's environment; the command shim is a `.cmd` file.
