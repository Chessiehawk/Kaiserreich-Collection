# Builds the launcher artwork into ..\img and ..\KaiserreichCollection.ico:
#  - one tile per Kaiserreich version (the Kaiserreich eagle art + version number + update name + era colour)
#  - Player-Led Peace tile, dimmed window background, title banner, multi-size icon
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$proj = Split-Path $PSScriptRoot -Parent
$img  = "$proj\img"; New-Item -ItemType Directory -Force $img | Out-Null
$game = 'C:\Program Files (x86)\Steam\steamapps\common\Hearts of Iron IV'
$versions = Get-Content -LiteralPath "$proj\versions.json" -Raw | ConvertFrom-Json

function Canvas([int]$w, [int]$h) { $b = New-Object System.Drawing.Bitmap $w, $h; $g = [System.Drawing.Graphics]::FromImage($b); $g.SmoothingMode = 'AntiAlias'; $g.InterpolationMode = 'HighQualityBicubic'; $g.TextRenderingHint = 'AntiAliasGridFit'; $g.PixelOffsetMode = 'HighQuality'; @($b, $g) }
function Font([string]$n, [single]$s, [bool]$bold = $false) { New-Object System.Drawing.Font -ArgumentList $n, $s, $(if ($bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }) }
function Brush([int]$a, [int]$r, [int]$g, [int]$b) { New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb($a, $r, $g, $b)) }
function SaveJpg($bmp, [string]$path) { $c = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object MimeType -eq 'image/jpeg'; $p = New-Object System.Drawing.Imaging.EncoderParameters 1; $p.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality), 90; $bmp.Save($path, $c, $p) }
function Cover($g, $src, [System.Drawing.Rectangle]$dst, [single]$zoom = 1.0, [single]$yShift = 0) {
    $sr = $src.Width / $src.Height; $dr = $dst.Width / $dst.Height
    if ($sr -gt $dr) { $h = $src.Height / $zoom; $w = $h * $dr } else { $w = $src.Width / $zoom; $h = $w / $dr }
    $x = ($src.Width - $w) / 2; $y = [math]::Max(0, [math]::Min($src.Height - $h, ($src.Height - $h) / 2 + $yShift * $src.Height))
    $dstF = New-Object System.Drawing.RectangleF $dst.X, $dst.Y, $dst.Width, $dst.Height
    $g.DrawImage($src, $dstF, (New-Object System.Drawing.RectangleF $x, $y, $w, $h), [System.Drawing.GraphicsUnit]::Pixel)
}

$kr = [System.Drawing.Image]::FromFile("$PSScriptRoot\kr_pictures\1.7.jpg")
# Steam's game folder may be on an old version without launcher-assets (e.g. mid-install): then keep the existing bg.jpg
$bgFile = "$game\launcher-assets\app-background.png"; $bgSrc = if (Test-Path $bgFile) { [System.Drawing.Image]::FromFile($bgFile) } else { $null }

# ---- one tile per version: era colour runs from dark red (oldest) to steel blue (newest) ----
$T = 300; $n = $versions.Count
for ($i = 0; $i -lt $n; $i++) {
    $v = $versions[$i]; $frac = $i / [math]::Max(1, $n - 1)
    $col = [System.Drawing.Color]::FromArgb(255, [int](150 - 110 * $frac), [int](40 + 60 * $frac), [int](40 + 120 * $frac))
    $c = Canvas $T $T; $b = $c[0]; $g = $c[1]
    Cover $g $kr (New-Object System.Drawing.Rectangle 0, 0, $T, $T) 1.55 (-0.12)          # zoom on the eagle
    $g.FillRectangle((Brush 70 $col.R $col.G $col.B), 0, 0, $T, $T)                        # era tint
    $g.FillRectangle((Brush 215 16 16 18), 0, 0, $T, 62)                                   # top plate
    $g.FillRectangle((New-Object System.Drawing.SolidBrush $col), 0, 60, $T, 6)            # era stripe
    $sf = New-Object System.Drawing.StringFormat; $sf.Alignment = 'Center'
    $g.DrawString("KAISERREICH $($v.krLabel)", (Font 'Segoe UI' 21 $true), [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF 0, 10, $T, 44), $sf)
    if ($v.update) { $g.FillRectangle((Brush 170 0 0 0), 0, 128, $T, 34); $g.DrawString($v.update, (Font 'Georgia' 14), (Brush 255 235 220 170), (New-Object System.Drawing.RectangleF 4, 133, ($T - 8), 30), $sf) }
    $g.Dispose(); SaveJpg $b ("$img\kr_{0}.jpg" -f ($v.branch -replace '[^\w.]', '_')); $b.Dispose()
}

# ---- Player-Led Peace tile (same art the Classic launcher uses) ----
$plpcSrc = [System.Drawing.Image]::FromFile("$proj\PLPC_Legacy\thumb.jpg")
$c = Canvas $T $T; $b = $c[0]; $g = $c[1]; Cover $g $plpcSrc (New-Object System.Drawing.Rectangle 0, 0, $T, $T); $g.Dispose(); SaveJpg $b "$img\plpc.jpg"; $b.Dispose(); $plpcSrc.Dispose()

# ---- custom-game tiles: a portrait under a "CUSTOM GAME" band in the flag's colours ----
if (Test-Path "$proj\scenarios.json") {
    foreach ($s in (Get-Content -LiteralPath "$proj\scenarios.json" -Raw | ConvertFrom-Json)) {
        $srcPic = "$PSScriptRoot\kr_pictures\$($s.id)_photo.png"; if (-not (Test-Path $srcPic)) { $srcPic = "$PSScriptRoot\kr_pictures\$($s.id).png" }; if (-not (Test-Path $srcPic)) { continue }
        $pic = [System.Drawing.Image]::FromFile($srcPic)
        $c = Canvas $T $T; $b = $c[0]; $g = $c[1]
        Cover $g $pic (New-Object System.Drawing.Rectangle 0, 0, $T, $T) 1.15 (-0.06)
        $g.FillRectangle((Brush 225 14 18 34), 0, 0, $T, 62)                                          # navy band
        $g.FillRectangle((Brush 255 178 34 52), 0, 62, $T, 5); $g.FillRectangle((Brush 255 240 240 240), 0, 67, $T, 3); $g.FillRectangle((Brush 255 178 34 52), 0, 70, $T, 5)
        $sf = New-Object System.Drawing.StringFormat; $sf.Alignment = 'Center'
        $g.DrawString('CUSTOM GAME', (Font 'Segoe UI' 21 $true), [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF 0, 4, $T, 34), $sf)
        $g.DrawString('★  SECOND AMERICAN CIVIL WAR  ★', (Font 'Segoe UI' 10 $true), (Brush 255 225 205 150), (New-Object System.Drawing.RectangleF 0, 38, $T, 22), $sf)
        $g.Dispose(); SaveJpg $b ("$img\{0}" -f (Split-Path $s.picture -Leaf)); $b.Dispose()
        # window background while this custom game is on: the photo on the right, fading into the dark behind the tiles
        $BW2 = 1180; $BH2 = 934
        $c = Canvas $BW2 $BH2; $b = $c[0]; $g = $c[1]; $g.Clear([System.Drawing.Color]::FromArgb(255, 12, 12, 16))
        $ph = $BH2; $pw = [int]($pic.Width * $ph / $pic.Height); $px = $BW2 - $pw
        $g.DrawImage($pic, (New-Object System.Drawing.Rectangle $px, 0, $pw, $ph))
        $fade = New-Object System.Drawing.Drawing2D.LinearGradientBrush -ArgumentList (New-Object System.Drawing.Rectangle ($px - 1), 0, ([int]($pw * 0.6)), $BH2), ([System.Drawing.Color]::FromArgb(255, 12, 12, 16)), ([System.Drawing.Color]::FromArgb(0, 12, 12, 16)), ([System.Drawing.Drawing2D.LinearGradientMode]::Horizontal)
        $g.FillRectangle($fade, ($px - 1), 0, ([int]($pw * 0.6)), $BH2)
        $g.FillRectangle((Brush 120 10 10 14), 0, 0, $BW2, $BH2)                                   # keep the tiles readable
        $g.Dispose(); SaveJpg $b ("$img\scnbg_{0}.jpg" -f $s.id); $b.Dispose(); $pic.Dispose()
    }
}

# ---- window background ----
$W = 1180; $H = 780
if ($bgSrc) { $c = Canvas $W $H; $b = $c[0]; $g = $c[1]; Cover $g $bgSrc (New-Object System.Drawing.Rectangle 0, 0, $W, $H)
$g.FillRectangle((Brush 200 12 12 16), 0, 0, $W, $H); $g.Dispose(); SaveJpg $b "$img\bg.jpg"; $b.Dispose() }

# ---- icon source: the eagle, framed in Kaiserreich red ----
$S = 256; $c = Canvas $S $S; $b = $c[0]; $g = $c[1]
Cover $g $kr (New-Object System.Drawing.Rectangle 0, 0, $S, $S) 1.6 (-0.13)
$g.DrawRectangle((New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 150, 30, 30)), 12), 0, 0, $S, $S)
$g.Dispose(); $b.Save("$img\icon_256.png", [System.Drawing.Imaging.ImageFormat]::Png); $iconSrc = $b

# ---- banner: emblem + stamped title ----
$BW = 1100; $BH = 84
$c = Canvas $BW $BH; $b = $c[0]; $g = $c[1]; $g.Clear([System.Drawing.Color]::Transparent)
$g.DrawImage($iconSrc, (New-Object System.Drawing.Rectangle 0, 6, 72, 72))
$font = Font 'Impact' 40
$path = New-Object System.Drawing.Drawing2D.GraphicsPath
$path.AddString('KAISERREICH COLLECTION', $font.FontFamily, [int]$font.Style, $g.DpiY * $font.Size / 72, (New-Object System.Drawing.Point 90, 8), [System.Drawing.StringFormat]::GenericDefault)
$bounds = $path.GetBounds(); $m = New-Object System.Drawing.Drawing2D.Matrix; $m.Translate(3, 3); $sh = $path.Clone(); $sh.Transform($m)
$g.FillPath((Brush 180 0 0 0), $sh)
$grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush -ArgumentList ([System.Drawing.RectangleF]$bounds), ([System.Drawing.Color]::FromArgb(255, 245, 235, 215)), ([System.Drawing.Color]::FromArgb(255, 175, 45, 40)), ([System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
$g.FillPath($grad, $path)
$g.DrawPath((New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 30, 10, 10)), 2), $path)
$g.DrawString('EVERY KAISERREICH ON ITS OWN HEARTS OF IRON IV VERSION  -  0.8.4a TO 1.7', (Font 'Segoe UI' 10), (Brush 255 205 205 205), 92, ($bounds.Bottom + 4))
$g.DrawLine((New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 150, 30, 30)), 2), 90, ($BH - 2), $BW, ($BH - 2))
$g.Dispose(); $b.Save("$img\banner.png", [System.Drawing.Imaging.ImageFormat]::Png); $b.Dispose()

# ---- multi-size .ico (classic BMP entries) ----
$entries = @()
foreach ($sz in 16, 24, 32, 48, 64, 128, 256) {
    $bmp = New-Object System.Drawing.Bitmap $sz, $sz; $gg = [System.Drawing.Graphics]::FromImage($bmp); $gg.InterpolationMode = 'HighQualityBicubic'; $gg.DrawImage($iconSrc, 0, 0, $sz, $sz); $gg.Dispose()
    $ms = New-Object IO.MemoryStream; $bw = New-Object IO.BinaryWriter $ms
    $bw.Write([uint32]40); $bw.Write([int32]$sz); $bw.Write([int32]($sz * 2)); $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]0); $bw.Write([uint32]($sz * $sz * 4)); $bw.Write([int32]0); $bw.Write([int32]0); $bw.Write([uint32]0); $bw.Write([uint32]0)
    for ($y = $sz - 1; $y -ge 0; $y--) { for ($x = 0; $x -lt $sz; $x++) { $px = $bmp.GetPixel($x, $y); $bw.Write([byte]$px.B); $bw.Write([byte]$px.G); $bw.Write([byte]$px.R); $bw.Write([byte]$px.A) } }
    $bw.Write((New-Object byte[] ([int]([math]::Ceiling($sz / 32.0) * 4) * $sz))); $bw.Flush(); $entries += ,@{ size = $sz; data = $ms.ToArray() }; $bmp.Dispose()
}
$ico = New-Object IO.MemoryStream; $w = New-Object IO.BinaryWriter $ico
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$entries.Count); $off = 6 + 16 * $entries.Count
foreach ($e in $entries) { $d = if ($e.size -ge 256) { 0 } else { $e.size }; $w.Write([byte]$d); $w.Write([byte]$d); $w.Write([byte]0); $w.Write([byte]0); $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$e.data.Length); $w.Write([uint32]$off); $off += $e.data.Length }
foreach ($e in $entries) { $w.Write($e.data) }; $w.Flush(); [IO.File]::WriteAllBytes("$proj\KaiserreichCollection.ico", $ico.ToArray())
$iconSrc.Dispose(); $kr.Dispose(); if ($bgSrc) { $bgSrc.Dispose() }
Get-ChildItem $img | ForEach-Object { "{0,-22} {1,4} KB" -f $_.Name, [math]::Round($_.Length / 1KB) }
