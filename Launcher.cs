using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("WinOptima Portable")]
[assembly: AssemblyDescription("Suite portatile di ottimizzazione, privacy e pulizia per Windows 10 e 11")]
[assembly: AssemblyProduct("WinOptima Portable")]
[assembly: AssemblyCompany("brn78")]
[assembly: AssemblyCopyright("© 2026 brn78 · github.com/brn78")]
[assembly: AssemblyVersion("3.6.2.0")]
[assembly: AssemblyFileVersion("3.6.2.0")]

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

                using (Process psProc = Process.Start(psInfo))
                {
                    if (psProc == null) return;
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
}
