// Blood Omen 2 Enhanced - setup program (originally the Blood Omen 2 Cutscene Skip).
// Patches the player's own files, so the download holds only the mod's code and icons. Every input and output is checked
// by SHA-256. Command line for scripting and tests: --dir <game folder> (--install | --uninstall) [--log <file>]

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: AssemblyTitle("Blood Omen 2 Enhanced Setup")]
[assembly: AssemblyDescription("Installs and removes Blood Omen 2 Enhanced, a fan-made quality-of-life mod for Blood Omen 2: Legacy of Kain.")]
[assembly: AssemblyCompany("pyrociterwatz")]
[assembly: AssemblyProduct("Blood Omen 2 Enhanced")]
[assembly: AssemblyCopyright("Copyright (c) 2026 pyrociterwatz. MIT License.")]
[assembly: AssemblyVersion("1.0.2.0")]
[assembly: AssemblyFileVersion("1.0.2.0")]
[assembly: AssemblyInformationalVersion("1.0.2")]

public class ModException : Exception { public ModException(string m) : base(m) { } }

public class PatchEntry {
    public string Name;
    public byte[] OriginalSha;
    public byte[] ResultSha;
    public List<KeyValuePair<int, byte[]>> Runs = new List<KeyValuePair<int, byte[]>>();
}

public static class Core {
    public const string ModFolder = "BO2SkipMod";
    public const string GameFolderName = "Blood Omen 2 Legacy of Kain";
    public const string RevampedUrl = "https://classicrebirth.com/index.php/blood-omen-2-re-vamped/";
    const string Marker = ".installed-by-bo2-cutscene-skip";
    const string VerifyHint = "\n\nRestore the original game files, then run setup again: in Steam, right-click the game, Properties > Installed Files > Verify integrity of game files; in GOG Galaxy, the game's settings > Manage installation > Verify / Repair. The Steam and GOG versions are supported.";

    // 1.0.1: the patch data, the launcher and the two DLLs ship as separate files in a "files" folder next to setup (an
    // installer that unpacks programs from inside itself looks like a malware dropper to anti-virus heuristics).
    public static string FilesDir { get { return Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "files"); } }
    public static bool HasFiles() {
        foreach (string n in new[] { "payload.bin", "launcher.exe", "dinput.dll", "bo2skipui.dll" })
            if (!File.Exists(Path.Combine(FilesDir, n))) return false;
        return true;
    }

    static byte[] ReadResource(string name) {
        string p = Path.Combine(FilesDir, name);
        if (!File.Exists(p))
            throw new ModException("The file files\\" + name + " was not found next to setup.\n\nExtract the whole zip to a folder first, then run setup from there (setup needs the files folder that comes with it).");
        return File.ReadAllBytes(p);
    }

    static Dictionary<string, PatchEntry> LoadPayload() {
        var result = new Dictionary<string, PatchEntry>();
        using (var r = new BinaryReader(new MemoryStream(ReadResource("payload.bin")))) {
            int entries = r.ReadInt32();
            for (int i = 0; i < entries; i++) {
                var e = new PatchEntry();
                e.Name = Encoding.ASCII.GetString(r.ReadBytes(r.ReadInt32()));
                e.OriginalSha = r.ReadBytes(32);
                e.ResultSha = r.ReadBytes(32);
                int runs = r.ReadInt32();
                for (int k = 0; k < runs; k++) {
                    int off = r.ReadInt32();
                    int len = r.ReadInt32();
                    e.Runs.Add(new KeyValuePair<int, byte[]>(off, r.ReadBytes(len)));
                }
                result[e.Name] = e;
            }
        }
        return result;
    }

    static byte[] Sha(byte[] data) { using (var s = SHA256.Create()) return s.ComputeHash(data); }

    static bool Same(byte[] a, byte[] b) {
        if (a.Length != b.Length) return false;
        for (int i = 0; i < a.Length; i++) if (a[i] != b[i]) return false;
        return true;
    }

    static byte[] FindOriginal(PatchEntry entry, params string[] paths) {
        foreach (string p in paths) {
            if (!File.Exists(p)) continue;
            byte[] data = File.ReadAllBytes(p);
            if (Same(Sha(data), entry.OriginalSha)) return data;
        }
        return null;
    }

    static byte[] Apply(PatchEntry entry, byte[] original) {
        byte[] data = (byte[])original.Clone();
        foreach (var run in entry.Runs) Array.Copy(run.Value, 0, data, run.Key, run.Value.Length);
        if (!Same(Sha(data), entry.ResultSha)) throw new ModException("Patching " + entry.Name + " gave an unexpected result. Nothing was changed.");
        return data;
    }

    static string Edit(string text, string from, string to) {
        int at = text.IndexOf(from, StringComparison.Ordinal);
        if (at < 0 || text.IndexOf(from, at + 1, StringComparison.Ordinal) >= 0) throw new ModException("Unexpected game.erg contents near: " + from);
        return text.Substring(0, at) + to + text.Substring(at + from.Length);
    }

    static byte[] MakeSpeedrunErg(byte[] vanilla) {
        Encoding enc = Encoding.GetEncoding(28591);
        return enc.GetBytes(Edit(enc.GetString(vanilla), "PlayMovie=1", "PlayMovie=0"));
    }

    static byte[] MakeTrainerErg(byte[] vanilla) {
        Encoding enc = Encoding.GetEncoding(28591);
        string t = enc.GetString(vanilla);
        string nl = t.Contains("\r\n") ? "\r\n" : "\n";
        t = Edit(t, "PlayMovie=1", "PlayMovie=0");
        t = Edit(t, "\"Debug Common\\Enable debug menus (Console)\"=0", "\"Debug Common\\Enable debug menus (Console)\"=1");
        t = Edit(t, "\"Debug Common\\Disable script debug print\"=1", "\"Debug Common\\Disable script debug print\"=0");
        t = Edit(t, "\"Blood Omen Specific Flags\\dont show monster prints\"=1", "\"Blood Omen Specific Flags\\dont show monster prints\"=0");
        foreach (string flag in new[] { "Debug Engine\\Show FPS", "Debug Common\\Display Current Regions", "Debug Common\\Draw Helper Creatures",
                                        "Blood Omen Specific Flags\\show detector debug stuff", "BO2 Kain Debug Flags\\show Kain's position",
                                        "BO2 Kain Debug Flags\\kain's invulnerable" })
            t = Edit(t, "\"-" + flag + "\"=1", "\"" + flag + "\"=1");
        foreach (string flag in new[] { "NoFPS", "NoFPSBar", "NoMemSize" })
            t = Edit(t, "\"" + flag + "\"=1", "\"" + flag + "\"=0");
        if (!t.EndsWith("\n")) t += nl;
        foreach (string flag in new[] { "BO2 Kain Debug Flags\\ignore water for Kain", "BO2 Kain Debug Flags\\show checkpoint info",
                                        "BO2 Kain Debug Flags\\show elapsed player time", "Debug Common\\Show UI debug info" })
            t += "\"" + flag + "\"=1" + nl;
        return enc.GetBytes(t);
    }

    static string Mod(string dir, string name) { return Path.Combine(dir, ModFolder, name); }
    static string Data(string dir, string name) { return Path.Combine(dir, "DATA", name); }

    public static bool LooksLikeGame(string dir) { return !string.IsNullOrEmpty(dir) && File.Exists(Path.Combine(dir, "bo2.exe")) && Directory.Exists(Path.Combine(dir, "DATA")); }
    public static bool IsInstalled(string dir) { return File.Exists(Mod(dir, Marker)); }
    public static bool HasRevamped(string dir) { return File.Exists(Path.Combine(dir, "d3d8.dll")); }

    // Sound fix: dinput.dll, a proxy the game loads from its own folder that replaces the FMOD 3 sound code inside the game
    // with miniaudio (separate project bo2-audio-replacement). The launcher's bo2audio.ini turns it on or off per launch.
    const string SoundDll = "dinput.dll";
    const string SoundIni = "bo2audio.ini";
    const string SoundMarker = "sound-fix.installed";   // in BO2SkipMod; the launcher shows the sound option only with it
    public const string SoundIniHeader = "; Written by the Blood Omen 2 Cutscene Skip launcher";
    static readonly string[] OwnSoundDlls = {
        "0871CB63F415197CCFC87925C4B2260365BE275C7EF54405E019393ED0CB76B4",   // backend shipped in 0.9.0
        "0DA4CF363304461D898E3B5F761632A5AA91E576C3B9A863F3BB4C44877EAB9A",   // logging-only build used while testing
    };

    // Skip ring: bo2skipui.dll, loaded by the mod's exe (V42) to draw a turning ring on the black screen of a long skip.
    // The name is the mod's own, so setup always writes it and uninstall always removes it.
    const string UiDll = "bo2skipui.dll";

    static string Hex(byte[] b) { var sb = new StringBuilder(); foreach (byte x in b) sb.Append(x.ToString("X2")); return sb.ToString(); }

    static bool IsOwnSoundDll(string path, byte[] shipped) {
        if (!File.Exists(path)) return false;
        string h = Hex(Sha(File.ReadAllBytes(path)));
        return h == Hex(Sha(shipped)) || Array.IndexOf(OwnSoundDlls, h) >= 0;
    }

    static void RequireGameClosed() {
        if (Process.GetProcessesByName("bo2").Length > 0 || Process.GetProcessesByName("bo2_actual").Length > 0)
            throw new ModException("Blood Omen 2 is running. Close it and try again.");
    }

    static void RemoveModFolder(string path) {
        if (!Directory.Exists(path)) return;
        if (!File.Exists(Path.Combine(path, Marker))) throw new ModException("Refusing to delete a folder this setup did not create:\n" + path);
        Directory.Delete(path, true);
    }

    public static void Install(string dir, Action<string> log) {
        if (!LooksLikeGame(dir)) throw new ModException("That folder does not contain Blood Omen 2 (bo2.exe and a DATA folder).");
        RequireGameClosed();
        var payload = LoadPayload();

        log("Checking game files...");
        var exeEntry = payload["bo2.exe"]; var preEntry = payload["precode.big"]; var codeEntry = payload["Code.big"]; var ergEntry = payload["game.erg"];
        byte[] exe = FindOriginal(exeEntry, Mod(dir, "bo2_vanilla.exe"), Path.Combine(dir, "bo2.exe"));
        byte[] pre = FindOriginal(preEntry, Mod(dir, "precode.big.orig"), Data(dir, "precode.big"));
        byte[] code = FindOriginal(codeEntry, Mod(dir, "Code.big.orig"), Data(dir, "Code.big"));
        byte[] erg = FindOriginal(ergEntry, Mod(dir, "game.erg.vanilla"), Data(dir, "game.erg"));
        if (exe == null) throw new ModException("bo2.exe is not the version this mod was built for." + VerifyHint);
        if (pre == null || code == null) throw new ModException("The game's font files (precode.big, Code.big) have been changed." + VerifyHint);
        if (erg == null) throw new ModException("DATA\\game.erg has been changed from the original." + VerifyHint);

        log("Building patched files...");
        byte[] exePatched = Apply(exeEntry, exe);
        byte[] exeFixes = Apply(payload["bo2_fixes.exe"], exe);   // Vanilla mode: fixes without the cutscene skip
        byte[] prePatched = Apply(preEntry, pre);
        byte[] codePatched = Apply(codeEntry, code);
        byte[] ergSpeedrun = MakeSpeedrunErg(erg);
        byte[] ergTrainer = MakeTrainerErg(erg);
        byte[] launcher = ReadResource("launcher.exe");
        byte[] soundDll = ReadResource(SoundDll);
        string soundPath = Path.Combine(dir, SoundDll);
        bool soundForeign = File.Exists(soundPath) && !IsOwnSoundDll(soundPath, soundDll);

        log("Writing mod files...");
        string modDir = Path.Combine(dir, ModFolder);
        string tmp = modDir + ".tmp";
        if (Directory.Exists(tmp)) Directory.Delete(tmp, true);
        Directory.CreateDirectory(tmp);
        File.WriteAllBytes(Path.Combine(tmp, "bo2_vanilla.exe"), exe);
        File.WriteAllBytes(Path.Combine(tmp, "bo2_patched.exe"), exePatched);
        File.WriteAllBytes(Path.Combine(tmp, "bo2_fixes.exe"), exeFixes);
        File.WriteAllBytes(Path.Combine(tmp, "precode.big.orig"), pre);
        File.WriteAllBytes(Path.Combine(tmp, "precode.big.mod"), prePatched);
        File.WriteAllBytes(Path.Combine(tmp, "Code.big.orig"), code);
        File.WriteAllBytes(Path.Combine(tmp, "Code.big.mod"), codePatched);
        File.WriteAllBytes(Path.Combine(tmp, "game.erg.vanilla"), erg);
        File.WriteAllBytes(Path.Combine(tmp, "game.erg.speedrun"), ergSpeedrun);
        File.WriteAllBytes(Path.Combine(tmp, "game.erg.trainer"), ergTrainer);
        File.WriteAllText(Path.Combine(tmp, Marker), "Blood Omen 2 Cutscene Skip");
        if (!soundForeign) File.WriteAllText(Path.Combine(tmp, SoundMarker), "The sound fix (dinput.dll) was installed by this setup.");
        RemoveModFolder(modDir);
        Directory.Move(tmp, modDir);

        log("Setting up the game folder...");
        File.WriteAllBytes(Path.Combine(dir, "bo2_actual.exe"), exePatched);
        File.WriteAllBytes(Data(dir, "game.erg"), ergSpeedrun);
        File.WriteAllBytes(Data(dir, "precode.big"), prePatched);
        File.WriteAllBytes(Data(dir, "Code.big"), codePatched);
        File.WriteAllBytes(Path.Combine(dir, "bo2.exe"), launcher);
        File.WriteAllBytes(Path.Combine(dir, UiDll), ReadResource(UiDll));
        if (soundForeign)
            log("Sound fix NOT installed: the game folder already has a dinput.dll that is not part of this mod (another mod or tool). " +
                "It was left alone. Everything else is installed.");
        else
            File.WriteAllBytes(soundPath, soundDll);
        log("Installed. Start the game as usual (Steam, GOG Galaxy or its shortcut) and pick a mode.");
    }

    public static void Uninstall(string dir, Action<string> log) {
        if (!IsInstalled(dir)) throw new ModException("The mod is not installed in that folder.");
        RequireGameClosed();
        var payload = LoadPayload();

        log("Checking saved originals...");
        byte[] exe = FindOriginal(payload["bo2.exe"], Mod(dir, "bo2_vanilla.exe"));
        byte[] pre = FindOriginal(payload["precode.big"], Mod(dir, "precode.big.orig"));
        byte[] code = FindOriginal(payload["Code.big"], Mod(dir, "Code.big.orig"));
        byte[] erg = FindOriginal(payload["game.erg"], Mod(dir, "game.erg.vanilla"));
        if (exe == null || pre == null || code == null || erg == null) throw new ModException("A saved original file is missing or damaged, so nothing was changed." + VerifyHint);

        log("Restoring original files...");
        File.WriteAllBytes(Path.Combine(dir, "bo2.exe"), exe);
        File.WriteAllBytes(Data(dir, "game.erg"), erg);
        File.WriteAllBytes(Data(dir, "precode.big"), pre);
        File.WriteAllBytes(Data(dir, "Code.big"), code);
        foreach (string name in new[] { "bo2_actual.exe", "bo2_launcher.last", UiDll }) {
            string p = Path.Combine(dir, name);
            if (File.Exists(p)) File.Delete(p);
        }
        string soundPath = Path.Combine(dir, SoundDll);
        if (IsOwnSoundDll(soundPath, ReadResource(SoundDll))) File.Delete(soundPath);
        string iniPath = Path.Combine(dir, SoundIni);
        if (File.Exists(iniPath) && File.ReadAllText(iniPath).StartsWith(SoundIniHeader, StringComparison.Ordinal)) File.Delete(iniPath);
        RemoveModFolder(Path.Combine(dir, ModFolder));
        log("Removed. The game is back to its original files. Re-vamped was left in place.");
    }

    public static string DetectGameFolder() {
        var roots = new List<string>();
        string steam = Registry.GetValue(@"HKEY_CURRENT_USER\Software\Valve\Steam", "SteamPath", null) as string;
        if (steam == null) steam = Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Valve\Steam", "InstallPath", null) as string;
        if (steam != null) {
            steam = steam.Replace('/', '\\');
            roots.Add(steam);
            try {
                string vdf = Path.Combine(steam, "steamapps", "libraryfolders.vdf");
                if (File.Exists(vdf))
                    foreach (Match m in Regex.Matches(File.ReadAllText(vdf), "\"path\"\\s+\"([^\"]+)\""))
                        roots.Add(m.Groups[1].Value.Replace("\\\\", "\\"));
            } catch { }
            foreach (string root in roots) {
                string candidate = Path.Combine(root, "steamapps", "common", GameFolderName);
                if (LooksLikeGame(candidate)) return candidate;
            }
        }
        // GOG (game id 1207659101): its bo2.exe and data files are identical to Steam's.
        foreach (string key in new[] { @"HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\GOG.com\Games\1207659101",
                                       @"HKEY_LOCAL_MACHINE\SOFTWARE\GOG.com\Games\1207659101" }) {
            string gog = Registry.GetValue(key, "path", null) as string;
            if (gog != null && LooksLikeGame(gog)) return gog;
        }
        return null;
    }
}

public class SetupForm : Form {
    readonly TextBox path = new TextBox();
    readonly Label status = new Label();
    readonly TextBox logBox = new TextBox();
    readonly Button install = new Button();
    readonly Button uninstall = new Button();

    Button MakeButton(string text, Point at, Size size) {
        var b = new Button { Text = text, Location = at, Size = size, FlatStyle = FlatStyle.Flat, BackColor = Color.FromArgb(50, 50, 55), ForeColor = Color.White };
        b.FlatAppearance.BorderColor = Color.FromArgb(90, 90, 100);
        Controls.Add(b);
        return b;
    }

    public SetupForm() {
        Text = "Blood Omen 2 Enhanced - Setup";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(560, 380);
        Font = new Font("Segoe UI", 9F);
        BackColor = Color.FromArgb(30, 30, 34);
        ForeColor = Color.White;

        Controls.Add(new Label { Text = "Blood Omen 2 Enhanced", Font = new Font("Segoe UI Semibold", 13F), Location = new Point(18, 12), AutoSize = true });
        Controls.Add(new Label { Text = "Game folder", Location = new Point(18, 52), AutoSize = true });

        path.Location = new Point(18, 72);
        path.Size = new Size(440, 24);
        path.BackColor = Color.FromArgb(45, 45, 50);
        path.ForeColor = Color.White;
        path.BorderStyle = BorderStyle.FixedSingle;
        path.TextChanged += (s, e) => Refresh2();
        Controls.Add(path);

        var browse = MakeButton("Browse...", new Point(466, 71), new Size(76, 26));
        browse.Click += (s, e) => {
            using (var d = new FolderBrowserDialog { Description = "Select the Blood Omen 2 folder (the one containing bo2.exe)" })
                if (d.ShowDialog(this) == DialogResult.OK) path.Text = d.SelectedPath;
        };

        status.Location = new Point(18, 108);
        status.Size = new Size(524, 62);
        Controls.Add(status);

        install.Text = "Install";
        install.Location = new Point(18, 176);
        install.Size = new Size(110, 32);
        install.FlatStyle = FlatStyle.Flat;
        install.BackColor = Color.FromArgb(75, 55, 90);
        install.ForeColor = Color.White;
        install.FlatAppearance.BorderColor = Color.FromArgb(120, 100, 140);
        install.Click += (s, e) => Run(Core.Install);
        Controls.Add(install);

        uninstall.Text = "Uninstall";
        uninstall.Location = new Point(136, 176);
        uninstall.Size = new Size(110, 32);
        uninstall.FlatStyle = FlatStyle.Flat;
        uninstall.BackColor = Color.FromArgb(50, 50, 55);
        uninstall.ForeColor = Color.White;
        uninstall.FlatAppearance.BorderColor = Color.FromArgb(90, 90, 100);
        uninstall.Click += (s, e) => Run(Core.Uninstall);
        Controls.Add(uninstall);

        var close = MakeButton("Close", new Point(462, 176), new Size(80, 32));
        close.Click += (s, e) => Close();

        logBox.Location = new Point(18, 220);
        logBox.Size = new Size(524, 144);
        logBox.Multiline = true;
        logBox.ReadOnly = true;
        logBox.ScrollBars = ScrollBars.Vertical;
        logBox.BackColor = Color.FromArgb(20, 20, 24);
        logBox.ForeColor = Color.Gainsboro;
        logBox.BorderStyle = BorderStyle.FixedSingle;
        Controls.Add(logBox);

        string found = null;
        try { found = Core.DetectGameFolder(); } catch { }
        if (found != null) path.Text = found;
        Refresh2();
    }

    void Refresh2() {
        string dir = path.Text.Trim();
        if (!Core.HasFiles()) {
            status.Text = "The \"files\" folder that comes with setup is missing.\nExtract the whole zip to a folder, then run setup from there.";
            status.ForeColor = Color.Khaki;
            install.Enabled = uninstall.Enabled = false;
            return;
        }
        if (!Core.LooksLikeGame(dir)) {
            status.Text = "Choose the folder that contains bo2.exe.";
            status.ForeColor = Color.Khaki;
            install.Enabled = uninstall.Enabled = false;
            return;
        }
        bool installed = Core.IsInstalled(dir);
        bool revamped = Core.HasRevamped(dir);
        status.Text = (installed ? "The mod is installed here. Install will repair it." : "Ready to install.") +
            (revamped ? "\nRe-vamped found." : "\nRe-vamped (d3d8.dll) was not found. The game may show a black screen or fail to start without it.\nDownload it from " + Core.RevampedUrl);
        status.ForeColor = revamped ? Color.LightGreen : Color.Khaki;
        install.Enabled = true;
        uninstall.Enabled = installed;
    }

    void Run(Action<string, Action<string>> action) {
        logBox.Clear();
        Cursor = Cursors.WaitCursor;
        try {
            action(path.Text.Trim(), m => { logBox.AppendText(m + "\r\n"); logBox.Update(); });
        } catch (UnauthorizedAccessException) {
            logBox.AppendText("Windows blocked access to the game folder. Close this window, then right-click setup and choose Run as administrator.\r\n");
        } catch (IOException ex) {
            logBox.AppendText("A file could not be written: " + ex.Message + "\r\nMake sure the game is closed and try again.\r\n");
        } catch (ModException ex) {
            logBox.AppendText(ex.Message + "\r\n");
        }
        Cursor = Cursors.Default;
        Refresh2();
    }
}

public static class Program {
    [STAThread]
    static int Main(string[] args) {
        string dir = null, logPath = null, action = null;
        for (int i = 0; i < args.Length; i++) {
            if (args[i] == "--dir" && i + 1 < args.Length) dir = args[++i];
            else if (args[i] == "--log" && i + 1 < args.Length) logPath = args[++i];
            else if (args[i] == "--install" || args[i] == "--uninstall") action = args[i];
        }
        if (action != null) {
            Action<string> log = m => { if (logPath != null) File.AppendAllText(logPath, m + "\r\n"); };
            try {
                if (action == "--install") Core.Install(dir, log); else Core.Uninstall(dir, log);
                return 0;
            } catch (Exception ex) {
                log("ERROR: " + ex.Message);
                return 1;
            }
        }
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new SetupForm());
        return 0;
    }
}
