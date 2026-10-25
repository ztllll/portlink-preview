// PortLink single-file launcher: embeds the verified portable ZIP, extracts it
// once to a per-user folder, verifies portlink.exe, then starts it.
// No registry writes, no autostart, no elevation, no network.
using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Security.Cryptography;
using System.Threading;
using System.Windows.Forms;

static class Program
{
    const string PayloadId = "__PAYLOAD_ID__";   // first 16 hex of payload ZIP SHA-256
    const string ExeSha256 = "__EXE_SHA256__";   // SHA-256 of portlink.exe inside the payload
    const string Marker = ".portlink-complete";

    [STAThread]
    static int Main()
    {
        try
        {
            string baseDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "PortLink");
            string root = Path.Combine(baseDir, "app-" + PayloadId);
            bool created;
            using (var mutex = new Mutex(false, "Local\\PortLinkLauncher-" + PayloadId))
            {
                mutex.WaitOne();
                try
                {
                    if (!IsComplete(root)) Extract(baseDir, root);
                }
                finally { mutex.ReleaseMutex(); }
                created = true;
            }
            if (!created) return 1;
            var info = new ProcessStartInfo(Path.Combine(root, "portlink.exe"))
            {
                WorkingDirectory = root,
                UseShellExecute = false
            };
            Process.Start(info);
            return 0;
        }
        catch (Exception error)
        {
            MessageBox.Show("PortLink could not start:\n\n" + error.Message,
                "PortLink", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    static bool IsComplete(string root)
    {
        string exe = Path.Combine(root, "portlink.exe");
        if (!File.Exists(Path.Combine(root, Marker)) || !File.Exists(exe)) return false;
        return Sha256(exe) == ExeSha256;
    }

    static string Sha256(string path)
    {
        using (var sha = SHA256.Create())
        using (var stream = File.OpenRead(path))
        {
            var hash = sha.ComputeHash(stream);
            return BitConverter.ToString(hash).Replace("-", "").ToLowerInvariant();
        }
    }

    static void Extract(string baseDir, string root)
    {
        Directory.CreateDirectory(baseDir);
        string temp = root + ".partial-" + Guid.NewGuid().ToString("N");
        string prefix = Path.GetFullPath(temp).TrimEnd('\\') + "\\";
        Directory.CreateDirectory(temp);
        try
        {
            using (var payload = Assembly.GetExecutingAssembly().GetManifestResourceStream("payload.zip"))
            {
                if (payload == null) throw new InvalidOperationException("Embedded payload is missing.");
                using (var archive = new ZipArchive(payload, ZipArchiveMode.Read))
                {
                    foreach (var entry in archive.Entries)
                    {
                        string name = entry.FullName.Replace('\\', '/');
                        if (name.Length == 0 || name.StartsWith("/") || name.Contains(":") ||
                            name.Contains("../") || name == "..")
                            throw new InvalidDataException("Unsafe payload entry: " + name);
                        string target = Path.GetFullPath(Path.Combine(temp, name.Replace('/', '\\')));
                        if (!target.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                            throw new InvalidDataException("Payload entry escapes target: " + name);
                        if (name.EndsWith("/")) { Directory.CreateDirectory(target); continue; }
                        Directory.CreateDirectory(Path.GetDirectoryName(target));
                        entry.ExtractToFile(target, false);
                    }
                }
            }
            if (Sha256(Path.Combine(temp, "portlink.exe")) != ExeSha256)
                throw new InvalidDataException("Extracted portlink.exe failed verification.");
            File.WriteAllText(Path.Combine(temp, Marker), PayloadId);
            // Only a previous incomplete/corrupt copy of this same payload id is removed.
            if (Directory.Exists(root)) Directory.Delete(root, true);
            Directory.Move(temp, root);
        }
        catch
        {
            try { if (Directory.Exists(temp)) Directory.Delete(temp, true); } catch { }
            throw;
        }
    }
}
