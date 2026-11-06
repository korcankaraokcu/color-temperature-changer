# Color Temperature Changer
# Live white point adjustment for Windows displays through the GPU gamma ramp.
# Run: powershell -NoProfile -ExecutionPolicy Bypass -File color-temperature-changer.ps1
# Undo everything without opening the window: add -Reset (or run reset.bat).
# https://github.com/korcankaraokcu/color-temperature-changer  (MIT License)
param([switch]$Reset)

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

// Raises DoubleClicked when the thumb (not the channel) of a TrackBar is double-clicked.
// The thumb position is checked before the trackbar handles the click, and the second click is
// swallowed so the trackbar does not start a drag that would move the thumb back.
public class ThumbDoubleClick : NativeWindow {
    const int WM_LBUTTONDOWN = 0x201, WM_LBUTTONDBLCLK = 0x203, TBM_GETTHUMBRECT = 0x419;
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, ref RECT r);

    public TrackBar Bar;
    public event EventHandler DoubleClicked;
    bool armed; int lastTick, lastX, lastY;

    public ThumbDoubleClick(TrackBar bar) {
        Bar = bar;
        if (bar.IsHandleCreated) AssignHandle(bar.Handle);
        bar.HandleCreated += (s, e) => AssignHandle(((Control)s).Handle);
        bar.HandleDestroyed += (s, e) => ReleaseHandle();
    }

    protected override void WndProc(ref Message m) {
        if (m.Msg == WM_LBUTTONDOWN || m.Msg == WM_LBUTTONDBLCLK) {
            long lp = m.LParam.ToInt64();
            int x = (short)(lp & 0xFFFF), y = (short)((lp >> 16) & 0xFFFF);
            var r = new RECT();
            SendMessage(Handle, TBM_GETTHUMBRECT, IntPtr.Zero, ref r);
            bool onThumb = x >= r.Left && x < r.Right && y >= r.Top && y < r.Bottom;
            int now = Environment.TickCount;
            var size = SystemInformation.DoubleClickSize;
            if (onThumb && armed && unchecked(now - lastTick) <= SystemInformation.DoubleClickTime &&
                Math.Abs(x - lastX) <= size.Width && Math.Abs(y - lastY) <= size.Height) {
                armed = false;
                if (DoubleClicked != null) DoubleClicked(this, EventArgs.Empty);
                return;
            }
            armed = onThumb; lastTick = now; lastX = x; lastY = y;
        }
        base.WndProc(ref m);
    }
}

public static class DisplayGamma {
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateDC(string driver, string device, string output, IntPtr mode);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern bool SetDeviceGammaRamp(IntPtr dc, ushort[] ramp);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DISPLAY_DEVICE {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplayDevices(string device, uint index, ref DISPLAY_DEVICE dd, uint flags);

    // Scales each channel of the display's gamma ramp: out = in * gain
    public static bool Set(string device, double r, double g, double b) {
        var ramp = new ushort[768]; double[] k = { r, g, b };
        for (int c = 0; c < 3; c++)
            for (int i = 0; i < 256; i++)
                ramp[c * 256 + i] = (ushort)Math.Round(Math.Max(0, Math.Min(1, i / 255.0 * k[c])) * 65535);
        IntPtr dc = CreateDC(device, null, null, IntPtr.Zero);
        if (dc == IntPtr.Zero) return false;
        try { return SetDeviceGammaRamp(dc, ramp); } finally { DeleteDC(dc); }
    }

    // Device interface path of the first monitor on an adapter, e.g. \\?\DISPLAY#AUO4AB8#4&...#{guid}
    public static string MonitorPath(string adapter) {
        var dd = new DISPLAY_DEVICE(); dd.cb = Marshal.SizeOf(dd);
        return EnumDisplayDevices(adapter, 0, ref dd, 1) ? dd.DeviceID : null;
    }
}
'@

if ($Reset) {
    foreach ($s in [Windows.Forms.Screen]::AllScreens) {
        $ok = [DisplayGamma]::Set($s.DeviceName, 1, 1, 1)
        '{0}: {1}' -f $s.DeviceName, $(if ($ok) { 'reset to normal' } else { 'could not reset' })
    }
    return
}

$Inv = [Globalization.CultureInfo]::InvariantCulture

# ---------- Colour math ----------

# CIE daylight locus: correlated colour temperature (4000-25000 K) -> xy chromaticity
function Get-DaylightXY([double]$kelvin) {
    $t = $kelvin
    if ($t -le 7000) { $cx = -4.6070e9 / [Math]::Pow($t, 3) + 2.9678e6 / ($t * $t) + 0.09911e3 / $t + 0.244063 }
    else { $cx = -2.0064e9 / [Math]::Pow($t, 3) + 1.9018e6 / ($t * $t) + 0.24748e3 / $t + 0.237040 }
    , @($cx, (-3.0 * $cx * $cx + 2.870 * $cx - 0.275))
}

# xy chromaticity (luminance 1) -> linear sRGB
function ConvertTo-LinearRgb($xy) {
    $cx = $xy[0]; $cy = $xy[1]; $bigX = $cx / $cy; $bigZ = (1 - $cx - $cy) / $cy
    , @((3.2406 * $bigX - 1.5372 - 0.4986 * $bigZ), (-0.9689 * $bigX + 1.8758 + 0.0415 * $bigZ), (0.0557 * $bigX - 0.2040 + 1.0570 * $bigZ))
}

function ConvertTo-UV($xy) { $d = -2 * $xy[0] + 12 * $xy[1] + 3; , @((4 * $xy[0] / $d), (6 * $xy[1] / $d)) }
function ConvertFrom-UV($uv) { $d = 2 * $uv[0] - 8 * $uv[1] + 4; , @((3 * $uv[0] / $d), (2 * $uv[1] / $d)) }

# Moves the white point perpendicular to the daylight locus in CIE 1960 uv (Duv). Positive = green, negative = magenta.
function Add-Tint([double]$kelvin, $xy, [double]$duv) {
    $p = ConvertTo-UV $xy; $q = ConvertTo-UV (Get-DaylightXY ($kelvin + 10))
    $du = $q[0] - $p[0]; $dv = $q[1] - $p[1]; $len = [Math]::Sqrt($du * $du + $dv * $dv)
    $nu = -$dv / $len; $nv = $du / $len
    if ($nv -lt 0) { $nu = -$nu; $nv = -$nv }
    ConvertFrom-UV @(($p[0] + $duv * $nu), ($p[1] + $duv * $nv))
}

$D65 = ConvertTo-LinearRgb (Get-DaylightXY 6504)
$TintStep = 0.0004   # Duv per tint slider step

# Kelvin + tint -> per-channel gains for gamma-encoded values (largest channel = 1, so nothing clips)
function Get-TemperatureGains([double]$kelvin, [double]$tint) {
    $xy = Get-DaylightXY $kelvin
    if ($tint -ne 0) { $xy = Add-Tint $kelvin $xy ($tint * $TintStep) }
    $lin = ConvertTo-LinearRgb $xy
    $ratio = @(0..2 | ForEach-Object { [Math]::Max(1e-6, $lin[$_] / $D65[$_]) })
    $max = ($ratio | Measure-Object -Maximum).Maximum
    , @($ratio | ForEach-Object { [Math]::Pow($_ / $max, 1 / 2.2) })
}

# ---------- Monitors ----------

function Get-Monitors {
    $wmi = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction SilentlyContinue)
    $i = 0
    foreach ($s in [Windows.Forms.Screen]::AllScreens) {
        $i++
        $name = ''
        try {
            $path = [DisplayGamma]::MonitorPath($s.DeviceName)
            if ($path) {
                $inst = (($path -replace '^\\\\\?\\', '') -split '#')[0..2] -join '\'
                $m = $wmi | Where-Object { ($_.InstanceName -replace '_\d+$', '') -eq $inst } | Select-Object -First 1
                if ($m) {
                    $name = (-join ($m.UserFriendlyName | Where-Object { $_ } | ForEach-Object { [char]$_ })).Trim()
                    if (-not $name) {
                        $edid = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Enum\$inst\Device Parameters" -ErrorAction SilentlyContinue).EDID
                        if ($edid) {
                            foreach ($o in 54, 72, 90, 108) {
                                if ($edid[$o] -eq 0 -and $edid[$o + 1] -eq 0 -and $edid[$o + 3] -in @(0xFC, 0xFE)) {
                                    $name = (-join ($edid[($o + 5)..($o + 17)] | ForEach-Object { [char]$_ })).Trim(); break
                                }
                            }
                        }
                    }
                    if (-not $name) { $name = ($inst -split '\\')[1] }
                }
            }
        } catch { }
        $label = "Display $i"
        if ($name) { $label += " - $name" }
        $label += " ($($s.Bounds.Width)x$($s.Bounds.Height)"
        if ($s.Primary) { $label += ', primary' }
        $label += ')'
        [pscustomobject]@{ Device = $s.DeviceName; Label = $label }
    }
}

# ---------- Export ----------

function Export-Cube([string]$path, $gains, [string]$title) {
    $n = 33; $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine("TITLE `"$title`"")
    [void]$sb.AppendLine("LUT_3D_SIZE $n")
    [void]$sb.AppendLine('DOMAIN_MIN 0.0 0.0 0.0')
    [void]$sb.AppendLine('DOMAIN_MAX 1.0 1.0 1.0')
    for ($bi = 0; $bi -lt $n; $bi++) { for ($gi = 0; $gi -lt $n; $gi++) { for ($ri = 0; $ri -lt $n; $ri++) {
        [void]$sb.AppendLine([string]::Format($Inv, '{0:F6} {1:F6} {2:F6}', ($ri / ($n - 1) * $gains[0]), ($gi / ($n - 1) * $gains[1]), ($bi / ($n - 1) * $gains[2])))
    } } }
    [IO.File]::WriteAllText($path, $sb.ToString())
}

# ICC v2 display profile: sRGB primaries and tone curve, plus a vcgt tag that carries the gains
function Export-Icc([string]$path, $gains, [string]$desc) {
    function BE32([uint32]$v) { $a = [BitConverter]::GetBytes($v); [Array]::Reverse($a); , $a }
    function BE16([uint16]$v) { $a = [BitConverter]::GetBytes($v); [Array]::Reverse($a); , $a }
    function S15([double]$v) { BE32 ([uint32]([int][Math]::Round($v * 65536) -band 0xFFFFFFFF)) }
    function Sig([string]$s) { , [Text.Encoding]::ASCII.GetBytes($s) }
    function XYZ($vx, $vy, $vz) { , ((Sig 'XYZ ') + (BE32 0) + (S15 $vx) + (S15 $vy) + (S15 $vz)) }

    $tags = [ordered]@{}
    $ascii = [Text.Encoding]::ASCII.GetBytes($desc) + [byte]0
    $tags['desc'] = (Sig 'desc') + (BE32 0) + (BE32 $ascii.Length) + $ascii + (BE32 0) + (BE32 0) + (BE16 0) + [byte]0 + (New-Object byte[] 67)
    $tags['cprt'] = (Sig 'text') + (BE32 0) + [Text.Encoding]::ASCII.GetBytes('Generated by color-temperature-changer') + [byte]0
    $tags['wtpt'] = XYZ 0.9642 1.0 0.8249
    $tags['rXYZ'] = XYZ 0.4361 0.2225 0.0139
    $tags['gXYZ'] = XYZ 0.3851 0.7169 0.0971
    $tags['bXYZ'] = XYZ 0.1431 0.0606 0.7141
    $trc = (Sig 'curv') + (BE32 0) + (BE32 1) + (BE16 0x0233)   # gamma 2.2
    $tags['rTRC'] = $trc; $tags['gTRC'] = $trc; $tags['bTRC'] = $trc
    $v = New-Object Collections.Generic.List[byte]
    $v.AddRange([byte[]]((Sig 'vcgt') + (BE32 0) + (BE32 0) + (BE16 3) + (BE16 256) + (BE16 2)))
    foreach ($k in $gains) { for ($i = 0; $i -lt 256; $i++) { $v.AddRange([byte[]](BE16 ([uint16][Math]::Round($i / 255 * $k * 65535)))) } }
    $tags['vcgt'] = $v.ToArray()

    $offset = 128 + 4 + 12 * $tags.Count
    $table = New-Object Collections.Generic.List[byte]
    $data = New-Object Collections.Generic.List[byte]
    $table.AddRange([byte[]](BE32 $tags.Count))
    $placed = @{}
    foreach ($key in $tags.Keys) {
        $bytes = [byte[]]$tags[$key]
        $hit = $placed.Keys | Where-Object { [Linq.Enumerable]::SequenceEqual([byte[]]$tags[$_], $bytes) } | Select-Object -First 1
        if ($hit) { $o = $placed[$hit] } else {
            $o = $offset + $data.Count; $placed[$key] = $o
            $data.AddRange($bytes); while ($data.Count % 4) { $data.Add(0) }
        }
        $table.AddRange([byte[]]((Sig $key) + (BE32 $o) + (BE32 $bytes.Length)))
    }
    $total = 128 + $table.Count + $data.Count
    $now = Get-Date
    $hdr = (BE32 $total) + (Sig 'none') + (BE32 0x02100000) + (Sig 'mntr') + (Sig 'RGB ') + (Sig 'XYZ ') +
           (BE16 $now.Year) + (BE16 $now.Month) + (BE16 $now.Day) + (BE16 $now.Hour) + (BE16 $now.Minute) + (BE16 $now.Second) +
           (Sig 'acsp') + (Sig 'MSFT') + (New-Object byte[] 24) + (S15 0.9642) + (S15 1.0) + (S15 0.8249) + (New-Object byte[] 48)
    [IO.File]::WriteAllBytes($path, [byte[]]($hdr + $table.ToArray() + $data.ToArray()))
}

# ---------- Window ----------

$monitors = @(Get-Monitors)
$state = @{}      # per-monitor settings
$touched = @{}    # monitors whose ramp was changed
$script:loading = $false

$font = New-Object Drawing.Font('Segoe UI', 10)
$form = New-Object Windows.Forms.Form
$form.Text = 'Color Temperature Changer'
$form.Font = $font
$form.ClientSize = New-Object Drawing.Size(590, 520)
$form.FormBorderStyle = 'FixedDialog'; $form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'; $form.TopMost = $true

function New-Control($type, $x, $y, $w, $h, $text) {
    $c = New-Object "Windows.Forms.$type"
    $c.Location = New-Object Drawing.Point($x, $y)
    if ($w) { $c.Size = New-Object Drawing.Size($w, $h) }
    if ($text) { $c.Text = $text }
    $c
}
function New-Slider($x, $y, $w, $min, $max, $small, $large, $tick) {
    $t = New-Control TrackBar $x $y $w 45
    $t.Minimum = $min; $t.Maximum = $max; $t.SmallChange = $small; $t.LargeChange = $large; $t.TickFrequency = $tick
    $t
}

$lblMon = New-Control Label 15 18 70 22 'Monitor'
$cmbMon = New-Control ComboBox 90 14 485 28
$cmbMon.DropDownStyle = 'DropDownList'
foreach ($m in $monitors) { [void]$cmbMon.Items.Add($m.Label) }

$rbTemp = New-Control RadioButton 15 52 220 26 'Temperature and tint'
$rbRgb = New-Control RadioButton 245 52 200 26 'RGB values'
$rbTemp.Checked = $true

$grpTemp = New-Control GroupBox 15 85 560 140 'Temperature and tint'
$trkTemp = New-Slider 10 25 420 4000 10000 50 250 500
$lblTemp = New-Control Label 440 32 115 22
$trkTint = New-Slider 10 80 420 -50 50 1 5 10
$lblTint = New-Control Label 440 87 115 40
$grpTemp.Controls.AddRange(@($trkTemp, $lblTemp, $trkTint, $lblTint))

$grpRgb = New-Control GroupBox 15 235 560 170 'RGB values (gain per channel)'
$rgbSliders = @(); $rgbLabels = @()
$names = 'Red', 'Green', 'Blue'
for ($i = 0; $i -lt 3; $i++) {
    $y = 25 + $i * 47
    $grpRgb.Controls.Add((New-Control Label 10 ($y + 6) 50 22 $names[$i]))
    $t = New-Slider 60 $y 370 300 1000 5 25 50
    $l = New-Control Label 440 ($y + 6) 115 22
    $grpRgb.Controls.AddRange(@($t, $l))
    $rgbSliders += $t; $rgbLabels += $l
}

$btnReset = New-Control Button 15 418 120 32 'Reset'
$btnCube = New-Control Button 145 418 130 32 'Export .cube'
$btnIcc = New-Control Button 285 418 130 32 'Export .icc'
$chkKeep = New-Control CheckBox 430 422 155 26 'Keep after closing'
$lblStatus = New-Control Label 15 462 560 50
$lblStatus.ForeColor = [Drawing.Color]::FromArgb(90, 90, 90)

$form.Controls.AddRange(@($lblMon, $cmbMon, $rbTemp, $rbRgb, $grpTemp, $grpRgb, $btnReset, $btnCube, $btnIcc, $chkKeep, $lblStatus))

# Reset a slider by double-clicking its thumb, or through its right-click menu
$tips = New-Object Windows.Forms.ToolTip
$thumbWatchers = @()
$sliderDefaults = @(@($trkTemp, 6500, '6500 K'), @($trkTint, 0, '0')) + @($rgbSliders | ForEach-Object { , @($_, 1000, '1.000') })
foreach ($entry in $sliderDefaults) {
    $bar = $entry[0]; $bar.Tag = $entry[1]
    $tips.SetToolTip($bar, 'Double-click the thumb or right-click to reset')

    $watcher = New-Object ThumbDoubleClick $bar
    $watcher.Add_DoubleClicked({ param($src, $e) $src.Bar.Value = [int]$src.Bar.Tag })
    $thumbWatchers += $watcher

    $menu = New-Object Windows.Forms.ContextMenuStrip
    $item = $menu.Items.Add("Reset to $($entry[2])")
    $item.Tag = $bar
    $item.Add_Click({ $this.Tag.Value = [int]$this.Tag.Tag })
    $bar.ContextMenuStrip = $menu
}
$tips.SetToolTip($btnReset, 'Reset this display to 6500 K, tint 0')
$tips.SetToolTip($chkKeep, 'Leave the adjustment active after the window closes')

function Get-CurrentDevice { if ($cmbMon.SelectedIndex -ge 0) { $monitors[$cmbMon.SelectedIndex].Device } }
function Get-CurrentGains { , @($rgbSliders | ForEach-Object { $_.Value / 1000.0 }) }
function Get-CurrentTitle {
    if ($rbTemp.Checked) { 'color-temperature-changer {0}K tint {1}' -f $trkTemp.Value, $trkTint.Value }
    else { $gn = Get-CurrentGains; [string]::Format($Inv, 'color-temperature-changer R{0:F3} G{1:F3} B{2:F3}', $gn[0], $gn[1], $gn[2]) }
}

$refresh = {
    if ($script:loading) { return }
    $dev = Get-CurrentDevice
    if (-not $dev) { return }
    $script:loading = $true
    if ($rbTemp.Checked) {
        $gn = Get-TemperatureGains $trkTemp.Value $trkTint.Value
        for ($i = 0; $i -lt 3; $i++) { $rgbSliders[$i].Value = [Math]::Max(300, [Math]::Min(1000, [int][Math]::Round($gn[$i] * 1000))) }
    } else {
        $gn = Get-CurrentGains
    }
    $script:loading = $false
    $grpTemp.Enabled = $rbTemp.Checked
    foreach ($t in $rgbSliders) { $t.Enabled = $rbRgb.Checked }

    $lblTemp.Text = "$($trkTemp.Value) K"
    $tv = $trkTint.Value
    $lblTint.Text = if ($tv -gt 0) { "Tint +$tv`n(green)" } elseif ($tv -lt 0) { "Tint $tv`n(magenta)" } else { 'Tint 0' }
    for ($i = 0; $i -lt 3; $i++) { $rgbLabels[$i].Text = [string]::Format($Inv, '{0:F3}', $gn[$i]) }

    $ok = [DisplayGamma]::Set($dev, $gn[0], $gn[1], $gn[2])
    $touched[$dev] = $true
    $state[$dev] = @{ Temp = $rbTemp.Checked; K = $trkTemp.Value; Tint = $trkTint.Value; Rgb = @($rgbSliders | ForEach-Object { $_.Value }) }
    $lblStatus.Text = if ($ok) {
        'Applied. Arrow keys move a focused slider in small steps, PgUp/PgDn in larger ones.'
    } else {
        'Windows rejected this setting (too far from normal, or the display does not support gamma ramps). Try a value closer to 6500 K / 1.000.'
    }
}

$loadMonitor = {
    $dev = Get-CurrentDevice
    $s = $state[$dev]
    $script:loading = $true
    if ($s) {
        $rbTemp.Checked = $s.Temp; $rbRgb.Checked = -not $s.Temp
        $trkTemp.Value = $s.K; $trkTint.Value = $s.Tint
        for ($i = 0; $i -lt 3; $i++) { $rgbSliders[$i].Value = $s.Rgb[$i] }
    } else {
        $rbTemp.Checked = $true; $trkTemp.Value = 6500; $trkTint.Value = 0
        foreach ($t in $rgbSliders) { $t.Value = 1000 }
    }
    $script:loading = $false
    & $refresh
}

$exportFile = {
    param([string]$kind)
    $dlg = New-Object Windows.Forms.SaveFileDialog
    $base = if ($rbTemp.Checked) { 'ctc_{0}K_tint{1}' -f $trkTemp.Value, $trkTint.Value } else { $gn = $rgbSliders | ForEach-Object { $_.Value }; 'ctc_r{0}_g{1}_b{2}' -f $gn[0], $gn[1], $gn[2] }
    if ($kind -eq 'cube') { $dlg.Filter = '3D LUT (*.cube)|*.cube'; $dlg.FileName = "$base.cube" }
    else { $dlg.Filter = 'ICC profile (*.icc)|*.icc'; $dlg.FileName = "$base.icc" }
    $form.TopMost = $false
    if ($dlg.ShowDialog($form) -eq 'OK') {
        try {
            if ($kind -eq 'cube') { Export-Cube $dlg.FileName (Get-CurrentGains) (Get-CurrentTitle) }
            else { Export-Icc $dlg.FileName (Get-CurrentGains) (Get-CurrentTitle) }
            $lblStatus.Text = "Saved $($dlg.FileName)"
        } catch { $lblStatus.Text = "Export failed: $_" }
    }
    $form.TopMost = $true
}

$cmbMon.Add_SelectedIndexChanged($loadMonitor)
$rbTemp.Add_CheckedChanged($refresh)
$trkTemp.Add_ValueChanged($refresh)
$trkTint.Add_ValueChanged($refresh)
foreach ($t in $rgbSliders) { $t.Add_ValueChanged($refresh) }
$btnReset.Add_Click({
    $script:loading = $true
    $rbTemp.Checked = $true; $trkTemp.Value = 6500; $trkTint.Value = 0
    $script:loading = $false
    & $refresh
})
$chkKeep.Add_CheckedChanged({
    $lblStatus.Text = if ($chkKeep.Checked) {
        'The adjustment will stay after closing, until Windows or another program resets it (a restart always does). To undo it: run reset.bat, or open this tool and press Reset.'
    } else { 'Closing the window will return the displays to normal.' }
})
$btnCube.Add_Click({ & $exportFile 'cube' })
$btnIcc.Add_Click({ & $exportFile 'icc' })
$form.Add_FormClosed({
    if (-not $chkKeep.Checked) { foreach ($dev in @($touched.Keys)) { [void][DisplayGamma]::Set($dev, 1, 1, 1) } }
})

if ($monitors.Count -eq 0) { [void][Windows.Forms.MessageBox]::Show('No displays found.'); return }
$primary = [Array]::FindIndex([object[]]$monitors, [Predicate[object]] { param($m) $m.Device -eq [Windows.Forms.Screen]::PrimaryScreen.DeviceName })
$cmbMon.SelectedIndex = [Math]::Max(0, $primary)
[void]$form.ShowDialog()
