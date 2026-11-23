# build-font-icons.ps1
# Adds Y and Space button icons to the game's font, keeping both .big files the same size.
# The art is drawn here, so nothing from another game is used. See scripts/extract-font.ps1 for the file layout.
#
# The two icons go in atlas rows no glyph uses. Two table entries no game text uses are repointed at them:
#   \u (0xD0, up arrow) becomes Y; \4 (0xCF, R2) becomes Space.
# precode.big and Code.big each hold the atlas (Code.big's copy is flipped vertically) and two glyph tables.
#
# Usage: build-font-icons.ps1 -SourceDir <folder with original precode.big, Code.big> -OutDir <folder> [-PreviewPath <png>]

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceDir,
    [Parameter(Mandatory)][string]$OutDir,
    [string]$PreviewPath
)

Add-Type -AssemblyName System.Drawing

$PrecodePixels = 0x2F20; $CodePixels = 0x206F0; $Size = 256
$PrecodeTables = 0x42F50, 0x43680; $CodeTables = 0x60720, 0xAC2F0
$SlotY = 0xD0; $SlotSpace = 0xCF
$YRect = @{ X = 2; Y = 170; W = 20; H = 20 }
$SpaceRect = @{ X = 26; Y = 170; W = 44; H = 20 }
$ClearX = 0; $ClearY = 168; $ClearW = 74; $ClearH = 25

function New-Canvas([int]$w, [int]$h, [int]$scale) {
    $bmp = New-Object Drawing.Bitmap ($w * $scale), ($h * $scale), ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([Drawing.Color]::FromArgb(0, 255, 255, 255))
    @{ Bmp = $bmp; G = $g }
}

function Add-CenteredText($g, [string]$text, [float]$emSize, [float]$cx, [float]$cy, $brush) {
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $family = New-Object Drawing.FontFamily 'Arial'
    $path.AddString($text, $family, [int][Drawing.FontStyle]::Bold, $emSize, (New-Object Drawing.PointF 0, 0), [Drawing.StringFormat]::GenericTypographic)
    $b = $path.GetBounds()
    $m = New-Object Drawing.Drawing2D.Matrix
    $m.Translate(($cx - $b.X - $b.Width / 2), ($cy - $b.Y - $b.Height / 2))
    $path.Transform($m)
    $g.FillPath($brush, $path)
    $path.Dispose()
}

function Reduce($canvas, [int]$w, [int]$h) {
    # Average each block of source pixels, weighting colour by alpha so edges keep their colour instead of going pale.
    $scale = [int]($canvas.Bmp.Width / $w)
    $out = New-Object Drawing.Bitmap $w, $h, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
    for ($y = 0; $y -lt $h; $y++) {
        for ($x = 0; $x -lt $w; $x++) {
            $a = 0.0; $r = 0.0; $g = 0.0; $b = 0.0
            for ($sy = 0; $sy -lt $scale; $sy++) {
                for ($sx = 0; $sx -lt $scale; $sx++) {
                    $p = $canvas.Bmp.GetPixel($x * $scale + $sx, $y * $scale + $sy)
                    $a += $p.A; $r += $p.R * $p.A; $g += $p.G * $p.A; $b += $p.B * $p.A
                }
            }
            if ($a -le 0) { $out.SetPixel($x, $y, [Drawing.Color]::FromArgb(0, 255, 255, 255)) }
            else { $out.SetPixel($x, $y, [Drawing.Color]::FromArgb([int]($a / ($scale * $scale)), [int]($r / $a), [int]($g / $a), [int]($b / $a))) }
        }
    }
    $out
}

function New-YIcon {
    $s = 8; $c = New-Canvas 20 20 $s
    $c.G.FillEllipse((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(255, 58, 58, 64))), 1 * $s, 1 * $s, 18 * $s, 18 * $s)
    $c.G.FillEllipse((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(255, 26, 26, 30))), 2 * $s, 2 * $s, 16 * $s, 16 * $s)
    Add-CenteredText $c.G 'Y' (17 * $s) (10 * $s) (10 * $s) (New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(255, 245, 200, 40)))
    Reduce $c 20 20
}

function New-SpaceIcon {
    $s = 8; $w = $SpaceRect.W; $c = New-Canvas $w 20 $s
    $c.G.FillRectangle((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(255, 190, 190, 185))), 1 * $s, 2 * $s, ($w - 2) * $s, 16 * $s)
    $c.G.FillRectangle((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(255, 50, 50, 48))), 2 * $s, 3 * $s, ($w - 3) * $s, 15 * $s)
    $c.G.FillRectangle((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(255, 98, 98, 94))), 2 * $s, 3 * $s, ($w - 4) * $s, 14 * $s)
    Add-CenteredText $c.G 'SPACE' (11 * $s) ($w * $s / 2) (10 * $s) ([Drawing.Brushes]::White)
    Reduce $c $w 20
}

function Assert-Tag([byte[]]$b, [int]$at, [string]$tag, [string]$what) {
    if ([Text.Encoding]::ASCII.GetString($b, $at, $tag.Length) -ne $tag) { throw "$what : expected '$tag' at 0x$($at.ToString('X'))" }
}

function Set-Pixel([byte[]]$b, [int]$base, [int]$x, [int]$y, [bool]$flip, [byte]$bb, [byte]$g, [byte]$r, [byte]$a) {
    $row = if ($flip) { $Size - 1 - $y } else { $y }
    $o = $base + ($row * $Size + $x) * 4
    $b[$o] = $bb; $b[$o + 1] = $g; $b[$o + 2] = $r; $b[$o + 3] = $a
}

function Write-Icons([byte[]]$b, [int]$base, [bool]$flip, $yIcon, $spaceIcon) {
    for ($y = $ClearY; $y -lt $ClearY + $ClearH; $y++) { for ($x = $ClearX; $x -lt $ClearX + $ClearW; $x++) { Set-Pixel $b $base $x $y $flip 255 255 255 0 } }
    foreach ($pair in @(@($yIcon, $YRect), @($spaceIcon, $SpaceRect))) {
        $img = $pair[0]; $rc = $pair[1]
        for ($y = 0; $y -lt $rc.H; $y++) { for ($x = 0; $x -lt $rc.W; $x++) {
            $p = $img.GetPixel($x, $y)
            Set-Pixel $b $base ($rc.X + $x) ($rc.Y + $y) $flip $p.B $p.G $p.R $p.A
        } }
    }
}

function Set-Entry([byte[]]$b, [int]$table, [int]$char, $rc) {
    Assert-Tag $b $table 'texfont' 'glyph table'
    $inner = [BitConverter]::ToInt32($b, $table + 8)
    for ($o = $table + 0x28; $o -lt $table + $inner - 19; $o += 20) {
        if (([BitConverter]::ToInt32($b, $o) -band 0xFF) -eq $char) {
            [Array]::Copy([BitConverter]::GetBytes([single]$rc.X), 0, $b, $o + 4, 4)
            [Array]::Copy([BitConverter]::GetBytes([single]$rc.Y), 0, $b, $o + 8, 4)
            [Array]::Copy([BitConverter]::GetBytes([single]$rc.W), 0, $b, $o + 12, 4)
            [Array]::Copy([BitConverter]::GetBytes([single]$rc.H), 0, $b, $o + 16, 4)
            return
        }
    }
    throw "Glyph 0x$($char.ToString('X')) not found in table at 0x$($table.ToString('X'))"
}

New-Item -ItemType Directory -Force $OutDir | Out-Null
$yIcon = New-YIcon
$spaceIcon = New-SpaceIcon

$pre = [IO.File]::ReadAllBytes((Join-Path $SourceDir 'precode.big'))
$code = [IO.File]::ReadAllBytes((Join-Path $SourceDir 'Code.big'))
Assert-Tag $pre ($PrecodePixels - 128) 'DDS ' 'precode.big atlas'
Assert-Tag $code ($CodePixels - 128) 'DDS ' 'Code.big atlas'

# Refuse already-patched input: the top-left icon pixel is the original opaque fill in an unpatched file.
$probe = $PrecodePixels + ($ClearY * $Size + $ClearX) * 4
if ($pre[$probe + 3] -ne 255) { throw "precode.big looks already patched; use the original files" }

# Confirm Code.big's atlas is precode.big's flipped, over the glyph rows, before relying on that.
for ($y = 0; $y -lt 165; $y += 7) {
    for ($x = 0; $x -lt $Size; $x += 5) {
        $a = $PrecodePixels + ($y * $Size + $x) * 4; $c = $CodePixels + (($Size - 1 - $y) * $Size + $x) * 4
        if ($pre[$a + 3] -ne $code[$c + 3]) { throw "Code.big atlas is not a vertical flip of precode.big at ($x,$y)" }
    }
}

Write-Icons $pre $PrecodePixels $false $yIcon $spaceIcon
Write-Icons $code $CodePixels $true $yIcon $spaceIcon
foreach ($t in $PrecodeTables) { Set-Entry $pre $t $SlotY $YRect; Set-Entry $pre $t $SlotSpace $SpaceRect }
foreach ($t in $CodeTables) { Set-Entry $code $t $SlotY $YRect; Set-Entry $code $t $SlotSpace $SpaceRect }

[IO.File]::WriteAllBytes((Join-Path $OutDir 'precode.big'), $pre)
[IO.File]::WriteAllBytes((Join-Path $OutDir 'Code.big'), $code)

if ($PreviewPath) {
    $k = 6
    $sheet = New-Object Drawing.Bitmap (($YRect.W + $SpaceRect.W + 12) * $k), (24 * $k)
    $g = [Drawing.Graphics]::FromImage($sheet)
    $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
    $g.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::Half
    $g.Clear([Drawing.Color]::FromArgb(255, 60, 60, 90))
    $g.DrawImage($yIcon, 2 * $k, 2 * $k, $YRect.W * $k, 20 * $k)
    $g.DrawImage($spaceIcon, ($YRect.W + 8) * $k, 2 * $k, $SpaceRect.W * $k, 20 * $k)
    $sheet.Save($PreviewPath, [Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose()
}
Write-Output "Wrote patched precode.big and Code.big to $OutDir"
foreach ($f in 'precode.big', 'Code.big') { Write-Output ("{0}: {1}" -f $f, (Get-FileHash -LiteralPath (Join-Path $OutDir $f) -Algorithm SHA256).Hash) }
