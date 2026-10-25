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
[assembly: AssemblyVersion("1.3.0.0")]
[assembly: AssemblyFileVersion("1.3.0.0")]

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
        if (mode != "1.3" && mode != "1.2") { Console.Error.WriteLine("--mode must be 1.3 or 1.2"); return 2; }
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
        string target = Path.GetFullPath(Path.Combine(root, @"tools\luna-orchestrator\v1.3.0\Luna-Control.exe"));
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
            if (File.Exists(shortcut) && !String.Equals(previous, target, StringComparison.OrdinalIgnoreCase))
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
        private readonly Button modern = new Button();
        private readonly Button compat = new Button();
        private readonly Label status = new Label();
        private readonly string smokeHome;
        private readonly string screenshot;
        private int smokeStage;
        private bool busy;
        public int SmokeExitCode = 0;
        private readonly DateTime smokeStarted = DateTime.UtcNow;
        private readonly System.Windows.Forms.Timer smokeTimer = new System.Windows.Forms.Timer();
        public SetupForm(string smokeHome, string screenshot)
        {
            this.smokeHome = smokeHome; this.screenshot = screenshot;
            Text = "Luna Codex"; ClientSize = new Size(600, 362); FormBorderStyle = FormBorderStyle.FixedSingle; MaximizeBox = false;
            StartPosition = FormStartPosition.CenterScreen; Font = new Font("Segoe UI", 10);
            BackColor = Color.FromArgb(248, 249, 251);
            var title = new Label { Text = "Режим Codex", Left = 24, Top = 18, Width = 550, Height = 34, Font = new Font("Segoe UI", 18, FontStyle.Bold) };
            var subtitle = new Label { Text = "Выбор сохраняется для всех новых чатов", Left = 26, Top = 55, Width = 550, Height = 24, ForeColor = Color.DimGray };
            modern.Text = "1.3 — Fast / Plan / Think"; modern.SetBounds(24, 90, 552, 56); modern.Font = new Font("Segoe UI", 13, FontStyle.Bold);
            var modernInfo = new Label { Text = "Medium — работа · High — план · Max — сложный анализ", Left = 28, Top = 151, Width = 548, Height = 26, Font = new Font("Segoe UI", 9), ForeColor = Color.DimGray };
            compat.Text = "1.2 — Luna Max"; compat.SetBounds(24, 188, 552, 52); compat.Font = new Font("Segoe UI", 13, FontStyle.Bold);
            var compatInfo = new Label { Text = "Совместимый режим: один Luna Max, без Antigravity", Left = 28, Top = 245, Width = 548, Height = 25, Font = new Font("Segoe UI", 9), ForeColor = Color.DimGray };
            status.SetBounds(26, 282, 548, 28); status.Text = "Проверяю активный режим…";
            var restart = new Label { Text = "После переключения перезапустите Codex и откройте новый чат.", Left = 26, Top = 320, Width = 552, Height = 32, Font = new Font("Segoe UI", 9), ForeColor = Color.DimGray };
            Controls.AddRange(new Control[] { title, subtitle, modern, modernInfo, compat, compatInfo, status, restart });
            modern.Click += delegate { StartMode("1.3"); }; compat.Click += delegate { StartMode("1.2"); };
            FormClosing += delegate(object sender, FormClosingEventArgs e) { if (busy) { e.Cancel = true; status.Text = "Завершаю переключение, пожалуйста подождите…"; } };
            Shown += delegate { ThreadPool.QueueUserWorkItem(delegate {
                string found = null;
                RunInstaller("Status", "1.3", this.smokeHome, true,
                    delegate(string line) { if (line.StartsWith("WorkflowMode=")) found = line.Substring("WorkflowMode=".Length); },
                    delegate(bool ok, string msg) { });
                UpdateUi(delegate { if (busy) return; if (found == "1.3" || found == "1.2") status.Text = "Активный режим: " + found; else if (this.smokeHome == null) StartMode("1.3"); else status.Text = "Нет сохранённого режима. По умолчанию: 1.3"; });
            }); };
            if (smokeHome != null)
            {
                smokeTimer.Interval = 250;
                smokeTimer.Tick += delegate {
                    if ((DateTime.UtcNow - smokeStarted).TotalSeconds > 90) { SmokeExitCode = 1; smokeTimer.Stop(); busy = false; Close(); return; }
                    if (smokeStage == 0 && modern.Enabled && !status.Text.Contains("Проверяю")) { smokeStage = 1; modern.PerformClick(); }
                    else if (smokeStage == 1 && modern.Enabled && status.Text.Contains("Активный режим: 1.3")) { smokeStage = 2; compat.PerformClick(); }
                    else if (smokeStage == 2 && compat.Enabled && status.Text.Contains("Активный режим: 1.2")) { smokeStage = 3; modern.PerformClick(); }
                    else if (smokeStage == 3 && modern.Enabled && status.Text.Contains("Активный режим: 1.3")) {
                        smokeTimer.Stop(); Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(this.screenshot)));
                        using (Bitmap image = new Bitmap(Width, Height)) { DrawToBitmap(image, new Rectangle(0, 0, Width, Height)); image.Save(this.screenshot); }
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
        private void StartMode(string selected)
        {
            busy = true; modern.Enabled = compat.Enabled = false; status.Text = "Применяю режим " + selected + "…";
            ThreadPool.QueueUserWorkItem(delegate {
                string lastError = null;
                RunInstaller("Install", selected, smokeHome, true,
                    delegate(string line) { lastError = line; },
                    delegate(bool ok, string message) { UpdateUi(delegate { busy = false; status.Text = ok ? "Активный режим: " + selected : "Не удалось применить режим"; modern.Enabled = compat.Enabled = true; if (!ok && smokeHome == null) MessageBox.Show(lastError ?? message, "Luna Codex", MessageBoxButtons.OK, MessageBoxIcon.Error); }); });
            });
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
