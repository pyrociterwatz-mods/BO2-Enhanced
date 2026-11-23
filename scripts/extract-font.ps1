# extract-font.ps1
# Exports the game's font atlas from precode.big as PNG and lists its glyph table.
# The file is a "goefile": chunks of [8-byte tag][u32 size][u32 0]. The `texture` chunk at 0x2E74 embeds a 256x256
# A8R8G8B8 DDS. Each `texfont` chunk holds a table of [i32 char][f32 x][f32 y][f32 w][f32 h] in atlas pixels.
# Usage: extract-font.ps1 -BigPath <precode.big> -OutDir <dir>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BigPath,
    [Parameter(Mandatory)][string]$OutDir,
    [int]$PixelsAt = 0x2F20,
    [int]$Table1 = 0x42F50,
    [int]$Table2 = 0x43680
)

Add-Type -AssemblyName System.Drawing
New-Item -ItemType Directory -Force $OutDir | Out-Null
$b = [IO.File]::ReadAllBytes($BigPath)

$Size = 256
if ([Text.Encoding]::ASCII.GetString($b, $PixelsAt - 128, 4) -ne 'DDS ') { throw "No DDS at the expected offset" }

function New-Atlas {
    $bmp = New-Object Drawing.Bitmap $Size, $Size, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $rect = New-Object Drawing.Rectangle 0, 0, $Size, $Size
    $data = $bmp.LockBits($rect, [Drawing.Imaging.ImageLockMode]::WriteOnly, $bmp.PixelFormat)
    [Runtime.InteropServices.Marshal]::Copy($b, $PixelsAt, $data.Scan0, $Size * $Size * 4)
    $bmp.UnlockBits($data)
    $bmp
}

function Read-Glyphs([int]$start) {
    # Entries begin 0x18 bytes after the inner texfont tag; the table is `count` entries long, up to the chunk's end.
    $inner = [BitConverter]::ToInt32($b, $start + 8)
    $list = New-Object Collections.ArrayList
    for ($o = $start + 0x28; $o -lt $start + $inner - 19; $o += 20) {
        [void]$list.Add([pscustomobject]@{
            Char = [BitConverter]::ToInt32($b, $o) -band 0xFF
            X    = [BitConverter]::ToSingle($b, $o + 4)
            Y    = [BitConverter]::ToSingle($b, $o + 8)
            W    = [BitConverter]::ToSingle($b, $o + 12)
            H    = [BitConverter]::ToSingle($b, $o + 16)
        })
    }
    $list
}

$glyphs = Read-Glyphs $Table1
$glyphs2 = Read-Glyphs $Table2
$lines = $glyphs | ForEach-Object {
    $c = if ($_.Char -ge 33 -and $_.Char -lt 127) { [char]$_.Char } else { ' ' }
    '{0:X2} {1} x={2,4} y={3,4} w={4,3} h={5,3}' -f $_.Char, $c, $_.X, $_.Y, $_.W, $_.H
}
Set-Content -LiteralPath (Join-Path $OutDir 'glyphs.txt') -Value $lines -Encoding UTF8

$same = ($glyphs.Count -eq $glyphs2.Count)
if ($same) { for ($i = 0; $i -lt $glyphs.Count; $i++) { if ($glyphs[$i].X -ne $glyphs2[$i].X -or $glyphs[$i].Y -ne $glyphs2[$i].Y -or $glyphs[$i].Char -ne $glyphs2[$i].Char) { $same = $false; break } } }
Write-Output "glyphs: $($glyphs.Count); second table: $($glyphs2.Count); identical layout: $same"

$atlas = New-Atlas
$bg = [Drawing.Color]::FromArgb(255, 60, 60, 90)

# Whole atlas, 4x.
$s = 4
$full = New-Object Drawing.Bitmap ($Size * $s), ($Size * $s)
$g = [Drawing.Graphics]::FromImage($full)
$g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
$g.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::Half
$g.Clear($bg)
$g.DrawImage($atlas, 0, 0, $full.Width, $full.Height)
$full.Save((Join-Path $OutDir 'atlas.png'), [Drawing.Imaging.ImageFormat]::Png)
$g.Dispose()

# Reserved slots 0xC8-0xD7, each enlarged and labelled.
$slots = @($glyphs | Where-Object { $_.Char -ge 0xC8 -and $_.Char -le 0xD7 })
$cell = 180; $cols = 4; $rows = [Math]::Ceiling($slots.Count / $cols)
$sheet = New-Object Drawing.Bitmap ($cell * $cols), ($cell * $rows)
$g = [Drawing.Graphics]::FromImage($sheet)
$g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
$g.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::Half
$g.Clear($bg)
$font = New-Object Drawing.Font 'Consolas', 12
$i = 0
foreach ($q in $slots) {
    $cx = ($i % $cols) * $cell; $cy = [Math]::Floor($i / $cols) * $cell
    $k = 5
    $dest = New-Object Drawing.RectangleF ($cx + 8), ($cy + 28), ($q.W * $k), ($q.H * $k)
    $src = New-Object Drawing.RectangleF $q.X, $q.Y, $q.W, $q.H
    $g.DrawImage($atlas, $dest, $src, [Drawing.GraphicsUnit]::Pixel)
    $g.DrawString(('0x{0:X2}  {1}x{2}' -f $q.Char, $q.W, $q.H), $font, [Drawing.Brushes]::White, ($cx + 6), ($cy + 4))
    $i++
}
$sheet.Save((Join-Path $OutDir 'slots.png'), [Drawing.Imaging.ImageFormat]::Png)
$g.Dispose()
Write-Output "slots: $($slots.Count)"
