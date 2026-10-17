<#
.SYNOPSIS
    Ricostruisce l'icona (WinOptima.ico) e il launcher (WinOptima.exe) di WinOptima Portable.
.DESCRIPTION
    1. Disegna l'icona in vettoriale con WPF e la esporta in un .ico multi-risoluzione (PNG 16-256 px).
    2. Compila Launcher.cs con il compilatore C# incluso in Windows (.NET Framework 4) in un exe UNICO
       e portatile che contiene WinOptima.ps1 e l'icona (estratti in %LOCALAPPDATA%\WinOptima all'avvio),
       incorporando icona, manifest UAC (richiede amministratore) e informazioni di versione.
    Non servono SDK o strumenti da installare.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Build.ps1
#>
param(
    [switch]$IconOnly,
    [string]$PreviewDir
)

$ErrorActionPreference = 'Stop'

# WPF richiede un thread STA: rilancia se necessario (es. PowerShell 7)
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $PSCommandPath)
    if ($IconOnly) { $argList += '-IconOnly' }
    if ($PreviewDir) { $argList += @('-PreviewDir', $PreviewDir) }
    & powershell.exe @argList
    exit $LASTEXITCODE
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$root = $PSScriptRoot
$icoPath = Join-Path $root 'WinOptima.ico'

# ---------------------------------------------------------------- icona
function Get-IconXaml {
    param([bool]$Detailed)
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $cx = 128.0; $cy = 130.0; $r = 78.0
    function Get-ArcPoint([double]$deg) {
        $rad = $deg * [Math]::PI / 180
        '{0},{1}' -f ($cx + $r * [Math]::Cos($rad)).ToString('0.###', $inv), ($cy + $r * [Math]::Sin($rad)).ToString('0.###', $inv)
    }
    $start = Get-ArcPoint 135
    $trackEnd = Get-ArcPoint 45
    $valueEnd = Get-ArcPoint (135 + 270 * 0.80)

    if ($Detailed) {
        # Quadrante prestazioni (arco 270 gradi) + fulmine centrato
        $ring = @"
<Path Stroke="#47FFFFFF" StrokeThickness="15" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Data="M $start A $r,$r 0 1 1 $trackEnd"/>
<Path Stroke="#FFFFFFFF" StrokeThickness="15" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Data="M $start A $r,$r 0 1 1 $valueEnd"/>
"@
        $boltMatrix = '0.96,0,0,0.96,80,84'
    } else {
        # Dimensioni piccole: solo fulmine grande, senza dettagli che si impasterebbero
        $ring = ''
        $boltMatrix = '1.3,0,0,1.3,63,55'
    }

    @"
<Canvas xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Width="256" Height="256">
  <Rectangle Canvas.Left="16" Canvas.Top="16" Width="224" Height="224" RadiusX="56" RadiusY="56">
    <Rectangle.Fill>
      <LinearGradientBrush StartPoint="0.1,0" EndPoint="0.9,1">
        <GradientStop Color="#5BCBFF" Offset="0"/>
        <GradientStop Color="#2B8EF0" Offset="0.55"/>
        <GradientStop Color="#1260CF" Offset="1"/>
      </LinearGradientBrush>
    </Rectangle.Fill>
    <Rectangle.Effect><DropShadowEffect BlurRadius="14" ShadowDepth="5" Direction="270" Opacity="0.35" Color="#001A4D"/></Rectangle.Effect>
  </Rectangle>
  <Rectangle Canvas.Left="16" Canvas.Top="16" Width="224" Height="224" RadiusX="56" RadiusY="56">
    <Rectangle.Fill>
      <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
        <GradientStop Color="#40FFFFFF" Offset="0"/>
        <GradientStop Color="#00FFFFFF" Offset="0.5"/>
      </LinearGradientBrush>
    </Rectangle.Fill>
  </Rectangle>
  <Rectangle Canvas.Left="17" Canvas.Top="17" Width="222" Height="222" RadiusX="55" RadiusY="55" StrokeThickness="2">
    <Rectangle.Stroke>
      <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
        <GradientStop Color="#70FFFFFF" Offset="0"/>
        <GradientStop Color="#08FFFFFF" Offset="0.6"/>
      </LinearGradientBrush>
    </Rectangle.Stroke>
  </Rectangle>
  $ring
  <Path Data="M 74,0 L 56,38 L 86,38 L 34,100 L 44,58 L 14,58 L 56,0 Z">
    <Path.RenderTransform><MatrixTransform Matrix="$boltMatrix"/></Path.RenderTransform>
    <Path.Fill>
      <LinearGradientBrush StartPoint="0.2,0" EndPoint="0.8,1">
        <GradientStop Color="#FFF07A" Offset="0"/>
        <GradientStop Color="#FFB92E" Offset="1"/>
      </LinearGradientBrush>
    </Path.Fill>
    <Path.Effect><DropShadowEffect BlurRadius="8" ShadowDepth="3" Direction="270" Opacity="0.35" Color="#00204D"/></Path.Effect>
  </Path>
</Canvas>
"@
}

function ConvertTo-PngBytes {
    param([string]$Xaml, [int]$Size)
    $canvas = [Windows.Markup.XamlReader]::Parse($Xaml)
    $box = New-Object Windows.Controls.Viewbox
    $box.Stretch = 'Uniform'; $box.Width = $Size; $box.Height = $Size
    $box.Child = $canvas
    $box.Measure([Windows.Size]::new($Size, $Size))
    $box.Arrange([Windows.Rect]::new(0, 0, $Size, $Size))
    $box.UpdateLayout()
    $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap($Size, $Size, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($box)
    $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    $ms = New-Object IO.MemoryStream
    $enc.Save($ms)
    , $ms.ToArray()
}

function Write-IcoFile {
    param([string]$Path, [hashtable]$Frames)   # dimensione -> byte[] PNG
    $sizes = $Frames.Keys | Sort-Object
    $ms = New-Object IO.MemoryStream
    $bw = New-Object IO.BinaryWriter($ms)
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    foreach ($s in $sizes) {
        $png = $Frames[$s]
        $dim = if ($s -ge 256) { 0 } else { $s }
        $bw.Write([byte]$dim); $bw.Write([byte]$dim); $bw.Write([byte]0); $bw.Write([byte]0)
        $bw.Write([uint16]1); $bw.Write([uint16]32)
        $bw.Write([uint32]$png.Length); $bw.Write([uint32]$offset)
        $offset += $png.Length
    }
    foreach ($s in $sizes) { $bw.Write($Frames[$s]) }
    $bw.Flush()
    [IO.File]::WriteAllBytes($Path, $ms.ToArray())
}

Write-Host '[1/2] Generazione icona...' -ForegroundColor Cyan
$frames = @{}
foreach ($s in 16, 20, 24, 32, 40, 48, 64, 96, 128, 256) {
    $frames[$s] = ConvertTo-PngBytes -Xaml (Get-IconXaml -Detailed ($s -ge 48)) -Size $s
}
Write-IcoFile -Path $icoPath -Frames $frames
Write-Host "      $icoPath ($((Get-Item $icoPath).Length) byte, $($frames.Count) risoluzioni)"

if ($PreviewDir) {
    New-Item -ItemType Directory -Force $PreviewDir | Out-Null
    foreach ($s in 256, 48, 32, 16) { [IO.File]::WriteAllBytes((Join-Path $PreviewDir "icon-$s.png"), $frames[$s]) }
}

if ($IconOnly) { return }

# ---------------------------------------------------------------- launcher
Write-Host '[2/2] Compilazione WinOptima.exe...' -ForegroundColor Cyan
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { throw 'Compilatore C# (csc.exe) non trovato: serve .NET Framework 4.x (incluso in Windows 10/11).' }

$exePath = Join-Path $root 'WinOptima.exe'
$cscArgs = @(
    '/nologo', '/target:winexe', '/optimize+', '/codepage:65001',
    "/out:$exePath",
    "/win32icon:$icoPath",
    "/win32manifest:$(Join-Path $root 'app.manifest')",
    '/reference:System.Windows.Forms.dll',
    # Script e icona dentro l'exe: un unico file portatile che si estrae in %LOCALAPPDATA%\WinOptima
    "/resource:$(Join-Path $root 'WinOptima.ps1'),WinOptima.ps1",
    "/resource:$icoPath,WinOptima.ico",
    (Join-Path $root 'Launcher.cs')
)
& $csc @cscArgs
if ($LASTEXITCODE -ne 0) { throw "Compilazione fallita (codice $LASTEXITCODE)." }
Write-Host "      $exePath ($((Get-Item $exePath).Length) byte)" -ForegroundColor Green
Write-Host 'Fatto.' -ForegroundColor Green
