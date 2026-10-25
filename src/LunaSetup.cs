using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Text;
using System.Drawing;
using System.Threading;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Windows.Forms;

[assembly: AssemblyTitle("Luna Codex Orchestrator Setup")]
[assembly: AssemblyProduct("Luna Codex Orchestrator")]
[assembly: AssemblyVersion("1.3.1.0")]
[assembly: AssemblyFileVersion("1.3.1.0")]

internal static class LunaSetup
{
    [STAThread]
    private static int Main(string[] args)
    {
        string action = "Install";
        string codexHome = null;
        bool quiet = false;
        bool uiSmoke = false;
        string screenshot = null;
        string mode = "1.3";
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "--uninstall") action = "Uninstall";
            else if (args[i] == "--status") action = "Status";
            else if (args[i] == "--quiet") quiet = true;
            else if (args[i] == "--ui-smoke") uiSmoke = true;
            else if (args[i] == "--screenshot" && i + 1 < args.Length) screenshot = args[++i];
            else if (args[i] == "--mode" && i + 1 < args.Length) mode = args[++i];
            else if (args[i] == "--codex-home" && i + 1 < args.Length) codexHome = args[++i];
            else { Console.Error.WriteLine("Unknown argument: " + args[i]); return 2; }
        }
        if (mode != "1.3" && mode != "1.2" && mode != "default") { Console.Error.WriteLine("--mode must be 1.3, 1.2 or default"); return 2; }
        if (uiSmoke)
        {
            string temp = Path.GetFullPath(Path.GetTempPath()).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            if (String.IsNullOrEmpty(codexHome) || !Path.GetFullPath(codexHome).StartsWith(temp, StringComparison.OrdinalIgnoreCase) || String.IsNullOrEmpty(screenshot))
            { Console.Error.WriteLine("--ui-smoke requires --codex-home under %TEMP% and --screenshot PATH"); return 2; }
            return RunUi(codexHome, screenshot);
        }
        if (action == "Install" && args.Length == 0 && !quiet) return RunUi(null, null);
        return RunInstaller(action, mode, codexHome, quiet, null, null);
    }

    private static int RunInstaller(string action, string mode, string codexHome, bool quiet, Action<string> status, Action<bool, string> completed)
    {

        string stage = Path.Combine(Path.GetTempPath(), "luna-setup-" + Guid.NewGuid().ToString("N"));
        int exitCode = 1;
        string resultMessage = "Luna setup did not complete. See the console output.";
        try
        {
            Directory.CreateDirectory(stage);
            ExtractPayload(stage);
            string script = Path.Combine(stage, "install-luna.ps1");
            string powerShell = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
            if (!File.Exists(powerShell)) throw new FileNotFoundException("Windows PowerShell was not found", powerShell);
            var start = new ProcessStartInfo(powerShell);
            start.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Quote(script) + " -Action " + action + " -WorkflowMode " + mode;
            if (codexHome != null) start.Arguments += " -CodexDirectory " + Quote(codexHome);
            start.UseShellExecute = false;
            start.RedirectStandardOutput = true;
            start.RedirectStandardError = true;
            start.CreateNoWindow = true;
            using (Process child = new Process())
            {
                child.StartInfo = start;
                child.OutputDataReceived += (sender, e) => { if (e.Data != null) { Console.WriteLine(e.Data); if (status != null) status(e.Data); } };
                child.ErrorDataReceived += (sender, e) => { if (e.Data != null) { Console.Error.WriteLine(e.Data); if (status != null) status(e.Data); } };
                child.Start();
                child.BeginOutputReadLine();
                child.BeginErrorReadLine();
                child.WaitForExit();
                exitCode = child.ExitCode;
            }
            if (exitCode == 0 && action == "Install" && codexHome == null) InstallController();
            resultMessage = exitCode == 0
                ? "Luna Orchestrator " + action.ToLowerInvariant() + " complete. Restart Codex and open a new chat."
                : "Luna Orchestrator " + action.ToLowerInvariant() + " failed. See the console output.";
        }
        catch (Exception error)
        {
            exitCode = 1;
            Console.Error.WriteLine(error.ToString());
            resultMessage = "Luna Orchestrator setup failed: " + error.Message;
        }
        finally
        {
            try
            {
                string temp = Path.GetFullPath(Path.GetTempPath()).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
                string full = Path.GetFullPath(stage);
                if (!full.StartsWith(temp, StringComparison.OrdinalIgnoreCase)) throw new IOException("Unsafe temporary cleanup path.");
                if (Directory.Exists(full)) Directory.Delete(full, true);
            }
            catch (Exception error) { Console.Error.WriteLine("Temporary payload cleanup: " + error.Message); }
        }
        if (completed != null) completed(exitCode == 0, resultMessage);
        else if (!quiet && action == "Install") MessageBox.Show(resultMessage, "Luna Codex Orchestrator", MessageBoxButtons.OK,
            exitCode == 0 ? MessageBoxIcon.Information : MessageBoxIcon.Error);
        return exitCode;
    }

    private static int RunUi(string smokeHome, string screenshot)
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        using (var form = new SetupForm(smokeHome, screenshot))
        {
            Application.Run(form);
            return form.SmokeExitCode;
        }
    }

    private static void InstallController()
    {
        string root = Environment.GetEnvironmentVariable("CODEX_HOME");
        if (String.IsNullOrEmpty(root)) root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");
        string target = Path.GetFullPath(Path.Combine(root, @"tools\luna-orchestrator\v1.3.1\Luna-Control.exe"));
        string source = Assembly.GetExecutingAssembly().Location;
        if (!String.Equals(source, target, StringComparison.OrdinalIgnoreCase))
        {
            bool equal = false;
            if (File.Exists(target)) using (var sha = SHA256.Create())
            {
                byte[] left, right;
                using (var stream = File.OpenRead(source)) left = sha.ComputeHash(stream);
                using (var stream = File.OpenRead(target)) right = sha.ComputeHash(stream);
                equal = Convert.ToBase64String(left) == Convert.ToBase64String(right);
            }
            if (!equal) File.Copy(source, target, true);
        }
        string desktop = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
        if (String.IsNullOrEmpty(desktop) || !Directory.Exists(desktop)) return;
        object shell = null, link = null;
        try
        {
            shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell"));
            string shortcut = Path.Combine(desktop, "Luna Codex.lnk");
            link = shell.GetType().InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { shortcut });
            string previous = (string)link.GetType().InvokeMember("TargetPath", BindingFlags.GetProperty, null, link, null);
            string description = (string)link.GetType().InvokeMember("Description", BindingFlags.GetProperty, null, link, null);
            string managedRoot = Path.GetFullPath(Path.Combine(root, @"tools\luna-orchestrator")).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            string priorPath = String.IsNullOrEmpty(previous) ? "" : Path.GetFullPath(previous);
            bool managedPrior = description == "Luna Codex workflow modes" && priorPath.StartsWith(managedRoot, StringComparison.OrdinalIgnoreCase)
                && System.Text.RegularExpressions.Regex.IsMatch(priorPath.Substring(managedRoot.Length), @"^v\d+\.\d+\.\d+\\Luna-Control\.exe$", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
            if (File.Exists(shortcut) && !String.Equals(previous, target, StringComparison.OrdinalIgnoreCase) && !managedPrior)
            { Console.WriteLine("Existing personal desktop shortcut preserved: " + shortcut); return; }
            link.GetType().InvokeMember("TargetPath", BindingFlags.SetProperty, null, link, new object[] { target });
            link.GetType().InvokeMember("Description", BindingFlags.SetProperty, null, link, new object[] { "Luna Codex workflow modes" });
            link.GetType().InvokeMember("Save", BindingFlags.InvokeMethod, null, link, null);
            Console.WriteLine("Controller: " + target);
        }
        finally
        {
            if (link != null) Marshal.FinalReleaseComObject(link);
            if (shell != null) Marshal.FinalReleaseComObject(shell);
        }
    }

    private sealed class SetupForm : Form
    {
        private readonly ModeButton modern = new ModeButton();
        private readonly ModeButton compat = new ModeButton();
        private readonly ModeButton defaultMode = new ModeButton();
        private readonly Label status = new Label();
        private readonly Label sidebarMode = new Label();
        private readonly string smokeHome;
        private readonly string screenshot;
        private int smokeStage;
        private bool busy;
        private bool isLoaded;
        private string activeMode;
        public int SmokeExitCode = 0;
        private readonly DateTime smokeStarted = DateTime.UtcNow;
        private readonly System.Windows.Forms.Timer smokeTimer = new System.Windows.Forms.Timer();
        public SetupForm(string smokeHome, string screenshot)
        {
            this.smokeHome = smokeHome; this.screenshot = screenshot;
            Text = "Luna Codex"; ClientSize = new Size(900, 620); FormBorderStyle = FormBorderStyle.FixedSingle; MaximizeBox = false;
            StartPosition = FormStartPosition.CenterScreen; Font = new Font("Segoe UI", 9.5f); BackColor = Color.White;
            DoubleBuffered = true;
            var sidebar = new Panel { Dock = DockStyle.Left, Width = 224, BackColor = Color.FromArgb(242, 245, 250), Padding = new Padding(20, 22, 18, 18) };
            var brand = new Label { Text = "◔  Luna Codex", Dock = DockStyle.Top, Height = 54, Font = new Font("Segoe UI Semibold", 13), ForeColor = Color.FromArgb(35, 39, 47) };
            var sideCaption = new Label { Text = "УПРАВЛЕНИЕ", Dock = DockStyle.Top, Height = 38, Padding = new Padding(2, 12, 0, 0), Font = new Font("Segoe UI", 8, FontStyle.Bold), ForeColor = Color.FromArgb(130, 136, 146) };
            var navigation = new Label { Text = "☷   Режимы", Dock = DockStyle.Top, Height = 38, Padding = new Padding(12, 0, 0, 0), TextAlign = ContentAlignment.MiddleLeft, BackColor = Color.FromArgb(225, 231, 240), ForeColor = Color.FromArgb(35, 39, 47) };
            var profile = new Label { Text = "Глобальный профиль\nДля всех проектов\n\nГлавную модель выбирайте\nв интерфейсе Codex.", Dock = DockStyle.Top, Height = 145, Padding = new Padding(2, 25, 0, 0), Font = new Font("Segoe UI", 9), ForeColor = Color.FromArgb(106, 113, 124) };
            var sideFooter = new Label { Text = "LUNA CODEX  ·  1.3.1", Dock = DockStyle.Bottom, Height = 34, TextAlign = ContentAlignment.MiddleLeft, Font = new Font("Segoe UI", 8, FontStyle.Bold), ForeColor = Color.FromArgb(133, 139, 149) };
            sidebarMode.Text = "Проверяю режим…"; sidebarMode.Dock = DockStyle.Bottom; sidebarMode.Height = 68; sidebarMode.Font = new Font("Segoe UI", 9); sidebarMode.ForeColor = Color.FromArgb(82, 89, 100); sidebarMode.TextAlign = ContentAlignment.MiddleLeft;
            var sideRule = new Panel { Dock = DockStyle.Bottom, Height = 1, BackColor = Color.FromArgb(226, 229, 234) };
            sidebar.Controls.Add(sideFooter); sidebar.Controls.Add(sideRule); sidebar.Controls.Add(sidebarMode); sidebar.Controls.Add(profile); sidebar.Controls.Add(navigation); sidebar.Controls.Add(sideCaption); sidebar.Controls.Add(brand);
            var workspace = new Panel { Dock = DockStyle.Fill, BackColor = Color.White, Padding = new Padding(48, 37, 48, 30) };
            var header = new Panel { Dock = DockStyle.Top, Height = 112 };
            header.Controls.Add(new Label { Text = "Выберите режим для новых чатов.", Dock = DockStyle.Top, Height = 30, Font = new Font("Segoe UI", 10), ForeColor = Color.FromArgb(106, 113, 124) });
            header.Controls.Add(new Label { Text = "Режим Codex", Dock = DockStyle.Top, Height = 44, Font = new Font("Segoe UI Semibold", 21), ForeColor = Color.FromArgb(28, 32, 39) });
            header.Controls.Add(new Label { Text = "НАСТРОЙКИ РАБОЧЕГО ПРОЦЕССА", Dock = DockStyle.Top, Height = 22, Font = new Font("Segoe UI", 8, FontStyle.Bold), ForeColor = Color.FromArgb(111, 119, 132) });
            ConfigureModeButton(modern, "1.3  ·  Fast / Plan / Think", "Medium — работа  ·  High — план  ·  Max — сложный анализ", 0);
            ConfigureModeButton(compat, "1.2  ·  Luna Max", "Один исполнитель Think с усилием Max", 1);
            ConfigureModeButton(defaultMode, "Default  ·  Обычный Codex", "Без управляемой маршрутизации Luna", 2);
            var cards = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, BackColor = Color.White, Padding = new Padding(0, 2, 0, 0) };
            cards.Controls.Add(modern); cards.Controls.Add(compat); cards.Controls.Add(defaultMode);
            status.Text = "Проверяю активный режим…"; status.Dock = DockStyle.Bottom; status.Height = 38; status.Font = new Font("Segoe UI", 9); status.ForeColor = Color.FromArgb(96, 103, 114); status.TextAlign = ContentAlignment.MiddleLeft;
            var restart = new Label { Text = "После переключения перезапустите Codex\nи откройте новый чат.", Dock = DockStyle.Bottom, Height = 42, Font = new Font("Segoe UI", 9), ForeColor = Color.FromArgb(125, 131, 141) };
            workspace.Controls.Add(cards); workspace.Controls.Add(status); workspace.Controls.Add(restart); workspace.Controls.Add(header);
            Controls.Add(workspace); Controls.Add(sidebar);
            modern.Click += delegate { StartMode("1.3"); }; compat.Click += delegate { StartMode("1.2"); }; defaultMode.Click += delegate { StartMode("default"); };
            FormClosing += delegate(object sender, FormClosingEventArgs e) { if (busy) { e.Cancel = true; status.Text = "Завершаю переключение…"; } };
            Shown += delegate { ThreadPool.QueueUserWorkItem(delegate {
                string found = null;
                RunInstaller("Status", "1.3", this.smokeHome, true,
                    delegate(string line) { if (line.StartsWith("WorkflowMode=")) found = line.Substring("WorkflowMode=".Length); },
                    delegate(bool ok, string msg) { });
                UpdateUi(delegate { if (busy) return; isLoaded = true; if (found == "1.3" || found == "1.2" || found == "default") SetActiveMode(found); else if (this.smokeHome == null) StartMode("1.3"); else { status.Text = "Режим ещё не настроен. По умолчанию: 1.3"; sidebarMode.Text = "ТЕКУЩИЙ РЕЖИМ\nНе настроен"; } });
            }); };
            if (smokeHome != null)
            {
                smokeTimer.Interval = 250;
                smokeTimer.Tick += delegate {
                    if ((DateTime.UtcNow - smokeStarted).TotalSeconds > 90) { SmokeExitCode = 1; smokeTimer.Stop(); busy = false; Close(); return; }
                    if (smokeStage == 0 && isLoaded && !busy) { smokeStage = 1; modern.PerformClick(); }
                    else if (smokeStage == 1 && !busy && activeMode == "1.3") { smokeStage = 2; compat.PerformClick(); }
                    else if (smokeStage == 2 && !busy && activeMode == "1.2") { SaveScreenshot("-1.2"); smokeStage = 3; defaultMode.PerformClick(); }
                    else if (smokeStage == 3 && !busy && activeMode == "default") { SaveScreenshot("-default"); smokeStage = 4; modern.PerformClick(); }
                    else if (smokeStage == 4 && !busy && activeMode == "1.3") {
                        smokeTimer.Stop(); SaveScreenshot("");
                        Close();
                    }
                };
                Shown += delegate { smokeTimer.Start(); };
            }
        }
        private void UpdateUi(MethodInvoker action)
        {
            if (!IsHandleCreated || IsDisposed) return;
            try { BeginInvoke(action); } catch (InvalidOperationException) { }
        }
        private void SaveScreenshot(string suffix)
        {
            string full = Path.GetFullPath(screenshot);
            Directory.CreateDirectory(Path.GetDirectoryName(full));
            string destination = Path.Combine(Path.GetDirectoryName(full), Path.GetFileNameWithoutExtension(full) + suffix + Path.GetExtension(full));
            using (Bitmap image = new Bitmap(Width, Height)) { DrawToBitmap(image, new Rectangle(0, 0, Width, Height)); image.Save(destination); }
        }
        private void StartMode(string selected)
        {
            busy = true; modern.Enabled = compat.Enabled = defaultMode.Enabled = false; status.Text = "Применяю режим " + selected + "…";
            ThreadPool.QueueUserWorkItem(delegate {
                string lastError = null;
                RunInstaller("Install", selected, smokeHome, true,
                    delegate(string line) { lastError = line; },
                    delegate(bool ok, string message) { UpdateUi(delegate { busy = false; modern.Enabled = compat.Enabled = defaultMode.Enabled = true; if (ok) SetActiveMode(selected); else status.Text = "Не удалось применить режим."; if (!ok && smokeHome == null) MessageBox.Show(lastError ?? message, "Luna Codex", MessageBoxButtons.OK, MessageBoxIcon.Error); }); });
            });
        }
        private void SetActiveMode(string mode)
        {
            activeMode = mode;
            modern.Selected = mode == "1.3"; compat.Selected = mode == "1.2"; defaultMode.Selected = mode == "default";
            string name = mode == "1.3" ? "1.3 · Fast / Plan / Think" : mode == "1.2" ? "1.2 · Luna Max" : "Default · Обычный Codex";
            sidebarMode.Text = "ТЕКУЩИЙ РЕЖИМ\n" + name; status.Text = "Активный режим: " + name;
        }
        private static void ConfigureModeButton(ModeButton button, string title, string detail, int tabIndex)
        {
            button.Text = title; button.Description = detail; button.TabIndex = tabIndex; button.AccessibleName = title; button.AccessibleDescription = detail;
            button.Size = new Size(560, 104); button.Margin = new Padding(0, 0, 0, 12); button.Font = new Font("Segoe UI Semibold", 11);
        }
        private sealed class ModeButton : Button
        {
            private bool selected;
            private bool hovered;
            public bool Selected { get { return selected; } set { selected = value; Invalidate(); } }
            public string Description;
            public ModeButton() { DoubleBuffered = true; Cursor = Cursors.Hand; FlatStyle = FlatStyle.Flat; FlatAppearance.BorderSize = 0; BackColor = Color.White; ForeColor = Color.FromArgb(35, 39, 47); TextAlign = ContentAlignment.MiddleLeft; Padding = new Padding(20, 0, 45, 0); UseVisualStyleBackColor = false; }
            protected override void OnMouseEnter(EventArgs e) { hovered = true; Invalidate(); base.OnMouseEnter(e); }
            protected override void OnMouseLeave(EventArgs e) { hovered = false; Invalidate(); base.OnMouseLeave(e); }
            protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }
            protected override void OnPaint(PaintEventArgs e)
            {
                e.Graphics.Clear(Parent == null ? Color.White : Parent.BackColor);
                Rectangle r = new Rectangle(1, 1, Width - 3, Height - 3);
                Color fillColor = Selected ? Color.FromArgb(247, 248, 250) : hovered && Enabled ? Color.FromArgb(250, 251, 252) : Color.White;
                using (var path = RoundedRect(r, 10)) using (var fill = new SolidBrush(fillColor)) using (var pen = new Pen(Selected ? Color.FromArgb(57, 64, 75) : Color.FromArgb(228, 231, 235), Selected ? 1.5f : 1)) { e.Graphics.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias; e.Graphics.FillPath(fill, path); e.Graphics.DrawPath(pen, path); }
                TextRenderer.DrawText(e.Graphics, Text, Font, new Rectangle(20, 17, Width - 110, 28), Enabled ? ForeColor : Color.Gray, TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
                using (var detailFont = new Font("Segoe UI", 9)) TextRenderer.DrawText(e.Graphics, Description, detailFont, new Rectangle(20, 50, Width - 42, 42), Color.FromArgb(105, 112, 123), TextFormatFlags.Left | TextFormatFlags.Top | TextFormatFlags.WordBreak);
                if (Selected) { using (var markFont = new Font("Segoe UI", 8)) TextRenderer.DrawText(e.Graphics, "✓ Активен", markFont, new Rectangle(Width - 96, 21, 80, 22), Color.FromArgb(57, 64, 75), TextFormatFlags.Right | TextFormatFlags.VerticalCenter); }
                if (Focused) { Rectangle focus = r; focus.Inflate(-5, -5); ControlPaint.DrawFocusRectangle(e.Graphics, focus); }
            }
            private static System.Drawing.Drawing2D.GraphicsPath RoundedRect(Rectangle r, int radius)
            {
                int d = radius * 2; var p = new System.Drawing.Drawing2D.GraphicsPath(); p.AddArc(r.Left, r.Top, d, d, 180, 90); p.AddArc(r.Right - d, r.Top, d, d, 270, 90); p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); p.AddArc(r.Left, r.Bottom - d, d, d, 90, 90); p.CloseFigure(); return p;
            }
        }
    }
    private static string Quote(string value)
    {
        if (value.IndexOf('"') >= 0 || value.IndexOf('\n') >= 0 || value.IndexOf('\r') >= 0)
            throw new ArgumentException("A path contains an unsupported character.");
        return "\"" + value + "\"";
    }

    private static void ExtractPayload(string stage)
    {
        using (Stream resource = Assembly.GetExecutingAssembly().GetManifestResourceStream("LunaPayload.zip"))
        {
            if (resource == null) throw new InvalidDataException("Embedded installer payload is missing.");
            using (var archive = new ZipArchive(resource, ZipArchiveMode.Read))
            {
                string root = Path.GetFullPath(stage).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
                foreach (ZipArchiveEntry entry in archive.Entries)
                {
                    string destination = Path.GetFullPath(Path.Combine(stage, entry.FullName.Replace('/', Path.DirectorySeparatorChar)));
                    if (!destination.StartsWith(root, StringComparison.OrdinalIgnoreCase))
                        throw new InvalidDataException("Unsafe installer payload path: " + entry.FullName);
                    if (entry.FullName.EndsWith("/")) { Directory.CreateDirectory(destination); continue; }
                    Directory.CreateDirectory(Path.GetDirectoryName(destination));
                    using (Stream input = entry.Open())
                    using (Stream output = File.Create(destination)) input.CopyTo(output);
                }
            }
        }
    }
}
