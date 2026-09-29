using System.Globalization;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using FarFile;

namespace FarFile.Client;

internal static class Program
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    private static async Task<int> Main(string[] rawArgs)
    {
        try
        {
            var args = rawArgs.ToList();
            if (args.Count >= 2 && args[0] == "--config")
            {
                Environment.SetEnvironmentVariable("FARFILE_CONFIG", args[1]);
                args.RemoveRange(0, 2);
            }
            if (args.Count == 0 || args[0] is "--help" or "help")
            {
                Console.WriteLine(Usage);
                return args.Count == 0 ? 2 : 0;
            }

            var command = args[0];
            args.RemoveAt(0);
            await Execute(command, args);
            return 0;
        }
        catch (Exception error) when (error is ArgumentException or IOException or HttpRequestException or
                                      JsonException or UnauthorizedAccessException)
        {
            Console.Error.WriteLine("farfile: " + error.GetBaseException().Message);
            return 1;
        }
    }

    private static async Task Execute(string command, List<string> args)
    {
        switch (command)
        {
            case "ls":
            case "stat":
            {
                Require(args, 2, 3);
                var records = args.Count == 3 && args[2] == "--records";
                if (args.Count == 3 && !records && args[2] != "--json") throw new ArgumentException(Usage);
                using var remote = new Remote(args[0]);
                if (command == "ls")
                {
                    var entries = await remote.GetJson<Entry[]>("list", args[1]);
                    if (records) await WriteRecords(entries);
                    else Console.WriteLine(JsonSerializer.Serialize(entries, Json));
                }
                else
                {
                    var entry = await remote.GetJson<Entry>("stat", args[1]);
                    if (records) await WriteRecords([entry]);
                    else Console.WriteLine(JsonSerializer.Serialize(entry, Json));
                }
                return;
            }
            case "read":
            case "get":
            {
                Require(args, command == "get" ? 3 : 2, command == "get" ? 3 : 6);
                using var remote = new Remote(args[0]);
                var options = command == "read" ? ParseRange(args, 2, allowLength: true) : (null, null);
                await using var output = command == "get" && args[2] != "-"
                    ? new FileStream(args[2], FileMode.Create, FileAccess.Write, FileShare.None, 64 * 1024, true)
                    : Console.OpenStandardOutput();
                await remote.Read(args[1], output, options.Item1, options.Item2);
                return;
            }
            case "write":
            case "put":
            {
                Require(args, command == "put" ? 3 : 2, command == "put" ? 3 : 6);
                using var remote = new Remote(args[0]);
                var options = command == "write" ? ParseRange(args, 2, allowLength: true) : (null, null);
                var inputPath = command == "put" ? args[1] : "-";
                var remotePath = command == "put" ? args[2] : args[1];
                await using var input = inputPath == "-" ? Console.OpenStandardInput() :
                    new FileStream(inputPath, FileMode.Open, FileAccess.Read, FileShare.Read, 64 * 1024, true);
                await remote.Write(remotePath, input, options.Item1, options.Item2);
                return;
            }
            case "cp":
            {
                Require(args, 4);
                using var source = new Remote(args[0]);
                using var destination = new Remote(args[2]);
                if (source.Address == destination.Address && NormalizePath(args[1]) == NormalizePath(args[3]))
                    throw new ArgumentException("Source and destination are the same file.");
                var copied = await source.CopyTo(args[1], destination, args[3]);
                Console.WriteLine(copied.ToString(CultureInfo.InvariantCulture));
                return;
            }
            case "mkdir":
            case "rm":
            case "rmdir":
            case "rmdir-all":
            {
                Require(args, 2);
                using var remote = new Remote(args[0]);
                if (command == "mkdir") await remote.Post("mkdir", new PathRequest(NormalizePath(args[1])));
                else await remote.Delete(command == "rm" ? "file" : "dir", args[1], command == "rmdir-all");
                return;
            }
            case "mv":
            {
                Require(args, 3);
                using var remote = new Remote(args[0]);
                await remote.Post("rename", new RenameRequest(NormalizePath(args[1]), NormalizePath(args[2])));
                return;
            }
            case "prepare":
            {
                Require(args, 2, 6);
                using var remote = new Remote(args[0]);
                var flags = args.Skip(2).ToHashSet(StringComparer.Ordinal);
                if (flags.Count != args.Count - 2 || flags.Except(["--create", "--create-new", "--truncate", "--append"]).Any())
                    throw new ArgumentException(Usage);
                var entry = await remote.PostJson<Entry>("prepare", new PrepareRequest(NormalizePath(args[1]),
                    flags.Contains("--create"), flags.Contains("--create-new"), flags.Contains("--truncate"),
                    flags.Contains("--append")));
                Console.WriteLine(entry.Size.ToString(CultureInfo.InvariantCulture));
                return;
            }
            case "setlen":
            {
                Require(args, 3);
                using var remote = new Remote(args[0]);
                await remote.Post("setlen", new SetLengthRequest(NormalizePath(args[1]), NonNegative(args[2])));
                return;
            }
            case "mtime":
            {
                Require(args, 3);
                using var remote = new Remote(args[0]);
                if (!double.TryParse(args[2], NumberStyles.Float, CultureInfo.InvariantCulture, out var mtime) ||
                    !double.IsFinite(mtime)) throw new ArgumentException("Invalid mtime.");
                await remote.Post("mtime", new SetMtimeRequest(NormalizePath(args[1]), mtime));
                return;
            }
            default:
                throw new ArgumentException(Usage);
        }
    }

    private static (long?, long?) ParseRange(List<string> args, int start, bool allowLength)
    {
        long? offset = null;
        long? length = null;
        for (var i = start; i < args.Count; i += 2)
        {
            if (i + 1 >= args.Count) throw new ArgumentException(Usage);
            if (args[i] == "--offset" && offset is null) offset = NonNegative(args[i + 1]);
            else if (args[i] == "--length" && allowLength && length is null) length = NonNegative(args[i + 1]);
            else throw new ArgumentException(Usage);
        }
        return (offset, length);
    }

    private static long NonNegative(string value)
    {
        if (!long.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out var result))
            throw new ArgumentException("Expected a non-negative integer.");
        return result;
    }

    private static void Require(List<string> args, int min, int? max = null)
    {
        if (args.Count < min || args.Count > (max ?? min)) throw new ArgumentException(Usage);
    }

    private static string NormalizePath(string path)
    {
        if (string.IsNullOrEmpty(path) || path.Contains('\0')) throw new ArgumentException("Invalid remote path.");
        var normalized = path.Replace('\\', '/');
        if (normalized.Length >= 2 && char.IsAsciiLetter(normalized[0]) && normalized[1] == ':')
            normalized = "/" + normalized;
        return normalized;
    }

    private static async Task WriteRecords(IEnumerable<Entry> entries)
    {
        var stream = Console.OpenStandardOutput();
        foreach (var entry in entries)
        {
            foreach (var field in new[] { entry.Name, entry.Kind,
                         entry.Size.ToString(CultureInfo.InvariantCulture),
                         entry.Mtime.ToString("R", CultureInfo.InvariantCulture), entry.Hidden ? "1" : "0" })
            {
                await stream.WriteAsync(Encoding.UTF8.GetBytes(field));
                stream.WriteByte(0);
            }
        }
        await stream.FlushAsync();
    }

    private const string Usage = """
        FarFile.Client [--config machines.json] <command> ...
          ls|stat MACHINE REMOTE_PATH [--json|--records]
          read MACHINE REMOTE_PATH [--offset N] [--length N]   (binary stdout)
          write MACHINE REMOTE_PATH [--offset N] [--length N]  (binary stdin)
          get MACHINE REMOTE_PATH LOCAL_PATH|-
          put MACHINE LOCAL_PATH|- REMOTE_PATH
          cp SOURCE_MACHINE SOURCE_PATH DEST_MACHINE DEST_PATH
          mkdir|rm|rmdir|rmdir-all MACHINE REMOTE_PATH
          mv MACHINE SOURCE_PATH DEST_PATH
          prepare MACHINE PATH [--create] [--create-new] [--truncate] [--append]
          setlen MACHINE PATH LENGTH
          mtime MACHINE PATH UNIX_SECONDS
        """;

    private sealed class Remote : IDisposable
    {
        private readonly HttpClient client = new() { Timeout = Timeout.InfiniteTimeSpan };
        public Uri Address { get; }

        public Remote(string machine)
        {
            var configPath = Environment.GetEnvironmentVariable("FARFILE_CONFIG") ?? DefaultConfigPath();
            if (!File.Exists(configPath)) throw new FileNotFoundException("Machine config not found: " + configPath);
            var machines = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(configPath), Json)
                ?? throw new JsonException("Machine config is empty.");
            if (!machines.TryGetValue(machine, out var endpoint))
                throw new ArgumentException("Unknown machine: " + machine);
            if (!Uri.TryCreate(endpoint, UriKind.Absolute, out var address) || address.Scheme != "http" ||
                address.UserInfo.Length != 0 || address.Query.Length != 0 || address.AbsolutePath != "/")
                throw new ArgumentException("Machine endpoint must be http://host:port/: " + machine);
            Address = address;
            client.BaseAddress = address;
        }

        private static string DefaultConfigPath() => Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".farfile", "machines.json");

        private static string Url(string operation, string path, long? offset = null, long? length = null, bool all = false)
        {
            var url = "/v1/" + operation + "?path=" + Uri.EscapeDataString(NormalizePath(path));
            if (offset is not null) url += "&offset=" + offset.Value.ToString(CultureInfo.InvariantCulture);
            if (length is not null) url += "&length=" + length.Value.ToString(CultureInfo.InvariantCulture);
            if (all) url += "&all=true";
            return url;
        }

        private static async Task Ensure(HttpResponseMessage response)
        {
            if (response.IsSuccessStatusCode) return;
            var body = await response.Content.ReadAsStringAsync();
            ApiError? error = null;
            try { error = JsonSerializer.Deserialize<ApiError>(body, Json); }
            catch (JsonException) { /* Kestrel can also return a plain error body. */ }
            throw new IOException($"HTTP {(int)response.StatusCode}: {error?.Message ?? body}");
        }

        public async Task<T> GetJson<T>(string operation, string path)
        {
            using var response = await client.GetAsync(Url(operation, path), HttpCompletionOption.ResponseHeadersRead);
            await Ensure(response);
            return await response.Content.ReadFromJsonAsync<T>(Json) ??
                throw new IOException("Empty metadata response.");
        }

        public async Task Read(string path, Stream output, long? offset, long? length)
        {
            using var response = await client.GetAsync(Url("file", path, offset, length),
                HttpCompletionOption.ResponseHeadersRead);
            await Ensure(response);
            await using var input = await response.Content.ReadAsStreamAsync();
            await input.CopyToAsync(output);
        }

        public async Task Write(string path, Stream input, long? offset, long? length)
        {
            await using var bounded = length is null ? null : new LimitedReadStream(input, length.Value);
            using var content = new StreamContent(bounded ?? input);
            if (length is not null) content.Headers.ContentLength = length;
            using var request = new HttpRequestMessage(offset is null ? HttpMethod.Put : HttpMethod.Patch,
                Url("file", path, offset)) { Content = content };
            using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead);
            await Ensure(response);
        }

        public async Task<long> CopyTo(string path, Remote destination, string destinationPath)
        {
            var metadata = await GetJson<Entry>("stat", path);
            if (metadata.Kind != "file") throw new IOException("Only file data can be relayed by cp.");
            using var response = await client.GetAsync(Url("file", path), HttpCompletionOption.ResponseHeadersRead);
            await Ensure(response);
            var size = response.Content.Headers.ContentLength ?? throw new IOException("Missing file length.");
            await using var input = await response.Content.ReadAsStreamAsync();
            await destination.Write(destinationPath, input, null, size);
            await destination.Post("mtime", new SetMtimeRequest(NormalizePath(destinationPath), metadata.Mtime));
            return size;
        }

        public async Task Post<T>(string operation, T value)
        {
            using var response = await client.PostAsJsonAsync("/v1/" + operation, value, Json);
            await Ensure(response);
        }

        public async Task<T> PostJson<T>(string operation, object value)
        {
            using var response = await client.PostAsJsonAsync("/v1/" + operation, value, Json);
            await Ensure(response);
            return await response.Content.ReadFromJsonAsync<T>(Json) ??
                throw new IOException("Empty metadata response.");
        }

        public async Task Delete(string operation, string path, bool all)
        {
            using var response = await client.DeleteAsync(Url(operation, path, all: all));
            await Ensure(response);
        }

        public void Dispose() => client.Dispose();
    }

    private sealed class LimitedReadStream : Stream
    {
        private readonly Stream source;
        private readonly long length;
        private long remaining;

        public LimitedReadStream(Stream source, long length)
        {
            this.source = source;
            this.length = length;
            remaining = length;
        }
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => length;
        public override long Position { get => length - remaining; set => throw new NotSupportedException(); }
        public override int Read(byte[] buffer, int offset, int count) =>
            ReadAsync(buffer.AsMemory(offset, count)).AsTask().GetAwaiter().GetResult();
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            if (remaining == 0) return 0;
            var read = await source.ReadAsync(buffer[..(int)Math.Min(buffer.Length, remaining)], cancellationToken);
            if (read == 0) throw new EndOfStreamException("Input ended before --length bytes were read.");
            remaining -= read;
            return read;
        }
        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
