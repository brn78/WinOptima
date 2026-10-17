<#
.SYNOPSIS
    WinOptima Portable - Suite di ottimizzazione, privacy e manutenzione per Windows 10 e 11.
.DESCRIPTION
    Applicazione portatile con interfaccia in stile Windows 11 (Fluent: Mica, tema chiaro/scuro,
    colore di accento di sistema). Ogni ottimizzazione è reversibile e mostra lo stato attuale.
.PARAMETER Simulate
    Avvia in modalità simulazione: nessuna modifica viene scritta nel sistema e non servono
    i privilegi di amministratore. Utile per provare l'interfaccia in sicurezza.
#>
[CmdletBinding()]
param([switch]$Simulate)

$script:AppVersion = '3.5'
$script:AppDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$script:ErrorLog = Join-Path $script:AppDir 'WinOptima-error.log'

# Qualsiasi errore fatale all'avvio finisce in un file di log e in un messaggio visibile
# (la console è nascosta, altrimenti l'app sparirebbe senza dire nulla).
trap {
    try {
        ('[{0}] {1}{2}{3}' -f (Get-Date -Format s), $_.Exception.Message, [Environment]::NewLine, $_.ScriptStackTrace) |
            Add-Content -LiteralPath $script:ErrorLog -Encoding UTF8
        # Se l'avvio e' passato da WinOptima.exe, e' il launcher a mostrare l'errore (un solo messaggio)
        if (-not $env:WINOPTIMA_LAUNCHER) {
            Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
            [void][System.Windows.MessageBox]::Show(
                "WinOptima non è riuscito ad avviarsi:`n`n$($_.Exception.Message)`n`nDettagli salvati in:`n$script:ErrorLog",
                'WinOptima Portable', 'OK', 'Error')
        }
    } catch {}
    exit 1
}

# --------------------------------------------------------------------------------------
#  Privilegi: l'app modifica il sistema, quindi richiede l'amministratore
#  (tranne in modalità simulazione).
# --------------------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
    IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin -and -not $Simulate) {
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList (
            '-NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File "{0}"' -f $PSCommandPath)
    } catch {
        Add-Type -AssemblyName PresentationFramework
        [void][System.Windows.MessageBox]::Show(
            'WinOptima richiede i permessi di amministratore per modificare le impostazioni di sistema.',
            'WinOptima Portable', 'OK', 'Warning')
    }
    exit
}

# --------------------------------------------------------------------------------------
#  Funzioni native: DPI, Mica/tema della finestra, ID applicazione, memoria
# --------------------------------------------------------------------------------------
$script:NativeOk = $false
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class WinOptimaNative
{
    [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("shell32.dll", PreserveSig = false)]
    static extern void SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string appId);
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    [DllImport("dwmapi.dll")] static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref Margins m);

    [StructLayout(LayoutKind.Sequential)]
    struct Margins { public int Left, Right, Top, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    struct MemoryStatus
    {
        public uint Length, MemoryLoad;
        public ulong TotalPhys, AvailPhys, TotalPageFile, AvailPageFile, TotalVirtual, AvailVirtual, AvailExtVirtual;
    }
    [DllImport("kernel32.dll")] static extern bool GlobalMemoryStatusEx(ref MemoryStatus s);

    // Nitidezza su schermi ad alta densita': va chiamato prima di creare qualunque finestra
    public static void EnableDpiAwareness()
    {
        try { if (!SetProcessDpiAwarenessContext(new IntPtr(-4))) SetProcessDPIAware(); }
        catch { try { SetProcessDPIAware(); } catch { } }
    }

    // Raggruppa la finestra sotto "WinOptima" nella barra delle applicazioni (non sotto PowerShell)
    public static void SetAppId(string id) { try { SetCurrentProcessExplicitAppUserModelID(id); } catch { } }

    public static bool SetDarkTitleBar(IntPtr hwnd, bool dark)
    {
        int v = dark ? 1 : 0;
        return DwmSetWindowAttribute(hwnd, 20, ref v, 4) == 0 || DwmSetWindowAttribute(hwnd, 19, ref v, 4) == 0;
    }

    // Materiale Mica (Windows 11 build 22621+). Restituisce false se non supportato.
    public static bool EnableMica(IntPtr hwnd)
    {
        int backdrop = 2;                                   // DWMSBT_MAINWINDOW = Mica
        if (DwmSetWindowAttribute(hwnd, 38, ref backdrop, 4) != 0) return false;
        Margins m = new Margins { Left = -1, Right = -1, Top = -1, Bottom = -1 };
        return DwmExtendFrameIntoClientArea(hwnd, ref m) == 0;
    }

    public static void GetMemory(out uint loadPercent, out ulong totalBytes, out ulong availBytes)
    {
        MemoryStatus s = new MemoryStatus();
        s.Length = (uint)Marshal.SizeOf(typeof(MemoryStatus));
        GlobalMemoryStatusEx(ref s);
        loadPercent = s.MemoryLoad; totalBytes = s.TotalPhys; availBytes = s.AvailPhys;
    }
}
'@
    [WinOptimaNative]::EnableDpiAwareness()
    [WinOptimaNative]::SetAppId('WinOptima.Portable')
    $script:NativeOk = $true
} catch {
    # Senza le funzioni native l'app funziona comunque (niente Mica, DPI di sistema)
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing


# ======================================================================================
#  MOTORE
#  Catalogo delle ottimizzazioni e funzioni di sistema. Questo blocco viene eseguito sia
#  nel thread dell'interfaccia (per leggere lo stato) sia in un runspace separato (per
#  applicare le modifiche senza bloccare la finestra). Comunica con la UI solo tramite la
#  coda $UiQueue: nessun controllo grafico viene mai toccato da qui.
# ======================================================================================
$Sim = [bool]$Simulate
$UiQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'

$Engine = {
    # ---------------------------------------------------------------- comunicazione con la UI
    function Send-Ui {
        param([string]$Type, [hashtable]$Data = @{})
        $Data['Type'] = $Type
        if ($UiQueue) { $UiQueue.Enqueue($Data) }
    }

    function Write-Log {
        param([string]$Text, [string]$Level = 'INFO')
        Send-Ui 'log' @{ Level = $Level; Text = $Text; Time = (Get-Date) }
    }

    # In simulazione descrive l'azione nel registro e dice al chiamante di non eseguirla
    function Test-Sim {
        param([string]$What)
        if ($Sim) { Write-Log $What 'SIM'; return $true }
        $false
    }

    function Format-Bytes {
        param([double]$Bytes)
        if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
        if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
        if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
        '{0:N0} B' -f $Bytes
    }

    $OsBuild = [Environment]::OSVersion.Version.Build
    $IsWin11 = $OsBuild -ge 22000

    # ---------------------------------------------------------------- registro di sistema
    function Get-RegValue {
        param([string]$Path, [string]$Name)
        try { (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name } catch { $null }
    }

    function Set-RegValue {
        param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
        if (Test-Sim "imposta $Path -> $Name = $Value") { return }
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
    }

    function Remove-RegValue {
        param([string]$Path, [string]$Name)
        if (Test-Sim "rimuove $Path -> $Name") { return }
        if (Test-Path -LiteralPath $Path) {
            Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
        }
    }

    # Una "specifica" descrive una chiave: Path, Name, Type, On (valore attivo) e Off (valore
    # predefinito di Windows; $null = il valore non esiste di default e va eliminato).
    function Test-RegSpec {
        param([hashtable]$Spec)
        $cur = Get-RegValue $Spec.Path $Spec.Name
        if ($null -eq $cur) { return $false }
        if ($Spec.Type -eq 'String') { return ([string]$cur -eq [string]$Spec.On) }
        [int64]$cur -eq [int64]$Spec.On
    }

    function Set-RegSpecOn  { param([hashtable]$Spec) Set-RegValue $Spec.Path $Spec.Name $Spec.On $(if ($Spec.Type) { $Spec.Type } else { 'DWord' }) }
    function Set-RegSpecOff {
        param([hashtable]$Spec)
        if ($null -eq $Spec.Off) { Remove-RegValue $Spec.Path $Spec.Name }
        else { Set-RegValue $Spec.Path $Spec.Name $Spec.Off $(if ($Spec.Type) { $Spec.Type } else { 'DWord' }) }
    }

    # ---------------------------------------------------------------- comandi e servizi
    function Invoke-Native {
        param([string]$File, [string[]]$Arguments)
        if (Test-Sim "$File $($Arguments -join ' ')") { return 0 }
        $null = & $File @Arguments 2>&1
        $LASTEXITCODE
    }

    function Set-ServiceRunning {
        param([string[]]$Names, [bool]$Running)
        foreach ($n in $Names) {
            if (Test-Sim ("{0} servizio {1}" -f $(if ($Running) { 'avvia' } else { 'arresta' }), $n)) { continue }
            try {
                if ($Running) { Start-Service -Name $n -ErrorAction Stop }
                else { Stop-Service -Name $n -Force -ErrorAction Stop }
            } catch { <# servizio assente o già nello stato richiesto #> }
        }
    }

    # ---------------------------------------------------------------- file system (pulizia)
    # Elenco file ricorsivo tollerante: salta cartelle inaccessibili e collegamenti (junction)
    function Get-FileList {
        param([string]$Root)
        $files = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
        $stack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
        try { $stack.Push((New-Object System.IO.DirectoryInfo $Root)) } catch { return , $files }
        while ($stack.Count -gt 0) {
            $d = $stack.Pop()
            try { foreach ($f in $d.EnumerateFiles()) { $files.Add($f) } } catch {}
            try {
                foreach ($s in $d.EnumerateDirectories()) {
                    if (-not ($s.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { $stack.Push($s) }
                }
            } catch {}
        }
        , $files
    }

    # Cartelle che la pulizia non deve mai svuotare, qualunque cosa accada alle variabili d'ambiente
    $ProtectedPaths = @($env:SystemDrive, $env:WINDIR, "$env:WINDIR\System32", $env:USERPROFILE, (Split-Path $env:USERPROFILE -ErrorAction SilentlyContinue),
        $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData) |
        Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\').ToLowerInvariant() }

    function Test-ProtectedPath {
        param([string]$Path)
        $n = $Path.TrimEnd('\').ToLowerInvariant()
        $root = [System.IO.Path]::GetPathRoot($Path)
        if ($root -and $root.TrimEnd('\').ToLowerInvariant() -eq $n) { return $true }    # radice di un'unità
        $ProtectedPaths -contains $n
    }

    # Ogni percorso può essere una cartella (tutto il contenuto), un file o un pattern (*.dmp)
    function Get-TargetFiles {
        param([string[]]$Paths)
        $all = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
        foreach ($p in $Paths) {
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            if (Test-ProtectedPath $p) { Write-Log "Percorso protetto ignorato: $p" 'WARN'; continue }
            if (Test-Path -LiteralPath $p -PathType Container) {
                foreach ($f in (Get-FileList $p)) { $all.Add($f) }
            } elseif (Test-Path -LiteralPath $p -PathType Leaf) {
                $all.Add((New-Object System.IO.FileInfo $p))
            } else {
                foreach ($f in @(Get-ChildItem -Path $p -File -Force -ErrorAction SilentlyContinue)) { $all.Add($f) }
            }
        }
        , $all
    }

    function Measure-Targets {
        param([string[]]$Paths)
        $bytes = [int64]0
        foreach ($f in (Get-TargetFiles $Paths)) { try { $bytes += $f.Length } catch {} }
        $bytes
    }

    function Remove-EmptyDirs {
        param([string]$Root)
        if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return }
        $dirs = New-Object 'System.Collections.Generic.List[string]'
        $stack = New-Object 'System.Collections.Generic.Stack[string]'
        $stack.Push($Root)
        while ($stack.Count -gt 0) {
            $d = $stack.Pop()
            try {
                foreach ($s in [System.IO.Directory]::GetDirectories($d)) {
                    if (([System.IO.File]::GetAttributes($s) -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
                        $dirs.Add($s); $stack.Push($s)
                    }
                }
            } catch {}
        }
        for ($i = $dirs.Count - 1; $i -ge 0; $i--) { try { [System.IO.Directory]::Delete($dirs[$i]) } catch {} }
    }

    function Remove-TargetFiles {
        param([string[]]$Paths)
        $files = Get-TargetFiles $Paths
        $count = 0; $failed = 0; $bytes = [int64]0
        foreach ($f in $files) {
            try {
                if ($f.IsReadOnly) { $f.IsReadOnly = $false }
                $len = $f.Length
                $f.Delete()
                $count++; $bytes += $len
            } catch { $failed++ }
        }
        foreach ($p in $Paths) {
            if ($p -and -not (Test-ProtectedPath $p) -and (Test-Path -LiteralPath $p -PathType Container)) { Remove-EmptyDirs $p }
        }
        @{ Count = $count; Failed = $failed; Bytes = $bytes }
    }

    function Get-BrowserCachePaths {
        $paths = New-Object 'System.Collections.Generic.List[string]'
        $chromium = @(
            "$env:LOCALAPPDATA\Microsoft\Edge\User Data",
            "$env:LOCALAPPDATA\Google\Chrome\User Data",
            "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data")
        foreach ($base in $chromium) {
            if (-not (Test-Path -LiteralPath $base)) { continue }
            $profiles = Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' }
            foreach ($prof in $profiles) {
                foreach ($sub in 'Cache', 'Code Cache', 'GPUCache') { $paths.Add((Join-Path $prof.FullName $sub)) }
            }
        }
        $ff = "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles"
        if (Test-Path -LiteralPath $ff) {
            foreach ($p in (Get-ChildItem -LiteralPath $ff -Directory -ErrorAction SilentlyContinue)) {
                $paths.Add((Join-Path $p.FullName 'cache2'))
            }
        }
        $paths.ToArray()
    }

    # ---------------------------------------------------------------- catalogo
    $Catalog = [ordered]@{}
    function Register-Item { param([hashtable]$Item) $Catalog[$Item.Id] = $Item }

    $KeyAdv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $KeyCdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    $KeyClassicMenu = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}'
    $PlanHigh = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    $PlanUltimate = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
    $PlanBalanced = '381b4222-f694-41f0-9685-ff5bb260df2e'

    # ---- Prestazioni -------------------------------------------------------------------
    Register-Item @{
        Id = 'classicMenu'; Page = 'perf'; Group = 'Reattività'; Icon = 0xE712; Rec = $true; Win11 = $true; Explorer = $true
        Title = 'Menu contestuale classico'
        Desc  = 'Mostra subito il menu completo con il tasto destro, senza passare da «Mostra altre opzioni».'
        Tip   = "Crea $KeyClassicMenu\InprocServer32 con valore predefinito vuoto."
        Test   = { Test-Path -LiteralPath "$KeyClassicMenu\InprocServer32" }
        Apply  = {
            if (Test-Sim 'crea la chiave del menu contestuale classico') { return }
            New-Item -Path "$KeyClassicMenu\InprocServer32" -Force -ErrorAction Stop | Out-Null
            Set-ItemProperty -LiteralPath "$KeyClassicMenu\InprocServer32" -Name '(default)' -Value '' -ErrorAction Stop
        }
        Revert = {
            if (Test-Sim 'elimina la chiave del menu contestuale classico') { return }
            Remove-Item -LiteralPath $KeyClassicMenu -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Register-Item @{
        Id = 'menuDelay'; Page = 'perf'; Group = 'Reattività'; Icon = 0xE916; Rec = $true
        Title = 'Menu più reattivi'
        Desc  = 'Riduce a 50 ms il ritardo di apertura di menu e sottomenu (predefinito: 400 ms).'
        Tip   = 'HKCU\Control Panel\Desktop\MenuShowDelay = 50'
        Reg   = @(@{ Path = 'HKCU:\Control Panel\Desktop'; Name = 'MenuShowDelay'; Type = 'String'; On = '50'; Off = '400' })
    }
    Register-Item @{
        Id = 'startupDelay'; Page = 'perf'; Group = 'Reattività'; Icon = 0xE823; Rec = $true
        Title = 'Avvio programmi senza ritardo'
        Desc  = 'Elimina la pausa artificiale che Windows inserisce prima di caricare le app di avvio.'
        Tip   = 'HKCU\...\Explorer\Serialize\StartupDelayInMSec = 0'
        Reg   = @(@{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize'; Name = 'StartupDelayInMSec'; On = 0; Off = $null })
    }
    Register-Item @{
        Id = 'fastKill'; Page = 'perf'; Group = 'Reattività'; Icon = 0xE711; Rec = $true
        Title = 'Arresto più veloce'
        Desc  = 'Attende 2 secondi (invece di 20) le app che non rispondono durante spegnimento e riavvio.'
        Tip   = 'HKCU\Control Panel\Desktop\WaitToKillAppTimeout = 2000 · HKLM\SYSTEM\CurrentControlSet\Control\WaitToKillServiceTimeout = 2000'
        Reg   = @(
            @{ Path = 'HKCU:\Control Panel\Desktop'; Name = 'WaitToKillAppTimeout'; Type = 'String'; On = '2000'; Off = '20000' },
            @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control'; Name = 'WaitToKillServiceTimeout'; Type = 'String'; On = '2000'; Off = '5000' })
    }
    Register-Item @{
        Id = 'highPerf'; Page = 'perf'; Group = 'Energia e risorse'; Icon = 0xE950; Rec = $true
        Title = 'Piano energetico Prestazioni elevate'
        Desc  = 'Evita i cali di frequenza della CPU sotto carico. Aumenta i consumi: sconsigliato con la batteria.'
        Tip   = "powercfg -setactive $PlanHigh (se manca viene creato). Il ripristino riattiva il piano Bilanciato."
        Test  = { (powercfg /getactivescheme | Out-String) -match "$PlanHigh|$PlanUltimate" }
        Apply = {
            if (Test-Sim 'attiva il piano energetico Prestazioni elevate') { return }
            $list = powercfg -list | Out-String
            $target = $null
            if ($list -match $PlanHigh) { $target = $PlanHigh }
            elseif ($list -match $PlanUltimate) { $target = $PlanUltimate }
            else {
                # Il piano esiste ma è nascosto (tipico dei portatili con Modern Standby): lo ricrea
                foreach ($g in $PlanHigh, $PlanUltimate) {
                    $null = powercfg -duplicatescheme $g $g 2>&1
                    if ((powercfg -list | Out-String) -match $g) { $target = $g; break }
                }
            }
            if (-not $target) { throw 'Nessun piano ad alte prestazioni disponibile su questo dispositivo.' }
            $null = powercfg -setactive $target
            if ($LASTEXITCODE -ne 0) { throw 'powercfg -setactive non riuscito.' }
        }
        Revert = {
            if (Test-Sim 'riattiva il piano energetico Bilanciato') { return }
            $null = powercfg -setactive $PlanBalanced
            if ($LASTEXITCODE -ne 0) { throw 'Impossibile riattivare il piano Bilanciato.' }
        }
    }
    Register-Item @{
        Id = 'gameDvr'; Page = 'perf'; Group = 'Energia e risorse'; Icon = 0xE7FC; Rec = $true
        Title = 'Disattiva registrazione Xbox in background'
        Desc  = 'Ferma Game Bar e Game DVR, liberando CPU e memoria, soprattutto sui portatili.'
        Tip   = 'HKCU\System\GameConfigStore\GameDVR_Enabled = 0 · HKCU\...\GameDVR\AppCaptureEnabled = 0 · policy AllowGameDVR = 0'
        Reg   = @(
            @{ Path = 'HKCU:\System\GameConfigStore'; Name = 'GameDVR_Enabled'; On = 0; Off = 1 },
            @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'AppCaptureEnabled'; On = 0; Off = 1 },
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR'; Name = 'AllowGameDVR'; On = 0; Off = $null })
    }
    Register-Item @{
        Id = 'fastStartup'; Page = 'perf'; Group = 'Energia e risorse'; Icon = 0xE7E8; Adv = $true
        Title = 'Disattiva Avvio rapido'
        Desc  = 'Ogni arresto spegne davvero il PC: utile con driver instabili, dual boot o aggiornamenti che non si completano.'
        Tip   = 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power\HiberbootEnabled = 0'
        Reg   = @(@{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'; Name = 'HiberbootEnabled'; On = 0; Off = 1 })
    }
    Register-Item @{
        Id = 'hibernate'; Page = 'perf'; Group = 'Energia e risorse'; Icon = 0xE708; Adv = $true
        Title = 'Disattiva ibernazione'
        Desc  = 'Elimina hiberfil.sys e libera diversi GB su disco. Disattiva anche l''Avvio rapido.'
        Tip   = 'powercfg -h off  (ripristino: powercfg -h on)'
        Test   = { (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled') -eq 0 }
        Apply  = { if ((Invoke-Native 'powercfg.exe' @('-h', 'off')) -ne 0) { throw 'powercfg -h off non riuscito.' } }
        Revert = { if ((Invoke-Native 'powercfg.exe' @('-h', 'on')) -ne 0) { throw 'powercfg -h on non riuscito.' } }
    }

    # ---- Privacy -----------------------------------------------------------------------
    Register-Item @{
        Id = 'telemetry'; Page = 'privacy'; Group = 'Raccolta dati'; Icon = 0xE9D9; Rec = $true
        Title = 'Telemetria diagnostica al minimo'
        Desc  = 'Limita l''invio a Microsoft di dati diagnostici e di utilizzo.'
        Tip   = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection\AllowTelemetry = 0'
        Reg   = @(@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name = 'AllowTelemetry'; On = 0; Off = $null })
    }
    Register-Item @{
        Id = 'activityHistory'; Page = 'privacy'; Group = 'Raccolta dati'; Icon = 0xE81C; Rec = $true
        Title = 'Disattiva cronologia attività'
        Desc  = 'Windows non registra più i file e le app aperti nel tempo (Timeline).'
        Tip   = 'Policy System: EnableActivityFeed, PublishUserActivities, UploadUserActivities = 0'
        Reg   = @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'EnableActivityFeed'; On = 0; Off = $null },
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'PublishUserActivities'; On = 0; Off = $null },
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'UploadUserActivities'; On = 0; Off = $null })
    }
    Register-Item @{
        Id = 'errorReporting'; Page = 'privacy'; Group = 'Raccolta dati'; Icon = 0xE7BA; Adv = $true
        Title = 'Disattiva segnalazione errori di Windows'
        Desc  = 'Non invia a Microsoft i report dei crash di sistema e delle applicazioni.'
        Tip   = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting\Disabled = 1'
        Reg   = @(@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting'; Name = 'Disabled'; On = 1; Off = $null })
    }
    Register-Item @{
        Id = 'recall'; Page = 'privacy'; Group = 'Raccolta dati'; Icon = 0xE794; Win11 = $true; Adv = $true
        Title = 'Disattiva istantanee AI (Recall)'
        Desc  = 'Impedisce il salvataggio di istantanee dello schermo per l''analisi AI, sui PC che lo supportano.'
        Tip   = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI\DisableAIDataAnalysis = 1'
        Reg   = @(@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name = 'DisableAIDataAnalysis'; On = 1; Off = $null })
    }
    Register-Item @{
        Id = 'advertisingId'; Page = 'privacy'; Group = 'Pubblicità e suggerimenti'; Icon = 0xE8EC; Rec = $true
        Title = 'Disattiva ID pubblicitario'
        Desc  = 'Le app non possono più usare un identificativo per profilarti e mostrarti annunci mirati.'
        Tip   = 'HKCU\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo\Enabled = 0'
        Reg   = @(@{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Name = 'Enabled'; On = 0; Off = 1 })
    }
    Register-Item @{
        Id = 'tailored'; Page = 'privacy'; Group = 'Pubblicità e suggerimenti'; Icon = 0xE77B; Rec = $true
        Title = 'Disattiva esperienze personalizzate'
        Desc  = 'Niente consigli e notifiche mirati basati sui dati diagnostici del tuo utilizzo.'
        Tip   = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Privacy\TailoredExperiencesWithDiagnosticDataEnabled = 0'
        Reg   = @(@{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy'; Name = 'TailoredExperiencesWithDiagnosticDataEnabled'; On = 0; Off = 1 })
    }
    Register-Item @{
        Id = 'feedback'; Page = 'privacy'; Group = 'Pubblicità e suggerimenti'; Icon = 0xE939; Rec = $true
        Title = 'Feedback su «Mai»'
        Desc  = 'Elimina i popup in cui Windows chiede pareri e valutazioni.'
        Tip   = 'HKCU\Software\Microsoft\Siuf\Rules\NumberOfSIUFInPeriod = 0'
        Reg   = @(@{ Path = 'HKCU:\Software\Microsoft\Siuf\Rules'; Name = 'NumberOfSIUFInPeriod'; On = 0; Off = $null })
    }
    Register-Item @{
        Id = 'bingSearch'; Page = 'privacy'; Group = 'Pubblicità e suggerimenti'; Icon = 0xE721; Rec = $true; Explorer = $true
        Title = 'Ricerca del menu Start solo locale'
        Desc  = 'Disattiva Bing nella ricerca: risultati istantanei e nulla di ciò che digiti viene inviato online.'
        Tip   = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Search\BingSearchEnabled = 0 · policy DisableSearchBoxSuggestions = 1'
        Reg   = @(
            @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'; Name = 'BingSearchEnabled'; On = 0; Off = 1 },
            @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'; Name = 'DisableSearchBoxSuggestions'; On = 1; Off = $null })
    }
    Register-Item @{
        Id = 'deliveryOpt'; Page = 'privacy'; Group = 'Rete e aggiornamenti'; Icon = 0xE753; Rec = $true
        Title = 'Aggiornamenti senza condivisione P2P'
        Desc  = 'Scarica gli aggiornamenti solo da Microsoft, senza usare la tua banda per inviarli ad altri PC.'
        Tip   = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization\DODownloadMode = 0 (solo HTTP)'
        Reg   = @(@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'; Name = 'DODownloadMode'; On = 0; Off = $null })
    }

    # ---- Esplora file e interfaccia ----------------------------------------------------
    Register-Item @{
        Id = 'showFileExt'; Page = 'ui'; Group = 'Esplora file'; Icon = 0xE8A5; Rec = $true; Explorer = $true
        Title = 'Mostra sempre le estensioni dei file'
        Desc  = 'Vedi .exe, .zip, .pdf: fondamentale per non aprire eseguibili mascherati da documenti.'
        Tip   = "$KeyAdv\HideFileExt = 0"
        Reg   = @(@{ Path = $KeyAdv; Name = 'HideFileExt'; On = 0; Off = 1 })
    }
    Register-Item @{
        Id = 'showHidden'; Page = 'ui'; Group = 'Esplora file'; Icon = 0xE890; Explorer = $true
        Title = 'Mostra file, cartelle e unità nascoste'
        Desc  = 'Rende visibili cartelle come AppData e i file di configurazione nascosti.'
        Tip   = "$KeyAdv\Hidden = 1"
        Reg   = @(@{ Path = $KeyAdv; Name = 'Hidden'; On = 1; Off = 2 })
    }
    Register-Item @{
        Id = 'openThisPC'; Page = 'ui'; Group = 'Esplora file'; Icon = 0xE770; Rec = $true
        Title = 'Apri Esplora file su «Questo PC»'
        Desc  = 'All''avvio mostra subito unità e cartelle principali invece di Home o Accesso rapido.'
        Tip   = "$KeyAdv\LaunchTo = 1"
        Reg   = @(@{ Path = $KeyAdv; Name = 'LaunchTo'; On = 1; Off = 2 })
    }
    Register-Item @{
        Id = 'compactMode'; Page = 'ui'; Group = 'Esplora file'; Icon = 0xE8FD; Explorer = $true
        Title = 'Visualizzazione compatta'
        Desc  = 'Riduce la spaziatura tra gli elementi di Esplora file per vederne di più.'
        Tip   = "$KeyAdv\UseCompactMode = 1"
        Reg   = @(@{ Path = $KeyAdv; Name = 'UseCompactMode'; On = 1; Off = 0 })
    }
    Register-Item @{
        Id = 'taskbarLeft'; Page = 'ui'; Group = 'Barra delle applicazioni'; Icon = 0xE8E4; Win11 = $true; Explorer = $true
        Title = 'Allinea la barra a sinistra'
        Desc  = 'Sposta Start e le icone a sinistra, come in Windows 10.'
        Tip   = "$KeyAdv\TaskbarAl = 0"
        Reg   = @(@{ Path = $KeyAdv; Name = 'TaskbarAl'; On = 0; Off = 1 })
    }
    Register-Item @{
        Id = 'widgets'; Page = 'ui'; Group = 'Barra delle applicazioni'; Icon = 0xE8A9; Win11 = $true; Explorer = $true
        Title = 'Nascondi Widget e Notizie'
        Desc  = 'Rimuove il feed MSN dalla barra: meno memoria e banda consumate.'
        Tip   = 'Policy HKLM\SOFTWARE\Policies\Microsoft\Dsh\AllowNewsAndInterests = 0 (+ TaskbarDa = 0 dove Windows lo consente)'
        # Sulle build recenti il driver UCPD blocca la scrittura di TaskbarDa («operazione non autorizzata»):
        # la policy ufficiale funziona sempre, TaskbarDa resta un tentativo facoltativo.
        Test  = { ((Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests') -eq 0) -or ((Get-RegValue $KeyAdv 'TaskbarDa') -eq 0) }
        Apply = {
            Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0
            try { Set-RegValue $KeyAdv 'TaskbarDa' 0 } catch { <# protetta da UCPD: basta la policy #> }
        }
        Revert = {
            Remove-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests'
            try { if ($null -ne (Get-RegValue $KeyAdv 'TaskbarDa')) { Set-RegValue $KeyAdv 'TaskbarDa' 1 } } catch { <# protetta da UCPD #> }
        }
    }
    Register-Item @{
        Id = 'hideSearch'; Page = 'ui'; Group = 'Barra delle applicazioni'; Icon = 0xE721; Explorer = $true
        Title = 'Nascondi «Cerca» dalla barra'
        Desc  = 'Toglie casella o icona di ricerca: per cercare basta aprire Start e iniziare a scrivere.'
        Tip   = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Search\SearchboxTaskbarMode = 0 (ripristino: casella di ricerca)'
        Reg   = @(@{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'; Name = 'SearchboxTaskbarMode'; On = 0; Off = 2 })
    }
    Register-Item @{
        Id = 'hideResume'; Page = 'ui'; Group = 'Barra delle applicazioni'; Icon = 0xE7F4; Win11 = $true; Explorer = $true
        Title = 'Nascondi «Riprendi» dalla barra'
        Desc  = 'Niente icona con notifica badge per riprendere sul PC le attività iniziate sul telefono.'
        Tip   = "$KeyAdv\IsEnabled = 0 (individuata confrontando il registro prima e dopo l'interruttore delle Impostazioni)"
        Reg   = @(@{ Path = $KeyAdv; Name = 'IsEnabled'; On = 0; Off = 1 })
    }
    Register-Item @{
        Id = 'taskView'; Page = 'ui'; Group = 'Barra delle applicazioni'; Icon = 0xE7C4; Explorer = $true
        Title = 'Nascondi «Visualizzazione attività»'
        Desc  = 'Toglie il pulsante delle finestre e dei desktop virtuali dalla barra.'
        Tip   = "$KeyAdv\ShowTaskViewButton = 0"
        Reg   = @(@{ Path = $KeyAdv; Name = 'ShowTaskViewButton'; On = 0; Off = 1 })
    }
    Register-Item @{
        Id = 'showSeconds'; Page = 'ui'; Group = 'Barra delle applicazioni'; Icon = 0xE917; Explorer = $true
        Title = 'Mostra i secondi nell''orologio'
        Desc  = 'L''orologio nell''area di notifica indica anche i secondi.'
        Tip   = "$KeyAdv\ShowSecondsInSystemClock = 1"
        Reg   = @(@{ Path = $KeyAdv; Name = 'ShowSecondsInSystemClock'; On = 1; Off = $null })
    }
    Register-Item @{
        Id = 'appSuggestions'; Page = 'ui'; Group = 'Menu Start e suggerimenti'; Icon = 0xE719; Rec = $true
        Title = 'Blocca suggerimenti e app sponsorizzate'
        Desc  = 'Niente banner promozionali né installazioni automatiche di app partner (Candy Crush, TikTok…).'
        Tip   = 'HKCU\...\ContentDeliveryManager: SystemPaneSuggestionsEnabled, SubscribedContent-*, PreInstalledAppsEnabled, SilentInstalledAppsEnabled… = 0'
        Reg   = @(
            @{ Path = $KeyCdm; Name = 'SystemPaneSuggestionsEnabled'; On = 0; Off = 1 },
            @{ Path = $KeyCdm; Name = 'SubscribedContent-338388Enabled'; On = 0; Off = 1 },
            @{ Path = $KeyCdm; Name = 'SubscribedContent-338389Enabled'; On = 0; Off = 1 },
            @{ Path = $KeyCdm; Name = 'SubscribedContent-310093Enabled'; On = 0; Off = 1 },
            @{ Path = $KeyCdm; Name = 'SubscribedContent-353694Enabled'; On = 0; Off = 1 },
            @{ Path = $KeyCdm; Name = 'SubscribedContent-353696Enabled'; On = 0; Off = 1 },
            @{ Path = $KeyCdm; Name = 'SoftLandingEnabled'; On = 0; Off = 1 },
            @{ Path = $KeyCdm; Name = 'PreInstalledAppsEnabled'; On = 0; Off = 1 },
            @{ Path = $KeyCdm; Name = 'OemPreInstalledAppsEnabled'; On = 0; Off = 1 },
            @{ Path = $KeyCdm; Name = 'SilentInstalledAppsEnabled'; On = 0; Off = 1 })
    }
    Register-Item @{
        Id = 'stickyKeys'; Page = 'ui'; Group = 'Accessibilità'; Icon = 0xE765
        Title = 'Disattiva la scorciatoia Tasti permanenti'
        Desc  = 'Premere Maiusc cinque volte non fa più comparire la finestra di attivazione (utile nei giochi).'
        Tip   = 'HKCU\Control Panel\Accessibility\StickyKeys\Flags = 506'
        Reg   = @(@{ Path = 'HKCU:\Control Panel\Accessibility\StickyKeys'; Name = 'Flags'; Type = 'String'; On = '506'; Off = '510' })
    }

    # Icone del desktop: valore DWORD per CLSID, 0 = visibile, 1 o assente = nascosta
    $KeyDesk = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel'
    foreach ($d in @(
            @{ Id = 'deskThisPC'; Icon = 0xE770; Clsid = '{20D04FE0-3AEA-1069-A2D8-08002B30309D}'; Title = 'Icona «Questo PC» sul desktop'; Desc = 'Accesso diretto a unità, dispositivi e proprietà del sistema.' },
            @{ Id = 'deskUser'; Icon = 0xE77B; Clsid = '{59031a47-3f72-44a7-89c5-5595fe6b30ee}'; Title = 'Icona della cartella utente sul desktop'; Desc = 'Documenti, Download, Immagini e le altre cartelle personali.' },
            @{ Id = 'deskNetwork'; Icon = 0xE839; Clsid = '{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}'; Title = 'Icona «Rete» sul desktop'; Desc = 'Computer e dispositivi condivisi della rete locale.' },
            @{ Id = 'deskControl'; Icon = 0xE9F5; Clsid = '{5399E694-6CE5-4D6C-8FCE-1D8870FDCBA0}'; Title = 'Icona «Pannello di controllo» sul desktop'; Desc = 'Le impostazioni classiche di Windows a portata di doppio clic.' })) {
        Register-Item @{
            Id = $d.Id; Page = 'ui'; Group = 'Icone del desktop'; Icon = $d.Icon; Explorer = $true
            Title = $d.Title; Desc = $d.Desc
            Tip = "HKCU\...\HideDesktopIcons\NewStartPanel\$($d.Clsid) = 0"
            Reg = @(@{ Path = $KeyDesk; Name = $d.Clsid; On = 0; Off = $null })
        }
    }

    # ---- Pulizia (operazioni una tantum) -----------------------------------------------
    Register-Item @{
        Id = 'userTemp'; Kind = 'action'; Page = 'clean'; Group = 'Pulizia file'; Icon = 0xE8B7; Rec = $true
        Title = 'File temporanei utente'
        Desc  = 'Cache e residui di browser, installer e programmi in %TEMP%.'
        Paths = { @($env:TEMP) }
    }
    Register-Item @{
        Id = 'winTemp'; Kind = 'action'; Page = 'clean'; Group = 'Pulizia file'; Icon = 0xE838; Rec = $true
        Title = 'File temporanei di sistema'
        Desc  = 'Log e cache accumulati dai processi di Windows in C:\Windows\Temp.'
        Paths = { @("$env:WINDIR\Temp") }
    }
    Register-Item @{
        Id = 'winUpdate'; Kind = 'action'; Page = 'clean'; Group = 'Pulizia file'; Icon = 0xE895; Rec = $true
        Title = 'Cache di Windows Update'
        Desc  = 'Pacchetti di aggiornamento già installati: spesso recupera diversi GB.'
        Paths = { @("$env:WINDIR\SoftwareDistribution\Download") }
        Pre   = { Set-ServiceRunning @('wuauserv', 'bits') $false }
        Post  = { Set-ServiceRunning @('bits', 'wuauserv') $true }
    }
    Register-Item @{
        Id = 'recycleBin'; Kind = 'action'; Page = 'clean'; Group = 'Pulizia file'; Icon = 0xE74D; Rec = $true
        Title = 'Cestino di tutte le unità'
        Desc  = 'Elimina definitivamente i file già cestinati.'
        Paths = { [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' } | ForEach-Object { Join-Path $_.RootDirectory.FullName '$Recycle.Bin' } }
        Run   = { if (-not (Test-Sim 'svuota il Cestino di tutte le unità')) { Clear-RecycleBin -Force -ErrorAction SilentlyContinue } }
    }
    Register-Item @{
        Id = 'dumps'; Kind = 'action'; Page = 'clean'; Group = 'Pulizia file'; Icon = 0xE783; Rec = $true
        Title = 'Crash dump e log di errore'
        Desc  = 'Copie di memoria (.dmp) generate da errori e arresti anomali passati.'
        Paths = { @("$env:WINDIR\Minidump", "$env:WINDIR\MEMORY.DMP", "$env:LOCALAPPDATA\CrashDumps") }
    }
    Register-Item @{
        Id = 'wer'; Kind = 'action'; Page = 'clean'; Group = 'Pulizia file'; Icon = 0xE7BA
        Title = 'Report di errore di Windows'
        Desc  = 'Archivio e coda dei report di crash di sistema e applicazioni.'
        Paths = { @("$env:ProgramData\Microsoft\Windows\WER\ReportArchive", "$env:ProgramData\Microsoft\Windows\WER\ReportQueue", "$env:LOCALAPPDATA\Microsoft\Windows\WER") }
    }
    Register-Item @{
        Id = 'deliveryCache'; Kind = 'action'; Page = 'clean'; Group = 'Pulizia file'; Icon = 0xE753
        Title = 'Cache Ottimizzazione recapito'
        Desc  = 'File di aggiornamento in cache per la condivisione tra PC.'
        Paths = { @("$env:WINDIR\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache") }
        Pre   = { Set-ServiceRunning @('DoSvc') $false }
        Post  = { Set-ServiceRunning @('DoSvc') $true }
    }
    Register-Item @{
        Id = 'browserCache'; Kind = 'action'; Page = 'clean'; Group = 'Pulizia file'; Icon = 0xE909
        Title = 'Cache dei browser'
        Desc  = 'Edge, Chrome, Brave e Firefox. Cookie, password e cronologia non vengono toccati. Chiudi i browser per una pulizia completa.'
        Paths = { Get-BrowserCachePaths }
    }
    Register-Item @{
        Id = 'flushDns'; Kind = 'action'; Page = 'clean'; Group = 'Manutenzione'; Icon = 0xE774; Rec = $true
        Title = 'Svuota la cache DNS'
        Desc  = 'Risolve siti non raggiungibili o indirizzi non aggiornati (ipconfig /flushdns).'
        Run   = { if (-not (Test-Sim 'svuota la cache del resolver DNS')) { Clear-DnsClientCache -ErrorAction Stop } }
    }
    Register-Item @{
        Id = 'trim'; Kind = 'action'; Page = 'clean'; Group = 'Manutenzione'; Icon = 0xEDA2; Rec = $true
        Title = 'Ottimizza l''unità di sistema (TRIM)'
        Desc  = 'Comunica all''SSD i blocchi liberi per mantenere alte le velocità di scrittura.'
        Run   = {
            if (Test-Sim 'esegue il TRIM sull''unità di sistema') { return }
            $letter = $env:SystemDrive.TrimEnd(':')
            try { Optimize-Volume -DriveLetter $letter -ReTrim -ErrorAction Stop | Out-Null }
            catch { throw "TRIM non eseguito (disco non SSD o non supportato): $($_.Exception.Message)" }
        }
    }
    Register-Item @{
        Id = 'componentCleanup'; Kind = 'action'; Page = 'clean'; Group = 'Manutenzione'; Icon = 0xE9F5; Slow = $true
        Title = 'Pulizia archivio componenti (WinSxS)'
        Desc  = 'Rimuove le versioni obsolete dei componenti di Windows. Può richiedere diversi minuti.'
        Run   = { if ((Invoke-Native 'dism.exe' @('/Online', '/Cleanup-Image', '/StartComponentCleanup', '/Quiet')) -ne 0) { throw 'DISM ha restituito un errore.' } }
    }

    # ---------------------------------------------------------------- stato e applicazione
    function Test-Tweak {
        param([hashtable]$Item)
        try {
            if ($Item.Test) { return [bool](& $Item.Test) }
            foreach ($spec in $Item.Reg) { if (-not (Test-RegSpec $spec)) { return $false } }
            return $true
        } catch { return $false }
    }

    function Invoke-Tweak {
        param([hashtable]$Item, [string]$Mode)
        try {
            if ($Mode -eq 'apply') {
                if ($Item.Apply) { & $Item.Apply } else { foreach ($s in $Item.Reg) { Set-RegSpecOn $s } }
                Write-Log "Attivata: $($Item.Title)" 'SUCCESS'
            } else {
                if ($Item.Revert) { & $Item.Revert } else { foreach ($s in $Item.Reg) { Set-RegSpecOff $s } }
                Write-Log "Ripristinata: $($Item.Title)" 'SUCCESS'
            }
            return $true
        } catch {
            Write-Log "$($Item.Title): $($_.Exception.Message)" 'ERROR'
            return $false
        }
    }

    function Invoke-CleanAction {
        param([hashtable]$Item)
        $freed = [int64]0
        try {
            if ($Item.Pre) { & $Item.Pre }
            $paths = if ($Item.Paths) { @(& $Item.Paths) } else { @() }
            if ($Item.Run) {
                $measured = if ($paths.Count) { Measure-Targets $paths } else { 0 }
                & $Item.Run
                if (-not $Sim) { $freed = $measured }
            } elseif ($paths.Count) {
                if ($Sim) {
                    $freed = Measure-Targets $paths
                    Write-Log "$($Item.Title): libererebbe $(Format-Bytes $freed)" 'SIM'
                    return @{ Ok = $true; Freed = 0 }
                }
                $r = Remove-TargetFiles $paths
                $freed = $r.Bytes
                $msg = "$($Item.Title): rimossi $($r.Count) file ($(Format-Bytes $r.Bytes))"
                if ($r.Failed -gt 0) { $msg += " · $($r.Failed) in uso, saltati" }
                Write-Log $msg 'SUCCESS'
                return @{ Ok = $true; Freed = $freed }
            }
            Write-Log "Completato: $($Item.Title)" 'SUCCESS'
            return @{ Ok = $true; Freed = $freed }
        } catch {
            Write-Log "$($Item.Title): $($_.Exception.Message)" 'ERROR'
            return @{ Ok = $false; Freed = 0 }
        } finally {
            if ($Item.Post) { try { & $Item.Post } catch {} }
        }
    }

    function Restart-Explorer {
        if (Test-Sim 'riavvia explorer.exe') { return }
        Write-Log 'Riavvio di Esplora risorse...'
        $old = @(Get-Process -Name explorer -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        # Windows riavvia da solo la shell con i privilegi dell'utente (non elevati): gli lasciamo il tempo
        # di farlo e controlliamo che sia comparso un processo nuovo, non quello appena terminato.
        $restarted = $false
        for ($i = 0; $i -lt 24 -and -not $restarted; $i++) {
            Start-Sleep -Milliseconds 250
            $restarted = [bool]@(Get-Process -Name explorer -ErrorAction SilentlyContinue | Where-Object { $old -notcontains $_.Id }).Count
        }
        if (-not $restarted) { Start-Process explorer.exe }
        Write-Log 'Esplora risorse riavviato.' 'SUCCESS'
    }

    function New-RestorePoint {
        if (Test-Sim 'crea il punto di ripristino «WinOptima_RestorePoint»') { return $true }
        Write-Log 'Creazione del punto di ripristino...'
        try {
            Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
            $warn = $null
            Checkpoint-Computer -Description 'WinOptima_RestorePoint' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop -WarningVariable warn -WarningAction SilentlyContinue
            if ($warn) {
                # Windows consente un solo punto di ripristino ogni 24 ore: ne esiste già uno recente
                Write-Log 'Esiste già un punto di ripristino delle ultime 24 ore: Windows non ne crea un altro.' 'WARN'
            } else {
                Write-Log 'Punto di ripristino «WinOptima_RestorePoint» creato.' 'SUCCESS'
            }
            return $true
        } catch {
            Write-Log "Punto di ripristino non creato: $($_.Exception.Message)" 'WARN'
            return $false
        }
    }

    # Esegue una sequenza di passaggi: @{ Id; Mode = 'apply' | 'revert' | 'run' }
    function Invoke-Plan {
        param([object[]]$Steps, [bool]$RestorePoint, [bool]$AutoExplorer)
        $ok = 0; $fail = 0; $freed = [int64]0; $needExplorer = $false
        $total = $Steps.Count + $(if ($RestorePoint) { 1 } else { 0 })
        $done = 0
        Send-Ui 'status' @{ Text = 'Applicazione in corso…'; Level = 'busy' }
        Write-Log '--- INIZIO SESSIONE ---'
        if ($Sim) { Write-Log 'Modalità simulazione: nessuna modifica verrà scritta nel sistema.' 'SIM' }
        Send-Ui 'progress' @{ Value = 0; Max = $total }

        if ($RestorePoint) {
            Send-Ui 'progress' @{ Value = 0; Max = $total; Text = 'Creazione del punto di ripristino' }
            [void](New-RestorePoint)
            $done++
            Send-Ui 'progress' @{ Value = $done; Max = $total }
        }
        foreach ($step in $Steps) {
            $item = $Catalog[$step.Id]
            $verb = switch ($step.Mode) { 'apply' { 'Attivo' } 'revert' { 'Ripristino' } default { 'Eseguo' } }
            Send-Ui 'progress' @{ Value = $done; Max = $total; Text = "${verb}: $($item.Title)" }
            if ($item.Kind -eq 'action') {
                $r = Invoke-CleanAction $item
                if ($r.Ok) { $ok++ } else { $fail++ }
                $freed += $r.Freed
            } else {
                if (Invoke-Tweak $item $step.Mode) {
                    $ok++
                    if ($item.Explorer) { $needExplorer = $true }
                } else { $fail++ }
            }
            $done++
            Send-Ui 'progress' @{ Value = $done; Max = $total }
        }
        if ($needExplorer -and $AutoExplorer) {
            Send-Ui 'progress' @{ Value = $done; Max = $total; Text = 'Riavvio di Esplora risorse' }
            Restart-Explorer
        }
        elseif ($needExplorer) { Write-Log 'Alcune modifiche saranno visibili dopo il riavvio di Esplora risorse (o di Windows).' 'WARN' }

        if ($fail -eq 0) { Write-Log '--- OPERAZIONE COMPLETATA ---' 'SUCCESS' }
        else { Write-Log "--- COMPLETATA CON $fail ERRORI ---" 'WARN' }
        Send-Ui 'summary' @{ Ok = $ok; Fail = $fail; Freed = $freed; Sim = $Sim; ExplorerPending = ($needExplorer -and -not $AutoExplorer) }
    }

    # Calcola lo spazio recuperabile di ogni voce di pulizia (senza cancellare nulla)
    function Measure-CleanSpace {
        param([string[]]$Ids)
        Send-Ui 'status' @{ Text = 'Analisi dello spazio recuperabile…'; Level = 'busy' }
        $total = [int64]0
        $i = 0
        foreach ($id in $Ids) {
            $item = $Catalog[$id]
            Send-Ui 'progress' @{ Value = $i; Max = $Ids.Count; Text = "Analizzo: $($item.Title)" }
            $i++
            if (-not $item.Paths) { continue }
            try {
                $bytes = Measure-Targets @(& $item.Paths)
                $total += $bytes
                Send-Ui 'size' @{ Id = $id; Text = (Format-Bytes $bytes) }
            } catch { Send-Ui 'size' @{ Id = $id; Text = 'n/d' } }
        }
        Write-Log "Analisi completata: circa $(Format-Bytes $total) recuperabili." 'SUCCESS'
        Send-Ui 'summary' @{ Analysis = $true; Freed = $total }
    }

    # ---------------------------------------------------------------- rete
    $DnsPresets = @(
        @{ Id = 'cloudflare'; Name = 'Cloudflare'; Servers = @('1.1.1.1', '1.0.0.1'); Desc = 'Molto veloce e attento alla privacy.' },
        @{ Id = 'google'; Name = 'Google'; Servers = @('8.8.8.8', '8.8.4.4'); Desc = 'Alta affidabilità a livello globale.' },
        @{ Id = 'quad9'; Name = 'Quad9'; Servers = @('9.9.9.9', '149.112.112.112'); Desc = 'Blocca domini malevoli, phishing e malware.' },
        @{ Id = 'adguard'; Name = 'AdGuard'; Servers = @('94.140.14.14', '94.140.15.15'); Desc = 'Blocca pubblicità e tracker a livello di rete.' }
    )

    # Schede di rete fisiche attive (esclude VPN e adattatori virtuali, che non vanno toccati)
    function Get-ActiveAdapters {
        $a = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
        if (-not $a.Count) { $a = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }) }
        $a
    }

    function Get-CurrentDns {
        $servers = New-Object 'System.Collections.Generic.List[string]'
        foreach ($a in (Get-ActiveAdapters)) {
            $dns = Get-DnsClientServerAddress -InterfaceIndex $a.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
            foreach ($s in $dns.ServerAddresses) { if (-not $servers.Contains($s)) { $servers.Add($s) } }
        }
        , $servers.ToArray()
    }

    function Send-DnsState {
        Send-Ui 'dns' @{ Servers = (Get-CurrentDns) }
    }

    function Set-DnsPreset {
        param([string[]]$Servers, [string]$Name)
        Write-Log "Imposto il DNS $Name..."
        try {
            $adapters = Get-ActiveAdapters
            if (-not $adapters.Count) { throw 'Nessuna scheda di rete attiva trovata.' }
            foreach ($a in $adapters) {
                if (Test-Sim "DNS $($Servers -join ', ') su $($a.InterfaceAlias)") { continue }
                Set-DnsClientServerAddress -InterfaceIndex $a.InterfaceIndex -ServerAddresses $Servers -ErrorAction Stop
                Write-Log "DNS aggiornato su: $($a.InterfaceAlias)"
            }
            if (-not $Sim) { Clear-DnsClientCache }
            Write-Log "DNS $Name impostato." 'SUCCESS'
        } catch { Write-Log "Errore impostazione DNS: $($_.Exception.Message)" 'ERROR' }
        Send-DnsState
    }

    function Reset-DnsAuto {
        Write-Log 'Ripristino del DNS automatico (DHCP)...'
        try {
            foreach ($a in (Get-ActiveAdapters)) {
                if (Test-Sim "reimposta il DNS automatico su $($a.InterfaceAlias)") { continue }
                Set-DnsClientServerAddress -InterfaceIndex $a.InterfaceIndex -ResetServerAddresses -ErrorAction Stop
                Write-Log "DNS reimpostato su: $($a.InterfaceAlias)"
            }
            if (-not $Sim) { Clear-DnsClientCache }
            Write-Log 'DNS ripristinato in modalità automatica.' 'SUCCESS'
        } catch { Write-Log "Errore ripristino DNS: $($_.Exception.Message)" 'ERROR' }
        Send-DnsState
    }

    function Reset-NetworkStack {
        Write-Log 'Ripristino di Winsock e dello stack TCP/IP...'
        $c1 = Invoke-Native 'netsh.exe' @('winsock', 'reset')
        $c2 = Invoke-Native 'netsh.exe' @('int', 'ip', 'reset')
        [void](Invoke-Native 'ipconfig.exe' @('/flushdns'))
        if ($c1 -eq 0 -and $c2 -eq 0) { Write-Log 'Stack di rete ripristinato. Riavvia il computer per completare.' 'SUCCESS' }
        else { Write-Log 'Il ripristino della rete ha restituito un errore (verifica di essere amministratore).' 'ERROR' }
    }

    function Get-RdpEnabled { (Get-RegValue 'HKLM:\System\CurrentControlSet\Control\Terminal Server' 'fDenyTSConnections') -eq 0 }

    function Send-RdpState { Send-Ui 'rdp' @{ Enabled = (Get-RdpEnabled) } }

    function Set-RemoteDesktop {
        param([bool]$Enable)
        try {
            if ($Enable) {
                Write-Log 'Abilitazione di Desktop remoto (RDP)...'
                $sku = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).OperatingSystemSKU
                if ($sku -in 98, 99, 100, 101) {
                    Write-Log 'Windows Home non include l''host Desktop remoto: serve l''edizione Pro o superiore.' 'WARN'
                    return
                }
                Set-RegValue 'HKLM:\System\CurrentControlSet\Control\Terminal Server' 'fDenyTSConnections' 0
                Set-RegValue 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' 'UserAuthentication' 1
                if (-not (Test-Sim 'imposta il servizio TermService su Automatico e lo avvia')) {
                    Set-Service -Name TermService -StartupType Automatic -ErrorAction Stop
                    Start-Service -Name TermService -ErrorAction SilentlyContinue
                }
                if (-not (Test-Sim 'abilita le regole firewall di Desktop remoto')) {
                    # Il gruppo di regole è identificato in modo indipendente dalla lingua di Windows
                    try { Enable-NetFirewallRule -Group '@FirewallAPI.dll,-28752' -ErrorAction Stop }
                    catch { Enable-NetFirewallRule -DisplayGroup 'Desktop remoto', 'Remote Desktop' -ErrorAction SilentlyContinue }
                }
                [void](Invoke-Native 'powercfg.exe' @('-change', '-standby-timeout-ac', '0'))
                $ip = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object { $_.InterfaceAlias -notmatch 'Loopback' -and $_.IPAddress -notmatch '^169\.254\.' }).IPAddress
                Write-Log "Desktop remoto abilitato. Indirizzo IP: $($ip -join ', ')" 'SUCCESS'
            } else {
                Write-Log 'Disabilitazione di Desktop remoto (RDP)...'
                Set-RegValue 'HKLM:\System\CurrentControlSet\Control\Terminal Server' 'fDenyTSConnections' 1
                if (-not (Test-Sim 'disabilita le regole firewall di Desktop remoto')) {
                    try { Disable-NetFirewallRule -Group '@FirewallAPI.dll,-28752' -ErrorAction Stop }
                    catch { Disable-NetFirewallRule -DisplayGroup 'Desktop remoto', 'Remote Desktop' -ErrorAction SilentlyContinue }
                }
                Write-Log 'Desktop remoto disabilitato.' 'SUCCESS'
            }
        } catch { Write-Log "Errore Desktop remoto: $($_.Exception.Message)" 'ERROR' }
        Send-RdpState
    }

    function Reset-WindowsUpdate {
        Write-Log 'Ripristino dei componenti di Windows Update...'
        try {
            Set-ServiceRunning @('wuauserv', 'bits', 'cryptsvc') $false
            if (-not (Test-Sim 'svuota SoftwareDistribution\Download')) {
                Remove-Item -Path "$env:WINDIR\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
            }
            Set-ServiceRunning @('cryptsvc', 'bits', 'wuauserv') $true
            Write-Log 'Componenti di Windows Update riavviati e cache svuotata.' 'SUCCESS'
        } catch { Write-Log "Errore Windows Update: $($_.Exception.Message)" 'ERROR' }
    }

    # ---------------------------------------------------------------- app di avvio
    # Stesse fonti e stesso meccanismo di Gestione attività: lo stato attivo/disattivo sta nelle chiavi
    # StartupApproved (12 byte: primo byte pari = attiva, dispari = disattivata, poi la data della modifica).
    $KeyApproved = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
    $StartupSources = @(
        @{ Kind = 'reg'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Approved = "HKCU:\$KeyApproved\Run"; Label = 'Registro · utente' },
        @{ Kind = 'reg'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Approved = "HKLM:\$KeyApproved\Run"; Label = 'Registro · tutti gli utenti' },
        @{ Kind = 'reg'; Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = "HKLM:\$KeyApproved\Run32"; Label = 'Registro 32 bit · tutti gli utenti' },
        @{ Kind = 'folder'; Path = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"; Approved = "HKCU:\$KeyApproved\StartupFolder"; Label = 'Cartella Esecuzione automatica · utente' },
        @{ Kind = 'folder'; Path = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp"; Approved = "HKLM:\$KeyApproved\StartupFolder"; Label = 'Cartella Esecuzione automatica · tutti gli utenti' }
    )

    # Ricava l'eseguibile da una riga di comando ("C:\x\app.exe" -arg  oppure  C:\x\app.exe /arg)
    function Get-ExePath {
        param([string]$Command)
        if ([string]::IsNullOrWhiteSpace($Command)) { return $null }
        $c = [Environment]::ExpandEnvironmentVariables($Command.Trim())
        if ($c.StartsWith('"')) {
            $end = $c.IndexOf('"', 1)
            if ($end -gt 1) { return $c.Substring(1, $end - 1) }
        }
        $m = [regex]::Match($c, '^(.*?\.(exe|com|bat|cmd))(\s|$)', 'IgnoreCase')
        if ($m.Success) { return $m.Groups[1].Value }
        ($c -split '\s+')[0]
    }

    function Get-StartupApps {
        param([object[]]$Sources = $StartupSources)
        $list = New-Object System.Collections.ArrayList
        $shell = $null
        foreach ($src in $Sources) {
            $entries = @()
            if ($src.Kind -eq 'reg') {
                if (-not (Test-Path -LiteralPath $src.Path)) { continue }
                $key = Get-Item -LiteralPath $src.Path
                foreach ($n in $key.GetValueNames()) {
                    if ($n -eq '') { continue }
                    $cmd = [string]$key.GetValue($n)
                    $entries += @{ Name = $n; ValueName = $n; Command = $cmd; Exe = (Get-ExePath $cmd) }
                }
            } else {
                if (-not (Test-Path -LiteralPath $src.Path)) { continue }
                foreach ($f in @(Get-ChildItem -LiteralPath $src.Path -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' })) {
                    $target = $f.FullName
                    if ($f.Extension -eq '.lnk') {
                        try {
                            if (-not $shell) { $shell = New-Object -ComObject WScript.Shell }
                            $lnk = $shell.CreateShortcut($f.FullName)
                            if ($lnk.TargetPath) { $target = $lnk.TargetPath; $cmd = ('"{0}" {1}' -f $lnk.TargetPath, $lnk.Arguments).Trim() }
                        } catch { $cmd = $f.FullName }
                    } else { $cmd = $f.FullName }
                    $entries += @{ Name = $f.BaseName; ValueName = $f.Name; Command = $cmd; Exe = $target; File = $f.FullName }
                }
            }
            foreach ($e in $entries) {
                # (il valore binario esce dalla funzione come object[]: si guarda solo il primo byte)
                $flag = @(Get-RegValue $src.Approved $e.ValueName)
                $e.Enabled = -not ($flag.Count -gt 0 -and $null -ne $flag[0] -and ([int]$flag[0] % 2) -eq 1)
                $e.Kind = $src.Kind; $e.Path = $src.Path; $e.Approved = $src.Approved; $e.Source = $src.Label
                [void]$list.Add($e)
            }
        }
        $list.ToArray()     # emessi uno a uno: i chiamanti usano @(...)
    }

    function Set-StartupEnabled {
        param([hashtable]$App, [bool]$Enabled)
        $verb = if ($Enabled) { 'Attivata' } else { 'Disattivata' }
        if (Test-Sim ("{0} all'avvio: {1}" -f $verb.ToLowerInvariant(), $App.Name)) { return }
        [byte[]]$data = if ($Enabled) { , 0 * 12 } else { , 0 * 4 + [BitConverter]::GetBytes((Get-Date).ToFileTime()) }
        $data[0] = if ($Enabled) { 2 } else { 3 }
        if (-not (Test-Path -LiteralPath $App.Approved)) { New-Item -Path $App.Approved -Force -ErrorAction Stop | Out-Null }
        New-ItemProperty -LiteralPath $App.Approved -Name $App.ValueName -Value $data -PropertyType Binary -Force -ErrorAction Stop | Out-Null
        Write-Log "$verb all'avvio: $($App.Name)" 'SUCCESS'
    }

    # Cartella delle copie di sicurezza: accanto all'app, oppure in %LOCALAPPDATA% se il supporto è in sola lettura
    function Get-BackupDir {
        param([string]$Sub)
        foreach ($base in @((Join-Path $script:AppDir 'Backup'), (Join-Path $env:LOCALAPPDATA 'WinOptima\Backup'))) {
            try {
                $d = Join-Path $base $Sub
                if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop | Out-Null }
                $probe = Join-Path $d '.scrittura'
                [IO.File]::WriteAllText($probe, ''); [IO.File]::Delete($probe)
                return $d
            } catch {}
        }
        throw 'Nessuna cartella scrivibile per la copia di sicurezza.'
    }

    # Elimina la voce dall'avvio dopo averne salvato una copia ripristinabile (.reg o il collegamento stesso)
    function Remove-StartupApp {
        param([hashtable]$App)
        if (Test-Sim "elimina dall'avvio: $($App.Name) ($($App.Source))") { return $null }
        $dir = Get-BackupDir 'Avvio'
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $safe = ($App.Name -replace '[\\/:*?"<>|]', '_')
        if ($App.Kind -eq 'reg') {
            $regKey = $App.Path -replace '^HKCU:', 'HKEY_CURRENT_USER' -replace '^HKLM:', 'HKEY_LOCAL_MACHINE'
            $esc = { param($s) $s.Replace('\', '\\').Replace('"', '\"') }
            $backup = Join-Path $dir "$stamp $safe.reg"
            $reg = "Windows Registry Editor Version 5.00`r`n`r`n[$regKey]`r`n`"$(& $esc $App.ValueName)`"=`"$(& $esc $App.Command)`"`r`n"
            [IO.File]::WriteAllText($backup, $reg, [Text.Encoding]::Unicode)
            Remove-ItemProperty -LiteralPath $App.Path -Name $App.ValueName -ErrorAction Stop
        } else {
            $backup = Join-Path $dir "$stamp $($App.ValueName)"
            Move-Item -LiteralPath $App.File -Destination $backup -Force -ErrorAction Stop
        }
        Remove-ItemProperty -LiteralPath $App.Approved -Name $App.ValueName -ErrorAction SilentlyContinue
        Write-Log "Eliminata dall'avvio: $($App.Name). Copia di sicurezza: $backup" 'SUCCESS'
        $backup
    }

    # ---------------------------------------------------------------- icone dell'area di notifica
    # Windows 11 (22H2+) salva una sottochiave per icona in HKCU\Control Panel\NotifyIconSettings:
    # IsPromoted = 1 la tiene visibile sulla barra, 0 la sposta nel menu «^» delle icone nascoste.
    $KeyNotify = 'HKCU:\Control Panel\NotifyIconSettings'
    $KnownFolders = @{
        '{6D809377-6AF0-444B-8957-A3773F02200E}' = $env:ProgramFiles
        '{905E63B6-C1BF-494E-B29C-65B732D3D21A}' = $env:ProgramFiles
        '{7C5A40EF-A0FB-4BFC-874A-C0F2E0B9FA8E}' = ${env:ProgramFiles(x86)}
        '{F38BF404-1D43-42F2-9305-67DE0B28FC23}' = $env:WINDIR
        '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}' = "$env:WINDIR\System32"
        '{D65231B0-B2F1-4857-A4CE-A8E7C6EA7D27}' = "$env:WINDIR\SysWOW64"
        '{F1B32785-6FBA-4FCF-9D55-7B8E7F157091}' = $env:LOCALAPPDATA
        '{3EB685DB-65F9-4CF6-A03A-E3EF65729F3D}' = $env:APPDATA
        '{62AB5D82-FDC1-4DC3-A9DD-070D1D495D97}' = $env:ProgramData
        '{5E6C858F-0E22-4760-9AFE-EA3317B67173}' = $env:USERPROFILE
    }

    function Resolve-KnownFolderPath {
        param([string]$Path)
        if ($Path -match '^(\{[0-9A-Fa-f-]{36}\})(.*)$') {
            $base = $KnownFolders[$Matches[1].ToUpperInvariant()]
            if ($base) { return $base + $Matches[2] }
        }
        $Path
    }

    # $null = funzione non disponibile (Windows 10 o Windows 11 21H2)
    function Get-TrayIcons {
        param([string]$Root = $KeyNotify)
        if (-not (Test-Path -LiteralPath $Root)) { return $null }
        $groups = [ordered]@{}
        foreach ($k in @(Get-ChildItem -LiteralPath $Root -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            if (-not $p.ExecutablePath) { continue }
            $exe = Resolve-KnownFolderPath $p.ExecutablePath
            $id = $exe.ToLowerInvariant()
            if (-not $groups.Contains($id)) {
                $name = $null
                if ($p.InitialTooltip) { $name = (($p.InitialTooltip -split "`n")[0]).Trim() }
                if (-not $name -and (Test-Path -LiteralPath $exe)) { try { $name = (Get-Item -LiteralPath $exe).VersionInfo.FileDescription } catch {} }
                if (-not $name) { $name = [IO.Path]::GetFileNameWithoutExtension($exe) }
                $groups[$id] = @{ Name = $name.Trim(); Exe = $exe; Exists = (Test-Path -LiteralPath $exe); Promoted = $false; Keys = (New-Object System.Collections.ArrayList) }
            }
            [void]$groups[$id].Keys.Add($k.PSPath)
            if ($p.IsPromoted -eq 1) { $groups[$id].Promoted = $true }
        }
        # Emessi uno a uno (i chiamanti usano @(...)); elenco vuoto = array vuoto, distinto da $null = non supportato
        $sorted = @($groups.Values | Sort-Object { $_.Name })
        if ($sorted.Count) { $sorted } else { , @() }
    }

    function Set-TrayIconPromoted {
        param([hashtable]$Icon, [bool]$Promoted)
        $what = if ($Promoted) { 'visibile sulla barra' } else { 'nel menu delle icone nascoste' }
        if (Test-Sim "icona «$($Icon.Name)» $what") { return }
        foreach ($k in $Icon.Keys) {
            New-ItemProperty -LiteralPath $k -Name 'IsPromoted' -Value $(if ($Promoted) { 1 } else { 0 }) -PropertyType DWord -Force -ErrorAction Stop | Out-Null
        }
        Write-Log "Icona «$($Icon.Name)»: $what." 'SUCCESS'
    }

    # ---------------------------------------------------------------- app preinstallate
    # App dello Store che di solito si rimuovono volentieri (nome pacchetto -> nome leggibile)
    $BloatApps = [ordered]@{
        'Microsoft.MicrosoftOfficeHub' = 'Microsoft 365 (Office)'; 'Microsoft.Office.OneNote' = 'OneNote per Windows 10'
        'Microsoft.BingNews' = 'Notizie'; 'Microsoft.BingWeather' = 'Meteo'; 'Microsoft.BingSearch' = 'Ricerca Bing'
        'Microsoft.BingFinance' = 'Finanza'; 'Microsoft.BingSports' = 'Sport'; 'Microsoft.GetHelp' = 'Assistenza'
        'Microsoft.Getstarted' = 'Suggerimenti'; 'Microsoft.MicrosoftSolitaireCollection' = 'Microsoft Solitaire Collection'
        'Microsoft.People' = 'Contatti'; 'Microsoft.WindowsFeedbackHub' = 'Hub di Feedback'; 'Microsoft.ZuneVideo' = 'Film e TV'
        'Microsoft.SkypeApp' = 'Skype'; 'Microsoft.Todos' = 'Microsoft To Do'; 'Microsoft.PowerAutomateDesktop' = 'Power Automate'
        'Clipchamp.Clipchamp' = 'Clipchamp'; 'Microsoft.549981C3F5F10' = 'Cortana'; 'Microsoft.WindowsMaps' = 'Mappe'
        'Microsoft.MixedReality.Portal' = 'Portale realtà mista'; 'Microsoft.Microsoft3DViewer' = 'Visualizzatore 3D'
        'Microsoft.MSPaint' = 'Paint 3D'; 'MicrosoftTeams' = 'Microsoft Teams (personale)'; 'MSTeams' = 'Microsoft Teams'
        'Microsoft.MicrosoftJournal' = 'Journal'; 'Microsoft.Wallet' = 'Wallet'; 'Microsoft.Messaging' = 'Messaggi'
        'Microsoft.OneConnect' = 'Piani mobili'; 'Microsoft.Print3D' = 'Stampa 3D'; 'MicrosoftCorporationII.MicrosoftFamily' = 'Microsoft Family'
        'Microsoft.Windows.DevHome' = 'Dev Home'; 'Microsoft.MicrosoftPCManager' = 'PC Manager'
    }
    # App di terze parti installate dai produttori o da Windows come «promozione»
    $BloatPattern = 'king\.com|Facebook|Instagram|TikTok|Spotify|Disney|PrimeVideo|AmazonVideo|Netflix|LinkedIn|Twitter|' +
        'CandyCrush|BubbleWitch|MarchofEmpires|Booking|McAfee|Norton|ExpressVPN|Dropbox|WildTangent|HiddenCity|Royal\s?Revolt|' +
        'Duolingo|PicsArt|Flipboard|ShazamEntertainment|Keeper|Plex|Hulu|CyberLink|Asphalt|FarmVille|Roblox'
    # Pacchetti da non mostrare mai: componenti di sistema, librerie, codec, driver e utilità hardware
    $KeepAppPattern = '^Microsoft\.(WindowsStore|DesktopAppInstaller|StorePurchaseApp|Services\.Store|VCLibs|UI\.Xaml|NET\.|' +
        'WindowsAppRuntime|SecHealthUI|Windows\.|WebpImageExtension|HEIFImageExtension|HEVCVideoExtension|VP9VideoExtensions|' +
        'AV1VideoExtension|MPEG2VideoExtension|RawImageExtension|WebMediaExtensions|AVCEncoderVideoExtension|' +
        'ApplicationCompatibilityEnhancements|WidgetsPlatformRuntime|LanguageExperiencePack|Winget|WindowsTerminal|' +
        'Paint|ScreenSketch|WindowsNotepad|WindowsCalculator|Photos|ImmersiveControlPanel|MicrosoftEdge|Edge\.Stable)|' +
        '^MicrosoftWindows\.|^Windows\.|^windows\.|NVIDIA|Realtek|RealtekSemiconductor|Intel|AMD|AdvancedMicroDevices|Dolby|DTS|' +
        'Synaptics|ELAN|Waves|Conexant|Nahimic|AppUp\.|DellInc\.Dell(Optimizer|Power|Display|Digital)|HPAudio|LenovoCorporation\.LenovoVantage'

    function Get-RemovableApps {
        $names = @{}
        try { foreach ($s in Get-StartApps) { if ($s.AppID -match '^([^!]+)!') { $names[$Matches[1]] = $s.Name } } } catch {}
        $seen = @{}
        foreach ($p in @(Get-AppxPackage -ErrorAction SilentlyContinue | Sort-Object Name)) {
            if ($p.IsFramework -or $p.NonRemovable -or $p.SignatureKind -eq 'System') { continue }
            if ($seen.ContainsKey($p.PackageFamilyName)) { continue }
            if (-not $BloatApps.Contains($p.Name) -and $p.Name -match $KeepAppPattern) { continue }
            $seen[$p.PackageFamilyName] = $true
            $display = if ($BloatApps.Contains($p.Name)) { $BloatApps[$p.Name] }
                elseif ($names[$p.PackageFamilyName]) { $names[$p.PackageFamilyName] }
                else { ($p.Name -replace '^[^.]+\.', '') -creplace '([a-z])([A-Z])', '$1 $2' }
            @{
                Name = $p.Name; FullName = $p.PackageFullName; Family = $p.PackageFamilyName
                Display = $display; Version = "$($p.Version)"; Publisher = $(if ($p.Publisher -match '^CN="?([^,"]+)' -and $Matches[1] -notmatch '^[0-9A-Fa-f-]{36}$') { $Matches[1] } else { 'editore non indicato' })
                Rec = ($BloatApps.Contains($p.Name) -or $p.Name -match $BloatPattern)
            }
        }
    }

    function Remove-Apps {
        param([object[]]$Apps, [bool]$Deprovision)
        $ok = 0; $fail = 0; $i = 0
        Write-Log "--- RIMOZIONE DI $($Apps.Count) APP ---"
        $prov = @()
        if ($Deprovision -and -not $Sim) { try { $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop) } catch { Write-Log "Elenco dei pacchetti di provisioning non disponibile: $($_.Exception.Message)" 'WARN' } }
        foreach ($a in $Apps) {
            Send-Ui 'progress' @{ Value = $i; Max = $Apps.Count; Text = "Rimuovo: $($a.Display)" }
            $i++
            if (Test-Sim "rimuove l'app $($a.Display) ($($a.FullName))$(if ($Deprovision) { ' e il pacchetto di provisioning' })") { $ok++; continue }
            try {
                Remove-AppxPackage -Package $a.FullName -ErrorAction Stop
                foreach ($pp in @($prov | Where-Object { $_.DisplayName -eq $a.Name })) {
                    try { Remove-AppxProvisionedPackage -Online -PackageName $pp.PackageName -ErrorAction Stop | Out-Null; Write-Log "Non verrà reinstallata per i nuovi utenti: $($a.Display)" }
                    catch { Write-Log "Provisioning di $($a.Display) non rimosso: $($_.Exception.Message)" 'WARN' }
                }
                Write-Log "Rimossa: $($a.Display)" 'SUCCESS'; $ok++
            } catch { Write-Log ("$($a.Display): " + (($_.Exception.Message -split "`r?`n")[0])) 'ERROR'; $fail++ }
        }
        Send-Ui 'progress' @{ Value = $Apps.Count; Max = $Apps.Count; Text = 'Completato' }
        Send-Ui 'summary' @{ Ok = $ok; Fail = $fail; Freed = 0; Sim = $Sim; AppsRemoved = $true }
    }

    # Programmi desktop tipicamente preinstallati (Office Click-to-Run in più lingue, antivirus in prova…)
    $PreinstalledProgramPattern = '^Microsoft 365|^Microsoft Office|^Microsoft OneNote|^Microsoft Project|^Microsoft Visio|McAfee|Norton|' +
        'WildTangent|ExpressVPN|Booking\.com|Dropbox (Promotion|Offer)|Avast Free|AVG|Candy Crush|Spotify'
    function Get-PreinstalledPrograms {
        $roots = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
        $seen = @{}
        foreach ($r in $roots) {
            foreach ($k in @(Get-ChildItem -LiteralPath $r -ErrorAction SilentlyContinue)) {
                $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
                if (-not $p.DisplayName -or -not $p.UninstallString -or $p.SystemComponent -eq 1) { continue }
                if ($p.DisplayName -notmatch $PreinstalledProgramPattern -or $seen.ContainsKey($p.DisplayName)) { continue }
                $seen[$p.DisplayName] = $true
                @{ Name = $p.DisplayName; Publisher = $p.Publisher; Version = $p.DisplayVersion; Uninstall = $p.UninstallString
                    SizeMB = $(if ($p.EstimatedSize) { [math]::Round($p.EstimatedSize / 1024) } else { 0 }) }
            }
        }
    }

    function Send-BloatState {
        $apps = @(Get-RemovableApps)
        $progs = @(Get-PreinstalledPrograms)
        Send-Ui 'bloat' @{ Apps = $apps; Programs = $progs }
    }

    # ---------------------------------------------------------------- aggiornamenti da GitHub
    $UpdateRepo = 'brn78/WinOptima'

    function ConvertTo-AppVersion {
        param([string]$Text)
        $t = ($Text -replace '^[vV]', '').Trim()
        if ($t -notmatch '^\d+(\.\d+){1,3}$') { return $null }
        if ($t -notmatch '\.') { $t += '.0' }
        [version]$t
    }

    # Controlla l'ultima release pubblicata; invia 'update' alla UI solo se è più recente di $CurrentVersion
    function Find-AppUpdate {
        param([string]$CurrentVersion, [switch]$Manual)
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$UpdateRepo/releases/latest" -TimeoutSec 15 `
                -Headers @{ 'User-Agent' = 'WinOptima-Updater'; 'Accept' = 'application/vnd.github+json' } -ErrorAction Stop
            $latest = ConvertTo-AppVersion $rel.tag_name
            $current = ConvertTo-AppVersion $CurrentVersion
            $asset = @($rel.assets | Where-Object { $_.name -eq 'WinOptima.exe' }) | Select-Object -First 1
            if ($latest -and $current -and $latest -gt $current -and $asset) {
                $digest = if ($asset.PSObject.Properties['digest'] -and $asset.digest -like 'sha256:*') { $asset.digest.Substring(7) } else { '' }
                Send-Ui 'update' @{ Version = "$latest"; Url = $asset.browser_download_url; Size = [int64]$asset.size; Sha256 = $digest; Page = $rel.html_url; Notes = [string]$rel.body }
            } elseif ($Manual) {
                Send-Ui 'update' @{ Version = ''; Current = $true }
                Write-Log "WinOptima è aggiornato (versione $CurrentVersion, ultima pubblicata $($rel.tag_name))." 'SUCCESS'
            }
        } catch {
            if ($Manual) { Write-Log "Controllo aggiornamenti non riuscito: $($_.Exception.Message)" 'WARN'; Send-Ui 'update' @{ Version = ''; Failed = $true } }
        }
    }

    # Scarica il nuovo exe in AppData e ne verifica dimensione, intestazione e (se fornito da GitHub) SHA-256
    function Save-AppUpdate {
        param([string]$Url, [int64]$Size, [string]$Sha256, [string]$Version)
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $dir = Join-Path $env:LOCALAPPDATA 'WinOptima\update'
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            Get-ChildItem -LiteralPath $dir -Filter '*.exe' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
            $dest = Join-Path $dir "WinOptima-$Version.exe"
            Write-Log "Download di WinOptima $Version…"
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add('User-Agent', 'WinOptima-Updater')
            $wc.DownloadFile($Url, $dest)
            $bytes = [IO.File]::ReadAllBytes($dest)
            if ($Size -gt 0 -and $bytes.Length -ne $Size) { throw "dimensione inattesa ($($bytes.Length) invece di $Size byte)" }
            if ($bytes.Length -lt 2 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) { throw 'il file scaricato non è un eseguibile valido' }
            if ($Sha256) {
                $h = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash
                if ($h -ne $Sha256.ToUpperInvariant()) { throw 'impronta SHA-256 non corrispondente' }
            }
            Write-Log "Aggiornamento $Version scaricato e verificato." 'SUCCESS'
            Send-Ui 'updateReady' @{ Path = $dest; Version = $Version }
        } catch {
            Write-Log "Download dell'aggiornamento non riuscito: $($_.Exception.Message)" 'WARN'
            Send-Ui 'updateReady' @{ Path = ''; Version = $Version }
        }
    }

    # ---------------------------------------------------------------- informazioni di sistema
    function Send-SystemInfo {
        try {
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
            $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
            $gpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -First 1
            $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
            Send-Ui 'sysinfo' @{
                OS      = ($os.Caption -replace '^Microsoft\s+', '')
                Build   = $os.BuildNumber
                Version = $os.Version
                Cpu     = ($cpu.Name -replace '\s+', ' ').Trim()
                Cores   = $cpu.NumberOfCores
                Threads = $cpu.NumberOfLogicalProcessors
                Gpu     = $gpu.Name
                RamGB   = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
                Machine = $cs.Model
                Boot    = $os.LastBootUpTime
            }
        } catch { Write-Log "Impossibile leggere alcune informazioni hardware: $($_.Exception.Message)" 'WARN' }
    }
}

. $Engine


# ======================================================================================
#  INTERFACCIA - struttura della finestra e stile Fluent (Windows 11)
#  I colori sono pennelli "dinamici" (DynamicResource): cambiando tema o colore di accento
#  vengono semplicemente sostituiti da Set-AppTheme e tutta la UI si aggiorna.
# ======================================================================================
$WindowXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        x:Name="Win" Title="WinOptima Portable"
        Width="1180" Height="800" MinWidth="960" MinHeight="640"
        WindowStartupLocation="CenterScreen"
        Background="{DynamicResource WindowBase}"
        Foreground="{DynamicResource TextPrimary}"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="14"
        UseLayoutRounding="True" SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Ideal" TextOptions.TextRenderingMode="ClearType">

  <Window.Resources>
    <!-- ================= PENNELLI (valori scuri di partenza, sostituiti da Set-AppTheme) ================= -->
    <SolidColorBrush x:Key="WindowBase" Color="#202020"/>
    <SolidColorBrush x:Key="LayerFill" Color="#992E2E2E"/>
    <SolidColorBrush x:Key="LogFill" Color="#26000000"/>
    <SolidColorBrush x:Key="TextPrimary" Color="#FFFFFF"/>
    <SolidColorBrush x:Key="TextSecondary" Color="#C5FFFFFF"/>
    <SolidColorBrush x:Key="TextTertiary" Color="#87FFFFFF"/>
    <SolidColorBrush x:Key="TextDisabled" Color="#5DFFFFFF"/>
    <SolidColorBrush x:Key="TextOnAccent" Color="#000000"/>
    <SolidColorBrush x:Key="CardFill" Color="#0DFFFFFF"/>
    <SolidColorBrush x:Key="CardFillHover" Color="#14FFFFFF"/>
    <SolidColorBrush x:Key="CardStroke" Color="#14FFFFFF"/>
    <SolidColorBrush x:Key="ControlFill" Color="#0FFFFFFF"/>
    <SolidColorBrush x:Key="ControlFillHover" Color="#15FFFFFF"/>
    <SolidColorBrush x:Key="ControlFillPressed" Color="#08FFFFFF"/>
    <SolidColorBrush x:Key="ControlFillDisabled" Color="#0BFFFFFF"/>
    <SolidColorBrush x:Key="ControlStroke" Color="#18FFFFFF"/>
    <SolidColorBrush x:Key="SubtleHover" Color="#0FFFFFFF"/>
    <SolidColorBrush x:Key="SubtlePressed" Color="#0AFFFFFF"/>
    <SolidColorBrush x:Key="SubtleSelected" Color="#17FFFFFF"/>
    <SolidColorBrush x:Key="Accent" Color="#60CDFF"/>
    <SolidColorBrush x:Key="AccentHover" Color="#E660CDFF"/>
    <SolidColorBrush x:Key="AccentPressed" Color="#CC60CDFF"/>
    <SolidColorBrush x:Key="AccentDisabled" Color="#28FFFFFF"/>
    <SolidColorBrush x:Key="ToggleOffStroke" Color="#9BFFFFFF"/>
    <SolidColorBrush x:Key="ToggleOffKnob" Color="#C5FFFFFF"/>
    <SolidColorBrush x:Key="ToggleOnKnob" Color="#000000"/>
    <SolidColorBrush x:Key="ProgressTrack" Color="#2EFFFFFF"/>
    <SolidColorBrush x:Key="ScrollThumb" Color="#7DFFFFFF"/>
    <SolidColorBrush x:Key="ScrollThumbHover" Color="#C5FFFFFF"/>
    <SolidColorBrush x:Key="DialogFill" Color="#2C2C2C"/>
    <SolidColorBrush x:Key="DialogFooterFill" Color="#212121"/>
    <SolidColorBrush x:Key="Scrim" Color="#66000000"/>
    <SolidColorBrush x:Key="Divider" Color="#14FFFFFF"/>
    <SolidColorBrush x:Key="SuccessText" Color="#6CCB5F"/>
    <SolidColorBrush x:Key="SuccessFill" Color="#393D1B"/>
    <SolidColorBrush x:Key="WarnText" Color="#FCE100"/>
    <SolidColorBrush x:Key="WarnFill" Color="#433519"/>
    <SolidColorBrush x:Key="ErrorText" Color="#FF99A4"/>
    <SolidColorBrush x:Key="ErrorFill" Color="#442726"/>
    <SolidColorBrush x:Key="InfoText" Color="#99DDFF"/>
    <SolidColorBrush x:Key="InfoFill" Color="#26323B"/>

    <!-- ================= TIPOGRAFIA ================= -->
    <Style x:Key="TxtTitle" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Segoe UI Variable Display, Segoe UI"/>
      <Setter Property="FontSize" Value="28"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="TxtSubtitle" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Segoe UI Variable Display, Segoe UI"/>
      <Setter Property="FontSize" Value="20"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="TxtBodyStrong" TargetType="TextBlock">
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="TxtSecondary" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource TextSecondary}"/>
    </Style>
    <Style x:Key="TxtCaption" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="{DynamicResource TextSecondary}"/>
    </Style>
    <Style x:Key="Glyph" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Segoe Fluent Icons, Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="16"/>
      <Setter Property="TextOptions.TextRenderingMode" Value="Auto"/>
    </Style>

    <!-- ================= SUPERFICI ================= -->
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="{DynamicResource CardFill}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource CardStroke}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="4"/>
    </Style>

    <!-- ================= PULSANTI ================= -->
    <Style x:Key="BaseButton" TargetType="Button">
      <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
      <Setter Property="Padding" Value="16,5,16,6"/>
      <Setter Property="MinHeight" Value="32"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    </Style>

    <Style TargetType="Button" BasedOn="{StaticResource BaseButton}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{DynamicResource ControlFill}" BorderBrush="{DynamicResource ControlStroke}"
                    BorderThickness="1" CornerRadius="4" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="True"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="{DynamicResource ControlFillHover}"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource Accent}"/></Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource ControlFillPressed}"/>
                <Setter Property="Foreground" Value="{DynamicResource TextSecondary}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource ControlFillDisabled}"/>
                <Setter Property="Foreground" Value="{DynamicResource TextDisabled}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="AccentButton" TargetType="Button" BasedOn="{StaticResource BaseButton}">
      <Setter Property="Foreground" Value="{DynamicResource TextOnAccent}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{DynamicResource Accent}" BorderBrush="{DynamicResource ControlStroke}"
                    BorderThickness="1" CornerRadius="4" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="True"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="{DynamicResource AccentHover}"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Bd" Property="Background" Value="{DynamicResource AccentPressed}"/></Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource AccentDisabled}"/>
                <Setter Property="Foreground" Value="{DynamicResource TextDisabled}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="SubtleButton" TargetType="Button" BasedOn="{StaticResource BaseButton}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="Transparent" CornerRadius="4" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="True"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="{DynamicResource SubtleHover}"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Bd" Property="Background" Value="{DynamicResource SubtlePressed}"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Foreground" Value="{DynamicResource TextDisabled}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ================= TOGGLE SWITCH (ToggleButton) ================= -->
    <Style x:Key="ToggleSwitch" TargetType="ToggleButton">
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToggleButton">
            <Grid x:Name="Root" Background="Transparent" Width="40" Height="20">
              <Border x:Name="Track" CornerRadius="10" BorderThickness="1"
                      Background="Transparent" BorderBrush="{DynamicResource ToggleOffStroke}"/>
              <Ellipse x:Name="Knob" Width="12" Height="12" HorizontalAlignment="Left" Margin="4,0,0,0"
                       Fill="{DynamicResource ToggleOffKnob}"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Knob" Property="Width" Value="14"/><Setter TargetName="Knob" Property="Height" Value="14"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="{DynamicResource Accent}"/>
                <Setter TargetName="Track" Property="BorderBrush" Value="{DynamicResource Accent}"/>
                <Setter TargetName="Knob" Property="Fill" Value="{DynamicResource ToggleOnKnob}"/>
                <Trigger.EnterActions>
                  <BeginStoryboard><Storyboard>
                    <ThicknessAnimation Storyboard.TargetName="Knob" Storyboard.TargetProperty="Margin" To="23,0,0,0" Duration="0:0:0.13">
                      <ThicknessAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></ThicknessAnimation.EasingFunction>
                    </ThicknessAnimation>
                  </Storyboard></BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard><Storyboard>
                    <ThicknessAnimation Storyboard.TargetName="Knob" Storyboard.TargetProperty="Margin" To="4,0,0,0" Duration="0:0:0.13">
                      <ThicknessAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></ThicknessAnimation.EasingFunction>
                    </ThicknessAnimation>
                  </Storyboard></BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Root" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ================= CHECKBOX ================= -->
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid x:Name="Root" Background="Transparent">
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Border x:Name="Box" Width="20" Height="20" CornerRadius="4" BorderThickness="1" VerticalAlignment="Center"
                      BorderBrush="{DynamicResource ToggleOffStroke}" Background="{DynamicResource ControlFill}">
                <Path x:Name="Mark" Data="M 4.5,9.5 L 8,13 L 14.5,6" Stretch="None" Visibility="Collapsed"
                      Stroke="{DynamicResource TextOnAccent}" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
              </Border>
              <ContentPresenter Grid.Column="1" Margin="10,0,0,0" VerticalAlignment="Center" RecognizesAccessKey="True"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="Background" Value="{DynamicResource ControlFillHover}"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Box" Property="Background" Value="{DynamicResource Accent}"/>
                <Setter TargetName="Box" Property="BorderBrush" Value="{DynamicResource Accent}"/>
                <Setter TargetName="Mark" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Root" Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ================= VOCI DI NAVIGAZIONE ================= -->
    <Style x:Key="NavItem" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Height" Value="40"/>
      <Setter Property="Margin" Value="0,1"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Grid Margin="8,0" Background="Transparent">
              <Border x:Name="Bd" CornerRadius="4" Background="Transparent"/>
              <Border x:Name="Ind" Width="3" Height="16" CornerRadius="1.5" HorizontalAlignment="Left" VerticalAlignment="Center"
                      Background="{DynamicResource Accent}" Visibility="Collapsed"/>
              <ContentPresenter Margin="14,0,8,0" VerticalAlignment="Center"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="{DynamicResource SubtleHover}"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Bd" Property="Background" Value="{DynamicResource SubtlePressed}"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource SubtleSelected}"/>
                <Setter TargetName="Ind" Property="Visibility" Value="Visible"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ================= SCROLLBAR SOTTILE ================= -->
    <Style x:Key="ScrollPageBtn" TargetType="RepeatButton">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="IsTabStop" Value="False"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="ScrollThumbV" TargetType="Thumb">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Border x:Name="T" Background="{DynamicResource ScrollThumb}" CornerRadius="3" Margin="5,2"/>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="T" Property="Margin" Value="4,2"/><Setter TargetName="T" Property="Background" Value="{DynamicResource ScrollThumbHover}"/></Trigger>
              <Trigger Property="IsDragging" Value="True"><Setter TargetName="T" Property="Margin" Value="4,2"/><Setter TargetName="T" Property="Background" Value="{DynamicResource ScrollThumbHover}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="ScrollThumbH" TargetType="Thumb">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Border x:Name="T" Background="{DynamicResource ScrollThumb}" CornerRadius="3" Margin="2,5"/>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="T" Property="Margin" Value="2,4"/><Setter TargetName="T" Property="Background" Value="{DynamicResource ScrollThumbHover}"/></Trigger>
              <Trigger Property="IsDragging" Value="True"><Setter TargetName="T" Property="Margin" Value="2,4"/><Setter TargetName="T" Property="Background" Value="{DynamicResource ScrollThumbHover}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <ControlTemplate x:Key="VScrollTpl" TargetType="ScrollBar">
      <Grid Background="Transparent" Width="14">
        <Track x:Name="PART_Track" IsDirectionReversed="True">
          <Track.DecreaseRepeatButton><RepeatButton Command="ScrollBar.PageUpCommand" Style="{StaticResource ScrollPageBtn}"/></Track.DecreaseRepeatButton>
          <Track.IncreaseRepeatButton><RepeatButton Command="ScrollBar.PageDownCommand" Style="{StaticResource ScrollPageBtn}"/></Track.IncreaseRepeatButton>
          <Track.Thumb><Thumb Style="{StaticResource ScrollThumbV}"/></Track.Thumb>
        </Track>
      </Grid>
    </ControlTemplate>
    <ControlTemplate x:Key="HScrollTpl" TargetType="ScrollBar">
      <Grid Background="Transparent" Height="14">
        <Track x:Name="PART_Track">
          <Track.DecreaseRepeatButton><RepeatButton Command="ScrollBar.PageLeftCommand" Style="{StaticResource ScrollPageBtn}"/></Track.DecreaseRepeatButton>
          <Track.IncreaseRepeatButton><RepeatButton Command="ScrollBar.PageRightCommand" Style="{StaticResource ScrollPageBtn}"/></Track.IncreaseRepeatButton>
          <Track.Thumb><Thumb Style="{StaticResource ScrollThumbH}"/></Track.Thumb>
        </Track>
      </Grid>
    </ControlTemplate>
    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template" Value="{StaticResource VScrollTpl}"/>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal"><Setter Property="Template" Value="{StaticResource HScrollTpl}"/></Trigger>
      </Style.Triggers>
    </Style>

    <!-- ================= PROGRESS BAR ================= -->
    <Style TargetType="ProgressBar">
      <Setter Property="Height" Value="4"/>
      <Setter Property="Foreground" Value="{DynamicResource Accent}"/>
      <Setter Property="Background" Value="{DynamicResource ProgressTrack}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Grid ClipToBounds="True">
              <Border x:Name="PART_Track" CornerRadius="2" Background="{TemplateBinding Background}"/>
              <Border x:Name="PART_Indicator" HorizontalAlignment="Left" CornerRadius="2" Background="{TemplateBinding Foreground}"/>
              <Border x:Name="Indet" Visibility="Collapsed" HorizontalAlignment="Left" Width="60" CornerRadius="2"
                      Background="{TemplateBinding Foreground}" Margin="-60,0,0,0"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsIndeterminate" Value="True">
                <Setter TargetName="PART_Indicator" Property="Visibility" Value="Collapsed"/>
                <Setter TargetName="Indet" Property="Visibility" Value="Visible"/>
                <Trigger.EnterActions>
                  <BeginStoryboard x:Name="IndetStory"><Storyboard RepeatBehavior="Forever">
                    <ThicknessAnimation Storyboard.TargetName="Indet" Storyboard.TargetProperty="Margin" From="-60,0,0,0" To="260,0,0,0" Duration="0:0:1.5"/>
                  </Storyboard></BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions><StopStoryboard BeginStoryboardName="IndetStory"/></Trigger.ExitActions>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ================= TOOLTIP ================= -->
    <Style TargetType="ToolTip">
      <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
      <Setter Property="Background" Value="{DynamicResource DialogFill}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource CardStroke}"/>
      <Setter Property="Padding" Value="10,7"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="MaxWidth" Value="440"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToolTip">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1"
                    CornerRadius="4" Padding="{TemplateBinding Padding}">
              <ContentPresenter>
                <ContentPresenter.Resources><Style TargetType="TextBlock"><Setter Property="TextWrapping" Value="Wrap"/></Style></ContentPresenter.Resources>
              </ContentPresenter>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="272"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <!-- ============================ NAVIGAZIONE ============================ -->
    <Grid Grid.Column="0">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="20,10,16,18">
        <Image x:Name="NavLogo" Width="30" Height="30" RenderOptions.BitmapScalingMode="HighQuality" Visibility="Collapsed"/>
        <TextBlock x:Name="NavLogoFallback" Style="{StaticResource Glyph}" Text="&#xE945;" FontSize="26" Foreground="{DynamicResource Accent}" VerticalAlignment="Center"/>
        <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
          <TextBlock Text="WinOptima" FontSize="16" FontWeight="SemiBold"/>
          <TextBlock x:Name="NavVersion" Text="Portable" Style="{StaticResource TxtCaption}"/>
        </StackPanel>
      </StackPanel>

      <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
        <StackPanel x:Name="NavList"/>
      </ScrollViewer>

      <StackPanel Grid.Row="2" x:Name="NavFooter" Margin="0,0,0,12"/>
    </Grid>

    <!-- ============================ CONTENUTO ============================ -->
    <Border Grid.Column="1" Background="{DynamicResource LayerFill}" BorderBrush="{DynamicResource CardStroke}"
            BorderThickness="1,1,0,0" CornerRadius="8,0,0,0">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Intestazione pagina + avvisi -->
        <StackPanel Grid.Row="0" Margin="36,24,36,6">
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <StackPanel>
              <TextBlock x:Name="PageTitle" Style="{StaticResource TxtTitle}"/>
              <TextBlock x:Name="PageSubtitle" Style="{StaticResource TxtSecondary}" TextWrapping="Wrap" Margin="0,4,24,0"/>
            </StackPanel>
            <StackPanel x:Name="HeaderActions" Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Bottom"/>
          </Grid>

          <Border x:Name="SimBanner" Visibility="Collapsed" CornerRadius="4" BorderThickness="1" Padding="14,9" Margin="0,14,0,0"
                  Background="{DynamicResource WarnFill}" BorderBrush="{DynamicResource CardStroke}">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <TextBlock Style="{StaticResource Glyph}" Text="&#xE7BA;" Foreground="{DynamicResource WarnText}" Margin="0,2,12,0"/>
              <TextBlock Grid.Column="1" TextWrapping="Wrap" VerticalAlignment="Center"
                         Text="Modalità simulazione attiva: nessuna modifica viene scritta nel sistema. Puoi disattivarla da Impostazioni."/>
            </Grid>
          </Border>

          <Border x:Name="InfoBar" Visibility="Collapsed" CornerRadius="4" BorderThickness="1" Padding="14,10,8,10" Margin="0,14,0,0"
                  Background="{DynamicResource InfoFill}" BorderBrush="{DynamicResource CardStroke}">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBlock x:Name="InfoIcon" Style="{StaticResource Glyph}" Text="&#xE946;" Margin="0,2,12,0" VerticalAlignment="Top"/>
              <StackPanel Grid.Column="1" VerticalAlignment="Center">
                <TextBlock x:Name="InfoTitle" FontWeight="SemiBold" TextWrapping="Wrap"/>
                <TextBlock x:Name="InfoMessage" Style="{StaticResource TxtSecondary}" TextWrapping="Wrap" FontSize="13"/>
              </StackPanel>
              <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                <Button x:Name="InfoAction" Style="{StaticResource AccentButton}" Visibility="Collapsed" Margin="12,0,6,0" Padding="14,4,14,5"/>
                <Button x:Name="InfoClose" Style="{StaticResource SubtleButton}" Padding="9,6" MinHeight="0" ToolTip="Chiudi">
                  <TextBlock Style="{StaticResource Glyph}" Text="&#xE711;" FontSize="12"/>
                </Button>
              </StackPanel>
            </Grid>
          </Border>

          <!-- Operazione in corso: sempre in vista, qualunque pagina si stia guardando -->
          <Border x:Name="BusyBar" Visibility="Collapsed" CornerRadius="4" BorderThickness="1" Padding="14,10,14,12" Margin="0,14,0,0"
                  Background="{DynamicResource InfoFill}" BorderBrush="{DynamicResource Accent}">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
              <TextBlock Style="{StaticResource Glyph}" Text="&#xE895;" Foreground="{DynamicResource Accent}" FontSize="16"
                         Margin="0,1,12,0" VerticalAlignment="Center" RenderTransformOrigin="0.5,0.5">
                <TextBlock.RenderTransform><RotateTransform/></TextBlock.RenderTransform>
                <TextBlock.Triggers>
                  <EventTrigger RoutedEvent="Loaded">
                    <BeginStoryboard><Storyboard RepeatBehavior="Forever">
                      <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(RotateTransform.Angle)" From="0" To="360" Duration="0:0:1.2"/>
                    </Storyboard></BeginStoryboard>
                  </EventTrigger>
                </TextBlock.Triggers>
              </TextBlock>
              <StackPanel Grid.Column="1" VerticalAlignment="Center">
                <TextBlock x:Name="BusyTitle" FontWeight="SemiBold" Text="Operazione in corso…" TextTrimming="CharacterEllipsis"/>
                <TextBlock x:Name="BusyDetail" Style="{StaticResource TxtSecondary}" FontSize="13" TextTrimming="CharacterEllipsis"/>
              </StackPanel>
              <TextBlock x:Name="BusyCount" Grid.Column="2" FontSize="20" FontWeight="SemiBold" VerticalAlignment="Center"
                         Foreground="{DynamicResource Accent}" Margin="12,0,0,0"/>
              <ProgressBar x:Name="BusyProgress" Grid.Row="1" Grid.ColumnSpan="3" Margin="0,10,0,0" IsIndeterminate="True"/>
            </Grid>
          </Border>
        </StackPanel>

        <!-- Pagina corrente -->
        <ScrollViewer x:Name="PageScroll" Grid.Row="1" VerticalScrollBarVisibility="Auto" Padding="0,0,0,0">
          <ContentControl x:Name="PageHost" Margin="36,8,36,20" MaxWidth="1000" IsTabStop="False"/>
        </ScrollViewer>

        <!-- Barra dei comandi (modifiche in sospeso) -->
        <Border x:Name="CommandBar" Grid.Row="2" Style="{StaticResource Card}" CornerRadius="8" Padding="12,8"
                Margin="36,4,36,12" MaxWidth="1000">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel Orientation="Horizontal">
              <Button x:Name="BtnPreset" Content="Preset consigliato" Margin="0,0,8,0"/>
              <Button x:Name="BtnSelectAll" Content="Seleziona tutto" Margin="0,0,8,0"/>
              <Button x:Name="BtnReset" Content="Annulla modifiche" Style="{StaticResource SubtleButton}"/>
            </StackPanel>
            <TextBlock x:Name="PendingText" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="12,0,16,0"
                       Style="{StaticResource TxtSecondary}"/>
            <Button x:Name="BtnApply" Grid.Column="2" Content="Applica" Style="{StaticResource AccentButton}" MinWidth="120" FontWeight="SemiBold"/>
          </Grid>
        </Border>

        <!-- Registro attività e stato -->
        <Border Grid.Row="3" Background="{DynamicResource LogFill}" BorderBrush="{DynamicResource CardStroke}" BorderThickness="0,1,0,0">
          <Grid>
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <!-- Maniglia per ridimensionare il registro trascinandone il bordo superiore -->
            <Thumb x:Name="LogGrip" Grid.Row="0" Height="8" VerticalAlignment="Top" Margin="0,-4,0,0" Cursor="SizeNS"
                   Visibility="Collapsed" ToolTip="Trascina per ridimensionare il registro">
              <Thumb.Template>
                <ControlTemplate TargetType="Thumb">
                  <Grid Background="Transparent">
                    <Border x:Name="Pill" Width="40" Height="4" CornerRadius="2" Background="{DynamicResource ScrollThumb}" Opacity="0.35"/>
                  </Grid>
                  <ControlTemplate.Triggers>
                    <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Pill" Property="Opacity" Value="1"/></Trigger>
                    <Trigger Property="IsDragging" Value="True"><Setter TargetName="Pill" Property="Opacity" Value="1"/><Setter TargetName="Pill" Property="Background" Value="{DynamicResource Accent}"/></Trigger>
                  </ControlTemplate.Triggers>
                </ControlTemplate>
              </Thumb.Template>
            </Thumb>
            <Grid Grid.Row="0" Margin="16,5,12,5">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <Button x:Name="BtnLogToggle" Style="{StaticResource SubtleButton}" Padding="8,4" MinHeight="0" ToolTip="Mostra o nascondi il registro attività">
                <StackPanel Orientation="Horizontal">
                  <TextBlock x:Name="LogChevron" Style="{StaticResource Glyph}" Text="&#xE70E;" FontSize="12" VerticalAlignment="Center"/>
                  <TextBlock Text="Registro attività" FontSize="13" FontWeight="SemiBold" Margin="8,0,0,0" VerticalAlignment="Center"/>
                </StackPanel>
              </Button>
              <StackPanel Grid.Column="1" Orientation="Horizontal" Margin="16,0,0,0" VerticalAlignment="Center">
                <TextBlock x:Name="StatusIcon" Style="{StaticResource Glyph}" Text="&#xE930;" FontSize="14" Margin="0,1,8,0" VerticalAlignment="Center"/>
                <TextBlock x:Name="StatusText" FontSize="13" Style="{StaticResource TxtSecondary}" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
              </StackPanel>
              <ProgressBar x:Name="WorkProgress" Grid.Column="2" Width="150" Visibility="Hidden" Margin="12,0,12,0" VerticalAlignment="Center" Maximum="1"/>
              <Button x:Name="BtnLogSave" Grid.Column="3" Content="Salva" Style="{StaticResource SubtleButton}" Padding="10,3" MinHeight="0" FontSize="12" ToolTip="Salva il registro in un file di testo"/>
              <Button x:Name="BtnLogClear" Grid.Column="4" Content="Pulisci" Style="{StaticResource SubtleButton}" Padding="10,3" MinHeight="0" FontSize="12"/>
            </Grid>
            <RichTextBox x:Name="LogBox" Grid.Row="1" Height="176" Visibility="Collapsed" IsReadOnly="True" Background="Transparent" BorderThickness="0"
                         Foreground="{DynamicResource TextPrimary}" FontFamily="Cascadia Mono, Consolas" FontSize="12"
                         Padding="16,2,16,10" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
              <RichTextBox.Document><FlowDocument PagePadding="0"/></RichTextBox.Document>
            </RichTextBox>
          </Grid>
        </Border>
      </Grid>
    </Border>

    <!-- ============================ DIALOGO DI CONFERMA ============================ -->
    <Grid x:Name="DialogLayer" Grid.ColumnSpan="2" Visibility="Collapsed">
      <Border Background="{DynamicResource Scrim}"/>
      <Border Width="520" MaxHeight="600" HorizontalAlignment="Center" VerticalAlignment="Center" CornerRadius="8" BorderThickness="1"
              Background="{DynamicResource DialogFill}" BorderBrush="{DynamicResource CardStroke}">
        <Border.Effect><DropShadowEffect BlurRadius="40" ShadowDepth="12" Direction="270" Opacity="0.45"/></Border.Effect>
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <StackPanel Margin="24,22,24,22">
            <TextBlock x:Name="DlgTitle" Style="{StaticResource TxtSubtitle}" TextWrapping="Wrap"/>
            <TextBlock x:Name="DlgBody" Style="{StaticResource TxtSecondary}" TextWrapping="Wrap" Margin="0,12,0,0"/>
            <Border x:Name="DlgListBox" Style="{StaticResource Card}" Margin="0,14,0,0" Padding="2" Visibility="Collapsed">
              <ScrollViewer MaxHeight="230" VerticalScrollBarVisibility="Auto">
                <TextBlock x:Name="DlgList" TextWrapping="Wrap" Margin="12,8" LineHeight="21" FontSize="13"/>
              </ScrollViewer>
            </Border>
            <CheckBox x:Name="DlgCheck" Margin="0,16,0,0" Visibility="Collapsed"/>
          </StackPanel>
          <Border Grid.Row="1" Background="{DynamicResource DialogFooterFill}" CornerRadius="0,0,8,8" Padding="24,16">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Button x:Name="DlgPrimary" Style="{StaticResource AccentButton}" FontWeight="SemiBold"/>
              <Button x:Name="DlgSecondary" Grid.Column="2"/>
            </Grid>
          </Border>
        </Grid>
      </Border>
    </Grid>
  </Grid>
</Window>
'@


# ======================================================================================
#  LOGICA DELL'INTERFACCIA
#  Regola d'oro: gli handler degli eventi non vedono le variabili locali delle funzioni che
#  li hanno creati. Per questo i dati passano da $script:* oppure dalla proprieta' .Tag.
# ======================================================================================

# ---------------------------------------------------------------- impostazioni persistenti
$script:SettingsPath = Join-Path $script:AppDir 'WinOptima.settings.json'
$script:Settings = @{ theme = 'system'; simulate = $false; restartExplorer = $true; restorePoint = $false; logOpen = $false; logHeight = 200; autoUpdate = $true; deprovision = $true }

function Read-Settings {
    try {
        if (Test-Path -LiteralPath $script:SettingsPath) {
            $json = Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $json.PSObject.Properties) {
                if ($script:Settings.ContainsKey($p.Name)) { $script:Settings[$p.Name] = $p.Value }
            }
        }
    } catch { <# file assente o danneggiato: si usano i valori predefiniti #> }
}

function Save-Settings {
    try { ($script:Settings | ConvertTo-Json) | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8 }
    catch { <# supporto in sola lettura (es. chiavetta protetta): le preferenze non vengono salvate #> }
}

Read-Settings
$Sim = [bool]($Simulate -or $script:Settings.simulate)

# ---------------------------------------------------------------- finestra
$window = [System.Windows.Markup.XamlReader]::Parse($WindowXaml)
$ui = @{}
foreach ($n in 'NavLogo', 'NavLogoFallback', 'NavVersion', 'NavList', 'NavFooter', 'PageTitle', 'PageSubtitle', 'HeaderActions',
    'SimBanner', 'InfoBar', 'InfoIcon', 'InfoTitle', 'InfoMessage', 'InfoClose', 'PageScroll', 'PageHost', 'CommandBar',
    'BtnPreset', 'BtnSelectAll', 'BtnReset', 'PendingText', 'BtnApply', 'BtnLogToggle', 'LogChevron', 'StatusIcon', 'StatusText',
    'WorkProgress', 'BtnLogSave', 'BtnLogClear', 'LogBox', 'DialogLayer', 'DlgTitle', 'DlgBody', 'DlgListBox', 'DlgList',
    'DlgCheck', 'DlgPrimary', 'DlgSecondary', 'BusyBar', 'BusyTitle', 'BusyDetail', 'BusyCount', 'BusyProgress', 'LogGrip', 'InfoAction') {
    $ui[$n] = $window.FindName($n)
}

# Avanzamento anche sul pulsante nella barra delle applicazioni (verde = in corso)
$window.TaskbarItemInfo = New-Object System.Windows.Shell.TaskbarItemInfo
$script:BaseTitle = $window.Title

$icoPath = Join-Path $script:AppDir 'WinOptima.ico'
if (Test-Path -LiteralPath $icoPath) {
    try {
        $decoder = [System.Windows.Media.Imaging.BitmapDecoder]::Create([Uri]$icoPath, 'None', 'OnLoad')
        $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]$icoPath)
        $ui.NavLogo.Source = ($decoder.Frames | Sort-Object PixelWidth -Descending | Select-Object -First 1)
        $ui.NavLogo.Visibility = 'Visible'
        $ui.NavLogoFallback.Visibility = 'Collapsed'
    } catch { <# icona non leggibile: resta il glifo di riserva #> }
}
$ui.NavVersion.Text = "Portable · v$script:AppVersion"

# ---------------------------------------------------------------- tema (chiaro/scuro, accento, Mica)
$script:MicaOn = $false
$script:Hwnd = [IntPtr]::Zero
$script:LastThemeKey = ''

function Get-SystemDark {
    try { (Get-ItemPropertyValue -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop) -eq 0 }
    catch { $true }
}

# La tavolozza di accento di Windows contiene 8 colori RGBA da 4 byte: [1] = Light2 (tema scuro), [4] = Dark1 (tema chiaro)
function Get-AccentHex {
    param([bool]$Dark)
    try {
        $pal = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' -Name AccentPalette -ErrorAction Stop).AccentPalette
        $i = if ($Dark) { 4 } else { 16 }
        return ('#{0:X2}{1:X2}{2:X2}' -f $pal[$i], $pal[$i + 1], $pal[$i + 2])
    } catch {
        if ($Dark) { '#60CDFF' } else { '#005FB8' }
    }
}

function New-Brush {
    param([string]$Hex)
    $b = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Hex))
    $b.Freeze()
    # BaseObject: senza, PowerShell inserisce nel ResourceDictionary un oggetto "avvolto" che WPF rifiuta
    $b.psobject.BaseObject
}

function Set-AppTheme {
    $dark = switch ($script:Settings.theme) { 'dark' { $true } 'light' { $false } default { Get-SystemDark } }
    $accent = Get-AccentHex $dark
    $key = "$dark|$accent|$script:MicaOn"
    if ($key -eq $script:LastThemeKey) { return }
    $script:LastThemeKey = $key

    $a = [System.Windows.Media.ColorConverter]::ConvertFromString($accent)
    $withAlpha = { param([byte]$alpha) '#{0:X2}{1:X2}{2:X2}{3:X2}' -f $alpha, $a.R, $a.G, $a.B }

    if ($dark) {
        $t = @{
            WindowBase = '#202020'; LayerFill = '#992E2E2E'; LogFill = '#26000000'
            TextPrimary = '#FFFFFF'; TextSecondary = '#C5FFFFFF'; TextTertiary = '#87FFFFFF'; TextDisabled = '#5DFFFFFF'; TextOnAccent = '#000000'
            CardFill = '#0DFFFFFF'; CardFillHover = '#14FFFFFF'; CardStroke = '#14FFFFFF'
            ControlFill = '#0FFFFFFF'; ControlFillHover = '#15FFFFFF'; ControlFillPressed = '#08FFFFFF'; ControlFillDisabled = '#0BFFFFFF'; ControlStroke = '#18FFFFFF'
            SubtleHover = '#0FFFFFFF'; SubtlePressed = '#0AFFFFFF'; SubtleSelected = '#17FFFFFF'
            AccentDisabled = '#28FFFFFF'
            ToggleOffStroke = '#9BFFFFFF'; ToggleOffKnob = '#C5FFFFFF'; ToggleOnKnob = '#000000'
            ProgressTrack = '#2EFFFFFF'; ScrollThumb = '#7DFFFFFF'; ScrollThumbHover = '#C5FFFFFF'
            DialogFill = '#2C2C2C'; DialogFooterFill = '#212121'; Scrim = '#66000000'; Divider = '#14FFFFFF'
            SuccessText = '#6CCB5F'; SuccessFill = '#393D1B'; WarnText = '#FCE100'; WarnFill = '#433519'
            ErrorText = '#FF99A4'; ErrorFill = '#442726'; InfoText = '#99DDFF'; InfoFill = '#26323B'
        }
    } else {
        $t = @{
            WindowBase = '#F3F3F3'; LayerFill = '#B3FFFFFF'; LogFill = '#80FFFFFF'
            TextPrimary = '#E4000000'; TextSecondary = '#9E000000'; TextTertiary = '#72000000'; TextDisabled = '#5C000000'; TextOnAccent = '#FFFFFF'
            CardFill = '#B3FFFFFF'; CardFillHover = '#80F9F9F9'; CardStroke = '#14000000'
            ControlFill = '#B3FFFFFF'; ControlFillHover = '#80F9F9F9'; ControlFillPressed = '#4DF9F9F9'; ControlFillDisabled = '#4DF9F9F9'; ControlStroke = '#1F000000'
            SubtleHover = '#09000000'; SubtlePressed = '#06000000'; SubtleSelected = '#0E000000'
            AccentDisabled = '#37000000'
            ToggleOffStroke = '#72000000'; ToggleOffKnob = '#99000000'; ToggleOnKnob = '#FFFFFF'
            ProgressTrack = '#1A000000'; ScrollThumb = '#72000000'; ScrollThumbHover = '#9E000000'
            DialogFill = '#FFFFFF'; DialogFooterFill = '#F3F3F3'; Scrim = '#4D000000'; Divider = '#0F000000'
            SuccessText = '#0F7B0F'; SuccessFill = '#DFF6DD'; WarnText = '#9D5D00'; WarnFill = '#FFF4CE'
            ErrorText = '#C42B1C'; ErrorFill = '#FDE7E9'; InfoText = '#005FB8'; InfoFill = '#E5F1FB'
        }
    }
    $t.Accent = $accent
    $t.AccentHover = (& $withAlpha 230)
    $t.AccentPressed = (& $withAlpha 204)
    foreach ($k in $t.Keys) { $window.Resources[$k] = New-Brush $t[$k] }

    # Con Mica la finestra è trasparente e il materiale del sistema si vede sotto; altrimenti tinta unita
    $window.Resources['WindowBase'] = if ($script:MicaOn) { [System.Windows.Media.Brushes]::Transparent } else { New-Brush $t.WindowBase }

    if ($script:NativeOk -and $script:Hwnd -ne [IntPtr]::Zero) { [void][WinOptimaNative]::SetDarkTitleBar($script:Hwnd, $dark) }
}

$window.Add_SourceInitialized({
    $script:Hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $window).Handle
    if ($script:NativeOk -and $OsBuild -ge 22621) {
        $script:MicaOn = [WinOptimaNative]::EnableMica($script:Hwnd)
        if ($script:MicaOn) {
            $src = [System.Windows.Interop.HwndSource]::FromHwnd($script:Hwnd)
            $src.CompositionTarget.BackgroundColor = [System.Windows.Media.Colors]::Transparent
        }
    }
    $script:LastThemeKey = ''
    Set-AppTheme
})

# ---------------------------------------------------------------- utilita' XAML
$NS = 'xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"'

function ConvertTo-Element {
    param([string]$Template, [hashtable]$Map = @{})
    $x = $Template.Replace('@NS@', $NS)
    foreach ($k in $Map.Keys) { $x = $x.Replace("@$k@", [string]$Map[$k]) }
    [System.Windows.Markup.XamlReader]::Parse($x)
}

function Esc { param([string]$Text) [System.Security.SecurityElement]::Escape($Text) }
function Get-GlyphRef { param([int]$Code) '&#x{0:X4};' -f $Code }

function New-Btn {
    param([string]$Text, [string]$Style = '', $Tag = $null, [scriptblock]$OnClick, [double]$MarginLeft = 8)
    $b = New-Object System.Windows.Controls.Button
    $b.Content = $Text
    $b.Tag = $Tag
    $b.Margin = New-Object System.Windows.Thickness ($MarginLeft, 0, 0, 0)
    if ($Style) { $b.SetResourceReference([System.Windows.FrameworkElement]::StyleProperty, $Style) }
    if ($OnClick) { $b.Add_Click($OnClick) }
    $b
}

$RowTemplate = @'
<Border @NS@ Style="{DynamicResource Card}" Padding="16,13" Margin="0,0,0,4" MinHeight="62">
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="40"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
    <Grid x:Name="iconHost" VerticalAlignment="Center" HorizontalAlignment="Left">
      <TextBlock x:Name="glyph" Style="{DynamicResource Glyph}" Text="@ICON@" FontSize="20" VerticalAlignment="Center"/>
    </Grid>
    <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="0,0,16,0">
      <StackPanel Orientation="Horizontal">
        <TextBlock x:Name="title" Text="@TITLE@" TextWrapping="Wrap" VerticalAlignment="Center"/>
        @TAGS@
        <TextBlock x:Name="pending" Visibility="Collapsed" Margin="10,0,0,0" FontSize="12" VerticalAlignment="Center"
                   Foreground="{DynamicResource Accent}" Text="@PENDING@"/>
      </StackPanel>
      <TextBlock x:Name="desc" Text="@DESC@" Style="{DynamicResource TxtCaption}" TextWrapping="Wrap" Margin="0,2,0,0"/>
    </StackPanel>
    <StackPanel x:Name="right" Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">@RIGHT@</StackPanel>
  </Grid>
</Border>
'@

$TagTemplate = '<Border CornerRadius="9" Padding="8,1,8,2" Margin="10,0,0,0" VerticalAlignment="Center" Background="{DynamicResource @FILL@}"><TextBlock FontSize="11" Foreground="{DynamicResource @TEXT@}" Text="@LABEL@"/></Border>'

function New-Row {
    param([int]$Icon = 0xE713, [string]$Title, [string]$Desc, [string]$Tags = '', [string]$Right = '', [string]$Pending = '', [string]$Tip = '')
    $card = ConvertTo-Element $RowTemplate @{
        ICON = (Get-GlyphRef $Icon); TITLE = (Esc $Title); DESC = (Esc $Desc); TAGS = $Tags; RIGHT = $Right; PENDING = (Esc $Pending)
    }
    if ($Tip) {
        $card.ToolTip = $Tip
        [System.Windows.Controls.ToolTipService]::SetShowDuration($card, 30000)
    }
    $card
}

function New-SectionHeader {
    param([string]$Text, [bool]$First = $false)
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text
    $tb.Margin = New-Object System.Windows.Thickness (2, $(if ($First) { 6 } else { 22 }), 0, 8)
    $tb.SetResourceReference([System.Windows.FrameworkElement]::StyleProperty, 'TxtBodyStrong')
    $tb
}

# ---------------------------------------------------------------- stato dei controlli
$script:Controls = @{}      # id voce -> @{ Ctl; Pending; Size }
$script:State = @{}         # id tweak -> stato reale nel sistema
$script:Busy = $false
$script:Jobs = New-Object System.Collections.ArrayList
$script:CurrentPage = ''
$script:SysInfo = $null

function New-ItemCard {
    param([hashtable]$Item)
    $isAction = ($Item.Kind -eq 'action')
    $tags = ''
    if ($Item.Rec) { $tags += $TagTemplate.Replace('@FILL@', 'SuccessFill').Replace('@TEXT@', 'SuccessText').Replace('@LABEL@', 'Consigliato') }
    if ($Item.Adv) { $tags += $TagTemplate.Replace('@FILL@', 'WarnFill').Replace('@TEXT@', 'WarnText').Replace('@LABEL@', 'Avanzato') }
    if ($Item.Slow) { $tags += $TagTemplate.Replace('@FILL@', 'InfoFill').Replace('@TEXT@', 'InfoText').Replace('@LABEL@', 'Lento') }
    $right = if ($isAction) {
        '<TextBlock x:Name="size" VerticalAlignment="Center" Style="{DynamicResource TxtCaption}" MinWidth="70" TextAlignment="Right"/><CheckBox x:Name="ctl" VerticalAlignment="Center" Margin="14,0,0,0"/>'
    } else {
        '<ToggleButton x:Name="ctl" Style="{DynamicResource ToggleSwitch}" VerticalAlignment="Center" Margin="14,0,0,0"/>'
    }
    $card = New-Row -Icon $Item.Icon -Title $Item.Title -Desc $Item.Desc -Tags $tags -Right $right -Tip $Item.Tip `
        -Pending $(if ($isAction) { '• Da eseguire' } else { '• Modifica in sospeso' })
    $ctl = $card.FindName('ctl')
    [System.Windows.Automation.AutomationProperties]::SetName($ctl, $Item.Title)    # per gli screen reader
    $script:Controls[$Item.Id] = @{ Ctl = $ctl; Card = $card; Pending = $card.FindName('pending'); Size = $card.FindName('size') }
    $card.Tag = $ctl
    # Checked/Unchecked (non Click): scattano con mouse, tastiera, screen reader e modifiche da codice
    $ctl.Add_Checked({ Update-Pending })
    $ctl.Add_Unchecked({ Update-Pending })
    # Un clic su tutta la riga attiva/disattiva l'opzione (come nelle Impostazioni di Windows)
    $card.Add_MouseLeftButtonUp({
        $c = $args[0].Tag
        if ($c -and $c.IsEnabled) { $c.IsChecked = -not [bool]$c.IsChecked; Update-Pending }
    })
    $card
}

function Build-ItemPage {
    param([string]$Key)
    $panel = New-Object System.Windows.Controls.StackPanel
    $groups = [ordered]@{}
    foreach ($item in $Catalog.Values) {
        if ($item.Page -ne $Key) { continue }
        if ($item.Win11 -and -not $IsWin11) { continue }
        if (-not $groups.Contains($item.Group)) { $groups[$item.Group] = New-Object System.Collections.ArrayList }
        [void]$groups[$item.Group].Add($item)
    }
    $first = $true
    foreach ($g in $groups.Keys) {
        $panel.Children.Add((New-SectionHeader $g $first)) | Out-Null
        $first = $false
        foreach ($item in $groups[$g]) { $panel.Children.Add((New-ItemCard $item)) | Out-Null }
    }
    $panel
}

# ---------------------------------------------------------------- registro, stato, avvisi
function Add-LogLine {
    param([datetime]$Time, [string]$Level, [string]$Text)
    $p = New-Object System.Windows.Documents.Paragraph
    $p.Margin = New-Object System.Windows.Thickness 0
    $label, $key = switch ($Level) {
        'SUCCESS' { 'OK', 'SuccessText' }
        'WARN'    { 'AVVISO', 'WarnText' }
        'ERROR'   { 'ERRORE', 'ErrorText' }
        'SIM'     { 'SIM', 'InfoText' }
        default   { 'INFO', 'TextSecondary' }
    }
    $r1 = New-Object System.Windows.Documents.Run ($Time.ToString('HH:mm:ss') + '  ')
    $r1.SetResourceReference([System.Windows.Documents.TextElement]::ForegroundProperty, 'TextTertiary')
    $r2 = New-Object System.Windows.Documents.Run (('{0,-7}' -f $label))
    $r2.FontWeight = 'SemiBold'
    $r2.SetResourceReference([System.Windows.Documents.TextElement]::ForegroundProperty, $key)
    $r3 = New-Object System.Windows.Documents.Run $Text
    $r3.SetResourceReference([System.Windows.Documents.TextElement]::ForegroundProperty, 'TextPrimary')
    $p.Inlines.Add($r1); $p.Inlines.Add($r2); $p.Inlines.Add($r3)
    $doc = $ui.LogBox.Document
    $doc.Blocks.Add($p)
    if ($doc.Blocks.Count -gt 1500) { for ($i = 0; $i -lt 200; $i++) { $doc.Blocks.Remove($doc.Blocks.FirstBlock) } }
    if ($ui.LogBox.Visibility -eq 'Visible') { $ui.LogBox.ScrollToEnd() }
}

function Set-LogOpen {
    param([bool]$Open)
    $ui.LogBox.Visibility = if ($Open) { 'Visible' } else { 'Collapsed' }
    $ui.LogGrip.Visibility = $ui.LogBox.Visibility
    $ui.LogBox.Height = Limit-LogHeight ([double]$script:Settings.logHeight)
    $ui.LogChevron.Text = if ($Open) { [string][char]0xE70D } else { [string][char]0xE70E }
    $script:Settings.logOpen = $Open
    if ($Open) { $ui.LogBox.ScrollToEnd() }
}

# Il registro può crescere fino a lasciare almeno ~260 px alla pagina
function Limit-LogHeight {
    param([double]$H)
    $max = [math]::Max(120, $window.ActualHeight - 330)
    if ($window.ActualHeight -le 0) { $max = 600 }
    [math]::Round([math]::Min($max, [math]::Max(90, $H)))
}

$ui.LogGrip.Add_DragDelta({ $ui.LogBox.Height = Limit-LogHeight ($ui.LogBox.Height - $args[1].VerticalChange) })
$ui.LogGrip.Add_DragCompleted({ $script:Settings.logHeight = $ui.LogBox.Height; Save-Settings })

function Set-Status {
    param([string]$Text, [string]$Level = 'ok')
    $script:StatusLevel = $Level
    $map = @{ ok = 0xE930, 'SuccessText'; busy = 0xE895, 'Accent'; warn = 0xE7BA, 'WarnText'; error = 0xE783, 'ErrorText'; info = 0xE946, 'InfoText' }
    $m = $map[$Level]; if (-not $m) { $m = $map['info'] }
    $ui.StatusIcon.Text = [string][char][int]$m[0]
    $ui.StatusIcon.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $m[1])
    $ui.StatusText.Text = $Text
}

function Show-Info {
    # -ActionText/-OnAction: pulsante d'azione nell'avviso; -Sticky: resta visibile anche cambiando pagina
    param([string]$Level, [string]$Title, [string]$Message = '', [string]$ActionText = '', [scriptblock]$OnAction, [switch]$Sticky)
    $script:InfoOnAction = $OnAction
    $script:InfoSticky = $Sticky.IsPresent
    $ui.InfoAction.Content = $ActionText
    $ui.InfoAction.Visibility = if ($ActionText -and $OnAction) { 'Visible' } else { 'Collapsed' }
    $map = @{
        success = 0xE930, 'SuccessText', 'SuccessFill'
        warning = 0xE7BA, 'WarnText', 'WarnFill'
        error   = 0xE783, 'ErrorText', 'ErrorFill'
        info    = 0xE946, 'InfoText', 'InfoFill'
    }
    $m = $map[$Level]; if (-not $m) { $m = $map['info'] }
    $ui.InfoIcon.Text = [string][char][int]$m[0]
    $ui.InfoIcon.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $m[1])
    $ui.InfoBar.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, $m[2])
    $ui.InfoTitle.Text = $Title
    $ui.InfoMessage.Text = $Message
    $ui.InfoMessage.Visibility = if ($Message) { 'Visible' } else { 'Collapsed' }
    $ui.InfoBar.Visibility = 'Visible'
}

$ui.InfoClose.Add_Click({ $ui.InfoBar.Visibility = 'Collapsed'; $script:InfoSticky = $false })
$ui.InfoAction.Add_Click({ if ($script:InfoOnAction) { & $script:InfoOnAction } })

# ---------------------------------------------------------------- aggiornamenti automatici
# Il launcher passa il proprio percorso in WINOPTIMA_EXE: solo così l'app sa quale exe sostituire.
# Si tengono al massimo 2 exe: quello attuale e «<nome>.old.exe» (la versione precedente, per tornare indietro).
$script:UpdateInfo = $null
$script:UpdateReady = $null
$script:Relaunching = $false

function Start-UpdateCheck {
    param([switch]$Manual)
    $script:ManualCheck = $Manual.IsPresent
    [void](Start-Work -Background -Vars @{ AppVer = $script:AppVersion; IsManual = $Manual.IsPresent } -Script {
            if ($IsManual) { Find-AppUpdate -CurrentVersion $AppVer -Manual } else { Find-AppUpdate -CurrentVersion $AppVer } })
}

function Receive-UpdateInfo {
    param($Msg)
    if (-not $Msg.Version) {
        if ($Msg.Current) { Show-Info 'success' 'WinOptima è aggiornato' "Stai usando l'ultima versione ($script:AppVersion)." }
        elseif ($Msg.Failed) { Show-Info 'warning' 'Controllo aggiornamenti non riuscito' 'Verifica la connessione a Internet e riprova più tardi.' }
        return
    }
    $script:UpdateInfo = $Msg
    Add-LogLine (Get-Date) 'INFO' "Disponibile WinOptima $($Msg.Version) (in uso: $script:AppVersion)."
    $exe = $env:WINOPTIMA_EXE
    if ($exe -and (Test-Path -LiteralPath $exe)) {
        # Avviato dall'exe: scarica subito in background, poi installa alla chiusura o su richiesta
        [void](Start-Work -Background -Vars @{ U = $Msg } -Script { Save-AppUpdate -Url $U.Url -Size $U.Size -Sha256 $U.Sha256 -Version $U.Version })
    } else {
        Show-Info 'info' "Disponibile WinOptima $($Msg.Version)" 'Stai eseguendo lo script direttamente: scarica il nuovo exe dalla pagina della release.' `
            -ActionText 'Apri la release' -OnAction { Start-Process $script:UpdateInfo.Page } -Sticky
    }
}

function Receive-UpdateReady {
    param($Msg)
    if (-not $Msg.Path) {
        Show-Info 'warning' "Aggiornamento a $($Msg.Version) non scaricato" 'Riproveremo al prossimo avvio. Puoi anche scaricarlo a mano dalla pagina della release.' `
            -ActionText 'Apri la release' -OnAction { Start-Process $script:UpdateInfo.Page }
        return
    }
    $script:UpdateReady = $Msg.Path
    Show-Info 'success' "WinOptima $($Msg.Version) è pronto" 'Verrà installato alla chiusura dell''app, oppure subito con un riavvio.' `
        -ActionText 'Riavvia e aggiorna' -OnAction {
        if ($script:Busy) { Show-Info 'warning' 'Attendi la fine dell''operazione in corso' 'L''aggiornamento si installerà comunque alla chiusura.'; return }
        [void](Install-AppUpdate -Relaunch)
    } -Sticky
}

# Sostituisce l'exe: quello attuale diventa .old.exe (rinominare un exe in esecuzione è consentito), il nuovo prende il suo posto
function Install-AppUpdate {
    param([switch]$Relaunch)
    $exe = $env:WINOPTIMA_EXE
    $new = $script:UpdateReady
    if (-not $exe -or -not $new -or -not (Test-Path -LiteralPath $exe) -or -not (Test-Path -LiteralPath $new)) { return $false }
    $old = Join-Path (Split-Path -Parent $exe) ([IO.Path]::GetFileNameWithoutExtension($exe) + '.old.exe')
    try {
        if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force -ErrorAction Stop }
        Move-Item -LiteralPath $exe -Destination $old -Force -ErrorAction Stop
        try { Copy-Item -LiteralPath $new -Destination $exe -Force -ErrorAction Stop }
        catch { Move-Item -LiteralPath $old -Destination $exe -Force; throw }
        Remove-Item -LiteralPath $new -Force -ErrorAction SilentlyContinue
        $script:UpdateReady = $null
        Write-Log "WinOptima aggiornato alla versione $($script:UpdateInfo.Version). Versione precedente conservata in $old" 'SUCCESS'
        if ($Relaunch) {
            $script:Relaunching = $true
            Start-Process -FilePath $exe
            $window.Close()
        }
        return $true
    } catch {
        Write-Log "Installazione dell'aggiornamento non riuscita: $($_.Exception.Message)" 'ERROR'
        if ($Relaunch) { Show-Info 'error' 'Aggiornamento non riuscito' "$($_.Exception.Message). La cartella dell'exe potrebbe essere in sola lettura." }
        return $false
    }
}

# ---------------------------------------------------------------- dialogo di conferma
$script:DlgOnPrimary = $null
$script:DlgChecked = $false

function Show-Dialog {
    param([string]$Title, [string]$Body = '', [string[]]$Items = @(), [string]$CheckText = '', [bool]$CheckValue = $false,
        [string]$Primary = 'OK', [string]$Secondary = 'Annulla', [scriptblock]$OnPrimary)
    $ui.DlgTitle.Text = $Title
    $ui.DlgBody.Text = $Body
    $ui.DlgBody.Visibility = if ($Body) { 'Visible' } else { 'Collapsed' }
    $ui.DlgList.Text = ($Items -join [Environment]::NewLine)
    $ui.DlgListBox.Visibility = if ($Items.Count) { 'Visible' } else { 'Collapsed' }
    $ui.DlgCheck.Content = $CheckText
    $ui.DlgCheck.IsChecked = $CheckValue
    $ui.DlgCheck.Visibility = if ($CheckText) { 'Visible' } else { 'Collapsed' }
    $ui.DlgPrimary.Content = $Primary
    $ui.DlgSecondary.Content = $Secondary
    $script:DlgOnPrimary = $OnPrimary
    $ui.DialogLayer.Visibility = 'Visible'
    [void]$ui.DlgPrimary.Focus()
}

function Hide-Dialog { $ui.DialogLayer.Visibility = 'Collapsed' }

$ui.DlgPrimary.Add_Click({
    $script:DlgChecked = [bool]$ui.DlgCheck.IsChecked
    Hide-Dialog
    if ($script:DlgOnPrimary) { & $script:DlgOnPrimary }
})
$ui.DlgSecondary.Add_Click({ Hide-Dialog })
$window.Add_PreviewKeyDown({
    if ($args[1].Key -eq 'Escape' -and $ui.DialogLayer.Visibility -eq 'Visible') { Hide-Dialog; $args[1].Handled = $true }
})

# ---------------------------------------------------------------- lavori in background (runspace separato)
# Il lavoro pesante gira fuori dal thread della finestra e comunica solo tramite $UiQueue.
function Set-Busy {
    param([bool]$Busy)
    $script:Busy = $Busy
    $ui.WorkProgress.Visibility = if ($Busy) { 'Visible' } else { 'Hidden' }
    if ($Busy) { $ui.WorkProgress.IsIndeterminate = $true }
    # Barra «in corso» ben visibile + barra delle applicazioni + titolo della finestra
    $ui.BusyBar.Visibility = if ($Busy) { 'Visible' } else { 'Collapsed' }
    $ui.BusyProgress.IsIndeterminate = $true
    $ui.BusyDetail.Text = if ($Busy) { 'Preparazione…' } else { '' }
    $ui.BusyCount.Text = ''
    $window.TaskbarItemInfo.ProgressState = if ($Busy) { 'Indeterminate' } else { 'None' }
    $window.Title = $script:BaseTitle
    Update-Pending
}

function Update-BusyProgress {
    param($Msg)
    $max = [math]::Max(1, [int]$Msg.Max)
    $val = [math]::Min($max, [int]$Msg.Value)
    $ui.WorkProgress.IsIndeterminate = $false
    $ui.WorkProgress.Maximum = $max
    $ui.WorkProgress.Value = $val
    if (-not $script:Busy) { return }
    $ui.BusyProgress.IsIndeterminate = $false
    $ui.BusyProgress.Maximum = $max
    $ui.BusyProgress.Value = $val
    $step = [math]::Min($max, $val + 1)
    if ($Msg.Text) {
        $ui.BusyDetail.Text = "Passo $step di ${max}: $($Msg.Text)"
        $ui.BusyCount.Text = '{0}%' -f [int](100 * $val / $max)
    }
    $window.TaskbarItemInfo.ProgressState = 'Normal'
    $window.TaskbarItemInfo.ProgressValue = $val / $max
    $window.Title = '({0}%) {1}' -f [int](100 * $val / $max), $script:BaseTitle
}

function Start-Work {
    param([string]$Status = '', [scriptblock]$Script, [hashtable]$Vars = @{}, [switch]$Background, [scriptblock]$OnDone)
    if (-not $Background -and $script:Busy) {
        Show-Info 'warning' 'Un''operazione è già in corso' 'Attendi che termini prima di avviarne un''altra.'
        return $false
    }
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('UiQueue', $UiQueue)
    $rs.SessionStateProxy.SetVariable('Sim', [bool]$Sim)
    foreach ($k in $Vars.Keys) { $rs.SessionStateProxy.SetVariable($k, $Vars[$k]) }
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($Engine.ToString() + [Environment]::NewLine + $Script.ToString())
    $job = @{ PS = $ps; RS = $rs; Background = $Background.IsPresent; OnDone = $OnDone }
    if (-not $Background) {
        Set-Busy $true
        $ui.BusyTitle.Text = if ($Status) { $Status } else { 'Operazione in corso…' }
        if ($Status) { Set-Status $Status 'busy' }
    }
    $job.Handle = $ps.BeginInvoke()
    [void]$script:Jobs.Add($job)
    $true
}

function Complete-Job {
    param($Job)
    try { [void]$Job.PS.EndInvoke($Job.Handle) }
    catch { Add-LogLine (Get-Date) 'ERROR' "Errore interno: $($_.Exception.Message)" }
    foreach ($e in $Job.PS.Streams.Error) { Add-LogLine (Get-Date) 'ERROR' ([string]$e) }
    try { $Job.PS.Dispose(); $Job.RS.Dispose() } catch {}
    [void]$script:Jobs.Remove($Job)
    if (-not $Job.Background) {
        Set-Busy $false
        if ($script:StatusLevel -eq 'busy') { Set-Status 'Pronto.' 'ok' }
        $ui.WorkProgress.Visibility = 'Hidden'
    }
    if ($Job.OnDone) { & $Job.OnDone }
}

# ---------------------------------------------------------------- modifiche in sospeso
function Get-PendingSteps {
    param([string]$Scope = 'all')
    $steps = New-Object System.Collections.ArrayList
    foreach ($id in $script:Controls.Keys) {
        $item = $Catalog[$id]
        $on = [bool]$script:Controls[$id].Ctl.IsChecked
        if ($item.Kind -eq 'action') {
            if ($on) { [void]$steps.Add(@{ Id = $id; Mode = 'run'; Title = $item.Title; Order = [array]::IndexOf(@($Catalog.Keys), $id) }) }
        } elseif ($Scope -eq 'all' -and $on -ne [bool]$script:State[$id]) {
            [void]$steps.Add(@{ Id = $id; Mode = $(if ($on) { 'apply' } else { 'revert' }); Title = $item.Title; Order = [array]::IndexOf(@($Catalog.Keys), $id) })
        }
    }
    # Prima le ottimizzazioni, poi le pulizie, ciascuna nell'ordine del catalogo
    @($steps | Sort-Object -Property @{ Expression = { if ($_.Mode -eq 'run') { 1 } else { 0 } } }, @{ Expression = { $_.Order } })
}

function Update-Pending {
    $n = 0
    foreach ($id in $script:Controls.Keys) {
        $c = $script:Controls[$id]
        $item = $Catalog[$id]
        $on = [bool]$c.Ctl.IsChecked
        $changed = if ($item.Kind -eq 'action') { $on } else { $on -ne [bool]$script:State[$id] }
        $c.Pending.Visibility = if ($changed) { 'Visible' } else { 'Collapsed' }
        if ($changed) { $n++ }
    }
    $ui.PendingText.Text = switch ($n) { 0 { 'Nessuna modifica in sospeso' } 1 { '1 modifica in sospeso' } default { "$n modifiche in sospeso" } }
    $ui.BtnApply.Content = if ($script:Busy) { 'In corso…' } elseif ($n -gt 0) { "Applica ($n)" } else { 'Applica' }
    $ui.BtnApply.IsEnabled = ($n -gt 0) -and (-not $script:Busy)
    Update-HomeOptimizations
}

function Sync-States {
    foreach ($id in @($script:Controls.Keys)) {
        $item = $Catalog[$id]
        if ($item.Kind -eq 'action') { continue }
        $script:State[$id] = [bool](Test-Tweak $item)
        $script:Controls[$id].Ctl.IsChecked = $script:State[$id]
    }
    Update-Pending
}

function Set-Preset {
    foreach ($id in @($script:Controls.Keys)) {
        $item = $Catalog[$id]
        if ($item.Kind -eq 'action') { $script:Controls[$id].Ctl.IsChecked = [bool]$item.Rec }
        elseif ($item.Rec) { $script:Controls[$id].Ctl.IsChecked = $true }
    }
    Update-Pending
}

function Request-Apply {
    param([string]$Scope = 'all')
    if ($script:Busy) { Show-Info 'warning' 'Un''operazione è già in corso' 'Attendi che termini prima di avviarne un''altra.'; return }
    $steps = @(Get-PendingSteps $Scope)
    if ($steps.Count -eq 0) {
        Show-Info 'info' 'Nessuna modifica da applicare' 'Attiva qualche opzione (o scegli «Preset consigliato») e poi premi Applica.'
        return
    }
    $lines = foreach ($s in $steps) {
        switch ($s.Mode) { 'apply' { "✓  Attiva: $($s.Title)" } 'revert' { "↺  Ripristina: $($s.Title)" } default { "▸  Esegui: $($s.Title)" } }
    }
    $nTweaks = @($steps | Where-Object { $_.Mode -ne 'run' }).Count
    $nRuns = $steps.Count - $nTweaks
    $parts = @()
    if ($nTweaks) { $parts += "$nTweaks modifiche alle impostazioni" }
    if ($nRuns) { $parts += "$nRuns operazioni di pulizia o manutenzione" }
    $body = 'Verranno eseguite: ' + ($parts -join ' e ') + '.'
    if ($nRuns) { $body += ' La pulizia elimina definitivamente i file selezionati.' }
    if ($Sim) { $body += ' Modalità simulazione attiva: nulla verrà modificato davvero.' }
    $script:PlanDraft = @{ Steps = $steps }
    Show-Dialog -Title 'Applicare le modifiche?' -Body $body -Items $lines `
        -CheckText 'Crea prima un punto di ripristino' -CheckValue ([bool]$script:Settings.restorePoint) `
        -Primary 'Applica' -Secondary 'Annulla' -OnPrimary { Start-DraftPlan }
}

function Start-DraftPlan {
    $steps = @($script:PlanDraft.Steps)
    $script:Settings.restorePoint = $script:DlgChecked
    Save-Settings
    $script:LastSteps = $steps
    Set-LogOpen $true
    [void](Start-Work -Status 'Applicazione in corso…' -Vars @{
            Steps = @($steps | ForEach-Object { @{ Id = $_.Id; Mode = $_.Mode } })
            RestorePoint = [bool]$script:DlgChecked
            AutoExplorer = [bool]$script:Settings.restartExplorer
        } -Script { Invoke-Plan -Steps $Steps -RestorePoint $RestorePoint -AutoExplorer $AutoExplorer })
}

function Complete-Summary {
    param($Msg)
    if ($Msg.AppsRemoved) {
        $sim = if ($Msg.Sim) { ' (simulazione)' } else { '' }
        if ($Msg.Fail -eq 0) { Show-Info 'success' "App rimosse$sim" "$($Msg.Ok) app rimosse senza errori." ; Set-Status "App rimosse$sim." 'ok' }
        else { Show-Info 'warning' "Rimozione completata con $($Msg.Fail) errori$sim" "$($Msg.Ok) app rimosse. Dettagli nel registro attività."; Set-Status "Rimozione con $($Msg.Fail) errori." 'warn' }
        return
    }
    if ($Msg.Analysis) {
        Show-Info 'info' 'Analisi completata' ('Circa {0} recuperabili con le voci elencate sotto.' -f (Format-Bytes $Msg.Freed))
        Set-Status 'Analisi completata.' 'ok'
        return
    }
    $steps = @($script:LastSteps)
    if ($Msg.Sim) {
        foreach ($s in $steps) { if ($s.Mode -ne 'run') { $script:State[$s.Id] = ($s.Mode -eq 'apply') } }
    }
    foreach ($s in $steps) {
        if ($s.Mode -eq 'run' -and $script:Controls.ContainsKey($s.Id)) {
            $script:Controls[$s.Id].Ctl.IsChecked = $false
            if ($script:Controls[$s.Id].Size) { $script:Controls[$s.Id].Size.Text = '' }
        }
    }
    if (-not $Msg.Sim) { Sync-States } else { Update-Pending }

    $freed = if ($Msg.Freed -gt 0) { ' Spazio liberato: ' + (Format-Bytes $Msg.Freed) + '.' } else { '' }
    $sim = if ($Msg.Sim) { ' (simulazione)' } else { '' }
    if ($Msg.Fail -eq 0) {
        Show-Info 'success' "Operazione completata$sim" ("$($Msg.Ok) elementi elaborati senza errori.$freed")
        Set-Status "Operazione completata$sim." 'ok'
    } else {
        Show-Info 'warning' "Completata con $($Msg.Fail) errori$sim" ("$($Msg.Ok) elementi riusciti.$freed Controlla il registro attività per i dettagli.")
        Set-Status "Completata con $($Msg.Fail) errori." 'warn'
    }
    if ($Msg.ExplorerPending) { Show-Info 'warning' 'Riavvio di Esplora risorse necessario' 'Alcune modifiche saranno visibili dopo il riavvio di Esplora risorse (Strumenti → Riavvia) o di Windows.' }
}

# ---------------------------------------------------------------- pagina: Home
$script:HomeCtl = @{}

function New-StatCard {
    param([int]$Icon, [string]$Label, [string]$Margin)
    ConvertTo-Element @'
<Border @NS@ Style="{DynamicResource Card}" Padding="18,16" Margin="@MARGIN@">
  <StackPanel>
    <StackPanel Orientation="Horizontal">
      <TextBlock Style="{DynamicResource Glyph}" Text="@ICON@" Foreground="{DynamicResource Accent}"/>
      <TextBlock Text="@LABEL@" Style="{DynamicResource TxtSecondary}" FontSize="13" Margin="10,0,0,0"/>
    </StackPanel>
    <TextBlock x:Name="val" Style="{DynamicResource TxtTitle}" FontSize="30" Margin="0,10,0,10" Text="—"/>
    <ProgressBar x:Name="bar" Maximum="100" Value="0"/>
    <TextBlock x:Name="cap" Style="{DynamicResource TxtCaption}" Margin="0,10,0,0" TextTrimming="CharacterEllipsis" Text=" "/>
  </StackPanel>
</Border>
'@ @{ ICON = (Get-GlyphRef $Icon); LABEL = (Esc $Label); MARGIN = $Margin }
}

function Build-HomePage {
    $panel = New-Object System.Windows.Controls.StackPanel

    # Statistiche in tempo reale
    $grid = New-Object System.Windows.Controls.Primitives.UniformGrid
    $grid.Columns = 3
    $cards = @(
        @{ Key = 'cpu'; Icon = 0xE950; Label = 'Processore'; Margin = '0,0,6,0' },
        @{ Key = 'ram'; Icon = 0xE964; Label = 'Memoria'; Margin = '3,0,3,0' },
        @{ Key = 'disk'; Icon = 0xEDA2; Label = "Disco $env:SystemDrive"; Margin = '6,0,0,0' })
    foreach ($c in $cards) {
        $el = New-StatCard $c.Icon $c.Label $c.Margin
        $script:HomeCtl[$c.Key] = @{ Val = $el.FindName('val'); Bar = $el.FindName('bar'); Cap = $el.FindName('cap') }
        [void]$grid.Children.Add($el)
    }
    [void]$panel.Children.Add($grid)

    # Stato delle ottimizzazioni
    $opt = ConvertTo-Element @'
<Border @NS@ Style="{DynamicResource Card}" Padding="20,18" Margin="0,8,0,0">
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
    <StackPanel VerticalAlignment="Center">
      <TextBlock x:Name="optTitle" Style="{DynamicResource TxtSubtitle}" Text="Ottimizzazioni attive"/>
      <TextBlock x:Name="optDesc" Style="{DynamicResource TxtSecondary}" TextWrapping="Wrap" Margin="0,4,16,0"/>
      <ProgressBar x:Name="optBar" Maximum="100" Margin="0,14,0,0" Width="380" HorizontalAlignment="Left"/>
    </StackPanel>
    <StackPanel Grid.Column="1" VerticalAlignment="Center"><StackPanel x:Name="optBtns"/></StackPanel>
  </Grid>
</Border>
'@
    $script:HomeCtl.opt = @{ Title = $opt.FindName('optTitle'); Desc = $opt.FindName('optDesc'); Bar = $opt.FindName('optBar') }
    $btn = New-Btn 'Ottimizzazione rapida' 'AccentButton' $null { Invoke-QuickOptimize } 0
    $btn.Padding = New-Object System.Windows.Thickness (20, 8, 20, 9)
    [void]$opt.FindName('optBtns').Children.Add($btn)
    [void]$panel.Children.Add($opt)

    # Azioni rapide
    [void]$panel.Children.Add((New-SectionHeader 'Azioni rapide'))
    $quick = @(
        @{ Icon = 0xE74D; Title = 'Pulizia rapida'; Desc = 'Seleziona le voci di pulizia consigliate e chiede conferma prima di eliminarle.'; Btn = 'Pulisci'; Act = { Invoke-QuickClean } },
        @{ Icon = 0xE777; Title = 'Punto di ripristino'; Desc = 'Salva lo stato del sistema per poter annullare le modifiche in caso di problemi.'; Btn = 'Crea'; Act = { Invoke-RestorePoint } },
        @{ Icon = 0xE72C; Title = 'Riavvia Esplora risorse'; Desc = 'Applica subito le modifiche all''interfaccia senza riavviare il PC.'; Btn = 'Riavvia'; Act = { Invoke-RestartExplorer } })
    foreach ($q in $quick) {
        $row = New-Row -Icon $q.Icon -Title $q.Title -Desc $q.Desc
        [void]$row.FindName('right').Children.Add((New-Btn $q.Btn '' $null $q.Act 0))
        [void]$panel.Children.Add($row)
    }

    # Informazioni di sistema
    [void]$panel.Children.Add((New-SectionHeader 'Il tuo sistema'))
    $info = ConvertTo-Element @'
<Border @NS@ Style="{DynamicResource Card}" Padding="20,14">
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <TextBlock Grid.Row="0" Text="Windows" Style="{DynamicResource TxtSecondary}" Margin="0,5"/>
    <TextBlock Grid.Row="0" Grid.Column="1" x:Name="iOs" Margin="0,5" TextWrapping="Wrap" Text="…"/>
    <TextBlock Grid.Row="1" Text="Processore" Style="{DynamicResource TxtSecondary}" Margin="0,5"/>
    <TextBlock Grid.Row="1" Grid.Column="1" x:Name="iCpu" Margin="0,5" TextWrapping="Wrap" Text="…"/>
    <TextBlock Grid.Row="2" Text="Scheda grafica" Style="{DynamicResource TxtSecondary}" Margin="0,5"/>
    <TextBlock Grid.Row="2" Grid.Column="1" x:Name="iGpu" Margin="0,5" TextWrapping="Wrap" Text="…"/>
    <TextBlock Grid.Row="3" Text="Memoria installata" Style="{DynamicResource TxtSecondary}" Margin="0,5"/>
    <TextBlock Grid.Row="3" Grid.Column="1" x:Name="iRam" Margin="0,5" Text="…"/>
    <TextBlock Grid.Row="4" Text="Attivo da" Style="{DynamicResource TxtSecondary}" Margin="0,5"/>
    <TextBlock Grid.Row="4" Grid.Column="1" x:Name="iBoot" Margin="0,5" Text="…"/>
  </Grid>
</Border>
'@
    $script:HomeCtl.info = @{ Os = $info.FindName('iOs'); Cpu = $info.FindName('iCpu'); Gpu = $info.FindName('iGpu'); Ram = $info.FindName('iRam'); Boot = $info.FindName('iBoot') }
    [void]$panel.Children.Add($info)
    $panel
}

function Format-Uptime {
    param([timespan]$Span)
    if ($Span.TotalDays -ge 1) { return '{0} g {1} h' -f [int]$Span.Days, $Span.Hours }
    if ($Span.TotalHours -ge 1) { return '{0} h {1} min' -f [int]$Span.Hours, $Span.Minutes }
    '{0} min' -f [int][math]::Max(1, $Span.Minutes)
}

function Update-HomeOptimizations {
    if (-not $script:HomeCtl.opt) { return }
    $total = 0; $on = 0
    foreach ($id in $script:State.Keys) {
        if ($script:Controls.ContainsKey($id)) { $total++; if ($script:State[$id]) { $on++ } }
    }
    if ($total -eq 0) { return }
    $script:HomeCtl.opt.Title.Text = "$on di $total ottimizzazioni attive"
    $script:HomeCtl.opt.Bar.Value = 100.0 * $on / $total
    $script:HomeCtl.opt.Desc.Text = if ($on -ge $total) { 'Ottimo: tutte le ottimizzazioni disponibili sono già attive.' }
        else { 'Usa «Ottimizzazione rapida» per attivare in sicurezza quelle consigliate, oppure scegli tu nelle altre pagine.' }
}

function Update-HomeLive {
    if ($script:CurrentPage -ne 'home' -or -not $script:HomeCtl.cpu) { return }
    try {
        if (-not $script:CpuCounter -and -not $script:CpuCounterFailed) {
            try { $script:CpuCounter = New-Object System.Diagnostics.PerformanceCounter 'Processor', '% Processor Time', '_Total'; [void]$script:CpuCounter.NextValue() }
            catch { $script:CpuCounterFailed = $true }
        }
        if ($script:CpuCounter) {
            $v = [math]::Min(100, [math]::Round($script:CpuCounter.NextValue()))
            $script:HomeCtl.cpu.Val.Text = "$v%"; $script:HomeCtl.cpu.Bar.Value = $v
        }
        if ($script:SysInfo) {
            $script:HomeCtl.cpu.Cap.Text = '{0} core · {1} thread' -f $script:SysInfo.Cores, $script:SysInfo.Threads
        }
        if ($script:NativeOk) {
            [uint32]$load = 0; [uint64]$tot = 0; [uint64]$av = 0
            [WinOptimaNative]::GetMemory([ref]$load, [ref]$tot, [ref]$av)
            $script:HomeCtl.ram.Val.Text = "$load%"; $script:HomeCtl.ram.Bar.Value = $load
            $script:HomeCtl.ram.Cap.Text = '{0} in uso su {1}' -f (Format-Bytes ($tot - $av)), (Format-Bytes $tot)
        }
        $d = New-Object System.IO.DriveInfo $env:SystemDrive
        $usedPct = [math]::Round(100.0 * ($d.TotalSize - $d.AvailableFreeSpace) / $d.TotalSize)
        $script:HomeCtl.disk.Val.Text = "$usedPct%"; $script:HomeCtl.disk.Bar.Value = $usedPct
        $script:HomeCtl.disk.Cap.Text = '{0} liberi su {1}' -f (Format-Bytes $d.AvailableFreeSpace), (Format-Bytes $d.TotalSize)
        if ($script:SysInfo -and $script:SysInfo.Boot) { $script:HomeCtl.info.Boot.Text = Format-Uptime ((Get-Date) - $script:SysInfo.Boot) }
    } catch { <# i contatori sono opzionali: un errore non deve disturbare l'utente #> }
}

function Update-SystemInfo {
    param($Msg)
    $script:SysInfo = $Msg
    $i = $script:HomeCtl.info
    if (-not $i) { return }
    $i.Os.Text = '{0}  ·  build {1}' -f $Msg.OS, $Msg.Build
    $i.Cpu.Text = $Msg.Cpu
    $i.Gpu.Text = $Msg.Gpu
    $i.Ram.Text = '{0} GB' -f $Msg.RamGB
    Add-LogLine (Get-Date) 'INFO' ('Sistema rilevato: {0} · {1} · {2} GB RAM' -f $Msg.OS, $Msg.Cpu, $Msg.RamGB)
    Update-HomeLive
}

# ---------------------------------------------------------------- azioni rapide
function Invoke-QuickOptimize {
    Set-Preset
    Request-Apply 'all'
}

function Invoke-QuickClean {
    foreach ($id in @($script:Controls.Keys)) {
        $item = $Catalog[$id]
        if ($item.Kind -eq 'action') { $script:Controls[$id].Ctl.IsChecked = [bool]$item.Rec }
    }
    Update-Pending
    Request-Apply 'clean'
}

function Invoke-RestorePoint {
    Set-LogOpen $true
    [void](Start-Work -Status 'Creazione del punto di ripristino…' -Script { [void](New-RestorePoint) })
}

function Invoke-RestartExplorer {
    Set-LogOpen $true
    [void](Start-Work -Status 'Riavvio di Esplora risorse…' -Script { Restart-Explorer })
}

# ---------------------------------------------------------------- pagina: Pulizia
function Build-CleanPage {
    $panel = Build-ItemPage 'clean'
    $analyze = New-Btn 'Analizza spazio' '' $null {
        $ids = @($Catalog.Values | Where-Object { $_.Kind -eq 'action' -and $_.Paths } | ForEach-Object { $_.Id })
        Set-LogOpen $true
        [void](Start-Work -Status 'Analisi dello spazio recuperabile…' -Vars @{ Ids = $ids } -Script { Measure-CleanSpace -Ids $Ids })
    } 0
    $now = New-Btn 'Pulisci ora' 'AccentButton' $null { Request-Apply 'clean' } 8
    $script:HeaderButtons.clean = @($analyze, $now)
    $panel
}

# ---------------------------------------------------------------- pagina: Rete
$script:DnsRows = @()
$script:RdpPill = $null

function Update-DnsView {
    param([string[]]$Servers)
    if ($script:DnsCaption) {
        $script:DnsCaption.Text = if ($Servers.Count) { 'DNS attuali: ' + ($Servers -join ', ') } else { 'DNS attuali: automatico (DHCP)' }
    }
    foreach ($r in $script:DnsRows) {
        $p = $r.Preset
        $r.Pill.Visibility = if ($Servers -contains $p.Servers[0] -and $Servers -contains $p.Servers[1]) { 'Visible' } else { 'Collapsed' }
    }
}

function Update-RdpView {
    param([bool]$Enabled)
    if (-not $script:RdpPill) { return }
    $script:RdpPill.Border.Visibility = 'Visible'
    $script:RdpPill.Text.Text = if ($Enabled) { 'Attivo' } else { 'Disattivo' }
    $key = if ($Enabled) { 'Success' } else { 'Error' }
    $script:RdpPill.Text.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, "${key}Text")
    $script:RdpPill.Border.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, "${key}Fill")
}

function Build-NetPage {
    $panel = New-Object System.Windows.Controls.StackPanel
    [void]$panel.Children.Add((New-SectionHeader 'Desktop remoto (RDP)' $true))

    $pill = '<Border x:Name="rdpPill" Visibility="Collapsed" CornerRadius="9" Padding="8,1,8,2" Margin="10,0,0,0" VerticalAlignment="Center" Background="{DynamicResource InfoFill}"><TextBlock x:Name="rdpText" FontSize="11" Foreground="{DynamicResource InfoText}" Text="…"/></Border>'
    $row = New-Row -Icon 0xE7F4 -Title 'Accesso remoto a questo PC' -Tags $pill `
        -Desc 'Abilita l''host RDP, apre la porta 3389 nel firewall e impedisce la sospensione quando sei in alimentazione di rete. Richiede Windows Pro o superiore.'
    $script:RdpPill = @{ Border = $row.FindName('rdpPill'); Text = $row.FindName('rdpText') }
    $right = $row.FindName('right')
    [void]$right.Children.Add((New-Btn 'Abilita' 'AccentButton' $null {
                Set-LogOpen $true
                [void](Start-Work -Status 'Abilitazione di Desktop remoto…' -Script { Set-RemoteDesktop $true })
            } 0))
    [void]$right.Children.Add((New-Btn 'Disabilita' '' $null {
                Set-LogOpen $true
                [void](Start-Work -Status 'Disabilitazione di Desktop remoto…' -Script { Set-RemoteDesktop $false })
            }))
    [void]$panel.Children.Add($row)

    [void]$panel.Children.Add((New-SectionHeader 'Server DNS'))
    $cap = New-Object System.Windows.Controls.TextBlock
    $cap.Margin = New-Object System.Windows.Thickness (2, 0, 0, 8)
    $cap.SetResourceReference([System.Windows.FrameworkElement]::StyleProperty, 'TxtCaption')
    $cap.Text = 'DNS attuali: lettura in corso…'
    $script:DnsCaption = $cap
    [void]$panel.Children.Add($cap)

    $script:DnsRows = @()
    foreach ($preset in $DnsPresets) {
        $pillXaml = '<Border x:Name="dnsPill" Visibility="Collapsed" CornerRadius="9" Padding="8,1,8,2" Margin="10,0,0,0" VerticalAlignment="Center" Background="{DynamicResource SuccessFill}"><TextBlock FontSize="11" Foreground="{DynamicResource SuccessText}" Text="Attivo"/></Border>'
        $r = New-Row -Icon 0xE774 -Title $preset.Name -Tags $pillXaml -Desc ("{0}  ·  {1}" -f $preset.Desc, ($preset.Servers -join '  /  '))
        $btn = New-Btn 'Imposta' '' $preset {
            $p = $args[0].Tag
            Set-LogOpen $true
            [void](Start-Work -Status "Imposto il DNS $($p.Name)…" -Vars @{ Servers = $p.Servers; Name = $p.Name } -Script { Set-DnsPreset -Servers $Servers -Name $Name })
        } 0
        [void]$r.FindName('right').Children.Add($btn)
        $script:DnsRows += @{ Preset = $preset; Pill = $r.FindName('dnsPill') }
        [void]$panel.Children.Add($r)
    }
    $auto = New-Row -Icon 0xE72C -Title 'Automatico (DHCP)' -Desc 'Ripristina i server DNS assegnati dal router o dal provider.'
    [void]$auto.FindName('right').Children.Add((New-Btn 'Ripristina' '' $null {
                Set-LogOpen $true
                [void](Start-Work -Status 'Ripristino del DNS automatico…' -Script { Reset-DnsAuto })
            } 0))
    [void]$panel.Children.Add($auto)

    [void]$panel.Children.Add((New-SectionHeader 'Riparazione della connessione'))
    $rep = New-Row -Icon 0xE90F -Title 'Ripristina stack TCP/IP e Winsock' `
        -Desc 'Utile in caso di cadute di linea o problemi di rete persistenti. Richiede il riavvio del computer.'
    [void]$rep.FindName('right').Children.Add((New-Btn 'Ripristina rete' '' $null {
                Show-Dialog -Title 'Ripristinare la rete?' `
                    -Body 'Winsock e lo stack TCP/IP torneranno alle impostazioni originali. La connessione potrebbe interrompersi e servirà un riavvio del computer.' `
                    -Primary 'Ripristina' -Secondary 'Annulla' -OnPrimary {
                    Set-LogOpen $true
                    [void](Start-Work -Status 'Ripristino della rete…' -Script { Reset-NetworkStack })
                }
            } 0))
    [void]$panel.Children.Add($rep)
    $panel
}

# ---------------------------------------------------------------- pagina: Strumenti
function Open-Tool {
    param([string]$File, [string]$Arguments = '')
    try {
        if ($Sim) { Write-Log "Avvierebbe: $File $Arguments" 'SIM'; return }
        if ($Arguments) { Start-Process $File -ArgumentList $Arguments -ErrorAction Stop } else { Start-Process $File -ErrorAction Stop }
    } catch { Write-Log "Impossibile aprire ${File}: $($_.Exception.Message)" 'ERROR'; Set-LogOpen $true }
}

function Build-ToolsPage {
    $panel = New-Object System.Windows.Controls.StackPanel
    [void]$panel.Children.Add((New-SectionHeader 'Sicurezza' $true))
    $r = New-Row -Icon 0xE777 -Title 'Punto di ripristino' `
        -Desc 'Salva lo stato del sistema («WinOptima_RestorePoint»). Windows ne consente uno ogni 24 ore.'
    [void]$r.FindName('right').Children.Add((New-Btn 'Crea ora' 'AccentButton' $null { Invoke-RestorePoint } 0))
    [void]$panel.Children.Add($r)

    [void]$panel.Children.Add((New-SectionHeader 'Integrità del sistema'))
    $r = New-Row -Icon 0xE73E -Title 'Verifica i file di sistema (SFC)' `
        -Desc 'Scansiona i file protetti di Windows e sostituisce quelli danneggiati. Si apre una finestra con l''avanzamento.'
    [void]$r.FindName('right').Children.Add((New-Btn 'Avvia scansione' '' $null {
                Write-Log 'Avvio della scansione SFC in una finestra dedicata.'; Set-LogOpen $true; Open-Tool 'cmd.exe' '/k sfc /scannow'
            } 0))
    [void]$panel.Children.Add($r)
    $r = New-Row -Icon 0xE90F -Title 'Ripara l''archivio componenti (DISM)' `
        -Desc 'Scarica da Windows Update i file originali per riparare l''immagine del sistema (DISM /RestoreHealth).'
    [void]$r.FindName('right').Children.Add((New-Btn 'Avvia riparazione' '' $null {
                Write-Log 'Avvio della riparazione DISM in una finestra dedicata.'; Set-LogOpen $true; Open-Tool 'cmd.exe' '/k DISM /Online /Cleanup-Image /RestoreHealth'
            } 0))
    [void]$panel.Children.Add($r)
    $r = New-Row -Icon 0xE895 -Title 'Ripristina Windows Update' `
        -Desc 'Arresta i servizi, svuota la cache dei download e li riavvia: sblocca aggiornamenti bloccati.'
    [void]$r.FindName('right').Children.Add((New-Btn 'Ripristina' '' $null {
                Show-Dialog -Title 'Ripristinare Windows Update?' `
                    -Body 'I servizi di aggiornamento verranno fermati e riavviati e i download già scaricati saranno eliminati.' `
                    -Primary 'Ripristina' -Secondary 'Annulla' -OnPrimary {
                    Set-LogOpen $true
                    [void](Start-Work -Status 'Ripristino di Windows Update…' -Script { Reset-WindowsUpdate })
                }
            } 0))
    [void]$panel.Children.Add($r)
    $r = New-Row -Icon 0xE72C -Title 'Riavvia Esplora risorse' -Desc 'Ricarica barra delle applicazioni, menu Start ed Esplora file senza riavviare il PC.'
    [void]$r.FindName('right').Children.Add((New-Btn 'Riavvia' '' $null { Invoke-RestartExplorer } 0))
    [void]$panel.Children.Add($r)

    # Collegamenti rapidi agli strumenti di Windows, divisi per argomento
    $linkGroups = [ordered]@{
        'Gestione del sistema' = @(
            @{ Icon = 0xE770; Title = 'Gestione computer'; Desc = 'Console unica con dischi, dispositivi, servizi, eventi, utenti e cartelle condivise.'; File = 'compmgmt.msc' },
            @{ Icon = 0xE950; Title = 'Gestione dispositivi'; Desc = 'Hardware installato, driver e dispositivi con problemi.'; File = 'devmgmt.msc' },
            @{ Icon = 0xEDA2; Title = 'Gestione disco'; Desc = 'Partizioni, volumi e unità collegate.'; File = 'diskmgmt.msc' },
            @{ Icon = 0xE713; Title = 'Servizi'; Desc = 'Elenco e configurazione dei servizi di Windows.'; File = 'services.msc' },
            @{ Icon = 0xE823; Title = 'Utilità di pianificazione'; Desc = 'Attività programmate, comprese quelle che partono all''accesso.'; File = 'taskschd.msc' },
            @{ Icon = 0xE8A9; Title = 'App installate'; Desc = 'Disinstalla o modifica i programmi.'; File = 'ms-settings:appsfeatures' },
            @{ Icon = 0xE9F5; Title = 'Pannello di controllo'; Desc = 'Le impostazioni classiche di Windows.'; File = 'control.exe' },
            @{ Icon = 0xE770; Title = 'Proprietà del sistema'; Desc = 'Nome del computer, variabili d''ambiente, prestazioni e memoria virtuale.'; File = 'SystemPropertiesAdvanced.exe' },
            @{ Icon = 0xE777; Title = 'Protezione del sistema'; Desc = 'Punti di ripristino e ripristino configurazione di sistema.'; File = 'SystemPropertiesProtection.exe' },
            @{ Icon = 0xE7E8; Title = 'Opzioni risparmio energia'; Desc = 'Piani energetici e comportamento dei pulsanti di accensione.'; File = 'powercfg.cpl' },
            @{ Icon = 0xE895; Title = 'Windows Update'; Desc = 'Aggiornamenti, cronologia e opzioni avanzate.'; File = 'ms-settings:windowsupdate' },
            @{ Icon = 0xE74D; Title = 'Pulizia disco di Windows'; Desc = 'Lo strumento classico di Microsoft per liberare spazio.'; File = 'cleanmgr.exe' })
        'Rete' = @(
            @{ Icon = 0xE839; Title = 'Connessioni di rete'; Desc = 'Schede di rete: attiva, disattiva, proprietà IP e DNS (ncpa.cpl).'; File = 'ncpa.cpl' },
            @{ Icon = 0xE774; Title = 'Stato della rete'; Desc = 'Impostazioni di rete e Internet, utilizzo dati e ripristino rete.'; File = 'ms-settings:network-status' },
            @{ Icon = 0xE701; Title = 'Wi-Fi'; Desc = 'Reti disponibili e reti salvate.'; File = 'ms-settings:network-wifi' },
            @{ Icon = 0xE705; Title = 'Windows Defender Firewall'; Desc = 'Regole in entrata e in uscita, profili di rete (console avanzata).'; File = 'wf.msc' },
            @{ Icon = 0xE8B7; Title = 'Centro connessioni di rete e condivisione'; Desc = 'Condivisione di file e stampanti, rilevamento rete.'; File = 'control.exe'; Args = '/name Microsoft.NetworkAndSharingCenter' })
        'Diagnostica' = @(
            @{ Icon = 0xE9D9; Title = 'Gestione attività'; Desc = 'Processi, prestazioni e utilizzo delle risorse.'; File = 'taskmgr.exe' },
            @{ Icon = 0xE9D9; Title = 'Monitoraggio risorse'; Desc = 'CPU, memoria, disco e rete per singolo processo.'; File = 'resmon.exe' },
            @{ Icon = 0xE7BA; Title = 'Visualizzatore eventi'; Desc = 'Errori e avvisi registrati da Windows e dalle applicazioni.'; File = 'eventvwr.msc' },
            @{ Icon = 0xE946; Title = 'Informazioni di sistema'; Desc = 'Riepilogo dettagliato di hardware, componenti e software.'; File = 'msinfo32.exe' },
            @{ Icon = 0xE81C; Title = 'Monitoraggio affidabilità'; Desc = 'Cronologia di arresti anomali, installazioni e problemi.'; File = 'perfmon.exe'; Args = '/rel' },
            @{ Icon = 0xE756; Title = 'Prompt dei comandi (amministratore)'; Desc = 'Riga di comando con i privilegi di WinOptima.'; File = 'cmd.exe' },
            @{ Icon = 0xE756; Title = 'Editor del Registro di sistema'; Desc = 'Per utenti esperti: modifiche errate possono danneggiare Windows.'; File = 'regedit.exe' })
    }
    foreach ($g in $linkGroups.Keys) {
        [void]$panel.Children.Add((New-SectionHeader $g))
        foreach ($l in $linkGroups[$g]) {
            $row = New-Row -Icon $l.Icon -Title $l.Title -Desc $l.Desc
            [void]$row.FindName('right').Children.Add((New-Btn 'Apri' 'SubtleButton' $l { $t = $args[0].Tag; Open-Tool $t.File $t.Args } 0))
            [void]$panel.Children.Add($row)
        }
    }
    $panel
}

# ---------------------------------------------------------------- pagina: Avvio e notifiche
# Le modifiche qui sono immediate (come in Gestione attività), non passano da «Applica».
$script:IconCache = @{}
$script:SuppressToggle = $false
$KeyExplorer = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'

function Get-AppIconImage {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $k = $Path.ToLowerInvariant()
    if ($script:IconCache.ContainsKey($k)) { return $script:IconCache[$k] }
    $src = $null
    try {
        $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($Path)
        $src = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($ico.Handle, [System.Windows.Int32Rect]::Empty,
            [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
        $src.Freeze()
        $ico.Dispose()
    } catch {}
    $script:IconCache[$k] = $src
    $src
}

# Sostituisce il glifo della riga con l'icona vera del programma, se disponibile
function Set-RowIcon {
    param($Row, [string]$Path)
    $src = Get-AppIconImage $Path
    if (-not $src) { return }
    $img = New-Object System.Windows.Controls.Image
    $img.Width = 24; $img.Height = 24; $img.Source = $src
    [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($img, 'HighQuality')
    $Row.FindName('glyph').Visibility = 'Collapsed'
    [void]$Row.FindName('iconHost').Children.Add($img)
}

function New-Caption {
    param([string]$Text)
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text
    $tb.TextWrapping = 'Wrap'
    $tb.Margin = New-Object System.Windows.Thickness (2, 0, 0, 8)
    $tb.SetResourceReference([System.Windows.FrameworkElement]::StyleProperty, 'TxtCaption')
    $tb
}

function Get-ShortText { param([string]$Text, [int]$Max = 110) if ($Text.Length -le $Max) { $Text } else { $Text.Substring(0, $Max - 1) + '…' } }

$ToggleXaml = '<ToggleButton x:Name="tgl" Style="{DynamicResource ToggleSwitch}" VerticalAlignment="Center"/>'

# Esegue un'azione immediata legata a un interruttore; se fallisce rimette l'interruttore com'era
function Invoke-ToggleAction {
    param($Toggle, [scriptblock]$Action)
    if ($script:SuppressToggle) { return }
    try { & $Action }
    catch {
        Write-Log $_.Exception.Message 'ERROR'
        Show-Info 'error' 'Modifica non riuscita' $_.Exception.Message
        $script:SuppressToggle = $true
        $Toggle.IsChecked = -not [bool]$Toggle.IsChecked
        $script:SuppressToggle = $false
    }
}

function Request-RemoveStartup {
    param([hashtable]$App)
    $script:StartupToRemove = $App
    Show-Dialog -Title "Eliminare «$($App.Name)» dall'avvio?" `
        -Body "La voce verrà rimossa da: $($App.Source). Il programma resta installato, semplicemente non partirà più con Windows. Prima viene salvata una copia ripristinabile (file .reg o collegamento) nella cartella Backup." `
        -Items @($App.Command) -Primary 'Elimina' -Secondary 'Annulla' -OnPrimary {
        $app = $script:StartupToRemove
        try {
            $backup = Remove-StartupApp $app
            if ($backup) { Show-Info 'success' "«$($app.Name)» eliminata dall'avvio" "Per ripristinarla apri la copia di sicurezza: $backup" }
            else { Show-Info 'info' 'Simulazione' "«$($app.Name)» verrebbe eliminata dall'avvio (con copia di sicurezza)." }
        } catch {
            Write-Log "Eliminazione di «$($app.Name)» non riuscita: $($_.Exception.Message)" 'ERROR'
            Show-Info 'error' 'Eliminazione non riuscita' $_.Exception.Message
        }
        Update-AppsPage
    }
}

function Build-AppsPage {
    $script:AppsPanel = New-Object System.Windows.Controls.StackPanel
    $refresh = New-Btn 'Aggiorna' '' $null { Update-AppsPage; Set-Status 'Elenchi aggiornati.' 'ok' } 0
    $script:HeaderButtons.apps = @($refresh)
    $script:AppsPanel
}

function Update-AppsPage {
    $panel = $script:AppsPanel
    $panel.Children.Clear()

    # ---- app di avvio
    [void]$panel.Children.Add((New-SectionHeader 'App di avvio' $true))
    $apps = @(Get-StartupApps | Sort-Object { $_.Name })
    $off = @($apps | Where-Object { -not $_.Enabled }).Count
    if ($apps.Count) {
        [void]$panel.Children.Add((New-Caption ("{0} app partono con Windows ({1} disattivate). Le modifiche hanno effetto subito; «Elimina» salva prima una copia ripristinabile." -f $apps.Count, $off)))
    } else {
        [void]$panel.Children.Add((New-Caption 'Nessuna app configurata per l''avvio automatico.'))
    }
    foreach ($a in $apps) {
        $row = New-Row -Icon 0xE768 -Title $a.Name -Desc ('{0}  ·  {1}' -f $a.Source, (Get-ShortText $a.Command)) -Tip $a.Command -Right $ToggleXaml
        Set-RowIcon $row $a.Exe
        $tgl = $row.FindName('tgl')
        $tgl.IsChecked = [bool]$a.Enabled
        $tgl.Tag = $a
        [System.Windows.Automation.AutomationProperties]::SetName($tgl, "Avvio automatico di $($a.Name)")
        $onStartup = {
            $t = $args[0]
            Invoke-ToggleAction $t { Set-StartupEnabled $t.Tag ([bool]$t.IsChecked); $t.Tag.Enabled = [bool]$t.IsChecked }
        }
        $tgl.Add_Checked($onStartup)
        $tgl.Add_Unchecked($onStartup)
        $del = New-Btn '' 'SubtleButton' $a { Request-RemoveStartup $args[0].Tag } 6
        $del.Content = ConvertTo-Element '<TextBlock @NS@ Style="{DynamicResource Glyph}" Text="&#xE74D;" FontSize="14"/>'
        $del.Padding = New-Object System.Windows.Thickness (10, 7, 10, 7)
        $del.ToolTip = 'Elimina dall''avvio'
        [System.Windows.Automation.AutomationProperties]::SetName($del, "Elimina $($a.Name) dall'avvio")
        [void]$row.FindName('right').Children.Add($del)
        [void]$panel.Children.Add($row)
    }

    # ---- icone dell'area di notifica
    [void]$panel.Children.Add((New-SectionHeader 'Icone dell''area di notifica'))
    $icons = Get-TrayIcons
    if ($null -eq $icons) {
        # Windows 10 / 11 21H2: esiste solo l'opzione globale
        $row = New-Row -Icon 0xE8A9 -Title 'Mostra sempre tutte le icone' -Right $ToggleXaml `
            -Desc 'Tutte le icone restano visibili accanto all''orologio invece che nel menu «^». Visibile dopo il riavvio di Esplora risorse.'
        $tgl = $row.FindName('tgl')
        $tgl.IsChecked = ((Get-RegValue $KeyExplorer 'EnableAutoTray') -eq 0)
        $onAll = {
            $t = $args[0]
            Invoke-ToggleAction $t {
                if ($t.IsChecked) { Set-RegValue $KeyExplorer 'EnableAutoTray' 0 } else { Remove-RegValue $KeyExplorer 'EnableAutoTray' }
                Write-Log 'Area di notifica aggiornata: riavvia Esplora risorse per vedere la modifica.' 'SUCCESS'
            }
        }
        $tgl.Add_Checked($onAll)
        $tgl.Add_Unchecked($onAll)
        [void]$panel.Children.Add($row)
        return
    }

    $icons = @($icons)
    $visible = @($icons | Where-Object { $_.Exists })
    $stale = $icons.Count - $visible.Count
    $cap = "{0} app con un'icona nell'area di notifica, {1} sempre visibili sulla barra. Spento = icona nel menu «^» delle icone nascoste." -f $visible.Count, @($visible | Where-Object { $_.Promoted }).Count
    if ($stale) { $cap += " Non mostrate: $stale voci di programmi non più presenti." }
    [void]$panel.Children.Add((New-Caption $cap))

    $all = New-Row -Icon 0xE8A9 -Title 'Tutte le icone' -Desc 'Mostra o nasconde in un colpo solo le icone di tutte le app elencate.'
    $bulk = {
        $show = [bool]$args[0].Tag
        try { foreach ($i in @(Get-TrayIcons | Where-Object { $_.Exists })) { Set-TrayIconPromoted $i $show } }
        catch { Write-Log $_.Exception.Message 'ERROR'; Show-Info 'error' 'Modifica non riuscita' $_.Exception.Message }
        Update-AppsPage
    }
    [void]$all.FindName('right').Children.Add((New-Btn 'Mostra tutte' '' $true $bulk 0))
    [void]$all.FindName('right').Children.Add((New-Btn 'Nascondi tutte' '' $false $bulk))
    [void]$panel.Children.Add($all)

    foreach ($i in $visible) {
        $row = New-Row -Icon 0xE7F4 -Title $i.Name -Desc (Get-ShortText $i.Exe) -Tip $i.Exe -Right $ToggleXaml
        Set-RowIcon $row $i.Exe
        $tgl = $row.FindName('tgl')
        $tgl.IsChecked = [bool]$i.Promoted
        $tgl.Tag = $i
        [System.Windows.Automation.AutomationProperties]::SetName($tgl, "Icona di $($i.Name) sempre visibile")
        $onTray = {
            $t = $args[0]
            Invoke-ToggleAction $t { Set-TrayIconPromoted $t.Tag ([bool]$t.IsChecked); $t.Tag.Promoted = [bool]$t.IsChecked }
        }
        $tgl.Add_Checked($onTray)
        $tgl.Add_Unchecked($onTray)
        [void]$panel.Children.Add($row)
    }
}

# ---------------------------------------------------------------- pagina: App preinstallate
$script:BloatChecks = @()

function Build-BloatPage {
    $script:BloatPanel = New-Object System.Windows.Controls.StackPanel
    $refresh = New-Btn 'Aggiorna' '' $null { Update-BloatPage } 0
    $script:BloatRemoveBtn = New-Btn 'Rimuovi selezionate' 'AccentButton' $null { Request-RemoveApps } 8
    $script:BloatRemoveBtn.IsEnabled = $false
    $script:HeaderButtons.bloat = @($refresh, $script:BloatRemoveBtn)
    $script:BloatPanel
}

function Update-BloatPage {
    $script:BloatPanel.Children.Clear()
    $script:BloatChecks = @()
    Update-BloatCount
    [void]$script:BloatPanel.Children.Add((New-SectionHeader 'App dello Store' $true))
    [void]$script:BloatPanel.Children.Add((New-Caption 'Lettura delle app installate…'))
    [void](Start-Work -Background -Script { Send-BloatState })
}

function Update-BloatCount {
    $n = @($script:BloatChecks | Where-Object { $_.IsChecked }).Count
    $script:BloatRemoveBtn.Content = if ($n) { "Rimuovi selezionate ($n)" } else { 'Rimuovi selezionate' }
    $script:BloatRemoveBtn.IsEnabled = ($n -gt 0)
}

function Show-BloatState {
    param($Msg)
    $panel = $script:BloatPanel
    $panel.Children.Clear()
    $script:BloatChecks = @()
    $apps = @($Msg.Apps | Sort-Object @{ Expression = { -not $_.Rec } }, @{ Expression = { $_.Display } })
    $progs = @($Msg.Programs)

    [void]$panel.Children.Add((New-SectionHeader 'App dello Store' $true))
    $rec = @($apps | Where-Object { $_.Rec }).Count
    if ($apps.Count) {
        [void]$panel.Children.Add((New-Caption ("{0} app rimovibili, {1} con rimozione consigliata. Componenti di sistema, Store, driver ed Edge non vengono mostrati. Puoi sempre reinstallarle dal Microsoft Store." -f $apps.Count, $rec)))
        $sel = New-Row -Icon 0xE73E -Title 'Selezione rapida' -Desc 'Spunta tutte le app con rimozione consigliata, oppure togli tutte le spunte.'
        [void]$sel.FindName('right').Children.Add((New-Btn 'Seleziona consigliate' '' $null { foreach ($c in $script:BloatChecks) { $c.IsChecked = [bool]$c.Tag.Rec }; Update-BloatCount } 0))
        [void]$sel.FindName('right').Children.Add((New-Btn 'Nessuna' 'SubtleButton' $null { foreach ($c in $script:BloatChecks) { $c.IsChecked = $false }; Update-BloatCount }))
        [void]$panel.Children.Add($sel)
    } else {
        [void]$panel.Children.Add((New-Caption 'Nessuna app preinstallata da rimuovere: il sistema è già pulito.'))
    }
    $tag = $TagTemplate.Replace('@FILL@', 'WarnFill').Replace('@TEXT@', 'WarnText').Replace('@LABEL@', 'Rimozione consigliata')
    foreach ($a in $apps) {
        $row = New-Row -Icon 0xE719 -Title $a.Display -Tags $(if ($a.Rec) { $tag } else { '' }) -Tip $a.FullName `
            -Desc ('{0}  ·  versione {1}  ·  {2}' -f $a.Name, $a.Version, $a.Publisher) `
            -Right '<CheckBox x:Name="ctl" VerticalAlignment="Center" Margin="14,0,0,0"/>'
        $chk = $row.FindName('ctl')
        $chk.Tag = $a
        [System.Windows.Automation.AutomationProperties]::SetName($chk, "Rimuovi $($a.Display)")
        $chk.Add_Checked({ Update-BloatCount }); $chk.Add_Unchecked({ Update-BloatCount })
        $row.Tag = $chk
        $row.Add_MouseLeftButtonUp({ $c = $args[0].Tag; $c.IsChecked = -not [bool]$c.IsChecked })
        $script:BloatChecks += $chk
        [void]$panel.Children.Add($row)
    }

    [void]$panel.Children.Add((New-SectionHeader 'Programmi desktop preinstallati'))
    if ($progs.Count) {
        [void]$panel.Children.Add((New-Caption 'Office/Microsoft 365 in più lingue, antivirus in prova e simili. «Disinstalla» apre il programma di disinstallazione ufficiale.'))
        foreach ($p in $progs) {
            $size = if ($p.SizeMB) { "  ·  $($p.SizeMB) MB" } else { '' }
            $row = New-Row -Icon 0xE74D -Title $p.Name -Desc ('{0}  ·  versione {1}{2}' -f $p.Publisher, $p.Version, $size) -Tip $p.Uninstall
            [void]$row.FindName('right').Children.Add((New-Btn 'Disinstalla' '' $p { Request-UninstallProgram $args[0].Tag } 0))
            [void]$panel.Children.Add($row)
        }
    } else {
        [void]$panel.Children.Add((New-Caption 'Nessun programma preinstallato riconosciuto (Office in prova, antivirus in prova…). Gli altri programmi si gestiscono da Strumenti → App installate.'))
    }
    Update-BloatCount
}

function Request-RemoveApps {
    $sel = @($script:BloatChecks | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag })
    if (-not $sel.Count) { return }
    $script:AppsToRemove = $sel
    Show-Dialog -Title "Rimuovere $($sel.Count) app?" `
        -Body 'Le app verranno disinstallate per il tuo utente. Potrai reinstallarle in qualsiasi momento dal Microsoft Store.' `
        -Items @($sel | ForEach-Object { "✕  $($_.Display)" }) `
        -CheckText 'Impedisci la reinstallazione automatica per i nuovi utenti' -CheckValue ([bool]$script:Settings.deprovision) `
        -Primary 'Rimuovi' -Secondary 'Annulla' -OnPrimary {
        $script:Settings.deprovision = $script:DlgChecked; Save-Settings
        Set-LogOpen $true
        [void](Start-Work -Status 'Rimozione delle app…' -Vars @{ Apps = $script:AppsToRemove; Dep = [bool]$script:DlgChecked } `
                -Script { Remove-Apps -Apps $Apps -Deprovision $Dep } -OnDone { if ($script:CurrentPage -eq 'bloat') { Update-BloatPage } })
    }
}

# Avvia il disinstallatore del programma (per gli MSI forza /X = disinstalla, non /I = installa/ripara)
function Request-UninstallProgram {
    param([hashtable]$Program)
    $script:ProgramToUninstall = $Program
    Show-Dialog -Title "Disinstallare «$($Program.Name)»?" `
        -Body 'Si aprirà il programma di disinstallazione ufficiale: segui le sue istruzioni per completare.' `
        -Items @($Program.Uninstall) -Primary 'Disinstalla' -Secondary 'Annulla' -OnPrimary {
        $p = $script:ProgramToUninstall
        $cmd = [Environment]::ExpandEnvironmentVariables($p.Uninstall.Trim())
        if ($cmd -match '(?i)msiexec(\.exe)?\s+/[IX]\s*(\{[0-9A-F-]+\})') { $file = 'msiexec.exe'; $arg = "/x $($Matches[2])" }
        else {
            $file = Get-ExePath $cmd
            $rest = if ($cmd.StartsWith('"')) { $cmd.Substring($cmd.IndexOf('"', 1) + 1) } else { $cmd.Substring([math]::Min($cmd.Length, $file.Length)) }
            $arg = $rest.Trim()
        }
        Set-LogOpen $true
        if ($Sim) { Write-Log "Avvierebbe: $file $arg" 'SIM'; return }
        try {
            if ($arg) { Start-Process -FilePath $file -ArgumentList $arg -ErrorAction Stop } else { Start-Process -FilePath $file -ErrorAction Stop }
            Write-Log "Avviata la disinstallazione di $($p.Name)." 'SUCCESS'
            Show-Info 'info' "Disinstallazione di «$($p.Name)» avviata" 'Completa la procedura nella finestra che si è aperta, poi premi «Aggiorna».'
        } catch {
            Write-Log "Impossibile avviare la disinstallazione di $($p.Name): $($_.Exception.Message)" 'ERROR'
            Show-Info 'error' 'Disinstallazione non avviata' $_.Exception.Message
        }
    }
}

# ---------------------------------------------------------------- pagina: Impostazioni
$script:ThemeButtons = @{}

function Update-ThemeButtons {
    foreach ($k in $script:ThemeButtons.Keys) {
        $b = $script:ThemeButtons[$k]
        if ($k -eq $script:Settings.theme) { $b.SetResourceReference([System.Windows.FrameworkElement]::StyleProperty, 'AccentButton') }
        # ClearValue (non "Style = $null": quello disattiverebbe anche lo stile implicito dei pulsanti)
        else { $b.ClearValue([System.Windows.FrameworkElement]::StyleProperty) }
    }
}

function Set-SimulationUi {
    $ui.SimBanner.Visibility = if ($Sim) { 'Visible' } else { 'Collapsed' }
}

function Build-SettingsPage {
    $panel = New-Object System.Windows.Controls.StackPanel
    [void]$panel.Children.Add((New-SectionHeader 'Aspetto' $true))
    $row = New-Row -Icon 0xE771 -Title 'Tema dell''app' -Desc 'Segue il tema di Windows oppure usa sempre il chiaro o lo scuro. Il colore di accento è quello del sistema.'
    foreach ($t in @(@('system', 'Sistema'), @('light', 'Chiaro'), @('dark', 'Scuro'))) {
        $b = New-Btn $t[1] '' $t[0] {
            $script:Settings.theme = $args[0].Tag
            Save-Settings
            Set-AppTheme
            Update-ThemeButtons
        } $(if ($t[0] -eq 'system') { 0 } else { 6 })
        $script:ThemeButtons[$t[0]] = $b
        [void]$row.FindName('right').Children.Add($b)
    }
    Update-ThemeButtons
    [void]$panel.Children.Add($row)

    [void]$panel.Children.Add((New-SectionHeader 'Comportamento'))
    $tpl = '<ToggleButton x:Name="tgl" Style="{DynamicResource ToggleSwitch}" VerticalAlignment="Center"/>'
    $row = New-Row -Icon 0xE9D9 -Title 'Modalità simulazione' -Right $tpl `
        -Desc 'Mostra nel registro cosa farebbe l''app senza modificare nulla. Ideale per provare le ottimizzazioni in sicurezza.'
    $tgl = $row.FindName('tgl'); $tgl.IsChecked = [bool]$Sim
    $onSim = {
        $script:Sim = [bool]$args[0].IsChecked
        $script:Settings.simulate = $script:Sim
        Save-Settings
        Set-SimulationUi
    }
    $tgl.Add_Checked($onSim)
    $tgl.Add_Unchecked($onSim)
    [void]$panel.Children.Add($row)
    $row = New-Row -Icon 0xE72C -Title 'Riavvia Esplora risorse automaticamente' -Right $tpl `
        -Desc 'Quando una modifica lo richiede, ricarica la shell di Windows al termine per renderla subito visibile.'
    $tgl = $row.FindName('tgl'); $tgl.IsChecked = [bool]$script:Settings.restartExplorer
    $onExplorer = { $script:Settings.restartExplorer = [bool]$args[0].IsChecked; Save-Settings }
    $tgl.Add_Checked($onExplorer)
    $tgl.Add_Unchecked($onExplorer)
    [void]$panel.Children.Add($row)

    [void]$panel.Children.Add((New-SectionHeader 'Aggiornamenti'))
    $row = New-Row -Icon 0xE895 -Title 'Aggiornamenti automatici' -Right $tpl `
        -Desc "Versione installata: $script:AppVersion. All'avvio controlla le release su GitHub (contatta solo api.github.com), scarica e verifica la nuova versione e la installa alla chiusura. La precedente resta come «.old.exe»."
    $tgl = $row.FindName('tgl'); $tgl.IsChecked = [bool]$script:Settings.autoUpdate
    $onUpd = { $script:Settings.autoUpdate = [bool]$args[0].IsChecked; Save-Settings }
    $tgl.Add_Checked($onUpd)
    $tgl.Add_Unchecked($onUpd)
    [void]$row.FindName('right').Children.Add((New-Btn 'Controlla ora' '' $null { Start-UpdateCheck -Manual; Set-Status 'Controllo aggiornamenti…' 'busy' } 12))
    [void]$panel.Children.Add($row)

    [void]$panel.Children.Add((New-SectionHeader 'Informazioni'))
    $about = New-Row -Icon 0xE946 -Title "WinOptima Portable $script:AppVersion" `
        -Desc ("Suite portatile di ottimizzazione, privacy e pulizia per Windows 10 e 11. Tutto il codice è leggibile in WinOptima.ps1.`nCartella: $script:AppDir")
    [void]$panel.Children.Add($about)
    $panel
}

# ---------------------------------------------------------------- navigazione e pagine
$PageDefs = @(
    @{ Key = 'home';     Title = 'Home';              Icon = 0xE80F; Sub = 'Panoramica del sistema e azioni rapide.' },
    @{ Key = 'perf';     Title = 'Prestazioni';       Icon = 0xE945; Sub = 'Rendi Windows più reattivo e sfrutta al meglio l''hardware.' },
    @{ Key = 'privacy';  Title = 'Privacy';           Icon = 0xE705; Sub = 'Riduci tracciamento, telemetria e profilazione pubblicitaria.' },
    @{ Key = 'ui';       Title = 'Personalizzazione'; Icon = 0xE771; Sub = 'Esplora file, barra delle applicazioni e menu Start.' },
    @{ Key = 'apps';     Title = 'Avvio e notifiche'; Icon = 0xE768; Sub = 'App che partono con Windows e icone visibili nell''area di notifica.' },
    @{ Key = 'bloat';    Title = 'App preinstallate'; Icon = 0xE8A9; Sub = 'Rimuovi app e programmi installati in fabbrica che non usi.' },
    @{ Key = 'clean';    Title = 'Pulizia';           Icon = 0xE74D; Sub = 'Recupera spazio eliminando cache, dump e file temporanei.' },
    @{ Key = 'net';      Title = 'Rete';              Icon = 0xE774; Sub = 'Desktop remoto, DNS veloci e riparazione della connessione.' },
    @{ Key = 'tools';    Title = 'Strumenti';         Icon = 0xE90F; Sub = 'Punti di ripristino, verifica dei file di sistema e manutenzione.' },
    @{ Key = 'settings'; Title = 'Impostazioni';      Icon = 0xE713; Sub = 'Tema, simulazione e informazioni sull''app.' })
$PagesByKey = @{}
foreach ($p in $PageDefs) { $PagesByKey[$p.Key] = $p }
$script:PageContent = @{}
$script:HeaderButtons = @{}
$script:NavButtons = @{}

function Show-Page {
    param([string]$Key)
    $page = $PagesByKey[$Key]
    $script:CurrentPage = $Key
    $ui.PageTitle.Text = $page.Title
    $ui.PageSubtitle.Text = $page.Sub
    $ui.PageHost.Content = $script:PageContent[$Key]
    if (-not $script:InfoSticky) { $ui.InfoBar.Visibility = 'Collapsed' }    # gli avvisi riguardano la pagina in cui sono nati
    $ui.HeaderActions.Children.Clear()
    foreach ($b in @($script:HeaderButtons[$Key])) { if ($b) { [void]$ui.HeaderActions.Children.Add($b) } }
    $ui.CommandBar.Visibility = if ($Key -in 'settings', 'net', 'tools', 'apps', 'bloat') { 'Collapsed' } else { 'Visible' }
    if ($Key -eq 'apps') { Update-AppsPage }
    if ($Key -eq 'bloat') { Update-BloatPage }
    $ui.BtnSelectAll.Visibility = if ($Key -eq 'home') { 'Collapsed' } else { 'Visible' }
    $ui.BtnSelectAll.ToolTip = "Seleziona tutte le voci della pagina «$($PagesByKey[$Key].Title)»"
    $ui.PageScroll.ScrollToTop()
    if (-not $script:NavButtons[$Key].IsChecked) { $script:NavButtons[$Key].IsChecked = $true }
    if ($Key -eq 'home') { Update-HomeLive }
    if ($Key -eq 'net') {
        [void](Start-Work -Background -Script { Send-DnsState; Send-RdpState })
    }
}

foreach ($p in $PageDefs) {
    $rb = New-Object System.Windows.Controls.RadioButton
    $rb.GroupName = 'nav'
    $rb.Tag = $p.Key
    $rb.SetResourceReference([System.Windows.FrameworkElement]::StyleProperty, 'NavItem')
    $rb.Content = ConvertTo-Element @'
<StackPanel @NS@ Orientation="Horizontal">
  <TextBlock Style="{DynamicResource Glyph}" Text="@ICON@" Width="22" FontSize="16" VerticalAlignment="Center"/>
  <TextBlock Text="@TITLE@" Margin="12,0,0,0" VerticalAlignment="Center"/>
</StackPanel>
'@ @{ ICON = (Get-GlyphRef $p.Icon); TITLE = (Esc $p.Title) }
    $rb.Add_Checked({ $k = $args[0].Tag; if ($script:CurrentPage -ne $k) { Show-Page $k } })
    $script:NavButtons[$p.Key] = $rb
    if ($p.Key -eq 'settings') { [void]$ui.NavFooter.Children.Add($rb) } else { [void]$ui.NavList.Children.Add($rb) }
}

# Costruzione delle pagine dal catalogo
$script:PageContent.home = Build-HomePage
$script:PageContent.perf = Build-ItemPage 'perf'
$script:PageContent.privacy = Build-ItemPage 'privacy'
$script:PageContent.ui = Build-ItemPage 'ui'
$script:PageContent.clean = Build-CleanPage
$script:PageContent.net = Build-NetPage
$script:PageContent.tools = Build-ToolsPage
$script:PageContent.apps = Build-AppsPage
$script:PageContent.bloat = Build-BloatPage
$script:PageContent.settings = Build-SettingsPage

# ---------------------------------------------------------------- pulsanti della barra dei comandi
$ui.BtnPreset.Add_Click({ Set-Preset; Write-Log 'Selezionate le ottimizzazioni consigliate: controlla e premi Applica.' })
$ui.BtnSelectAll.Add_Click({
    # Solo la pagina visibile: selezionare voci di altre pagine senza vederle sarebbe una sorpresa
    foreach ($id in @($script:Controls.Keys)) {
        if ($Catalog[$id].Page -eq $script:CurrentPage) { $script:Controls[$id].Ctl.IsChecked = $true }
    }
    Update-Pending
})
$ui.BtnReset.Add_Click({
    foreach ($id in @($script:Controls.Keys)) {
        $item = $Catalog[$id]
        $script:Controls[$id].Ctl.IsChecked = if ($item.Kind -eq 'action') { $false } else { [bool]$script:State[$id] }
    }
    Update-Pending
})
$ui.BtnApply.Add_Click({ Request-Apply 'all' })
$ui.BtnLogToggle.Add_Click({ Set-LogOpen ($ui.LogBox.Visibility -ne 'Visible') })
$ui.BtnLogClear.Add_Click({ $ui.LogBox.Document.Blocks.Clear() })
$ui.BtnLogSave.Add_Click({
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = 'File di testo (*.txt)|*.txt'
    $dlg.FileName = 'WinOptima-registro-{0:yyyyMMdd-HHmm}.txt' -f (Get-Date)
    if ($dlg.ShowDialog()) {
        try {
            $range = New-Object System.Windows.Documents.TextRange ($ui.LogBox.Document.ContentStart, $ui.LogBox.Document.ContentEnd)
            [System.IO.File]::WriteAllText($dlg.FileName, $range.Text, (New-Object System.Text.UTF8Encoding $true))
            Set-Status "Registro salvato in $($dlg.FileName)" 'ok'
        } catch { Set-Status "Impossibile salvare il registro: $($_.Exception.Message)" 'error' }
    }
})

# ---------------------------------------------------------------- ciclo principale: coda messaggi + aggiornamenti periodici
$script:TickCount = 0
$script:StatusLevel = 'ok'

function Receive-UiMessages {
    $msg = $null
    $count = 0
    while ($count -lt 300 -and $UiQueue.TryDequeue([ref]$msg)) {
        $count++
        switch ($msg.Type) {
            'log'      { Add-LogLine $msg.Time $msg.Level $msg.Text }
            'status'   { Set-Status $msg.Text $msg.Level }
            'progress' { Update-BusyProgress $msg }
            'size'     { if ($script:Controls.ContainsKey($msg.Id) -and $script:Controls[$msg.Id].Size) { $script:Controls[$msg.Id].Size.Text = $msg.Text } }
            'summary'  { Complete-Summary $msg }
            'sysinfo'  { Update-SystemInfo $msg }
            'dns'      { Update-DnsView ([string[]]$msg.Servers) }
            'rdp'      { Update-RdpView ([bool]$msg.Enabled) }
            'update'   { Receive-UpdateInfo $msg }
            'bloat'    { Show-BloatState $msg }
            'updateReady' { Receive-UpdateReady $msg }
        }
    }
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(100)
$timer.Add_Tick({
    # I lavori terminati vanno individuati PRIMA di svuotare la coda, così non si perdono messaggi
    $finished = @($script:Jobs | Where-Object { $_.Handle.IsCompleted })
    Receive-UiMessages
    foreach ($j in $finished) { Complete-Job $j }
    if ($finished.Count) { Receive-UiMessages }

    $script:TickCount++
    if ($script:TickCount % 10 -eq 0) {
        Update-HomeLive
        # Se il tema è "Sistema" segue anche i cambi fatti da Windows mentre l'app è aperta
        Set-AppTheme
    }
})

# ---------------------------------------------------------------- eventi della finestra
$window.Dispatcher.Add_UnhandledException({
    $args[1].Handled = $true
    try { Add-LogLine (Get-Date) 'ERROR' "Errore interno: $($args[1].Exception.Message)" } catch {}
})

$window.Add_Closing({
    if ($script:Busy) {
        $answer = [System.Windows.MessageBox]::Show('Un''operazione è ancora in corso. Chiudere comunque WinOptima?', 'WinOptima Portable', 'YesNo', 'Question')
        if ($answer -ne 'Yes') { $args[1].Cancel = $true; return }
    }
    Save-Settings
    # Aggiornamento già scaricato: si installa in silenzio alla chiusura (al prossimo avvio parte la nuova versione)
    if ($script:UpdateReady -and -not $script:Relaunching) { [void](Install-AppUpdate) }
    $timer.Stop()
    if ($script:CpuCounter) { $script:CpuCounter.Dispose() }
})

$window.Add_Loaded({
    Set-SimulationUi
    Set-LogOpen ([bool]$script:Settings.logOpen)
    Set-Status 'Pronto.' 'ok'
    Sync-States
    Show-Page 'home'
    Add-LogLine (Get-Date) 'INFO' "WinOptima Portable $script:AppVersion avviato."
    if ($Sim) { Add-LogLine (Get-Date) 'SIM' 'Modalità simulazione attiva: nessuna modifica verrà scritta nel sistema.' }
    [void](Start-Work -Background -Script { Send-SystemInfo })
    if ($script:Settings.autoUpdate) { Start-UpdateCheck }
    $timer.Start()
})

[void]$window.ShowDialog()
