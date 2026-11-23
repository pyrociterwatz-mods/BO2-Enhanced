// Blood Omen 2 Enhanced - mode picker (originally the Blood Omen 2 Cutscene Skip).
// Installed as bo2.exe, so Steam starts it. Copies the chosen mode's files into place, then runs bo2_actual.exe.
// With "Write a crash log" ticked, it runs the game under a small debugger (CrashLogger) that records the mod's skip state as
// the game runs and, if the game crashes, the crash details and a minidump. Logs keep module file names only, not full paths.
//
// Game folder after install:
//   bo2.exe                     this launcher
//   bo2_actual.exe              the game exe for the chosen mode: BO2SkipMod\bo2_patched.exe (Speedrun, Trainer) or
//                               BO2SkipMod\bo2_fixes.exe (Vanilla: the same fixes without the cutscene skip, 0.9.1).
//                               BO2SkipMod\bo2_vanilla.exe is the untouched original, kept for uninstall.
//   DATA\game.erg, DATA\precode.big, DATA\Code.big    set for the chosen mode
//   BO2SkipMod\                 one copy of each variant
//   bo2_launcher.last           line 1 last mode, then log=0|1, logdir=<folder>, lockmouse=0|1 and newsound=0|1
//   dinput.dll                  the sound fix (FMOD 3 replaced by miniaudio), loaded by the game from its folder
//   bo2audio.ini                written before each launch: [bo2audio] enable=1 when the box is ticked (every mode)
//
// The sound fix writes its own log (bo2audio-<date>.txt) every session; BO2AUDIO_LOGDIR puts it in the log folder chosen
// here, and the newest 30 are kept.
//
// Windows compatibility settings the player set on bo2.exe (Properties > Compatibility, for example "Override high DPI
// scaling") apply to this launcher, not to bo2_actual.exe. CompatLayers passes them on to the game.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("Blood Omen 2 Enhanced Launcher")]
[assembly: AssemblyDescription("Mode picker for Blood Omen 2 Enhanced: starts Blood Omen 2 in Speedrun, Trainer or Vanilla mode.")]
[assembly: AssemblyCompany("pyrociterwatz")]
[assembly: AssemblyProduct("Blood Omen 2 Enhanced")]
[assembly: AssemblyCopyright("Copyright (c) 2026 pyrociterwatz. MIT License.")]
[assembly: AssemblyVersion("1.0.2.0")]
[assembly: AssemblyFileVersion("1.0.2.0")]
[assembly: AssemblyInformationalVersion("1.0.2")]

public static class Launcher {
    public const string Version = "1.0.2";
    public const string Product = "Enhanced";
    const string ModFolder = "BO2SkipMod";
    const string LastChoiceFile = "bo2_launcher.last";

    public static string DefaultLogDir() {
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "Blood Omen 2 Enhanced logs");
    }

    [STAThread]
    static int Main(string[] args) {
        string gameDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        string modDir = Path.Combine(gameDir, ModFolder);
        string lastFile = Path.Combine(gameDir, LastChoiceFile);

        // "bo2.exe -setup" opens the game's own settings window (GOG Galaxy's "Settings" entry uses it): pass it straight
        // to the game instead of showing the mode picker.
        foreach (string a in args) {
            if (!string.Equals(a, "-setup", StringComparison.OrdinalIgnoreCase)) continue;
            string game = Path.Combine(gameDir, "bo2_actual.exe");
            if (!File.Exists(game)) game = Path.Combine(modDir, "bo2_vanilla.exe");
            try {
                Process.Start(new ProcessStartInfo(game, "-setup") { WorkingDirectory = gameDir, UseShellExecute = false });
                return 0;
            } catch (Exception ex) {
                MessageBox.Show("Could not open the game's settings:\n\n" + ex.Message, "Blood Omen 2 Enhanced",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
        }

        string[] required = { "bo2_vanilla.exe", "bo2_patched.exe", "bo2_fixes.exe", "game.erg.vanilla", "game.erg.speedrun", "game.erg.trainer",
                              "precode.big.orig", "precode.big.mod", "Code.big.orig", "Code.big.mod" };
        foreach (string name in required) {
            string p = Path.Combine(modDir, name);
            if (!File.Exists(p)) {
                MessageBox.Show("The mod is not fully installed.\n\nMissing file:\n" + p + "\n\nRun the setup program again to repair it.",
                    "Blood Omen 2 Enhanced", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 2;
            }
        }

        string lastChoice = null;
        bool logOn = false;
        bool lockMouse = true;
        bool newSound = true;
        HashSet<string> trainer = TrainerOptions.Defaults();   // all on until the player changes them
        // Only when setup installed the sound fix itself (not another mod's dinput.dll).
        bool soundInstalled = File.Exists(Path.Combine(modDir, "sound-fix.installed")) && File.Exists(Path.Combine(gameDir, "dinput.dll"));
        string logDir = DefaultLogDir();
        try {
            if (File.Exists(lastFile)) {
                string[] lines = File.ReadAllLines(lastFile);
                if (lines.Length > 0) lastChoice = lines[0].Trim();
                foreach (string line in lines) {
                    if (line.StartsWith("log=")) logOn = line.Substring(4).Trim() == "1";
                    else if (line.StartsWith("logdir=") && line.Length > 7) logDir = line.Substring(7).Trim();
                    else if (line.StartsWith("lockmouse=")) lockMouse = line.Substring(10).Trim() != "0";
                    else if (line.StartsWith("newsound=")) newSound = line.Substring(9).Trim() != "0";
                    else if (line.StartsWith("trainer=")) trainer = TrainerOptions.Parse(line.Substring(8));
                }
            }
        } catch { }

        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        var picker = new ModePicker(lastChoice, logOn, logDir, lockMouse, soundInstalled ? (bool?)newSound : null, trainer);
        if (picker.ShowDialog() != DialogResult.OK) return 0;

        string mode = picker.SelectedMode;
        logOn = picker.LogEnabled;
        logDir = picker.LogDir;
        lockMouse = picker.LockMouse;
        if (soundInstalled) newSound = picker.NewSound;
        trainer = picker.Trainer;
        string exe, erg, suffix;
        switch (mode) {
            case "speedrun": exe = "bo2_patched.exe"; erg = "game.erg.speedrun"; suffix = ".mod"; break;
            case "trainer":  exe = "bo2_patched.exe"; erg = "game.erg.trainer";  suffix = ".mod"; break;
            case "vanilla":  exe = "bo2_fixes.exe";   erg = "game.erg.vanilla";  suffix = ".orig"; break;   // no skip, so no prompt glyphs needed
            default: return 3;
        }

        try { File.WriteAllLines(lastFile, new[] { mode, "log=" + (logOn ? "1" : "0"), "logdir=" + logDir,
                                                  "lockmouse=" + (lockMouse ? "1" : "0"), "newsound=" + (newSound ? "1" : "0"),
                                                  "trainer=" + TrainerOptions.Join(trainer) }); } catch { }

        // Sound fix: every mode, when ticked (0.9.1; 0.9.0 kept it off in Vanilla).
        bool soundOn = soundInstalled && newSound;
        string soundNote = !soundInstalled ? "Sound fix: not installed by setup (bo2audio.ini left alone)"
                         : soundOn ? "Sound fix: on (bo2audio.ini enable=1)"
                         : "Sound fix: off for this launch (bo2audio.ini enable=0, original FMOD sound code)";
        if (soundInstalled) {
            try {
                File.WriteAllText(Path.Combine(gameDir, "bo2audio.ini"),
                    "; Written by the Blood Omen 2 Cutscene Skip launcher before each launch. Changes here are overwritten.\r\n" +
                    "[bo2audio]\r\nenable=" + (soundOn ? "1" : "0") + "\r\n");
            } catch (Exception ex) {
                soundNote += " - could not write bo2audio.ini: " + ex.Message;
            }
        }
        try {
            Directory.CreateDirectory(logDir);
            Environment.SetEnvironmentVariable("BO2AUDIO_LOGDIR", logDir);
            var audioLogs = new List<FileInfo>(new DirectoryInfo(logDir).GetFiles("bo2audio-*.txt"));
            audioLogs.Sort((a, b) => b.LastWriteTimeUtc.CompareTo(a.LastWriteTimeUtc));
            for (int i = 30; i < audioLogs.Count; i++) audioLogs[i].Delete();
        } catch { }

        string actual = Path.Combine(gameDir, "bo2_actual.exe");
        string trainerNote = null;
        try {
            File.Copy(Path.Combine(modDir, exe), actual, true);
            if (mode == "trainer") {
                // Trainer: only the ticked options (falls back to setup's game.erg.trainer with everything on).
                try {
                    File.WriteAllBytes(Path.Combine(gameDir, "DATA\\game.erg"),
                        TrainerOptions.BuildErg(File.ReadAllBytes(Path.Combine(modDir, "game.erg.vanilla")), trainer));
                    trainerNote = "Trainer options: " + (trainer.Count > 0 ? TrainerOptions.Join(trainer) : "none");
                } catch (Exception ex) {
                    File.Copy(Path.Combine(modDir, erg), Path.Combine(gameDir, "DATA\\game.erg"), true);
                    trainerNote = "Trainer options could not be applied (" + ex.Message + "); all of them are on";
                }
            } else
            File.Copy(Path.Combine(modDir, erg), Path.Combine(gameDir, "DATA\\game.erg"), true);
            File.Copy(Path.Combine(modDir, "precode.big" + suffix), Path.Combine(gameDir, "DATA\\precode.big"), true);
            File.Copy(Path.Combine(modDir, "Code.big" + suffix), Path.Combine(gameDir, "DATA\\Code.big"), true);
        } catch (Exception ex) {
            MessageBox.Show("Could not prepare the game files:\n\n" + ex.Message, "Blood Omen 2 Enhanced",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 4;
        }

        string compat = CompatLayers.PassOn();

#if CRASHLOG
        // Tester build only (compiled with /define:CRASHLOG): run the game under the crash logger.
        if (logOn) {
            CrashLogger logger = null;
            try {
                logger = new CrashLogger(logDir, mode, actual, true);   // every mode runs the mod's exe since 0.9.1 (same layout)
            } catch (Exception ex) {
                MessageBox.Show("Could not create the log in:\n" + logDir + "\n\n" + ex.Message + "\n\nThe game will start without a log.",
                    "Blood Omen 2 Enhanced", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
            if (logger != null) {
                logger.Note(compat != null ? "Windows compatibility settings for bo2.exe passed on to the game: " + compat
                                           : "No Windows compatibility settings set for bo2.exe");
                logger.Note(soundNote);
                if (trainerNote != null) logger.Note(trainerNote);
                CursorLock cursorLock = null;
                if (lockMouse) logger.Started = pid => { cursorLock = new CursorLock(pid, logger.Note); };
                try {
                    int code = logger.Run(actual, gameDir);
                    if (cursorLock != null) cursorLock.Stop();
                    if (logger.Crashed) {
                        MessageBox.Show("The game crashed. The details were saved to:\n\n" + logger.LogPath +
                            (logger.DumpPath != null ? "\n" + logger.DumpPath : "") +
                            "\n\nPlease send the log (and the .dmp file if there is one) with your report.",
                            "Blood Omen 2 Enhanced", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    }
                    return code;
                } catch (Exception ex) {
                    if (cursorLock != null) cursorLock.Stop();
                    MessageBox.Show("Could not start the game with logging:\n\n" + ex.Message, "Blood Omen 2 Enhanced",
                        MessageBoxButtons.OK, MessageBoxIcon.Error);
                    return 5;
                }
            }
        }
#endif

        try {
            var psi = new ProcessStartInfo(actual) { WorkingDirectory = gameDir, UseShellExecute = false };
            var proc = Process.Start(psi);
            CursorLock cursorLock = lockMouse ? new CursorLock(proc.Id, null) : null;
            proc.WaitForExit();
            if (cursorLock != null) cursorLock.Stop();
            return proc.ExitCode;
        } catch (Exception ex) {
            MessageBox.Show("Could not start the game:\n\n" + ex.Message, "Blood Omen 2 Enhanced",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 5;
        }
    }
}

// Windows keeps compatibility settings per exe path (AppCompatFlags\Layers, value name = full path, data = "[markers] LAYER ...").
// The game runs as bo2_actual.exe, so settings the player made on bo2.exe (before or after installing the mod) would not reach
// it; the environment variable __COMPAT_LAYER applies layers to the process started with it. Elevation layers (RUNAS...) are
// left out: they cannot be applied that way and would stop the game from starting.
public static class CompatLayers {
    const string Key = @"Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers";

    public static string PassOn() {
        try {
            string self = Process.GetCurrentProcess().MainModule.FileName;
            var layers = new List<string>();
            Add(layers, Environment.GetEnvironmentVariable("__COMPAT_LAYER"));
            Add(layers, Read(Microsoft.Win32.RegistryHive.CurrentUser, Microsoft.Win32.RegistryView.Default, self));
            Add(layers, Read(Microsoft.Win32.RegistryHive.LocalMachine, Microsoft.Win32.RegistryView.Registry64, self));
            Add(layers, Read(Microsoft.Win32.RegistryHive.LocalMachine, Microsoft.Win32.RegistryView.Registry32, self));
            if (layers.Count == 0) return null;
            string value = string.Join(" ", layers.ToArray());
            Environment.SetEnvironmentVariable("__COMPAT_LAYER", value);
            return value;
        } catch { return null; }
    }

    static string Read(Microsoft.Win32.RegistryHive hive, Microsoft.Win32.RegistryView view, string exe) {
        try {
            using (var b = Microsoft.Win32.RegistryKey.OpenBaseKey(hive, view))
            using (var k = b.OpenSubKey(Key))
                return k != null ? k.GetValue(exe) as string : null;
        } catch { return null; }
    }

    static void Add(List<string> layers, string data) {
        if (string.IsNullOrEmpty(data)) return;
        foreach (string t in data.Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries)) {
            if (t.Length == 1) continue;   // "~", "^", "#", "$" markers
            if (t.StartsWith("RUNAS", StringComparison.OrdinalIgnoreCase)) continue;
            bool have = false;
            foreach (string l in layers) if (string.Equals(l, t, StringComparison.OrdinalIgnoreCase)) have = true;
            if (!have) layers.Add(t);
        }
    }
}

// Trainer mode's settings, each one a toggle (1.0). The launcher builds DATA\game.erg from the original (BO2SkipMod\
// game.erg.vanilla) with only the ticked ones, the same edits setup makes for game.erg.trainer (which stays as the fallback).
public static class TrainerOptions {
    public class Option {
        public string Key, Label;
        public string[] Uncomment;     // "-Flag"=1 lines in the original file that become "Flag"=1
        public string[] Append;        // "Flag"=1 lines added at the end
        public string[][] Replace;     // exact text replaced once
    }
    public static readonly Option[] All = {
        new Option { Key = "god", Label = "God mode (Kain cannot be hurt)", Uncomment = new[] { "BO2 Kain Debug Flags\\kain's invulnerable" } },
        new Option { Key = "water", Label = "Walk on water", Append = new[] { "BO2 Kain Debug Flags\\ignore water for Kain" } },
        new Option { Key = "fps", Label = "Frame rate and memory display", Uncomment = new[] { "Debug Engine\\Show FPS" },
                     Replace = new[] { new[] { "\"NoFPS\"=1", "\"NoFPS\"=0" }, new[] { "\"NoFPSBar\"=1", "\"NoFPSBar\"=0" }, new[] { "\"NoMemSize\"=1", "\"NoMemSize\"=0" } } },
        new Option { Key = "position", Label = "Kain's position", Uncomment = new[] { "BO2 Kain Debug Flags\\show Kain's position" } },
        new Option { Key = "regions", Label = "Current regions", Uncomment = new[] { "Debug Common\\Display Current Regions" } },
        new Option { Key = "checkpoint", Label = "Checkpoint info", Append = new[] { "BO2 Kain Debug Flags\\show checkpoint info" } },
        new Option { Key = "time", Label = "Elapsed play time", Append = new[] { "BO2 Kain Debug Flags\\show elapsed player time" } },
        new Option { Key = "helpers", Label = "Helper creatures (debug markers)", Uncomment = new[] { "Debug Common\\Draw Helper Creatures" } },
        new Option { Key = "detectors", Label = "Detector debug display", Uncomment = new[] { "Blood Omen Specific Flags\\show detector debug stuff" } },
        new Option { Key = "uidebug", Label = "UI debug info", Append = new[] { "Debug Common\\Show UI debug info" } },
        new Option { Key = "console", Label = "Debug menus (console)",
                     Replace = new[] { new[] { "\"Debug Common\\Enable debug menus (Console)\"=0", "\"Debug Common\\Enable debug menus (Console)\"=1" } } },
        new Option { Key = "prints", Label = "Script and monster debug messages",
                     Replace = new[] { new[] { "\"Debug Common\\Disable script debug print\"=1", "\"Debug Common\\Disable script debug print\"=0" },
                                       new[] { "\"Blood Omen Specific Flags\\dont show monster prints\"=1", "\"Blood Omen Specific Flags\\dont show monster prints\"=0" } } },
    };

    public static HashSet<string> Defaults() {
        var s = new HashSet<string>();
        foreach (var o in All) s.Add(o.Key);
        return s;
    }

    public static HashSet<string> Parse(string list) {
        var s = new HashSet<string>();
        foreach (string k in list.Split(',')) { string t = k.Trim(); if (t.Length > 0) s.Add(t); }
        return s;
    }

    public static string Join(HashSet<string> on) {
        var keys = new List<string>();
        foreach (var o in All) if (on.Contains(o.Key)) keys.Add(o.Key);
        return string.Join(",", keys.ToArray());
    }

    static string EditOnce(string text, string from, string to) {
        int at = text.IndexOf(from, StringComparison.Ordinal);
        if (at < 0 || text.IndexOf(from, at + 1, StringComparison.Ordinal) >= 0) throw new InvalidDataException("unexpected game.erg contents near: " + from);
        return text.Substring(0, at) + to + text.Substring(at + from.Length);
    }

    // The original game.erg with movies off (as every skip mode) and the ticked options.
    public static byte[] BuildErg(byte[] vanilla, HashSet<string> on) {
        Encoding enc = Encoding.GetEncoding(28591);
        string t = enc.GetString(vanilla);
        string nl = t.Contains("\r\n") ? "\r\n" : "\n";
        t = EditOnce(t, "PlayMovie=1", "PlayMovie=0");
        var append = new List<string>();
        foreach (var o in All) {
            if (!on.Contains(o.Key)) continue;
            if (o.Uncomment != null) foreach (string f in o.Uncomment) t = EditOnce(t, "\"-" + f + "\"=1", "\"" + f + "\"=1");
            if (o.Replace != null) foreach (string[] r in o.Replace) t = EditOnce(t, r[0], r[1]);
            if (o.Append != null) append.AddRange(o.Append);
        }
        if (append.Count > 0 && !t.EndsWith("\n")) t += nl;
        foreach (string f in append) t += "\"" + f + "\"=1" + nl;
        return enc.GetBytes(t);
    }
}

public class TrainerDialog : Form {
    readonly List<CheckBox> boxes = new List<CheckBox>();
    public HashSet<string> Selected { get; private set; }

    public TrainerDialog(HashSet<string> on) {
        Selected = new HashSet<string>(on);
        SuspendLayout();
        AutoScaleDimensions = new SizeF(96F, 96F);
        AutoScaleMode = AutoScaleMode.Dpi;
        Text = "Trainer";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterParent;
        Font = new Font("Segoe UI", 9F);
        BackColor = Color.FromArgb(30, 30, 34);
        ForeColor = Color.White;
        Controls.Add(new Label { Text = "Choose the cheats and displays (remembered):", Location = new Point(16, 12), AutoSize = true });
        int y = 38;
        foreach (var o in TrainerOptions.All) {
            var cb = new CheckBox { Text = o.Label, Tag = o.Key, Checked = on.Contains(o.Key), Location = new Point(20, y), AutoSize = true, ForeColor = Color.White };
            boxes.Add(cb);
            Controls.Add(cb);
            y += 24;
        }
        var all = MakeButton("All", new Point(20, y + 8), 60);
        all.Click += (s, e) => { foreach (var b in boxes) b.Checked = true; };
        var none = MakeButton("None", new Point(86, y + 8), 60);
        none.Click += (s, e) => { foreach (var b in boxes) b.Checked = false; };
        var ok = MakeButton("Start Trainer", new Point(156, y + 8), 100);
        ok.Click += (s, e) => {
            Selected = new HashSet<string>();
            foreach (var b in boxes) if (b.Checked) Selected.Add((string)b.Tag);
            DialogResult = DialogResult.OK; Close();
        };
        var cancel = MakeButton("Back", new Point(262, y + 8), 60);
        cancel.Click += (s, e) => { DialogResult = DialogResult.Cancel; Close(); };
        AcceptButton = ok;
        CancelButton = cancel;
        ClientSize = new Size(340, y + 48);
        ResumeLayout(false);
        PerformLayout();
    }

    Button MakeButton(string text, Point at, int width) {
        var b = new Button { Text = text, Location = at, Size = new Size(width, 26), FlatStyle = FlatStyle.Flat,
                             BackColor = Color.FromArgb(50, 50, 55), ForeColor = Color.White };
        b.FlatAppearance.BorderColor = Color.FromArgb(70, 70, 75);
        Controls.Add(b);
        return b;
    }
}

public class ModePicker : Form {
    public string SelectedMode { get; private set; }
    public bool LogEnabled { get { return logBox != null && logBox.Checked; } }
    public string LogDir { get; private set; }
    public bool LockMouse { get { return lockBox.Checked; } }
    public bool NewSound { get { return soundBox != null && soundBox.Checked; } }
    public HashSet<string> Trainer { get; private set; }

    CheckBox logBox, lockBox, soundBox;
    Label logPath;

    // newSound: null when the sound fix is not installed (no checkbox).
    public ModePicker(string defaultMode, bool logOn, string logDir, bool lockMouse, bool? newSound, HashSet<string> trainer) {
        Trainer = trainer;
        SuspendLayout();
        // Positions below are in 96-dpi pixels; scale them to the display (the bo2.exe "high DPI" override makes the launcher
        // DPI-aware, and fixed pixel sizes then cut off text that Windows draws larger).
        AutoScaleDimensions = new SizeF(96F, 96F);
        AutoScaleMode = AutoScaleMode.Dpi;
        LogDir = logDir;
        Text = "Blood Omen 2 - " + Launcher.Product + " " + Launcher.Version;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        int dy = newSound.HasValue ? 28 : 0;   // room for the sound checkbox
#if CRASHLOG
        ClientSize = new Size(460, 428 + dy);
#else
        ClientSize = new Size(460, 360 + dy);   // no crash-log row in the public build
#endif
        Font = new Font("Segoe UI", 9F);
        BackColor = Color.FromArgb(30, 30, 34);
        ForeColor = Color.White;

        Controls.Add(new Label {
            Text = "Choose how to launch Blood Omen 2",
            Font = new Font("Segoe UI Semibold", 12F),
            Location = new Point(20, 15),
            AutoSize = true,
            ForeColor = Color.White
        });

        AddModeButton("Speedrun", "Hold Y or Space to skip cutscenes. FMVs are off. No cheats.", "speedrun", 55, defaultMode == "speedrun");
        AddModeButton("Trainer", "Cutscene skip, FMVs off, cheats and debug display (choose next).", "trainer", 130, defaultMode == "trainer");
        AddModeButton("Vanilla", "No cutscene skip, FMVs on. Keeps the sound and stability fixes.", "vanilla", 205, defaultMode == "vanilla");

        if (newSound.HasValue) {
            soundBox = new CheckBox {
                Text = "Use the new sound engine (against sound crashes)",
                Checked = newSound.Value,
                Location = new Point(20, 285),
                AutoSize = true,
                ForeColor = Color.White
            };
            Controls.Add(soundBox);
        }

        lockBox = new CheckBox {
            Text = "Keep the mouse inside the game window (for borderless windowed)",
            Checked = lockMouse,
            Location = new Point(20, 285 + dy),
            AutoSize = true,
            ForeColor = Color.White
        };
        Controls.Add(lockBox);

#if CRASHLOG
        logBox = new CheckBox {
            Text = "Write a crash log (for bug reports)",
            Checked = logOn,
            Location = new Point(20, 313 + dy),
            AutoSize = true,
            ForeColor = Color.White
        };
        Controls.Add(logBox);

        logPath = new Label {
            Location = new Point(38, 338 + dy),
            Size = new Size(300, 34),
            ForeColor = Color.FromArgb(170, 170, 180),
            AutoEllipsis = true
        };
        Controls.Add(logPath);
        ShowPath();

        var change = SmallButton("Change...", new Point(345, 334 + dy));
        change.Click += (s, e) => {
            using (var dlg = new FolderBrowserDialog()) {
                dlg.Description = "Choose where to save crash logs";
                dlg.ShowNewFolderButton = true;
                try { if (Directory.Exists(LogDir)) dlg.SelectedPath = LogDir; } catch { }
                if (dlg.ShowDialog(this) == DialogResult.OK) { LogDir = dlg.SelectedPath; logBox.Checked = true; ShowPath(); }
            }
        };
        var open = SmallButton("Open", new Point(345, 364 + dy));
        open.Click += (s, e) => {
            try { Directory.CreateDirectory(LogDir); Process.Start("explorer.exe", "\"" + LogDir + "\""); } catch { }
        };
        // Above 100% display scaling the path label came out scaled twice and covered these two buttons (it is above them in
        // the z-order). Size it from the buttons' final positions instead, and keep the buttons on top.
        Load += (s, e) => {
            logPath.Width = Math.Max(60, change.Left - logPath.Left - 6);
            logPath.Height = Math.Max(20, open.Bottom - logPath.Top);
            change.BringToFront();
            open.BringToFront();
        };

        var cancel = SmallButton("Cancel", new Point(360, 394 + dy));
#else
        // Public build: no crash logger (its debugger code made anti-virus heuristics flag the launcher). The sound engine still
        // writes its own log there every session.
        var openLogs = SmallButton("Open log folder", new Point(20, 326 + dy));
        openLogs.Width = 130;
        openLogs.Click += (s, e) => {
            try { Directory.CreateDirectory(LogDir); Process.Start("explorer.exe", "\"" + LogDir + "\""); } catch { }
        };
        var cancel = SmallButton("Cancel", new Point(360, 326 + dy));
#endif
        cancel.Click += (s, e) => { DialogResult = DialogResult.Cancel; Close(); };
        CancelButton = cancel;
        ResumeLayout(false);
        PerformLayout();
    }

    void ShowPath() { if (logPath != null) logPath.Text = "Saved to: " + LogDir; }

    Button SmallButton(string text, Point at) {
        var b = new Button {
            Text = text,
            Location = at,
            Size = new Size(text == "Cancel" ? 80 : 95, 26),
            FlatStyle = FlatStyle.Flat,
            BackColor = Color.FromArgb(50, 50, 55),
            ForeColor = Color.White
        };
        b.FlatAppearance.BorderColor = Color.FromArgb(70, 70, 75);
        Controls.Add(b);
        return b;
    }

    void AddModeButton(string title, string description, string mode, int y, bool isDefault) {
        var btn = new Button {
            Location = new Point(20, y),
            Size = new Size(420, 65),
            FlatStyle = FlatStyle.Flat,
            BackColor = isDefault ? Color.FromArgb(75, 55, 90) : Color.FromArgb(45, 45, 50),
            ForeColor = Color.White,
            TextAlign = ContentAlignment.TopLeft,
            Text = "  " + title + (isDefault ? "  (last choice)" : "") + "\n  " + description,
            Font = new Font("Segoe UI", 10F)
        };
        btn.FlatAppearance.BorderColor = Color.FromArgb(90, 90, 100);
        btn.Click += (s, e) => {
            if (mode == "trainer") {                // pick the cheats and displays first; Back returns to this window
                using (var d = new TrainerDialog(Trainer)) {
                    if (d.ShowDialog(this) != DialogResult.OK) return;
                    Trainer = d.Selected;
                }
            }
            SelectedMode = mode; DialogResult = DialogResult.OK; Close();
        };
        Controls.Add(btn);
        if (isDefault) AcceptButton = btn;
    }
}

// Keeps the mouse pointer inside the game window while the game is the window in front, for borderless windowed play where
// the pointer could otherwise drift onto another monitor and a click would take the focus away. Checks ten times a second on
// its own thread: confines the pointer to the game window's client area while the game is in front and not minimised, and
// lets go as soon as another window is in front (Alt+Tab, the Windows key, a message box) or the game exits. Windows can drop
// the confinement by itself (focus or display changes), so it is set again whenever it no longer matches the window.
public class CursorLock {
    readonly int pid;
    readonly Action<string> note;
    readonly Thread thread;
    volatile bool stop;
    bool clipped;
    CursorNative.RECT lastRect;

    public CursorLock(int pid, Action<string> note) {
        this.pid = pid;
        this.note = note;
        thread = new Thread(Loop) { IsBackground = true, Name = "CursorLock" };
        thread.Start();
    }

    public void Stop() {
        stop = true;
        try { thread.Join(1000); } catch { }
        if (clipped) Release("Mouse released (game closed)");
    }

    void Note(string s) { if (note != null) try { note(s); } catch { } }

    void Loop() {
        // Physical pixels for this thread, so the window rectangle and the confinement agree at any display scaling.
        try { CursorNative.SetThreadDpiAwarenessContext(new IntPtr(-4)); } catch { }
        while (!stop) {
            try { Tick(); } catch { }
            Thread.Sleep(100);
        }
    }

    void Tick() {
        IntPtr fg = CursorNative.GetForegroundWindow();
        uint fgPid = 0;
        if (fg != IntPtr.Zero) CursorNative.GetWindowThreadProcessId(fg, out fgPid);
        CursorNative.RECT r = new CursorNative.RECT();
        bool want = fg != IntPtr.Zero && fgPid == (uint)pid && !CursorNative.IsIconic(fg) && ClientOnScreen(fg, ref r)
                    && r.Right - r.Left >= 64 && r.Bottom - r.Top >= 64;
        if (!want) {
            if (clipped) Release("Mouse released (another window is in front)");
            return;
        }
        CursorNative.RECT cur;
        if (clipped && CursorNative.GetClipCursor(out cur) && Same(cur, r)) return;
        if (!CursorNative.ClipCursor(ref r)) return;
        if (!clipped || !Same(r, lastRect))
            Note(string.Format("Mouse kept inside the game window ({0},{1} to {2},{3})", r.Left, r.Top, r.Right, r.Bottom));
        clipped = true;
        lastRect = r;
    }

    void Release(string why) {
        CursorNative.ClipCursor(IntPtr.Zero);
        clipped = false;
        Note(why);
    }

    static bool ClientOnScreen(IntPtr hwnd, ref CursorNative.RECT r) {
        if (!CursorNative.GetClientRect(hwnd, out r)) return false;
        var tl = new CursorNative.POINT { X = r.Left, Y = r.Top };
        var br = new CursorNative.POINT { X = r.Right, Y = r.Bottom };
        if (!CursorNative.ClientToScreen(hwnd, ref tl) || !CursorNative.ClientToScreen(hwnd, ref br)) return false;
        r.Left = tl.X; r.Top = tl.Y; r.Right = br.X; r.Bottom = br.Y;
        return true;
    }

    static bool Same(CursorNative.RECT a, CursorNative.RECT b) {
        return a.Left == b.Left && a.Top == b.Top && a.Right == b.Right && a.Bottom == b.Bottom;
    }
}

static class CursorNative {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hwnd, out RECT r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hwnd, ref POINT p);
    [DllImport("user32.dll")] public static extern bool ClipCursor(ref RECT r);
    [DllImport("user32.dll")] public static extern bool ClipCursor(IntPtr r);
    [DllImport("user32.dll")] public static extern bool GetClipCursor(out RECT r);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
}

// Runs the game as a debuggee. Records loaded modules, the mod's skip state while it changes, the game's debug output,
// exceptions, and on a crash the registers, code, stack, likely call stack, the mod's state block and a minidump.
// Must be compiled for x86 so that it debugs the 32-bit game directly.
#if CRASHLOG
public class CrashLogger {
    public string LogPath { get; private set; }
    public string DumpPath { get; private set; }
    public bool Crashed { get; private set; }
    public Action<int> Started;   // called with the game's process id once it is created (the mouse lock starts here)

    readonly StreamWriter log;
    readonly string stamp;
    readonly string logDir;
    readonly bool modded;
    readonly Stopwatch clock = Stopwatch.StartNew();
    IntPtr hProcess;
    int pid;

    class Module { public uint Base, Size; public string Name; }
    readonly List<Module> modules = new List<Module>();
    readonly Dictionary<int, uint> gameThreads = new Dictionary<int, uint>();

    // Mod state (see patches/apply-cutscene-fastforward-v44.ps1)
    const uint StateBase = 0x00AAFF00;
    const int StateSize = 0xF8;          // fields up to 0x9C, KeyBuf (file name) at 0xA0, then CamMode 0xE0, CamPath 0xE4, CineCam 0xE8
    static readonly string[] StateNames = {
        "Latch", "Counter", "HoldT", "Button", "Phase", "WaitT", "PXInput", "PKey", "Init", "PadOk", "PromptTick", "Hint",
        "HintPopup", "LastPacket", "LastKeys", "Dev", "DevShown", "DevInit", "PLastInput", "PJoy", "JoyInit", "VoGroup1",
        "VoGroup2", "SkipT", "PadRecent", "VoTrimmed", "StopWaits", "AbortReq", "DevSkip", "DevSkips",
        "ChapterCine", "LastCine", "ChainOn", "ChainT", "PrevLatch", "Chains", "CineSeen", "HudMode", "ScriptT", "ScriptOn" };
    static readonly bool[] StateFloat = new bool[40];
    static CrashLogger() { StateFloat[2] = StateFloat[5] = StateFloat[23] = StateFloat[33] = StateFloat[38] = true; }
    const uint ModCodeStart = 0x0083E780, ModCodeEnd = 0x0083F000;
    // Two unused game functions reused for mod code since V23
    const uint ModSpareA = 0x004E0130, ModSpareAEnd = 0x004E0170, ModSpareB = 0x004E0230, ModSpareBEnd = 0x004E02D0;
    const uint ModSpareC = 0x004E8EE0, ModSpareCEnd = 0x004E9020, ModSpareD = 0x004CA8D0, ModSpareDEnd = 0x004CAA00;
    const uint ModSpareE = 0x004CC810, ModSpareEEnd = 0x004CC940, ModSpareF = 0x0049AB70, ModSpareFEnd = 0x0049AD00;

    byte[] lastState;
    int sceneOffPolls;
    bool sceneOn;
    int noSkipOffPolls, noSkipPolls;
    bool noSkipOn;
    uint lastCap;   // V33 CapCine (0xAAFEF8): lightning scene whose fast-forward was stopped
    uint lastLoadReset;   // V35 LoadReset (0xAAFFF8): the skip during which a load screen loaded
    bool loadWait;        // V35: fast-forward held at normal speed while the stream loader has files queued

    uint U(uint addr) { byte[] b = Read(addr, 4); return b != null ? BitConverter.ToUInt32(b, 0) : 0; }

    // V35: the mod's MulGate test: loader = [[0xA79CD4]], queue sentinel = [loader+0xC], empty when [sentinel] == sentinel
    bool LoaderBusy() {
        uint p = U(0x00A79CD4); if (p == 0) return false;
        uint l = U(p); if (l == 0) return false;
        uint q = U(l + 0xC); if (q == 0) return false;
        return U(q) != q;
    }
    long lastPoll;
    readonly HashSet<string> seenExceptions = new HashSet<string>();
    int exceptionCount;
    int detailedFirstChance;

    public CrashLogger(string dir, string mode, string exePath, bool modded) {
        logDir = dir;
        this.modded = modded;
        Directory.CreateDirectory(dir);
        Prune(dir);
        stamp = DateTime.Now.ToString("yyyyMMdd-HHmmss");
        LogPath = Path.Combine(dir, "bo2-log-" + stamp + ".txt");
        log = new StreamWriter(LogPath, false, new UTF8Encoding(false)) { AutoFlush = true };
        log.WriteLine("Blood Omen 2 " + Launcher.Product + " " + Launcher.Version + " log");
        log.WriteLine("Started: " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
        log.WriteLine("Mode: " + mode);
        log.WriteLine("Windows: " + Environment.OSVersion.VersionString + (Environment.Is64BitOperatingSystem ? " 64-bit" : " 32-bit"));
        log.WriteLine("Game exe SHA256: " + Sha256(exePath));
        log.WriteLine("Times are seconds since the game started. Skip phases: 0 idle, 1 fading out, 2 fast-forward (or the game's own abort for chapter scenes), 3 fading back.");
        log.WriteLine();
    }

    static void Prune(string dir) {
        try {
            var files = new List<FileInfo>(new DirectoryInfo(dir).GetFiles("bo2-*"));
            files.Sort((a, b) => b.LastWriteTimeUtc.CompareTo(a.LastWriteTimeUtc));
            for (int i = 30; i < files.Count; i++) files[i].Delete();
        } catch { }
    }

    static string Sha256(string path) {
        try {
            using (var s = File.OpenRead(path))
            using (var sha = System.Security.Cryptography.SHA256.Create())
                return BitConverter.ToString(sha.ComputeHash(s)).Replace("-", "");
        } catch { return "?"; }
    }

    string T() { return (clock.ElapsedMilliseconds / 1000.0).ToString("F2").PadLeft(8); }
    void Line(string s) { lock (log) { try { log.WriteLine(T() + "  " + s); } catch { } } }
    public void Note(string s) { Line(s); }   // for other threads (the mouse lock)

    public int Run(string exe, string workDir) {
        // A process started under a debugger gets the checked heap unless this is set; keep the game's behaviour unchanged.
        Environment.SetEnvironmentVariable("_NO_DEBUG_HEAP", "1");
        var si = new Native.STARTUPINFO();
        si.cb = Marshal.SizeOf(typeof(Native.STARTUPINFO));
        Native.PROCESS_INFORMATION pi;
        var cmd = new StringBuilder("\"" + exe + "\"");
        if (!Native.CreateProcess(exe, cmd, IntPtr.Zero, IntPtr.Zero, false, Native.DEBUG_ONLY_THIS_PROCESS, IntPtr.Zero, workDir, ref si, out pi))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        Native.CloseHandle(pi.hThread);
        hProcess = pi.hProcess;
        pid = pi.dwProcessId;
        Native.DebugSetProcessKillOnExit(false);   // if the launcher itself dies, the game keeps running
        if (Started != null) try { Started(pid); } catch { }

        IntPtr ev = Marshal.AllocHGlobal(256);
        bool initialBreak = true;
        int exitCode = 0;
        try {
            while (true) {
                if (!Native.WaitForDebugEvent(ev, 50)) { Poll(); continue; }
                int code = Marshal.ReadInt32(ev, 0);
                int evPid = Marshal.ReadInt32(ev, 4);
                int evTid = Marshal.ReadInt32(ev, 8);
                uint cont = Native.DBG_CONTINUE;
                switch (code) {
                    case 1: { // exception
                        uint exCode = (uint)Marshal.ReadInt32(ev, 12);
                        bool firstChance = Marshal.ReadInt32(ev, 92) != 0;
                        if (initialBreak && exCode == 0x80000003) { initialBreak = false; Line("Game loaded."); break; }
                        cont = Native.DBG_EXCEPTION_NOT_HANDLED;
                        OnException(ev, evTid, exCode, firstChance);
                        break;
                    }
                    case 3: { // process created
                        IntPtr hFile = Marshal.ReadIntPtr(ev, 12);
                        uint bas = (uint)Marshal.ReadInt32(ev, 24);
                        AddModule(bas, hFile, "bo2_actual.exe");
                        break;
                    }
                    case 2: { // thread created: record the game's own threads (the sound mixer is 0x6E8970)
                        uint start = (uint)Marshal.ReadInt32(ev, 20);
                        Module m = ModuleAt(start);
                        if (m != null && m.Name.Equals("bo2_actual.exe", StringComparison.OrdinalIgnoreCase)) {
                            gameThreads[evTid] = start;
                            int same = 0;
                            foreach (uint s in gameThreads.Values) if (s == start) same++;
                            Line(string.Format("Game thread {0} started at 0x{1:X8}{2} ({3} running from there)", evTid, start,
                                start == 0x006E8970 ? " (sound mixer)" : "", same));
                        }
                        break;
                    }
                    case 4: { // thread exited
                        uint start;
                        if (gameThreads.TryGetValue(evTid, out start)) {
                            gameThreads.Remove(evTid);
                            Line(string.Format("Game thread {0} (0x{1:X8}) ended", evTid, start));
                        }
                        break;
                    }
                    case 5: // process exited
                        exitCode = Marshal.ReadInt32(ev, 12);
                        Poll();
                        if (!Crashed && ((uint)exitCode >= 0x80000000u)) {
                            // Ended with an error status but without an unhandled-exception event (for example a fast fail
                            // or the game's own handler quitting): the first-chance exceptions above are the clue.
                            Crashed = true;
                            log.WriteLine();
                            Line("CRASH: the game ended abnormally; see the exceptions logged above.");
                            DumpState();
                            WriteRecentDebug();
                        }
                        Line(string.Format("Game exited with code 0x{0:X8}{1}.", exitCode, Crashed ? " after a crash" : ""));
                        Native.ContinueDebugEvent(evPid, evTid, Native.DBG_CONTINUE);
                        return exitCode;
                    case 6: { // dll loaded
                        IntPtr hFile = Marshal.ReadIntPtr(ev, 12);
                        uint bas = (uint)Marshal.ReadInt32(ev, 16);
                        AddModule(bas, hFile, null);
                        break;
                    }
                    case 7: { // dll unloaded
                        uint bas = (uint)Marshal.ReadInt32(ev, 12);
                        Module m = modules.Find(x => x.Base == bas);
                        if (m != null) modules.Remove(m);
                        break;
                    }
                    case 8: // debug output
                        OnDebugString(ev);
                        break;
                }
                Poll();
                Native.ContinueDebugEvent(evPid, evTid, cont);
            }
        } finally {
            Marshal.FreeHGlobal(ev);
            try { WriteDebugSummary(); log.Close(); } catch { }
            Native.CloseHandle(hProcess);
        }
    }

    // ---- modules ----
    void AddModule(uint bas, IntPtr hFile, string fallback) {
        string name = fallback ?? "?";
        if (hFile != IntPtr.Zero) {
            var sb = new StringBuilder(1024);
            if (Native.GetFinalPathNameByHandle(hFile, sb, sb.Capacity, 0) > 0) name = Path.GetFileName(sb.ToString());
            Native.CloseHandle(hFile);
        }
        uint size = 0;
        byte[] hdr = Read(bas, 0x400);
        if (hdr != null) {
            int nt = BitConverter.ToInt32(hdr, 0x3C);
            if (nt > 0 && nt + 0x54 <= hdr.Length) size = BitConverter.ToUInt32(hdr, nt + 0x50);
        }
        modules.Add(new Module { Base = bas, Size = size, Name = name });
        Line(string.Format("Module {0} at 0x{1:X8} size 0x{2:X}", name, bas, size));
    }

    Module ModuleAt(uint a) {
        foreach (var m in modules) if (a >= m.Base && a < m.Base + m.Size) return m;
        return null;
    }

    string Where(uint a) {
        Module m = ModuleAt(a);
        if (m == null) return "";
        string s = string.Format("{0}+0x{1:X}", m.Name, a - m.Base);
        if (modded && m.Name.Equals("bo2_actual.exe", StringComparison.OrdinalIgnoreCase) && m.Base == 0x400000 &&
            ((a >= ModCodeStart && a < ModCodeEnd) || (a >= ModSpareA && a < ModSpareAEnd) || (a >= ModSpareB && a < ModSpareBEnd) || (a >= ModSpareC && a < ModSpareCEnd) || (a >= ModSpareD && a < ModSpareDEnd) || (a >= ModSpareE && a < ModSpareEEnd) || (a >= ModSpareF && a < ModSpareFEnd)))
            s += " [MOD CODE]";
        return s;
    }

    // ---- memory ----
    byte[] Read(uint addr, int size) {
        var buf = new byte[size];
        IntPtr got;
        if (!Native.ReadProcessMemory(hProcess, (IntPtr)unchecked((int)addr), buf, size, out got)) return null;
        if ((int)got != size) return null;
        return buf;
    }

    // The cinematic's object name: [[cinematic+0x2C]+0xB0]+6 (what the game prints in its own cinematic messages)
    string CinematicName(uint cin) {
        try {
            if (cin == 0) return "?";
            byte[] p = Read(cin + 0x2C, 4); if (p == null) return "?";
            uint obj = BitConverter.ToUInt32(p, 0); if (obj == 0) return "?";
            p = Read(obj + 0xB0, 4); if (p == null) return "?";
            uint str = BitConverter.ToUInt32(p, 0); if (str == 0) return "?";
            byte[] b = Read(str + 6, 64); if (b == null) return "?";
            int n = Array.IndexOf(b, (byte)0); if (n < 0) n = b.Length;
            return Encoding.ASCII.GetString(b, 0, n);
        } catch { return "?"; }
    }

    static string HudModeName(int m) {
        switch (m) { case 0: return "none"; case 1: return "kain"; case 2: return "cinematic"; case 3: return "kain+enemy"; case 4: return "charm"; }
        return m.ToString();
    }

    static string CamModeName(int m) {
        if (m == -1) return "none";
        if (m == 3) return "3 (exported path)";
        return m.ToString();
    }

    static string KeyName(byte[] s) {
        int n = 0;
        while (n < 64 && 0xA0 + n < s.Length && s[0xA0 + n] != 0) n++;
        return n == 0 ? "(none)" : "'" + Encoding.ASCII.GetString(s, 0xA0, n) + "'";
    }

    int lastAppState = -1;
    uint lastEvicts = 0;

    static string AppStateName(int s) {
        switch (s) {
            case 4: return "4 (main menu)";
            case 11: return "11 (in game)";
            case 8: return "8 (credits movie)";
            case 9: return "9 (demo movies)";
            case 10: return "10 (intro movies)";
            case 12: return "12 (outro movies: the game was ended by its script)";
            default: return s.ToString();
        }
    }

    // ---- live mod state ----
    void Poll() {
        if (!modded || hProcess == IntPtr.Zero) return;
        long now = clock.ElapsedMilliseconds;
        if (now - lastPoll < 50) return;
        lastPoll = now;
        byte[] s = Read(StateBase, StateSize);
        if (s == null) return;
        if (lastState == null) { lastState = s; return; }

        // 0.9.2: the game's top-level state, [[0xA83664]+0x18] (set by 0x4AE220). The script function endgame (native 0x20,
        // 0x4CE4B0 -> 0x4D8820, deferred) switches it to 12 (outro movies, then 3). The 0.9.2 log showed 4 = main menu, 11 = in game.
        uint app = U(0x00A83664);
        int appState = app != 0 ? (int)U(app + 0x18) : -1;
        if (appState != lastAppState) {
            if (appState >= 0) Line("Game state " + AppStateName(appState) + (lastAppState >= 0 ? " (was " + AppStateName(lastAppState) + ")" : ""));
            lastAppState = appState;
        }

        // 0.9.3 (V39): [0xAAFFFC] counts voice/music streams that found all 48 sound channels busy, for which the mod released a
        // sound effect's channel (the original game started such a stream with channel -1 and corrupted memory).
        uint evicts = U(0x00AAFFFC);
        if (evicts != lastEvicts) {
            Line(string.Format("All 48 sound channels were busy when a voice or music stream started; a sound effect's channel was freed for it ({0} so far)", evicts));
            lastEvicts = evicts;
        }

        int tick = BitConverter.ToInt32(s, 0x28);
        if (tick > 0) {
            sceneOffPolls = 0;
            if (!sceneOn) { sceneOn = true; Line("Cinematic running."); }
        } else if (sceneOn && ++sceneOffPolls >= 3) {
            sceneOn = false; Line("Cinematic stopped.");
        }
        // V31: a cinematic that ticks (CineSeen) without setting PromptTick is one the mod leaves alone
        bool cineTicking = BitConverter.ToInt32(s, 0x90) > 0;
        if (cineTicking && tick <= 0) {
            noSkipOffPolls = 0;
            if (!noSkipOn && ++noSkipPolls >= 2) {
                noSkipOn = true;
                uint last = BitConverter.ToUInt32(s, 0x7C);
                Line("Cinematic '" + CinematicName(last) + "' running with no skip offered (a scene that breaks when fast-forwarded)");
            }
        } else if (!noSkipOn) { noSkipPolls = 0;
        } else if (++noSkipOffPolls >= 3) {
            noSkipPolls = 0;
            noSkipOn = false; Line("Unskippable cinematic over.");
        }
        uint seer = BitConverter.ToUInt32(s, 0xF4), oldSeer = BitConverter.ToUInt32(lastState, 0xF4);
        if (seer != oldSeer)
            Line(seer != 0 ? "Seer scene being skipped: if the game leaves the HUD hidden afterwards, the mod will show it again"
                           : "Seer scene skip over: HUD checked (a \"HUD mode kain\" line right here means the mod put it back)");
        byte[] capB = Read(0x00AAFEF8, 4);
        uint cap = capB != null ? BitConverter.ToUInt32(capB, 0) : 0;
        if (cap != lastCap) {
            if (cap != 0) Line(string.Format("Long lightning scene: fast-forward stopped after {0:F2} s, so the rest (the switches) plays at normal speed",
                                             BitConverter.ToSingle(s, 0x5C)));
            lastCap = cap;
        }
        uint lr = U(0x00AAFFF8);
        if (lr != lastLoadReset) {
            if (lr != 0) Line("Level reloaded during this skip: the next cinematic will show its prompt instead of continuing the skip");
            lastLoadReset = lr;
        }
        bool busy = BitConverter.ToInt32(s, 0x10) == 2 && BitConverter.ToUInt32(s, 0x70) == 0 && LoaderBusy();
        if (busy != loadWait) {
            if (busy) Line("Fast-forward held at normal speed: the game is loading files");
            else if (BitConverter.ToInt32(s, 0x10) == 2) Line("Files loaded: fast-forward going again");
            loadWait = busy;
        }
        int phase = BitConverter.ToInt32(s, 0x10), oldPhase = BitConverter.ToInt32(lastState, 0x10);
        if (phase != oldPhase) {
            Line(string.Format("Skip phase {0} -> {1}  (cinematic 0x{2:X8}, skip time {3:F2} s)", oldPhase, phase,
                BitConverter.ToUInt32(s, 0x00), BitConverter.ToSingle(s, 0x5C)));
            if (phase == 1) Line(BitConverter.ToUInt32(s, 0x00) == 1 ? "Skipping a scripted scene (camera path 0x" + BitConverter.ToUInt32(s, 0xE4).ToString("X8") + ", no cinematic)"
                                                                     : "Skipping cinematic '" + CinematicName(BitConverter.ToUInt32(s, 0x00)) + "'");
            if (phase == 2) Line(BitConverter.ToUInt32(s, 0x70) != 0
                ? "Chapter scene (name: '" + CinematicName(BitConverter.ToUInt32(s, 0x00)) + "'): using the game's own abort (dev skip)"
                : (BitConverter.ToUInt32(s, 0x78) != 0 && BitConverter.ToUInt32(s, 0x00) == BitConverter.ToUInt32(s, 0x78)
                    ? "Fast-forwarding (a chapter region loaded during this cinematic, but its name is not a chapter scene's)"
                    : "Fast-forwarding (not a chapter scene)"));
        }
        uint aborts = BitConverter.ToUInt32(s, 0x74), oldAborts = BitConverter.ToUInt32(lastState, 0x74);
        if (aborts != oldAborts) Line(string.Format("Chapter-scene aborts so far: {0}", aborts));
        int hud = BitConverter.ToInt32(s, 0x94), oldHud = BitConverter.ToInt32(lastState, 0x94);
        if (hud != oldHud && hud >= 0) Line("HUD mode " + HudModeName(hud) + (oldHud >= 0 ? " (was " + HudModeName(oldHud) + ")" : ""));
        uint so = BitConverter.ToUInt32(s, 0x9C), oldSo = BitConverter.ToUInt32(lastState, 0x9C);
        if (so != oldSo) Line(so != 0 ? "Scripted scene: camera path 0x" + BitConverter.ToUInt32(s, 0xE4).ToString("X8") + " playing with no cinematic running (skippable)" : "Scripted scene over");
        float att = BitConverter.ToSingle(s, 0xEC), oldAtt = BitConverter.ToSingle(lastState, 0xEC);
        if (att > 0 && oldAtt <= 0) Line("Sound effects fading out (music keeps playing)");
        if (att >= 1 && oldAtt < 1) Line("Sound effects silent");
        if (att < 1 && oldAtt >= 1) Line("Sound effects fading back in");
        if (att <= 0 && oldAtt > 0) Line("Sound effects at full volume again");
        int cam = BitConverter.ToInt32(s, 0xE0), oldCam = BitConverter.ToInt32(lastState, 0xE0);
        uint path = BitConverter.ToUInt32(s, 0xE4), oldPath = BitConverter.ToUInt32(lastState, 0xE4);
        if (cam != oldCam || path != oldPath)
            Line(string.Format("Camera mode {0} (was {1}), path 0x{2:X8}", CamModeName(cam), CamModeName(oldCam), path));
        uint cineCam = BitConverter.ToUInt32(s, 0xE8), oldCineCam = BitConverter.ToUInt32(lastState, 0xE8);
        if (cineCam != oldCineCam) Line(string.Format("Camera path 0x{0:X8} played during a cinematic (not a scripted scene)", cineCam));
        uint chap = BitConverter.ToUInt32(s, 0x78), oldChap = BitConverter.ToUInt32(lastState, 0x78);
        if (chap != oldChap)
            Line(chap != 0 ? string.Format("Chapter region {0} loaded while cinematic 0x{1:X8} ran (noted only; chapter scenes are found by name)", KeyName(s), chap)
                           : "Chapter cinematic cleared (another file loaded)");
        uint chains = BitConverter.ToUInt32(s, 0x8C), oldChains = BitConverter.ToUInt32(lastState, 0x8C);
        if (chains != oldChains)
            { uint nx = BitConverter.ToUInt32(s, 0x00) != 0 ? BitConverter.ToUInt32(s, 0x00) : BitConverter.ToUInt32(s, 0x0C);
              Line(nx == 1 ? string.Format("Skip continued into the scripted camera scene ({0} so far)", chains)
                           : string.Format("Skip continued into the next cinematic 0x{0:X8} ({1} so far)", nx, chains)); }
        uint req = BitConverter.ToUInt32(s, 0x6C), oldReq = BitConverter.ToUInt32(lastState, 0x6C);
        if (req == 0 && oldReq != 0 && phase == 2) Line("Abort taken by the cinematic.");
        uint hint = BitConverter.ToUInt32(s, 0x2C), oldHint = BitConverter.ToUInt32(lastState, 0x2C);
        if (hint != oldHint)
            Line(hint != 0 ? string.Format("Prompt shown (hint 0x{0:X8}, popup 0x{1:X8})", hint, BitConverter.ToUInt32(s, 0x30)) : "Prompt removed.");
        int dev = BitConverter.ToInt32(s, 0x3C), oldDev = BitConverter.ToInt32(lastState, 0x3C);
        if (dev != oldDev) Line("Input device: " + (dev != 0 ? "pad" : "keyboard"));
        for (int off = 0x54; off <= 0x58; off += 4) {
            uint g = BitConverter.ToUInt32(s, off), og = BitConverter.ToUInt32(lastState, off);
            if (g != og) Line(string.Format("Voice group {0} = 0x{1:X8}", off == 0x54 ? "vo/cinestream" : "vo/scripted", g));
        }
        uint waits = BitConverter.ToUInt32(s, 0x68), oldWaits = BitConverter.ToUInt32(lastState, 0x68);
        if (waits != oldWaits) Line(string.Format("Voice stop waited for a stream read ({0} so far)", waits));
        lastState = s;
        SoundLevels(now, s);
        Watch(now);
    }

    // ---- sound levels: the sfx, vo and music root groups' own volume (what the game and level scripts set) and the slider level
    // the mod applies on top. Logged when they change, at most every half second so a scripted fade gives a few lines. ----
    const uint SoundBase = 0x00AAFEE0;   // SlSfx, SlVo, SlMus, SfxGrp, VoGrp, MusGrp
    string lastSound;
    long lastSoundMs = -1000;

    string SoundText(byte[] s, byte[] snd) {
        uint set = BitConverter.ToUInt32(s, 0xF0);
        string[] names = { "sfx", "vo", "music" };
        var parts = new List<string>();
        for (int i = 0; i < 3; i++) {
            uint grp = BitConverter.ToUInt32(snd, 12 + i * 4);
            byte[] v = grp != 0 ? Read(grp + 0x1C, 4) : null;
            string own = v != null ? BitConverter.ToSingle(v, 0).ToString("F2") : "?";
            string slider = (set & (1u << i)) != 0 ? BitConverter.ToSingle(snd, i * 4).ToString("F2") : "unset";
            parts.Add(string.Format("{0} {1} x slider {2}", names[i], own, slider));
        }
        return string.Join(", ", parts.ToArray());
    }

    void SoundLevels(long now, byte[] s) {
        if (now - lastSoundMs < 500) return;
        byte[] snd = Read(SoundBase, 0x18);
        if (snd == null) return;
        string t = SoundText(s, snd);
        if (t == lastSound) return;
        Line("Sound levels (game's own x slider): " + t);
        lastSound = t; lastSoundMs = now;
    }

    // ---- watch: game globals (.data) that change rarely, to find what a scripted scene switches on ----
    // A 4-byte value is listed when it changes from one small value (0-0xFFFF) to another, or by a single bit, and only for its first
    // WatchMaxChanges changes (anything changing more often is a counter or timer). Nothing is listed within 3 s of a file load.
    const uint WatchBase = 0x008E6000, WatchEnd = 0x00AAF4F8;
    const int WatchMaxChanges = 6, WatchMaxPerPoll = 24, WatchMaxLines = 1500;
    byte[] watchLast, watchCounts;
    long lastWatch, lastLoadMs = -1;
    int watchLines;

    void Watch(long now) {
        if (now - lastWatch < 100 || watchLines >= WatchMaxLines) return;
        lastWatch = now;
        byte[] w = Read(WatchBase, (int)(WatchEnd - WatchBase));
        if (w == null) return;
        if (watchLast == null) { watchLast = w; watchCounts = new byte[w.Length / 4]; return; }
        bool quiet = lastLoadMs < 0 || now - lastLoadMs < 3000;
        var changed = new List<string>();
        int more = 0;
        for (int i = 0; i + 4 <= w.Length; i += 4) {
            uint a = BitConverter.ToUInt32(watchLast, i), b = BitConverter.ToUInt32(w, i);
            if (a == b) continue;
            int k = i / 4;
            if (watchCounts[k] < 255) watchCounts[k]++;
            if (quiet || watchCounts[k] > WatchMaxChanges) continue;
            uint x = a ^ b;
            if (!((a <= 0xFFFF && b <= 0xFFFF) || (x & (x - 1)) == 0)) continue;
            if (changed.Count < WatchMaxPerPoll) changed.Add(string.Format("{0:X8} {1:X}->{2:X}", WatchBase + i, a, b));
            else more++;
        }
        watchLast = w;
        WatchObjects(changed, ref more, quiet);
        if (changed.Count == 0) return;
        Line("Watch: " + string.Join(", ", changed.ToArray()) + (more > 0 ? string.Format(" (+{0} more)", more) : ""));
        if (++watchLines >= WatchMaxLines) Line("Watch: line limit reached, no more watch lines.");
    }

    // The game camera ([[world+0x44]+0x124], vtable 0x83F77C) and the creature it follows (+0x6C, normally Kain): their setup and
    // master pointers are logged on every change, and their first bytes go through the same rare-change filter as the globals.
    const int CamWatchSize = 0x200, CreatureWatchSize = 0x600;
    uint watchCam, watchCreature, lastSetup;
    byte[] camLast, camCounts, crLast, crCounts;

    uint ReadU32(uint a) { byte[] b = Read(a, 4); return b == null ? 0 : BitConverter.ToUInt32(b, 0); }

    uint FindCamera() {
        uint p = ReadU32(0x00A83C84); if (p == 0 || ReadU32(p) != 1) return 0;
        uint world = ReadU32(ReadU32(p + 8)); if (world == 0) return 0;
        uint beh = ReadU32(world + 0x44); if (beh == 0) return 0;
        uint cam = ReadU32(beh + 0x124); if (cam == 0 || ReadU32(cam) != 0x0083F77C) return 0;
        return cam;
    }

    void WatchObjects(List<string> changed, ref int more, bool quiet) {
        uint cam = FindCamera();
        uint creature = cam != 0 ? ReadU32(cam + 0x6C) : 0;
        uint setup = cam != 0 ? ReadU32(cam + 0x84) : 0;
        if (cam != watchCam || creature != watchCreature) {
            Line(string.Format("Camera object 0x{0:X8}, following creature 0x{1:X8}", cam, creature));
            if (cam != watchCam) { camLast = null; }
            if (creature != watchCreature) { crLast = null; }
            watchCam = cam; watchCreature = creature;
        }
        if (setup != lastSetup) { Line(string.Format("Camera setup 0x{0:X8} (was 0x{1:X8})", setup, lastSetup)); lastSetup = setup; }
        if (cam != 0) WatchBlock("cam", cam, CamWatchSize, ref camLast, ref camCounts, changed, ref more, quiet);
        if (creature != 0) WatchBlock("creature", creature, CreatureWatchSize, ref crLast, ref crCounts, changed, ref more, quiet);
    }

    void WatchBlock(string tag, uint addr, int size, ref byte[] last, ref byte[] counts, List<string> changed, ref int more, bool quiet) {
        byte[] w = Read(addr, size);
        if (w == null) return;
        if (last == null) { last = w; counts = new byte[size / 4]; return; }
        for (int i = 0; i + 4 <= size; i += 4) {
            uint a = BitConverter.ToUInt32(last, i), b = BitConverter.ToUInt32(w, i);
            if (a == b) continue;
            if (counts[i / 4] < 255) counts[i / 4]++;
            if (quiet || counts[i / 4] > WatchMaxChanges) continue;
            uint x = a ^ b;
            if (!((a <= 0xFFFF && b <= 0xFFFF) || (x & (x - 1)) == 0)) continue;
            if (changed.Count < WatchMaxPerPoll) changed.Add(string.Format("{0}+0x{1:X} {2:X}->{3:X}", tag, i, a, b));
            else more++;
        }
        last = w;
    }

    void DumpState() {
        if (!modded) return;
        byte[] s = Read(StateBase, StateSize);
        if (s == null) { log.WriteLine("Mod state: unreadable"); return; }
        log.WriteLine("Mod state:");
        for (int i = 0; i < StateNames.Length; i++) {
            string v = StateFloat[i] ? BitConverter.ToSingle(s, i * 4).ToString("F3") : "0x" + BitConverter.ToUInt32(s, i * 4).ToString("X8");
            log.WriteLine(string.Format("  {0,-11} {1}", StateNames[i], v));
        }
        log.WriteLine("  KeyBuf      " + KeyName(s));
        log.WriteLine("  FxAtt       " + BitConverter.ToSingle(s, 0xEC).ToString("F3"));
        byte[] snd = Read(SoundBase, 0x18);
        if (snd != null) log.WriteLine("  Sound       " + SoundText(s, snd));
        log.WriteLine(string.Format("  CamMode     0x{0:X8}\n  CamPath     0x{1:X8}\n  CineCam     0x{2:X8}",
            BitConverter.ToUInt32(s, 0xE0), BitConverter.ToUInt32(s, 0xE4), BitConverter.ToUInt32(s, 0xE8)).Replace("\n", Environment.NewLine));
    }

    // ---- debug output ----
    // The game prints a lot: a banner for every file it loads and some warnings every frame. File loads become one line each;
    // other messages that differ only in their numbers are shown three times, then only counted (totals at the end). The last
    // 60 messages, unfiltered, are kept and written out if the game crashes.
    const int PatternShown = 3;
    readonly Dictionary<string, int> patternCounts = new Dictionary<string, int>();
    readonly Queue<string> recentDebug = new Queue<string>();
    string pendingPrefix;
    static readonly System.Text.RegularExpressions.Regex Numbers =
        new System.Text.RegularExpressions.Regex(@"-?\d+(\.\d+)?");

    void OnDebugString(IntPtr ev) {
        uint addr = (uint)Marshal.ReadInt32(ev, 12);
        bool unicode = Marshal.ReadInt16(ev, 16) != 0;
        int len = Marshal.ReadInt16(ev, 18) & 0xFFFF;
        if (len <= 0) return;
        int bytes = Math.Min(unicode ? len * 2 : len, 4096);
        byte[] b = Read(addr, bytes);
        if (b == null) return;
        string s = (unicode ? Encoding.Unicode.GetString(b) : Encoding.Default.GetString(b)).Trim('\0', '\r', '\n', ' ', '\t');
        if (s.Length == 0) return;

        recentDebug.Enqueue(T() + "  " + s);
        while (recentDebug.Count > 60) recentDebug.Dequeue();

        // loader banner: "***", the file name, "Stream Loader Stats ***", a table header and a rule
        if (s == "***" || s.Contains("Stream Loader Stats") || s.StartsWith("Type ") || s.Trim('-', ' ').Length == 0) return;
        if (s.StartsWith("/gogames/bo2/") && s.EndsWith(".big", StringComparison.OrdinalIgnoreCase)) {
            Line("Loading " + s.Substring(13));
            if (s.IndexOf("/levels/", StringComparison.OrdinalIgnoreCase) >= 0) lastLoadMs = clock.ElapsedMilliseconds;
            return;
        }
        // messages split over two calls ("Unable to load string table in" + file name)
        if (s.EndsWith(" in")) { pendingPrefix = s; return; }
        if (pendingPrefix != null) { s = pendingPrefix + " " + s; pendingPrefix = null; }
        // the mod's own DLL (ring, autosave) prints rarely and every line matters: never fold it
        if (s.StartsWith("bo2skipui: ")) { Line("Game says: " + s); return; }

        string pattern = Numbers.Replace(s, "#");
        int n;
        patternCounts.TryGetValue(pattern, out n);
        patternCounts[pattern] = ++n;
        if (n <= PatternShown) Line("Game says: " + s);
        if (n == PatternShown) Line("  (more messages like this are counted but not shown)");
    }

    void WriteDebugSummary() {
        bool any = false;
        foreach (var kv in patternCounts) {
            if (kv.Value <= PatternShown) continue;
            if (!any) { log.WriteLine(); log.WriteLine("Repeated game messages (numbers shown as #):"); any = true; }
            log.WriteLine(string.Format("  {0,7}x  {1}", kv.Value, kv.Key));
        }
    }

    void WriteRecentDebug() {
        log.WriteLine("  last game messages before the crash:");
        foreach (string m in recentDebug) log.WriteLine("    " + m);
    }

    // ---- exceptions ----
    static string ExceptionName(uint c) {
        switch (c) {
            case 0xC0000005: return "access violation";
            case 0xC000001D: return "illegal instruction";
            case 0xC0000094: return "integer divide by zero";
            case 0xC0000095: return "integer overflow";
            case 0xC00000FD: return "stack overflow";
            case 0xC0000409: return "stack buffer overrun";
            case 0xC0000374: return "heap corruption";
            case 0xC000008C: return "array bounds exceeded";
            case 0xC000008E: return "float divide by zero";
            case 0xC0000090: return "float invalid operation";
            case 0xC0000091: return "float overflow";
            case 0x80000003: return "breakpoint";
            case 0x80000004: return "single step";
            case 0xE06D7363: return "C++ exception";
            case 0x406D1388: return "thread name";
            default: return "exception";
        }
    }

    void OnException(IntPtr ev, int tid, uint code, bool firstChance) {
        uint addr = (uint)Marshal.ReadInt32(ev, 24);
        int nParams = Marshal.ReadInt32(ev, 28);
        uint p0 = nParams > 0 ? (uint)Marshal.ReadInt32(ev, 32) : 0;
        uint p1 = nParams > 1 ? (uint)Marshal.ReadInt32(ev, 36) : 0;
        if (code == 0x406D1388) return;

        string what = string.Format("0x{0:X8} {1} at 0x{2:X8} {3}", code, ExceptionName(code), addr, Where(addr));
        if (code == 0xC0000005)
            what += string.Format(" ({0} 0x{1:X8})", p0 == 0 ? "reading" : p0 == 1 ? "writing" : p0 == 8 ? "executing" : "accessing", p1);

        if (firstChance) {
            exceptionCount++;
            string key = code.ToString("X") + "@" + addr.ToString("X");
            bool fresh = seenExceptions.Add(key);
            if (!fresh || exceptionCount > 500) return;
            Line("First-chance " + what + " (the game may handle this)");
            if (code == 0xC0000005 && detailedFirstChance < 5) { detailedFirstChance++; Details(tid, false); }
            return;
        }

        Crashed = true;
        log.WriteLine();
        Line("CRASH: " + what);
        if (code == 0xC0000005) MemoryInfo(p1);
        Details(tid, true);
        OtherThreads(tid);
        WriteRecentDebug();
        WriteDump();
    }

    void Details(int tid, bool full) {
        IntPtr hThread = Native.OpenThread(0x0002 | 0x0008 | 0x0040, false, tid);
        if (hThread == IntPtr.Zero) { log.WriteLine("  (could not open the thread)"); return; }
        IntPtr ctx = Marshal.AllocHGlobal(0x2CC + 16);
        try {
            for (int i = 0; i < 0x2CC; i += 4) Marshal.WriteInt32(ctx, i, 0);
            Marshal.WriteInt32(ctx, 0, 0x10007);   // CONTEXT_i386 | CONTROL | INTEGER | SEGMENTS
            if (!Native.GetThreadContext(hThread, ctx)) { log.WriteLine("  (could not read registers)"); return; }
            Func<int, uint> R = off => (uint)Marshal.ReadInt32(ctx, off);
            uint eip = R(0xB8), esp = R(0xC4), ebp = R(0xB4);
            log.WriteLine(string.Format("  eax={0:X8} ebx={1:X8} ecx={2:X8} edx={3:X8} esi={4:X8} edi={5:X8}",
                R(0xB0), R(0xA4), R(0xAC), R(0xA8), R(0xA0), R(0x9C)));
            log.WriteLine(string.Format("  eip={0:X8} esp={1:X8} ebp={2:X8} eflags={3:X8}  thread {4}", eip, esp, ebp, R(0xC0), tid));

            byte[] codeBytes = Read(eip - 16, 32);
            if (codeBytes != null) log.WriteLine("  code at eip-16: " + Hex(codeBytes, 0, 16) + " | " + Hex(codeBytes, 16, 16));
            else if ((codeBytes = Read(eip, 16)) != null) log.WriteLine("  code at eip: " + Hex(codeBytes, 0, 16));
            else log.WriteLine("  code at eip: unreadable");

            byte[] stack = null;
            for (int size = full ? 0x800 : 0x100; stack == null && size >= 0x10; size /= 2) stack = Read(esp, size);
            if (stack != null) {
                log.WriteLine("  stack:");
                int rows = Math.Min(stack.Length, full ? 0x100 : 0x40) / 16;
                for (int r = 0; r < rows; r++) {
                    var sb = new StringBuilder(string.Format("    {0:X8}:", esp + r * 16));
                    var notes = new StringBuilder();
                    for (int c = 0; c < 4; c++) {
                        uint v = BitConverter.ToUInt32(stack, r * 16 + c * 4);
                        sb.AppendFormat(" {0:X8}", v);
                        string w = Where(v);
                        if (w.Length > 0) notes.Append("  " + w);
                    }
                    log.WriteLine(sb.ToString() + notes.ToString());
                }
                log.WriteLine("  likely call stack (return addresses found on the stack):");
                int found = 0;
                for (int i = 0; i + 4 <= stack.Length && found < (full ? 40 : 12); i += 4) {
                    uint v = BitConverter.ToUInt32(stack, i);
                    if (ModuleAt(v) == null || !FollowsCall(v)) continue;
                    found++;
                    log.WriteLine(string.Format("    [esp+{0:X3}] 0x{1:X8} {2}", i, v, Where(v)));
                }
            }
            if (full) DumpState();
        } finally {
            Marshal.FreeHGlobal(ctx);
            Native.CloseHandle(hThread);
        }
    }

    // What the memory at the faulting address is now: freed, reserved, or committed without access.
    void MemoryInfo(uint addr) {
        var mbi = new Native.MEMORY_BASIC_INFORMATION();
        if (Native.VirtualQueryEx(hProcess, (IntPtr)unchecked((int)addr), out mbi, Marshal.SizeOf(typeof(Native.MEMORY_BASIC_INFORMATION))) == 0) {
            log.WriteLine("  memory at the address: unknown"); return;
        }
        string state = mbi.State == 0x10000 ? "free (released)" : mbi.State == 0x2000 ? "reserved, not committed" : mbi.State == 0x1000 ? "committed" : "state 0x" + mbi.State.ToString("X");
        log.WriteLine(string.Format("  memory at the address: {0}, protect 0x{1:X}, region 0x{2:X8} size 0x{3:X}, allocation base 0x{4:X8}",
            state, mbi.Protect, (uint)mbi.BaseAddress, (uint)mbi.RegionSize, (uint)mbi.AllocationBase));
    }

    // Every other thread in the game: where it is and the return addresses on its stack.
    void OtherThreads(int crashTid) {
        IntPtr snap = Native.CreateToolhelp32Snapshot(0x4, 0);
        if (snap == (IntPtr)(-1)) return;
        try {
            var te = new Native.THREADENTRY32();
            te.dwSize = Marshal.SizeOf(typeof(Native.THREADENTRY32));
            if (!Native.Thread32First(snap, ref te)) return;
            log.WriteLine("  other threads:");
            do {
                if (te.th32OwnerProcessID != pid || te.th32ThreadID == crashTid) continue;
                IntPtr h = Native.OpenThread(0x0002 | 0x0008 | 0x0040, false, te.th32ThreadID);
                if (h == IntPtr.Zero) continue;
                IntPtr ctx = Marshal.AllocHGlobal(0x2CC + 16);
                try {
                    for (int i = 0; i < 0x2CC; i += 4) Marshal.WriteInt32(ctx, i, 0);
                    Marshal.WriteInt32(ctx, 0, 0x10007);
                    if (!Native.GetThreadContext(h, ctx)) continue;
                    uint eip = (uint)Marshal.ReadInt32(ctx, 0xB8), esp = (uint)Marshal.ReadInt32(ctx, 0xC4);
                    log.WriteLine(string.Format("    thread {0}: eip=0x{1:X8} {2}", te.th32ThreadID, eip, Where(eip)));
                    byte[] stack = null;
                    for (int size = 0x1000; stack == null && size >= 0x10; size /= 2) stack = Read(esp, size);
                    if (stack == null) continue;
                    int found = 0;
                    for (int i = 0; i + 4 <= stack.Length && found < 16; i += 4) {
                        uint v = BitConverter.ToUInt32(stack, i);
                        if (ModuleAt(v) == null || !FollowsCall(v)) continue;
                        found++;
                        log.WriteLine(string.Format("      [esp+{0:X3}] 0x{1:X8} {2}", i, v, Where(v)));
                    }
                } finally {
                    Marshal.FreeHGlobal(ctx);
                    Native.CloseHandle(h);
                }
            } while (Native.Thread32Next(snap, ref te));
        } finally { Native.CloseHandle(snap); }
    }

    bool FollowsCall(uint ret) {
        byte[] b = Read(ret - 7, 7);
        if (b == null) return false;
        if (b[2] == 0xE8) return true;                                  // call rel32
        if (b[1] == 0xFF && (b[2] & 0x38) == 0x10) return true;         // call [mem32] / call [reg+disp32]
        if (b[4] == 0xFF && (b[5] & 0x38) == 0x10) return true;         // call [reg+disp8]
        if (b[5] == 0xFF && (b[6] & 0x38) == 0x10) return true;         // call reg / call [reg]
        return false;
    }

    static string Hex(byte[] b, int start, int count) {
        var sb = new StringBuilder();
        for (int i = start; i < start + count && i < b.Length; i++) { if (i > start) sb.Append(' '); sb.Append(b[i].ToString("X2")); }
        return sb.ToString();
    }

    void WriteDump() {
        try {
            string path = Path.Combine(logDir, "bo2-crash-" + stamp + ".dmp");
            using (var fs = new FileStream(path, FileMode.Create, FileAccess.ReadWrite)) {
                // MiniDumpNormal | MiniDumpWithIndirectlyReferencedMemory: threads, stacks and the memory they point at
                if (Native.MiniDumpWriteDump(hProcess, pid, fs.SafeFileHandle, 0x40,IntPtr.Zero, IntPtr.Zero, IntPtr.Zero)) {
                    DumpPath = path;
                    log.WriteLine("  minidump: " + Path.GetFileName(path));
                } else {
                    log.WriteLine("  minidump failed: error " + Marshal.GetLastWin32Error());
                }
            }
            if (DumpPath == null) File.Delete(path);
        } catch (Exception ex) { log.WriteLine("  minidump failed: " + ex.Message); }
    }
}

static class Native {
    public const uint DEBUG_ONLY_THIS_PROCESS = 0x2;
    public const uint DBG_CONTINUE = 0x00010002;
    public const uint DBG_EXCEPTION_NOT_HANDLED = 0x80010001;

    [StructLayout(LayoutKind.Sequential)]
    public struct STARTUPINFO {
        public int cb; public IntPtr lpReserved, lpDesktop, lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CreateProcess(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags,
        IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool WaitForDebugEvent(IntPtr ev, uint ms);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool ContinueDebugEvent(int pid, int tid, uint status);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool DebugSetProcessKillOnExit(bool kill);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, int size, out IntPtr read);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr OpenThread(uint access, bool inherit, int tid);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetThreadContext(IntPtr h, IntPtr ctx);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "GetFinalPathNameByHandleW")]
    public static extern int GetFinalPathNameByHandle(IntPtr h, StringBuilder sb, int len, int flags);
    [StructLayout(LayoutKind.Sequential)]
    public struct MEMORY_BASIC_INFORMATION {
        public IntPtr BaseAddress, AllocationBase; public uint AllocationProtect; public IntPtr RegionSize; public uint State, Protect, Type;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct THREADENTRY32 {
        public int dwSize, cntUsage, th32ThreadID, th32OwnerProcessID, tpBasePri, tpDeltaPri, dwFlags;
    }
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern int VirtualQueryEx(IntPtr h, IntPtr addr, out MEMORY_BASIC_INFORMATION mbi, int len);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr CreateToolhelp32Snapshot(uint flags, int pid);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool Thread32First(IntPtr snap, ref THREADENTRY32 te);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool Thread32Next(IntPtr snap, ref THREADENTRY32 te);
    [DllImport("dbghelp.dll", SetLastError = true)]
    public static extern bool MiniDumpWriteDump(IntPtr hProcess, int pid, Microsoft.Win32.SafeHandles.SafeFileHandle hFile, int type,
        IntPtr exceptionParam, IntPtr userStream, IntPtr callback);
}
#endif
