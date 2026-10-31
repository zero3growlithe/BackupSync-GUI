using System;
using System.Globalization;
using System.IO;
using System.Text;

namespace BackupSyncGui.Services;

/// <summary>
/// Writes unhandled exceptions to %LOCALAPPDATA%\BackupSyncGui\crash.log,
/// tagged with the build SHA so a report can be matched to a CI artifact.
/// </summary>
internal static class CrashLog
{
    public static string FilePath => Path.Combine(ApplicationPaths.DataDirectory, "crash.log");

    public static void Write(Exception exception)
    {
        try
        {
            Directory.CreateDirectory(ApplicationPaths.DataDirectory);
            StringBuilder builder = new StringBuilder();
            builder.AppendLine("================================================================");
            builder.AppendLine("time:  " + DateTime.Now.ToString("o", CultureInfo.InvariantCulture));
            builder.AppendLine("build: " + BackupSyncGui.BuildInfo.Sha);
            builder.AppendLine("type:  " + exception.GetType().FullName);
            builder.AppendLine("msg:   " + exception.Message);
            builder.AppendLine("stack: " + exception.StackTrace);
            if (exception.InnerException is not null)
            {
                builder.AppendLine("inner: " + exception.InnerException.GetType().FullName + ": " + exception.InnerException.Message);
                builder.AppendLine("inner stack: " + exception.InnerException.StackTrace);
            }
            File.AppendAllText(FilePath, builder.ToString());
        }
        catch (Exception)
        {
            // Logging failures must never mask the original error.
        }
    }
}
