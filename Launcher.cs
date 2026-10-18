using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;
using Timer = System.Windows.Forms.Timer;

[assembly: AssemblyTitle("WinOptima Portable")]
[assembly: AssemblyDescription("Suite portatile di ottimizzazione, privacy e pulizia per Windows 10 e 11")]
[assembly: AssemblyProduct("WinOptima Portable")]
[assembly: AssemblyCompany("brn78")]
[assembly: AssemblyCopyright("© 2026 brn78 · github.com/brn78")]
[assembly: AssemblyVersion("3.8.1.0")]
[assembly: AssemblyFileVersion("3.8.1.0")]

namespace WinOptimaLauncher
{
    // Eseguibile unico e portatile: contiene WinOptima.ps1 e l'icona come risorse incorporate.
    // A ogni avvio li estrae in %LOCALAPPDATA%\WinOptima (solo se sono cambiati) e avvia lo script da lì;
    // nella stessa cartella finiscono preferenze, copie di sicurezza e log degli errori.
    // L'elevazione UAC è richiesta dal manifest incorporato (requireAdministrator).
    static class Program
    {
        const string Title = "WinOptima Portable";

        [STAThread]
        static void Main()
        {
            try
            {
                string appDir = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "WinOptima");
                Directory.CreateDirectory(appDir);

                string scriptPath = Extract("WinOptima.ps1", appDir);
                Extract("WinOptima.ico", appDir);

                // Dopo un aggiornamento la versione precedente resta come «<nome>.old.exe»: la si elimina
                // in background, riprovando finché il vecchio processo non è terminato (max ~30 s)
                string exePath = Application.ExecutablePath;
                string oldExe = Path.Combine(Path.GetDirectoryName(exePath),
                    Path.GetFileNameWithoutExtension(exePath) + ".old.exe");
                if (File.Exists(oldExe))
                {
                    System.Threading.Thread cleaner = new System.Threading.Thread(() =>
                    {
                        for (int i = 0; i < 30 && File.Exists(oldExe); i++)
                        {
                            try { File.Delete(oldExe); }
                            catch { System.Threading.Thread.Sleep(1000); }
                        }
                    });
                    cleaner.IsBackground = true;
                    cleaner.Start();
                }

                // Senza risorse incorporate (build di sviluppo) usa lo script accanto all'exe
                if (scriptPath == null)
                {
                    appDir = AppDomain.CurrentDomain.BaseDirectory;
                    scriptPath = Path.Combine(appDir, "WinOptima.ps1");
                }
                if (!File.Exists(scriptPath))
                {
                    MessageBox.Show("File 'WinOptima.ps1' non trovato:\n" + scriptPath,
                        Title + " - Errore", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    return;
                }

                // PowerShell nascosto, in STA (necessario per WPF)
                ProcessStartInfo psInfo = new ProcessStartInfo
                {
                    FileName = "powershell.exe",
                    Arguments = "-NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File \"" + scriptPath + "\"",
                    WorkingDirectory = appDir,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };
                // Dice allo script che l'errore lo mostra il launcher (evita il doppio messaggio)
                psInfo.EnvironmentVariables["WINOPTIMA_LAUNCHER"] = "1";
                // Percorso di questo exe: serve all'aggiornamento automatico per sostituirlo
                psInfo.EnvironmentVariables["WINOPTIMA_EXE"] = Application.ExecutablePath;

                // Evento con cui l'app segnala «interfaccia disegnata»: fino ad allora si mostra lo splash
                string readyName = "WinOptima-Ready-" + Process.GetCurrentProcess().Id;
                using (EventWaitHandle ready = new EventWaitHandle(false, EventResetMode.ManualReset, readyName))
                using (Process psProc = StartWithReady(psInfo, readyName))
                {
                    if (psProc == null) return;
                    // L'app potrà portarsi in primo piano anche se lanciata da un processo nascosto
                    AllowSetForegroundWindow(psProc.Id);
                    Application.EnableVisualStyles();
                    Application.Run(new Splash(psProc, ready));
                    psProc.WaitForExit();

                    // Un'uscita anomala significa che l'interfaccia non è partita: lo diciamo all'utente
                    if (psProc.ExitCode != 0)
                    {
                        string logPath = Path.Combine(appDir, "WinOptima-error.log");
                        string message = "WinOptima si è chiuso in modo inatteso (codice " + psProc.ExitCode + ").";
                        if (File.Exists(logPath))
                        {
                            string[] lines = File.ReadAllLines(logPath);
                            // La prima riga dell'ultima segnalazione contiene il motivo
                            for (int i = lines.Length - 1; i >= 0; i--)
                            {
                                if (lines[i].StartsWith("[")) { message += "\n\n" + lines[i]; break; }
                            }
                            message += "\n\nDettagli nel file:\n" + logPath;
                        }
                        MessageBox.Show(message, Title + " - Errore", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    }
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show(
                    "Si è verificato un errore durante l'avvio:\n" + ex.Message,
                    Title + " - Errore", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        [DllImport("user32.dll")] static extern bool AllowSetForegroundWindow(int processId);

        static Process StartWithReady(ProcessStartInfo info, string readyName)
        {
            info.EnvironmentVariables["WINOPTIMA_READY"] = readyName;
            return Process.Start(info);
        }

        // Icona dell'app a 64 px dalla risorsa incorporata (o da quella dell'exe se manca)
        internal static Bitmap LoadLogo()
        {
            // I fotogrammi del nostro .ico sono PNG (System.Drawing.Icon non li legge): si estrae il più grande a mano
            try
            {
                using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("WinOptima.ico"))
                {
                    if (s != null)
                    {
                        byte[] d = new byte[s.Length];
                        int r = 0; while (r < d.Length) r += s.Read(d, r, d.Length - r);
                        int count = BitConverter.ToUInt16(d, 4), best = -1, bestW = 0;
                        for (int i = 0; i < count; i++)
                        {
                            int w = d[6 + i * 16]; if (w == 0) w = 256;
                            if (w > bestW) { bestW = w; best = i; }
                        }
                        if (best >= 0)
                        {
                            int size = BitConverter.ToInt32(d, 6 + best * 16 + 8), off = BitConverter.ToInt32(d, 6 + best * 16 + 12);
                            using (MemoryStream ms = new MemoryStream(d, off, size))
                            using (Image img = Image.FromStream(ms)) return new Bitmap(img);
                        }
                    }
                }
            }
            catch { }
            try { return Icon.ExtractAssociatedIcon(Application.ExecutablePath).ToBitmap(); } catch { return null; }
        }

        // Scrive la risorsa incorporata nella cartella solo se manca o è diversa (aggiornamento automatico).
        // Restituisce il percorso, oppure null se la risorsa non è incorporata.
        static string Extract(string name, string dir)
        {
            using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream(name))
            {
                if (s == null) return null;
                byte[] data = new byte[s.Length];
                int read = 0;
                while (read < data.Length) read += s.Read(data, read, data.Length - read);

                string path = Path.Combine(dir, name);
                if (File.Exists(path) && SameBytes(File.ReadAllBytes(path), data)) return path;
                try { File.WriteAllBytes(path, data); }
                catch (IOException) { if (!File.Exists(path)) throw; }   // file in uso da un'altra istanza: va bene quello esistente
                return path;
            }
        }

        static bool SameBytes(byte[] a, byte[] b)
        {
            if (a.Length != b.Length) return false;
            for (int i = 0; i < a.Length; i++) if (a[i] != b[i]) return false;
            return true;
        }
    }

    // Splash in stile Windows 11 mostrato mentre PowerShell prepara l'interfaccia:
    // si chiude quando l'app segnala di essere pronta, se il processo termina o dopo 60 secondi.
    sealed class Splash : Form
    {
        [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

        readonly Process proc;
        readonly EventWaitHandle ready;
        readonly Timer timer = new Timer();
        readonly DateTime started = DateTime.Now;
        readonly Bitmap logo = Program.LoadLogo();
        readonly bool dark;
        readonly Color accent;
        float scale = 1f;
        int tick;

        public Splash(Process proc, EventWaitHandle ready)
        {
            this.proc = proc;
            this.ready = ready;
            dark = IsDark();
            accent = dark ? Color.FromArgb(0x60, 0xCD, 0xFF) : Color.FromArgb(0x00, 0x5F, 0xB8);
            Text = "WinOptima Portable";
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.CenterScreen;
            ShowInTaskbar = true;
            TopMost = true;
            DoubleBuffered = true;
            BackColor = dark ? Color.FromArgb(0x2B, 0x2B, 0x2B) : Color.FromArgb(0xF9, 0xF9, 0xF9);
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
            using (Graphics g = CreateGraphics()) scale = g.DpiX / 96f;
            ClientSize = new Size(S(380), S(180));
            timer.Interval = 16;
            timer.Tick += (s, e) =>
            {
                tick++;
                Invalidate();
                if (ready.WaitOne(0) || proc.HasExited || (DateTime.Now - started).TotalSeconds > 60) { timer.Stop(); Close(); }
            };
        }

        int S(float v) { return (int)Math.Round(v * scale); }

        static bool IsDark()
        {
            try
            {
                using (Microsoft.Win32.RegistryKey k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"))
                {
                    object v = k == null ? null : k.GetValue("AppsUseLightTheme");
                    return v is int && (int)v == 0;
                }
            }
            catch { return true; }
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            try { int round = 2; DwmSetWindowAttribute(Handle, 33, ref round, 4); } catch { }   // angoli arrotondati (Windows 11)
        }

        protected override void OnShown(EventArgs e) { base.OnShown(e); timer.Start(); }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
            Color text = dark ? Color.White : Color.FromArgb(0x1B, 0x1B, 0x1B);
            Color sub = dark ? Color.FromArgb(0xC5, 0xC5, 0xC5) : Color.FromArgb(0x60, 0x60, 0x60);
            using (Pen border = new Pen(dark ? Color.FromArgb(0x3A, 0x3A, 0x3A) : Color.FromArgb(0xE0, 0xE0, 0xE0)))
                g.DrawRectangle(border, 0, 0, ClientSize.Width - 1, ClientSize.Height - 1);

            if (logo != null) g.DrawImage(logo, new Rectangle(S(32), S(40), S(64), S(64)));
            using (Font title = new Font("Segoe UI Variable Display", 20f, FontStyle.Bold, GraphicsUnit.Point))
            using (Font small = new Font("Segoe UI", 10f, FontStyle.Regular, GraphicsUnit.Point))
            using (Brush tb = new SolidBrush(text))
            using (Brush sb = new SolidBrush(sub))
            {
                g.DrawString("WinOptima", title, tb, S(112), S(44));
                string dots = new string('.', (tick / 20) % 4);
                g.DrawString("Avvio in corso" + dots, small, sb, S(114), S(82));
            }

            // Barra di avanzamento indeterminata (come la ProgressBar di Windows 11)
            Rectangle track = new Rectangle(S(32), S(136), ClientSize.Width - S(64), Math.Max(2, S(4)));
            using (Brush tr = new SolidBrush(dark ? Color.FromArgb(0x45, 0x45, 0x45) : Color.FromArgb(0xD8, 0xD8, 0xD8)))
                g.FillRectangle(tr, track);
            int seg = track.Width / 3;
            int x = track.X - seg + (tick * S(5)) % (track.Width + seg);
            Rectangle bar = Rectangle.Intersect(track, new Rectangle(x, track.Y, seg, track.Height));
            using (Brush ab = new SolidBrush(accent)) g.FillRectangle(ab, bar);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing) { timer.Dispose(); if (logo != null) logo.Dispose(); }
            base.Dispose(disposing);
        }
    }
}
