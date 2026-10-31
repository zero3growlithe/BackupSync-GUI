using System;
using System.Reflection;

namespace BackupSyncGui;

internal static class BuildInfo
{
    public static string Sha { get; } = ReadSha();

    public static string ShortSha => Sha.Length > 7 ? Sha.Substring(0, 7) : Sha;

    private static string ReadSha()
    {
        AssemblyInformationalVersionAttribute? attribute = Assembly.GetExecutingAssembly()
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>();
        string? version = attribute?.InformationalVersion;
        if (string.IsNullOrWhiteSpace(version))
        {
            return "local";
        }
        int separator = version.IndexOf('+');
        if (separator >= 0 && separator + 1 < version.Length)
        {
            return version.Substring(separator + 1).Trim();
        }
        return "local";
    }
}
