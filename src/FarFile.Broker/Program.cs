using System.Buffers;
using System.Globalization;
using FarFile;

namespace FarFile.Broker;

internal static class Program
{
    private static async Task<int> Main(string[] args)
    {
        if (args is ["--help"])
        {
            Console.WriteLine("FarFile.Broker [--listen 127.0.0.1:8023]");
            return 0;
        }

        if (args.Length is not (0 or 2) || (args.Length == 2 && args[0] != "--listen"))
        {
            Console.Error.WriteLine("Usage: FarFile.Broker [--listen host:port]");
            return 2;
        }

        var listen = args.Length == 2 ? args[1] : "127.0.0.1:8023";
        if (!Uri.TryCreate("http://" + listen, UriKind.Absolute, out var address) ||
            address.Host.Length == 0 || address.Port is < 1 or > 65535 ||
            address.AbsolutePath != "/" || address.Query.Length != 0 || address.UserInfo.Length != 0)
        {
            Console.Error.WriteLine("Invalid --listen address. Use host:port (for example 0.0.0.0:8023).");
            return 2;
        }

        var builder = WebApplication.CreateBuilder(Array.Empty<string>());
        builder.WebHost.UseUrls(address.ToString());
        var app = builder.Build();

        app.Use(async (context, next) =>
        {
            try
            {
                await next();
            }
            catch (Exception error)
            {
                if (context.Response.HasStarted)
                {
                    context.Abort();
                    return;
                }

                var (status, code) = error switch
                {
                    FileNotFoundException or DirectoryNotFoundException => (404, "not_found"),
                    UnauthorizedAccessException => (403, "access_denied"),
                    ArgumentException or NotSupportedException => (400, "invalid_request"),
                    IOException => (409, "io_conflict"),
                    _ => (500, "internal_error")
                };
                context.Response.Clear();
                context.Response.StatusCode = status;
                await context.Response.WriteAsJsonAsync(new ApiError(code, error.Message));
            }
        });

        app.MapGet("/v1/list", (string path) =>
        {
            if (OperatingSystem.IsWindows() && RemotePath.IsVirtualRoot(path))
            {
                return Results.Json(DriveInfo.GetDrives()
                    .Where(drive => drive.IsReady)
                    .Select(drive => new Entry(drive.Name.TrimEnd('\\'), "dir", 0, 0, false)));
            }

            var directory = RemotePath.Resolve(path);
            if (!Directory.Exists(directory)) throw new DirectoryNotFoundException(directory);
            return Results.Json(Directory.EnumerateFileSystemEntries(directory).Select(ToEntry).ToArray());
        });

        app.MapGet("/v1/stat", (string path) => Results.Json(ToEntryForPath(path)));

        app.MapGet("/v1/file", async (HttpContext context, string path, long? offset, long? length) =>
        {
            if (offset < 0 || length < 0) throw new ArgumentOutOfRangeException(nameof(offset));
            await using var file = new FileStream(RemotePath.Resolve(path), FileMode.Open, FileAccess.Read,
                FileShare.Read, 64 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);
            var start = Math.Min(offset ?? 0, file.Length);
            file.Position = start;
            var remaining = Math.Min(length ?? long.MaxValue, file.Length - start);
            context.Response.ContentType = "application/octet-stream";
            context.Response.ContentLength = remaining;
            var buffer = ArrayPool<byte>.Shared.Rent(64 * 1024);
            try
            {
                while (remaining > 0)
                {
                    var read = await file.ReadAsync(buffer.AsMemory(0, (int)Math.Min(remaining, buffer.Length)),
                        context.RequestAborted);
                    if (read == 0) throw new EndOfStreamException("Source file changed during read.");
                    await context.Response.Body.WriteAsync(buffer.AsMemory(0, read), context.RequestAborted);
                    remaining -= read;
                }
            }
            finally
            {
                ArrayPool<byte>.Shared.Return(buffer);
            }
        });

        app.MapPut("/v1/file", async (HttpRequest request, string path) =>
        {
            var destination = RemotePath.ResolveMutable(path);
            await using var file = new FileStream(destination, FileMode.Create, FileAccess.Write,
                FileShare.None, 64 * 1024, FileOptions.Asynchronous);
            await request.Body.CopyToAsync(file, request.HttpContext.RequestAborted);
            return Results.NoContent();
        });

        app.MapMethods("/v1/file", ["PATCH"], async (HttpRequest request, string path, long offset) =>
        {
            if (offset < 0) throw new ArgumentOutOfRangeException(nameof(offset));
            var destination = RemotePath.ResolveMutable(path);
            await using var file = new FileStream(destination, FileMode.Open, FileAccess.Write,
                FileShare.None, 64 * 1024, FileOptions.Asynchronous);
            file.Position = offset;
            await request.Body.CopyToAsync(file, request.HttpContext.RequestAborted);
            return Results.NoContent();
        });

        app.MapDelete("/v1/file", (string path) =>
        {
            var file = RemotePath.ResolveMutable(path);
            if ((File.GetAttributes(file) & FileAttributes.Directory) != 0)
                throw new IOException("Path is a directory.");
            File.Delete(file);
            return Results.NoContent();
        });

        app.MapPost("/v1/mkdir", (PathRequest request) =>
        {
            Directory.CreateDirectory(RemotePath.ResolveMutable(request.Path));
            return Results.NoContent();
        });

        app.MapDelete("/v1/dir", (string path, bool? all) =>
        {
            var directory = RemotePath.ResolveMutable(path);
            if (all == true) RemoveDirectoryTree(directory);
            else Directory.Delete(directory);
            return Results.NoContent();
        });

        app.MapPost("/v1/rename", (RenameRequest request) =>
        {
            var from = RemotePath.ResolveMutable(request.From);
            var to = RemotePath.ResolveMutable(request.To);
            if (File.Exists(to) || Directory.Exists(to)) throw new IOException("Destination already exists.");
            if ((File.GetAttributes(from) & FileAttributes.Directory) != 0) Directory.Move(from, to);
            else File.Move(from, to);
            return Results.NoContent();
        });

        app.MapPost("/v1/prepare", (PrepareRequest request) =>
        {
            var path = RemotePath.ResolveMutable(request.Path);
            var mode = request.CreateNew ? FileMode.CreateNew :
                request.Truncate ? (request.Create ? FileMode.Create : FileMode.Truncate) :
                request.Create ? FileMode.OpenOrCreate : FileMode.Open;
            using var file = new FileStream(path, mode, FileAccess.ReadWrite, FileShare.None);
            return Results.Json(ToEntry(path));
        });

        app.MapPost("/v1/setlen", (SetLengthRequest request) =>
        {
            if (request.Length < 0) throw new ArgumentOutOfRangeException(nameof(request.Length));
            using var file = new FileStream(RemotePath.ResolveMutable(request.Path), FileMode.Open,
                FileAccess.Write, FileShare.None);
            file.SetLength(request.Length);
            return Results.NoContent();
        });

        app.MapPost("/v1/mtime", (SetMtimeRequest request) =>
        {
            var path = RemotePath.ResolveMutable(request.Path);
            var time = DateTime.UnixEpoch.AddSeconds(request.Mtime);
            if ((File.GetAttributes(path) & FileAttributes.Directory) != 0)
                Directory.SetLastWriteTimeUtc(path, time);
            else File.SetLastWriteTimeUtc(path, time);
            return Results.NoContent();
        });

        await app.RunAsync();
        return 0;
    }

    private static Entry ToEntryForPath(string remote)
    {
        if (OperatingSystem.IsWindows() && RemotePath.IsVirtualRoot(remote))
            return new Entry("/", "dir", 0, 0, false);
        return ToEntry(RemotePath.Resolve(remote));
    }

    private static Entry ToEntry(string path)
    {
        var attributes = File.GetAttributes(path);
        var isDirectory = (attributes & FileAttributes.Directory) != 0;
        var name = Path.GetFileName(Path.TrimEndingDirectorySeparator(path));
        if (name.Length == 0) name = Path.GetPathRoot(path) ?? "/";
        var modified = isDirectory ? Directory.GetLastWriteTimeUtc(path) : File.GetLastWriteTimeUtc(path);
        var mtime = (modified - DateTime.UnixEpoch).TotalSeconds;
        var size = isDirectory ? 0 : new FileInfo(path).Length;
        var hidden = (attributes & FileAttributes.Hidden) != 0 ||
            (!OperatingSystem.IsWindows() && name.StartsWith('.'));
        return new Entry(name, isDirectory ? "dir" : "file", size, mtime, hidden);
    }

    private static void RemoveDirectoryTree(string path)
    {
        var attributes = File.GetAttributes(path);
        if ((attributes & FileAttributes.Directory) == 0) throw new IOException("Path is not a directory.");
        if ((attributes & FileAttributes.ReparsePoint) != 0)
        {
            Directory.Delete(path);
            return;
        }

        foreach (var child in Directory.EnumerateFileSystemEntries(path))
        {
            var childAttributes = File.GetAttributes(child);
            if ((childAttributes & FileAttributes.Directory) != 0) RemoveDirectoryTree(child);
            else File.Delete(child);
        }
        Directory.Delete(path);
    }
}

internal static class RemotePath
{
    public static bool IsVirtualRoot(string path) => path.Replace('\\', '/') == "/";

    public static string ResolveMutable(string path)
    {
        var resolved = Resolve(path);
        var root = Path.GetPathRoot(resolved);
        if (root is not null && Path.TrimEndingDirectorySeparator(resolved)
                .Equals(Path.TrimEndingDirectorySeparator(root),
                    OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal))
            throw new ArgumentException("The filesystem root cannot be modified.");
        return resolved;
    }

    public static string Resolve(string path)
    {
        if (string.IsNullOrWhiteSpace(path) || path.Contains('\0'))
            throw new ArgumentException("An absolute path is required.");
        var normalized = path.Replace('\\', '/');
        if (OperatingSystem.IsWindows())
        {
            if (normalized == "/") throw new ArgumentException("The virtual root is not a file path.");
            if (normalized.StartsWith("//", StringComparison.Ordinal))
                throw new ArgumentException("UNC paths are not supported.");
            var drivePath = normalized.TrimStart('/');
            if (drivePath.Length < 2 || !char.IsAsciiLetter(drivePath[0]) || drivePath[1] != ':' ||
                (drivePath.Length > 2 && drivePath[2] != '/'))
                throw new ArgumentException("Use an absolute drive path such as /C:/Projects.");
            if (drivePath.Length == 2) drivePath += "/";
            return Path.GetFullPath(drivePath.Replace('/', '\\'));
        }

        if (!normalized.StartsWith('/') || normalized.StartsWith("//", StringComparison.Ordinal))
            throw new ArgumentException("Use an absolute Unix path.");
        return Path.GetFullPath(normalized);
    }
}
