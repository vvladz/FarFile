namespace FarFile;

// Private HTTP contract. Only the client CLI is consumed by the Yazi plugin.
public sealed record Entry(string Name, string Kind, long Size, double Mtime, bool Hidden);
public sealed record ApiError(string Code, string Message);
public sealed record PathRequest(string Path);
public sealed record RenameRequest(string From, string To);
public sealed record PrepareRequest(string Path, bool Create, bool CreateNew, bool Truncate, bool Append);
public sealed record SetLengthRequest(string Path, long Length);
public sealed record SetMtimeRequest(string Path, double Mtime);
