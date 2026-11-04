Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32 {
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@

$p = Get-Process ArmaReforgerWorkbenchSteamDiag -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $p) { throw 'Workbench window not found' }
$h = $p.MainWindowHandle

$r = New-Object Win32+RECT
[void][Win32]::GetWindowRect($h, [ref]$r)
$w = $r.Right - $r.Left
$hh = $r.Bottom - $r.Top

$bmp = New-Object System.Drawing.Bitmap $w, $hh
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
[void][Win32]::PrintWindow($h, $hdc, 2)
$g.ReleaseHdc($hdc)

# tight crop around the character
$x0 = [int]($w * 0.635); $y0 = [int]($hh * 0.200)
$cw = [int]($w * 0.150); $ch = [int]($hh * 0.660)

$out = New-Object System.Drawing.Bitmap 1024, 576
$g3 = [System.Drawing.Graphics]::FromImage($out)
$g3.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic

# background: plain dark panel so the character reads clearly
$bg = New-Object System.Drawing.Rectangle 0, 0, 1024, 576
$g3.Clear([System.Drawing.Color]::FromArgb(255, 26, 26, 26))

$scale = 556.0 / $ch
$dw = [int]($cw * $scale)
$dx = [int]((1024 - $dw) / 2)
$src = New-Object System.Drawing.Rectangle $x0, $y0, $cw, $ch
$dst = New-Object System.Drawing.Rectangle $dx, 10, $dw, 556
$g3.DrawImage($bmp, $dst, $src, [System.Drawing.GraphicsUnit]::Pixel)

$path = 'C:\Users\Administrator\Documents\Default Project\arma-ai\work\mr-fix\preview.png'
$out.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $g3.Dispose(); $bmp.Dispose(); $out.Dispose()
Write-Output "saved $path"
