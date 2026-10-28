// Kaiserreich Collection - picture-tile launcher for every old Kaiserreich on its matching HOI4 version.
// A separate program from the Classic HOI4 Collection (own files, own folder, own shortcut).
// 16 version tiles (3 rows) + a Player-Led Peace toggle tile; DLC picker per version; Play / Install / Clear cache.
// Everything (engine script, version table, 7-Zip, peace-mod builds, images) is embedded and unpacked to
// %LOCALAPPDATA%\KaiserreichCollection; the Desktop shortcut points there.
//
// Test hooks: /screenshot:<file>   /autoplay:<branch>   /autoinstall:<branch>   /nolaunch   /dlcdump:<file>
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Reflection;
using System.Text.RegularExpressions;
using System.Windows.Forms;

class Ver { public string Branch, Game, Codename, Kr, Update, Plpc; public string[] Dlc; }
// custom game: a ready-made game-rule preset (scenarios.txt: id|title|preset|picture|branches|about)
class Scn { public string Id, Title, Preset, Picture, About, SavePrefix = ""; public HashSet<string> Branches, SaveOnly, WithSave; public Tile Tile; public Image Bg; }

class Tile : Control
{
    public Image Picture; public string Title, Sub, ToggleWord = "add-on"; public bool Selected, IsToggle, On, Unavailable;
    static readonly Color Gold = Color.FromArgb(212, 175, 55), Green = Color.FromArgb(90, 200, 110), Dim = Color.FromArgb(70, 70, 70);
    public Tile() { DoubleBuffered = true; Cursor = Cursors.Hand; Size = new Size(140, 140); }
    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics; g.InterpolationMode = InterpolationMode.HighQualityBicubic; g.SmoothingMode = SmoothingMode.AntiAlias;
        var r = ClientRectangle;
        if (Picture != null) g.DrawImage(Picture, r); else g.FillRectangle(Brushes.Black, r);
        bool lit = IsToggle ? (On && !Unavailable) : Selected;
        if (!lit) using (var dimmer = new SolidBrush(Color.FromArgb(IsToggle ? 140 : 80, 0, 0, 0))) g.FillRectangle(dimmer, r);
        using (var strip = new SolidBrush(Color.FromArgb(185, 0, 0, 0))) g.FillRectangle(strip, 0, r.Height - 38, r.Width, 38);
        // shrink the title until it fits the tile width (long codenames like "Stella Polaris")
        float size = 9.5f; Font f1 = new Font("Segoe UI", size, FontStyle.Bold);
        while (size > 6.5f && g.MeasureString(Title, f1).Width > r.Width - 4) { f1.Dispose(); size -= 0.5f; f1 = new Font("Segoe UI", size, FontStyle.Bold); }
        using (f1) using (var f2 = new Font("Segoe UI", 8))
        using (var sf = new StringFormat { Alignment = StringAlignment.Center }) {
            g.DrawString(Title, f1, Brushes.White, new RectangleF(0, r.Height - 37, r.Width, 18), sf);
            string sub = IsToggle ? (Unavailable ? "not for this version" : On ? ToggleWord + ": ON" : ToggleWord + ": off") : Sub;
            using (var b2 = new SolidBrush(Color.FromArgb(210, 210, 210))) g.DrawString(sub, f2, b2, new RectangleF(0, r.Height - 19, r.Width, 16), sf);
        }
        Color bc = lit ? (IsToggle ? Green : Gold) : Dim; int bw = lit ? 4 : 1;
        using (var pen = new Pen(bc, bw)) g.DrawRectangle(pen, bw / 2, bw / 2, r.Width - bw, r.Height - bw);
    }
}

class CollectionForm : Form
{
    List<Ver> versions = new List<Ver>();
    List<Tile> verTiles = new List<Tile>();
    Tile tPlpc;
    List<Scn> scns = new List<Scn>();
    Image defaultBg;
    Ver sel;
    Button playBtn, installBtn, installAllBtn, cacheBtn, dlcBtn, uninstallBtn;
    Label dlcLabel, status;
    CheckBox cbNoDlc, cbWasd;
    TextBox log;
    bool syncingDlc, auto;
    // per version: null = every allowed DLC on, empty = all off, else the chosen set
    Dictionary<string, HashSet<string>> dlcChoice = new Dictionary<string, HashSet<string>>();
    Dictionary<string, HashSet<string>> dlcBeforeNone = new Dictionary<string, HashSet<string>>();
    Process proc;
    string homeDir, exePath;
    static string[] args;

    [STAThread]
    static void Main(string[] a) { args = a; if (a.Length > 0 && a[0].Equals("/wasd", StringComparison.OrdinalIgnoreCase)) { Wasd.Run(); return; } Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false); Application.Run(new CollectionForm()); }

    static Stream ResStream(string name) { return Assembly.GetExecutingAssembly().GetManifestResourceStream(name); }
    static Image Res(string name) { var s = ResStream(name); return s == null ? null : Image.FromStream(s); }

    CollectionForm()
    {
        Text = "Kaiserreich Collection";
        ClientSize = new Size(1180, 780);   // grows by a tile row below when the versions need a third row
        StartPosition = FormStartPosition.CenterScreen; FormBorderStyle = FormBorderStyle.FixedSingle; MaximizeBox = false;
        DoubleBuffered = true; BackColor = Color.FromArgb(16, 16, 20);
        BackgroundImage = defaultBg = Res("img/bg.jpg"); BackgroundImageLayout = ImageLayout.Stretch;
        try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
        LoadVersions(); LoadScenarios();

        var banner = new PictureBox { Image = Res("img/banner.png"), SizeMode = PictureBoxSizeMode.AutoSize, BackColor = Color.Transparent, Left = 40, Top = 10 };
        Controls.Add(banner);
        uninstallBtn = new Button { Text = "Uninstall", Left = 1040, Top = 22, Width = 100, Height = 30, BackColor = Color.FromArgb(90, 30, 30), ForeColor = Color.FromArgb(235, 220, 220),
            FlatStyle = FlatStyle.Flat, Font = new Font("Segoe UI", 9.5f, FontStyle.Bold), Cursor = Cursors.Hand };
        uninstallBtn.FlatAppearance.BorderSize = 0;
        uninstallBtn.Click += (s, e) => ConfirmUninstall();
        Controls.Add(uninstallBtn); uninstallBtn.BringToFront();

        int x0 = 40, y0 = 104, tw = 140, gap = 12, perRow = 7;
        int rows = (versions.Count + 1 + scns.Count + perRow - 1) / perRow;   // version tiles + the peace tile + custom games
        ClientSize = new Size(1180, 780 + Math.Max(0, rows - 2) * (tw + 14));
        for (int i = 0; i < versions.Count; i++) {
            var v = versions[i];
            var t = new Tile { Picture = Res("img/kr_" + Regex.Replace(v.Branch, @"[^\w.]", "_") + ".jpg"), Title = "HOI4 " + v.Game + " " + v.Codename,
                Left = x0 + (i % perRow) * (tw + gap), Top = y0 + (i / perRow) * (tw + 14), Tag = v };
            t.Click += (s, e) => Select((Ver)((Tile)s).Tag);
            verTiles.Add(t); Controls.Add(t);
        }
        int pi = versions.Count;
        tPlpc = new Tile { Picture = Res("img/plpc.jpg"), Title = "Player-Led Peace", IsToggle = true, On = true,
            Left = x0 + (pi % perRow) * (tw + gap), Top = y0 + (pi / perRow) * (tw + 14) };
        tPlpc.Click += (s, e) => { if (!tPlpc.Unavailable) { tPlpc.On = !tPlpc.On; tPlpc.Invalidate(); } };
        Controls.Add(tPlpc);
        var tips = new ToolTip { AutoPopDelay = 20000, InitialDelay = 300 };
        for (int k = 0; k < scns.Count; k++) {
            var sc = scns[k]; int si = versions.Count + 1 + k;
            sc.Tile = new Tile { Picture = Res(sc.Picture), Title = sc.Title, IsToggle = true, On = false, ToggleWord = "custom game", Tag = sc,
                Left = x0 + (si % perRow) * (tw + gap), Top = y0 + (si / perRow) * (tw + 14) };
            sc.Bg = Res("img/scnbg_" + sc.Id + ".jpg");
            sc.Tile.Click += (s, e) => { var t = (Tile)s; if (!t.Unavailable) { t.On = !t.On; t.Invalidate(); UpdateScenarioHint(); UpdateBackground(); } };
            tips.SetToolTip(sc.Tile, sc.About + "\nIn the game: Custom Game Rules > Load Preset > \"" + sc.Preset + "\"" +
                (sc.SaveOnly.Count > 0 ? "\n(Kaiserreich versions without the game rule: Load Game > the ready save.)" : ""));
            Controls.Add(sc.Tile);
        }

        int yHint = y0 + rows * (tw + 14) - 10;
        Controls.Add(new Label { Text = "pick a Kaiserreich - each one runs on its own Hearts of Iron IV version", ForeColor = Color.FromArgb(170, 170, 170), BackColor = Color.Transparent, AutoSize = true, Left = x0, Top = yHint, Font = new Font("Segoe UI", 9) });
        Controls.Add(new Label { Text = "peace add-on: 1.10, 1.11, 1.19 only", ForeColor = Color.FromArgb(170, 170, 170), BackColor = Color.Transparent, AutoSize = true, Left = Math.Max(tPlpc.Left, x0 + 560), Top = yHint, Font = new Font("Segoe UI", 9) });

        int yDlc = yHint + 24;
        dlcBtn = MakeButton("Choose DLC...", x0, yDlc, 140, Color.FromArgb(50, 54, 62), Color.FromArgb(220, 220, 220)); dlcBtn.Height = 30; dlcBtn.Font = new Font("Segoe UI", 10);
        cbNoDlc = new CheckBox { Text = "No DLC", ForeColor = Color.White, BackColor = Color.Transparent, AutoSize = true, Left = x0 + 152, Top = yDlc + 6, Font = new Font("Segoe UI", 10, FontStyle.Bold) };
        dlcLabel = new Label { ForeColor = Color.FromArgb(210, 210, 210), BackColor = Color.Transparent, AutoSize = true, Left = x0 + 240, Top = yDlc + 7, Font = new Font("Segoe UI", 9.5f) };
        dlcBtn.Click += (s, e) => ChooseDlc();
        cbNoDlc.CheckedChanged += (s, e) => {
            if (syncingDlc || sel == null) return;
            if (cbNoDlc.Checked) { dlcBeforeNone[sel.Branch] = Choice(sel); dlcChoice[sel.Branch] = new HashSet<string>(); }
            else { HashSet<string> prev; dlcBeforeNone.TryGetValue(sel.Branch, out prev); dlcChoice[sel.Branch] = (prev == null || prev.Count == 0) ? null : prev; dlcBeforeNone.Remove(sel.Branch); }
            UpdateDlcLabel();
        };
        cbWasd = new CheckBox { Text = "WASD map movement (F11 = off/on)", Checked = true, ForeColor = Color.White, BackColor = Color.Transparent, AutoSize = true, Left = x0 + 640, Top = yDlc + 6, Font = new Font("Segoe UI", 10) };
        Controls.AddRange(new Control[] { dlcBtn, cbNoDlc, dlcLabel, cbWasd });

        int yBtn = yDlc + 44;
        playBtn = MakeButton("PLAY", x0, yBtn, 200, Color.FromArgb(212, 175, 55), Color.Black);
        installBtn = MakeButton("Install this version", x0 + 212, yBtn, 210, Color.FromArgb(70, 74, 82), Color.White); installBtn.Font = new Font("Segoe UI", 12, FontStyle.Bold);
        installAllBtn = MakeButton("Install all", x0 + 434, yBtn, 150, Color.FromArgb(58, 62, 70), Color.White); installAllBtn.Font = new Font("Segoe UI", 12, FontStyle.Bold);
        cacheBtn = MakeButton("Clear cache", x0 + 596, yBtn, 140, Color.FromArgb(50, 54, 62), Color.FromArgb(220, 220, 220)); cacheBtn.Font = new Font("Segoe UI", 10.5f);
        status = new Label { Left = x0 + 752, Top = yBtn - 2, Width = 340, Height = 58, ForeColor = Color.FromArgb(200, 200, 200), BackColor = Color.Transparent, Font = new Font("Segoe UI", 9.5f),
            Text = "First time on a version: Steam downloads that game version once and it is copied to its own folder. After that it starts instantly." };
        log = new TextBox { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Left = x0, Top = yBtn + 66, Width = 1100, Height = ClientSize.Height - (yBtn + 66) - 14,
            Font = new Font("Consolas", 9.5f), BackColor = Color.FromArgb(20, 22, 26), ForeColor = Color.FromArgb(180, 220, 180), BorderStyle = BorderStyle.None };
        Controls.AddRange(new Control[] { playBtn, installBtn, installAllBtn, cacheBtn, status, log });

        playBtn.Click += (s, e) => Run("play");
        installBtn.Click += (s, e) => Run("install");
        installAllBtn.Click += (s, e) => {
            if (MessageBox.Show("Install all " + versions.Count + " versions? Steam downloads every old Hearts of Iron IV version once (roughly 100 GB of game copies in total) plus each Kaiserreich. This can take hours.",
                "Install all", MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes) Run("installall");
        };
        cacheBtn.Click += (s, e) => Run("cache");
        FormClosing += (s, e) => { if (proc != null && !proc.HasExited && MessageBox.Show("Still working. Quit anyway?", "Kaiserreich Collection", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) e.Cancel = true; };

        Select(versions.Count > 0 ? versions[versions.Count - 1] : null);
        Shown += (s, e) => {
            LoadLastChoice(); RefreshReady();
            ImportSavePacks();
            FirstStartSetup();
            foreach (var a in args) {
                if (a.Equals("/uninstall", StringComparison.OrdinalIgnoreCase)) { ConfirmUninstall(); }   // from Windows Settings > Apps
                else if (a.StartsWith("/autoplay:", StringComparison.OrdinalIgnoreCase) || a.StartsWith("/autoinstall:", StringComparison.OrdinalIgnoreCase)) {
                    auto = true; string b = a.Substring(a.IndexOf(':') + 1); var v = versions.Find(x => x.Branch == b); if (v != null) Select(v);
                    Run(a.StartsWith("/autoplay:", StringComparison.OrdinalIgnoreCase) ? "play" : "install");
                }
                else if (a.StartsWith("/dlcdump:", StringComparison.OrdinalIgnoreCase)) {
                    var lines = new List<string>();
                    foreach (var v in versions) { Select(v); lines.Add(v.Branch + " -> " + CompatDlc(v).Count + " DLC listed; label: " + dlcLabel.Text); }
                    try { File.WriteAllLines(a.Substring(9), lines.ToArray()); } catch { }
                    Close();
                }
                else if (a.StartsWith("/screenshot:", StringComparison.OrdinalIgnoreCase)) {
                    using (var bmp = new Bitmap(Width, Height)) { DrawToBitmap(bmp, new Rectangle(0, 0, Width, Height)); bmp.Save(a.Substring(12)); }
                    Close();
                }
            }
        };
    }

    void ConfirmUninstall()
    {
        if (MessageBox.Show(this,
            "This removes the whole Kaiserreich Collection:\n\n" +
            "  -  every stored Hearts of Iron IV version copy and Kaiserreich download (in " + StoreDir() + ")\n" +
            "  -  its mod files in the game's mod folder\n" +
            "  -  the launcher itself, its Desktop shortcut and its Windows Apps entry\n\n" +
            "Your saves, Steam, your normal Hearts of Iron IV and any other mods are NOT touched.\n\nUninstall now?",
            "Uninstall Kaiserreich Collection", MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) != DialogResult.Yes) return;
        Run("uninstall");
    }

    void LoadScenarios()
    {
        using (var s = ResStream("scenarios.txt")) {
            if (s == null) return;
            using (var r = new StreamReader(s)) {
                string line;
                while ((line = r.ReadLine()) != null) {
                    var p = line.Split('|'); if (p.Length < 6) continue;
                    var comma = new[] { ',' };
                    scns.Add(new Scn { Id = p[0], Title = p[1], Preset = p[2], Picture = p[3], About = p[5], Branches = new HashSet<string>(p[4].Split(comma, StringSplitOptions.RemoveEmptyEntries)),
                        // optional: versions that only have a ready save (no game rule), the save name prefix, versions with a save
                        SaveOnly = new HashSet<string>(p.Length > 6 ? p[6].Split(comma, StringSplitOptions.RemoveEmptyEntries) : new string[0]),
                        SavePrefix = p.Length > 7 ? p[7] : "",
                        WithSave = new HashSet<string>(p.Length > 8 ? p[8].Split(comma, StringSplitOptions.RemoveEmptyEntries) : new string[0]) });
                }
            }
        }
    }
    string ScenarioArgs()
    {
        var on = new List<string>(); if (sel == null) return "";
        foreach (var sc in scns) if (sc.Tile.On && sc.Branches.Contains(sel.Branch)) on.Add(sc.Id);
        return on.Count == 0 ? "" : " -Scenario " + string.Join(",", on.ToArray());
    }
    // while a custom game is on (and exists for the picked version) its own picture is the window background
    void UpdateBackground()
    {
        Image want = defaultBg;
        if (sel != null) foreach (var sc in scns) if (sc.Tile != null && sc.Tile.On && sc.Bg != null && sc.Branches.Contains(sel.Branch)) { want = sc.Bg; break; }
        if (BackgroundImage != want) { BackgroundImage = want; Invalidate(true); }
    }
    void UpdateScenarioHint()
    {
        if (status == null || sel == null) return;
        foreach (var sc in scns) if (sc.Tile.On && sc.Branches.Contains(sel.Branch)) {
            string save = sc.SavePrefix.Length > 0 && sc.WithSave.Contains(sel.Branch) ? sc.SavePrefix + sel.Kr : null;
            if (sc.SaveOnly.Contains(sel.Branch) && save != null)
                status.Text = "Custom game \"" + sc.Title + "\" is on. This Kaiserreich has no game rule for it - in the game: Load Game > \"" + save + "\".";
            else
                status.Text = "Custom game \"" + sc.Title + "\" is on. In the game: Custom Game Rules > Load Preset > \"" + sc.Preset + "\"" + (save != null ? ", or Load Game > \"" + save + "\"" : "") + ".";
            return;
        }
    }

    void LoadVersions()
    {
        using (var s = ResStream("versions.txt")) using (var r = new StreamReader(s)) {
            string line;
            while ((line = r.ReadLine()) != null) {
                var p = line.Split('|'); if (p.Length < 7) continue;
                versions.Add(new Ver { Branch = p[0], Game = p[1], Codename = p[2], Kr = p[3], Update = p[4], Plpc = p[5], Dlc = p[6].Length > 0 ? p[6].Split(',') : new string[0] });
            }
        }
    }

    Button MakeButton(string text, int x, int y, int w, Color back, Color fore)
    {
        var b = new Button { Text = text, Left = x, Top = y, Width = w, Height = 52, BackColor = back, ForeColor = fore, FlatStyle = FlatStyle.Flat, Font = new Font("Segoe UI", 14, FontStyle.Bold), Cursor = Cursors.Hand };
        b.FlatAppearance.BorderSize = 0; return b;
    }

    // ---- paths ----
    // The launcher lives in <store>\app next to its game copies - deliberately NOT in AppData, because
    // sandboxed installers can have AppData silently redirected, which would break the Desktop shortcut.
    static string DefaultStore()
    {
        try {
            var d = new DriveInfo("D");
            if (Directory.Exists(@"D:\KaiserreichCollection") || (d.IsReady && d.DriveType == DriveType.Fixed && d.AvailableFreeSpace > 150L * 1024 * 1024 * 1024)) return @"D:\KaiserreichCollection";
        } catch { }
        DriveInfo best = null;
        foreach (var di in DriveInfo.GetDrives()) if (di.IsReady && di.DriveType == DriveType.Fixed && (best == null || di.AvailableFreeSpace > best.AvailableFreeSpace)) best = di;
        return Path.Combine(best != null ? best.RootDirectory.FullName : @"C:\", "KaiserreichCollection");
    }
    string HomeDir()
    {
        if (homeDir == null) {
            string exeDir = Path.GetDirectoryName(Application.ExecutablePath);
            homeDir = (Path.GetFileName(exeDir).Equals("app", StringComparison.OrdinalIgnoreCase) && File.Exists(Path.Combine(exeDir, "Kaiserreich-Collection.ps1")))
                      ? exeDir : Path.Combine(DefaultStore(), "app");
            Directory.CreateDirectory(homeDir);
        }
        return homeDir;
    }
    string StoreDir() { try { string f = Path.Combine(HomeDir(), "store.txt"); if (File.Exists(f)) return File.ReadAllText(f).Trim(); } catch { } return Path.GetDirectoryName(HomeDir()); }
    bool IsReady(Ver v) { string st = StoreDir(); return File.Exists(Path.Combine(st, "games", v.Branch, "krc_build.txt")) && File.Exists(Path.Combine(st, "mods", "Kaiserreich_" + v.Kr, "descriptor.mod")); }
    void RefreshReady() { foreach (var t in verTiles) { var v = (Ver)t.Tag; t.Sub = IsReady(v) ? "ready" : "not installed"; t.Invalidate(); } }

    // ---- selection ----
    void Select(Ver v)
    {
        sel = v;
        foreach (var t in verTiles) { t.Selected = t.Tag == v; t.Invalidate(); }
        tPlpc.Unavailable = v == null || string.IsNullOrEmpty(v.Plpc); tPlpc.Invalidate();
        foreach (var sc in scns) { if (sc.Tile == null) continue; sc.Tile.Unavailable = v == null || !sc.Branches.Contains(v.Branch); sc.Tile.Invalidate(); }
        UpdateBackground();
        UpdateDlcLabel();
    }

    // ---- DLC ----
    // DLC allowed for this version (from Steam's data, capped at the version's own DLC) that are actually installed.
    List<string[]> CompatDlc(Ver v)
    {
        var list = new List<string[]>(); if (v == null) return list;
        string dir = Path.Combine(StoreDir(), "games", v.Branch, "dlc");
        if (!Directory.Exists(dir)) dir = SteamDlcDir();
        var allowed = new HashSet<string>(v.Dlc);
        if (dir == null || !Directory.Exists(dir)) return list;
        foreach (var d in Directory.GetDirectories(dir)) {
            string folder = Path.GetFileName(d); if (!allowed.Contains(folder)) continue;
            var f = Directory.GetFiles(d, "*.dlc"); if (f.Length == 0) continue;
            string name = folder;
            try { var m = Regex.Match(File.ReadAllText(f[0]), "(?m)^\\s*name\\s*=\\s*\"([^\"]+)\""); if (m.Success) name = m.Groups[1].Value; } catch { }
            list.Add(new[] { folder, name });
        }
        list.Sort((a, b) => string.Compare(a[1], b[1], StringComparison.OrdinalIgnoreCase));
        return list;
    }
    static string SteamDlcDir()
    {
        try {
            string steam = null;
            using (var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Valve\Steam")) if (k != null) steam = k.GetValue("SteamPath") as string;
            if (steam == null) steam = @"C:\Program Files (x86)\Steam";
            steam = steam.Replace('/', '\\');
            var libs = new List<string> { steam }; string vdf = Path.Combine(steam, @"steamapps\libraryfolders.vdf");
            if (File.Exists(vdf)) foreach (Match m in Regex.Matches(File.ReadAllText(vdf), "\"path\"\\s+\"([^\"]+)\"")) libs.Add(m.Groups[1].Value.Replace("\\\\", "\\"));
            foreach (var lib in libs) {
                string acf = Path.Combine(lib, @"steamapps\appmanifest_394360.acf"); if (!File.Exists(acf)) continue;
                var im = Regex.Match(File.ReadAllText(acf), "\"installdir\"\\s+\"([^\"]+)\"");
                string dlc = Path.Combine(lib, @"steamapps\common", im.Success ? im.Groups[1].Value : "Hearts of Iron IV", "dlc");
                if (Directory.Exists(dlc)) return dlc;
            }
        } catch { }
        return null;
    }
    HashSet<string> Choice(Ver v) { HashSet<string> c; return v != null && dlcChoice.TryGetValue(v.Branch, out c) ? c : null; }

    void ChooseDlc()
    {
        if (sel == null) return;
        var dlc = CompatDlc(sel);
        if (dlc.Count == 0) { MessageBox.Show("No DLC for this version is installed on this PC.", "Choose DLC"); return; }
        var cur = Choice(sel);
        using (var dlg = new Form { Text = "Choose DLC - HOI4 " + sel.Game, ClientSize = new Size(440, 460), StartPosition = FormStartPosition.CenterParent, FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false, MinimizeBox = false, Font = new Font("Segoe UI", 9.5f) }) {
            var info = new Label { Text = "Ticked DLC stay ON for Kaiserreich " + sel.Kr + ". For multiplayer, everyone must tick the SAME DLC (or all off).\nOnly DLC that work on HOI4 " + sel.Game + " and are installed are listed.", Left = 12, Top = 10, Width = 416, Height = 48 };
            var clb = new CheckedListBox { Left = 12, Top = 62, Width = 416, Height = 312, CheckOnClick = true, IntegralHeight = false };
            foreach (var d in dlc) clb.Items.Add(d[1], cur == null || cur.Contains(d[0]));
            var allOn = new Button { Text = "All on", Left = 12, Top = 382, Width = 90, Height = 30 };
            var allOff = new Button { Text = "All off", Left = 108, Top = 382, Width = 90, Height = 30 };
            allOn.Click += (s, e) => { for (int i = 0; i < clb.Items.Count; i++) clb.SetItemChecked(i, true); };
            allOff.Click += (s, e) => { for (int i = 0; i < clb.Items.Count; i++) clb.SetItemChecked(i, false); };
            var ok = new Button { Text = "OK", Left = 256, Top = 420, Width = 80, Height = 30, DialogResult = DialogResult.OK };
            var cancel = new Button { Text = "Cancel", Left = 344, Top = 420, Width = 84, Height = 30, DialogResult = DialogResult.Cancel };
            dlg.Controls.AddRange(new Control[] { info, clb, allOn, allOff, ok, cancel }); dlg.AcceptButton = ok; dlg.CancelButton = cancel;
            if (dlg.ShowDialog(this) != DialogResult.OK) return;
            var set = new HashSet<string>(); for (int i = 0; i < clb.Items.Count; i++) if (clb.GetItemChecked(i)) set.Add(dlc[i][0]);
            dlcChoice[sel.Branch] = set.Count == dlc.Count ? null : set; dlcBeforeNone.Remove(sel.Branch);
            UpdateDlcLabel();
        }
    }
    void UpdateDlcLabel()
    {
        if (dlcLabel == null || sel == null) return;
        int total = CompatDlc(sel).Count; var c = Choice(sel);
        dlcLabel.Text = c == null ? "DLC: all " + total + " that fit HOI4 " + sel.Game + " on" : c.Count == 0 ? "DLC: none  (multiplayer-safe)" : "DLC: " + c.Count + " of " + total + " on";
        syncingDlc = true; cbNoDlc.Checked = c != null && c.Count == 0; syncingDlc = false;
    }
    string DlcArgs()
    {
        var c = Choice(sel); if (c == null) return "";
        if (c.Count == 0) return " -AllDlcOff";
        return " -DlcList -EnableDlc \"" + string.Join(",", new List<string>(c).ToArray()) + "\"";
    }

    // ---- remembered choices (own file, nothing shared with other launchers) ----
    void LoadLastChoice()
    {
        try {
            string f = Path.Combine(HomeDir(), "last.txt"); if (!File.Exists(f)) return;
            foreach (var line in File.ReadAllLines(f)) {
                int eq = line.IndexOf('='); if (eq < 0) continue; string k = line.Substring(0, eq), val = line.Substring(eq + 1);
                if (k == "sel") { var v = versions.Find(x => x.Branch == val); if (v != null) Select(v); }
                else if (k == "plpc") { tPlpc.On = val == "1"; tPlpc.Invalidate(); }
                else if (k == "scn") { var ids = new List<string>(val.Split(',')); foreach (var sc in scns) { sc.Tile.On = ids.Contains(sc.Id); sc.Tile.Invalidate(); } UpdateBackground(); }
                else if (k == "wasd") { cbWasd.Checked = val != "0"; }
                else if (k.StartsWith("dlc:")) { string b = k.Substring(4); if (val == "*") dlcChoice.Remove(b); else if (val == "-") dlcChoice[b] = new HashSet<string>(); else dlcChoice[b] = new HashSet<string>(val.Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries)); }
            }
            UpdateDlcLabel(); status.Text = "Ready. Pick a Kaiserreich and click PLAY.";
        } catch { }
    }
    void SaveLastChoice()
    {
        var lines = new List<string> { "sel=" + (sel == null ? "" : sel.Branch), "plpc=" + (tPlpc.On ? "1" : "0"), "scn=" + string.Join(",", scns.FindAll(x => x.Tile.On).ConvertAll(x => x.Id).ToArray()), "wasd=" + (cbWasd.Checked ? "1" : "0") };
        foreach (var kv in dlcChoice) lines.Add("dlc:" + kv.Key + "=" + (kv.Value == null ? "*" : kv.Value.Count == 0 ? "-" : string.Join(";", new List<string>(kv.Value).ToArray())));
        try { File.WriteAllLines(Path.Combine(HomeDir(), "last.txt"), lines.ToArray()); } catch { }
    }

    static bool SameBytes(byte[] a, byte[] b) { if (a.Length != b.Length) return false; for (int i = 0; i < a.Length; i++) if (a[i] != b[i]) return false; return true; }

    // ---- unpack embedded files + keep a copy of this exe in the home folder (the shortcut points there) ----
    void Deploy()
    {
        string dir = HomeDir(); var asm = Assembly.GetExecutingAssembly();
        foreach (var name in asm.GetManifestResourceNames()) {
            if (name.StartsWith("img/")) continue;
            string path = Path.Combine(dir, name.Replace('/', '\\')); Directory.CreateDirectory(Path.GetDirectoryName(path));
            byte[] data; using (var s = asm.GetManifestResourceStream(name)) using (var ms = new MemoryStream()) { s.CopyTo(ms); data = ms.ToArray(); }
            // skip files that are already there unchanged - one may be in use by a job that is still running (e.g. 7-Zip)
            try { if (File.Exists(path) && new FileInfo(path).Length == data.Length && SameBytes(File.ReadAllBytes(path), data)) continue; } catch { }
            try { File.WriteAllBytes(path, data); }
            catch (IOException) { if (!File.Exists(path)) throw; Append("Note: " + name + " is in use, kept the copy that is already there."); }   // in use and already present: keep it
        }
        exePath = Path.Combine(dir, "Kaiserreich Collection.exe");
        if (!string.Equals(Path.GetFullPath(Application.ExecutablePath), Path.GetFullPath(exePath), StringComparison.OrdinalIgnoreCase)) { try { File.Copy(Application.ExecutablePath, exePath, true); } catch { } }
        ImportSavePacks();
    }

    // Started from a download (not from its home folder): set up right away - copy itself and its files home and put
    // the Desktop shortcut there, so a friend only has to double-click the exe they were sent.
    void FirstStartSetup()
    {
        string home = Path.Combine(HomeDir(), "Kaiserreich Collection.exe");
        if (string.Equals(Path.GetFullPath(Application.ExecutablePath), Path.GetFullPath(home), StringComparison.OrdinalIgnoreCase)) return;
        try {
            Deploy();
            MakeShortcut(home);
            Append("Installed to " + HomeDir() + " - use the 'Kaiserreich Collection' shortcut on your Desktop from now on.");
            status.Text = "Installed. Pick a Kaiserreich and click PLAY.";
        } catch (Exception ex) { Append("Couldn't finish setting up: " + ex.Message); }
    }
    static void MakeShortcut(string target)
    {
        try {
            var shellType = Type.GetTypeFromProgID("WScript.Shell"); object shell = Activator.CreateInstance(shellType);
            string lnk = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "Kaiserreich Collection.lnk");
            object sc = shellType.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { lnk });
            var t = sc.GetType(); string dir = Path.GetDirectoryName(target), ico = Path.Combine(dir, "KaiserreichCollection.ico");
            t.InvokeMember("TargetPath", BindingFlags.SetProperty, null, sc, new object[] { target });
            t.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, sc, new object[] { dir });
            t.InvokeMember("IconLocation", BindingFlags.SetProperty, null, sc, new object[] { (File.Exists(ico) ? ico : target) + ",0" });
            t.InvokeMember("Description", BindingFlags.SetProperty, null, sc, new object[] { "Every old Kaiserreich on its matching Hearts of Iron IV version" });
            t.InvokeMember("Save", BindingFlags.InvokeMethod, null, sc, null);
        } catch { }
    }

    // The custom games' ready saves travel separately (to keep every download under Discord's 10 MB): files named
    // like "ACW-saves-1-of-2.7z". Picked up from next to this exe, Downloads or the Desktop into <home>\scenario_saves\packs;
    // the engine takes the save it needs out of them.
    void ImportSavePacks()
    {
        string packs = Path.Combine(HomeDir(), "scenario_saves", "packs");
        string user = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var places = new List<string> { Path.GetDirectoryName(Application.ExecutablePath), Path.Combine(user, "Downloads"), Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory) };
        foreach (var place in places) {
            try {
                if (string.IsNullOrEmpty(place) || !Directory.Exists(place)) continue;
                foreach (var f in Directory.GetFiles(place, "*.7z")) {
                    string n = Path.GetFileName(f).ToLowerInvariant();
                    if (!(n.Contains("acw") && n.Contains("saves"))) continue;
                    string to = Path.Combine(packs, Path.GetFileName(f));
                    if (File.Exists(to) && new FileInfo(to).Length == new FileInfo(f).Length) continue;
                    Directory.CreateDirectory(packs); File.Copy(f, to, true);
                    Append("Took in the custom game saves: " + Path.GetFileName(f));
                }
            } catch { }
        }
    }

    void SetBusy(bool busy) { playBtn.Enabled = installBtn.Enabled = installAllBtn.Enabled = cacheBtn.Enabled = dlcBtn.Enabled = !busy; foreach (var t in verTiles) t.Enabled = !busy; }

    void Run(string mode)
    {
        if (sel == null) return;
        SetBusy(true); log.Clear();
        status.Text = mode == "cache" ? "Clearing the game cache..." : mode == "play" ? (IsReady(sel) ? "Starting Kaiserreich " + sel.Kr + "..." : "First time on this version - installing it first (Steam download + copy). This can take a while.")
                    : "Installing... Steam may close and reopen to download old game versions. Don't close this window.";
        try { Deploy(); SaveLastChoice(); }
        catch (Exception ex) { Append("ERROR unpacking files: " + ex.Message); SetBusy(false); return; }

        string a = "-NoProfile -ExecutionPolicy RemoteSigned -File \""   // RemoteSigned runs our own local scripts; "Bypass" is what malware uses + Path.Combine(HomeDir(), "Kaiserreich-Collection.ps1") + "\" -NoPause -Branch " + sel.Branch
                 + (tPlpc.On ? " -Plpc" : " -NoPlpc") + (cbWasd.Checked ? "" : " -NoWasd") + ScenarioArgs() + DlcArgs() + " -ShortcutTarget \"" + exePath + "\"";
        if (mode == "install") a += " -Install";
        if (mode == "installall") a += " -InstallAll";
        if (mode == "cache") a += " -ClearCache";
        if (mode == "uninstall") { a += " -Uninstall"; foreach (var x in args) if (x.Equals("/dryrun", StringComparison.OrdinalIgnoreCase)) a += " -DryRun"; }
        foreach (var x in args) if (x.Equals("/nolaunch", StringComparison.OrdinalIgnoreCase)) a += " -NoLaunch";

        proc = new Process();
        proc.StartInfo = new ProcessStartInfo("powershell.exe", a) { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true, WorkingDirectory = HomeDir() };
        proc.EnableRaisingEvents = true;
        proc.OutputDataReceived += (s, e) => { if (e.Data != null) Append(e.Data); };
        proc.ErrorDataReceived += (s, e) => { if (e.Data != null) Append(e.Data); };
        proc.Exited += (s, e) => BeginInvoke((Action)(() => {
            bool ok = proc.ExitCode == 0;
            status.Text = !ok ? "Something went wrong - read the log, fix it, and try again."
                        : mode == "cache" ? "Cache cleared." : mode == "play" ? (ScenarioArgs() != "" ? "Game started. Custom game: Custom Game Rules > Load Preset - or Load Game, where its ready save is at the top of the list." :"Game started. Your normal game settings come back automatically when it closes.")
                        : "Installed. Pick a Kaiserreich and click PLAY.";
            SetBusy(false); RefreshReady();
            if (mode == "uninstall" && ok) {
                bool dry = Array.Exists(args, x => x.Equals("/dryrun", StringComparison.OrdinalIgnoreCase));
                status.Text = dry ? "Dry run finished - nothing was removed." : "Uninstalled.";
                if (!dry) { MessageBox.Show(this, "The Kaiserreich Collection has been uninstalled.", "Uninstall", MessageBoxButtons.OK, MessageBoxIcon.Information); Close(); return; }
            }
            if (auto) { Environment.ExitCode = proc.ExitCode; Close(); }
        }));
        try { proc.Start(); proc.BeginOutputReadLine(); proc.BeginErrorReadLine(); }
        catch (Exception ex) { Append("ERROR starting PowerShell: " + ex.Message); status.Text = "Failed."; SetBusy(false); }
    }

    void Append(string text) { if (InvokeRequired) { BeginInvoke((Action<string>)Append, text); return; } log.AppendText(text + "\r\n"); }
}
