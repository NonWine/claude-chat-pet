# Turns a pile of visual-novel character art into the pet's frame contract.
#
#     powershell -NoProfile -ExecutionPolicy Bypass -STA -File sprites\build-character-frames.ps1 `
#         -SourceDir sprites\kurisu-source -MappingPath sprites\kurisu-source\mapping.json
#
# VN "tachie" art is one PNG per pose-and-expression, at 300-800px, cropped by whoever ripped
# it to that pose's own bounds. Three things have to happen before it can be a 150px desktop
# pet, and only the second one is non-obvious:
#
#   1. compose  - the body, plus an optional overlay layer, at native pixel size (1:1, DPI
#                 metadata ignored). Most rips need no overlay: the expression is already
#                 baked into the body file, and the separate mouth parts are lip-sync crops
#                 whose on-canvas position lives in the game's scripts, not in the PNGs.
#   2. register - the frames onto ONE canvas, THEN crop them all with one rectangle. Both
#                 halves matter. Poses do not share a canvas size (arms-crossed is 360px wide
#                 where relaxed is 480px), so one rectangle applied to the raw files falls
#                 outside the narrow ones. But registering by each frame's own alpha bounds
#                 is just as wrong, and more insidious: a pose cropped at the hips has
#                 shorter bounds than one cropped at the thighs, so aligning the bounds
#                 makes the character appear to change size between states. A rip's canvases
#                 are already registered against each other - verify it by overlaying two
#                 poses - so the canvas is the alignment, and the alpha only decides how much
#                 shared padding to trim once everything is on it.
#   3. scale    - down to the target height, HighQuality, aspect preserved.
#
# Output is exactly what pet-sprite.ps1 reads: <OutDir>\<state>\NN.png plus manifest.json.
# Nothing in the widget changes - not even the pet's size, which the manifest carries.
#
# Run with -ListSource to just dump what is in the source folder; a ripped sheet is typically
# a couple of hundred files and the mapping has to be written by hand against real names.
#
# NOTE: this file must stay pure ASCII (PowerShell 5.1 reads a BOM-less script as ANSI).

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $SourceDir,
    [string] $MappingPath,
    [string] $OutDir,
    [switch] $ListSource
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName PresentationCore, WindowsBase

$SourceDir = (Resolve-Path $SourceDir).Path

# ------------------------------------------------------------------ -ListSource
if ($ListSource) {
    Get-ChildItem -Path $SourceDir -Recurse -Filter *.png |
        ForEach-Object {
            $rel = $_.FullName.Substring($SourceDir.Length).TrimStart('\')
            $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
            $bmp.BeginInit(); $bmp.UriSource = [Uri]$_.FullName; $bmp.CacheOption = "OnLoad"; $bmp.EndInit()
            "{0,-52} {1,5} x {2,-5} {3,8:n0} KB" -f $rel, $bmp.PixelWidth, $bmp.PixelHeight, ($_.Length / 1KB)
        }
    return
}

if (-not $MappingPath) { throw "-MappingPath is required unless -ListSource is given" }
$mapping = Get-Content (Resolve-Path $MappingPath).Path -Raw -Encoding UTF8 | ConvertFrom-Json

if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot "frames" }

$dispH  = if ($mapping.displayHeight) { [int]$mapping.displayHeight } else { 150 }
# Frames are stored above display size so the widget's Ctrl+wheel zoom (up to 2.5x) and a
# 150% Windows scale still have real pixels to show instead of a blur.
$super  = if ($mapping.supersample) { [double]$mapping.supersample } else { 2.0 }
$offset = if ($mapping.overlayOffset) { $mapping.overlayOffset } else { @(0, 0) }

# How a frame's canvas sits in the register canvas. 'center-top' matches every rip seen so
# far: files are the same height, centred on the character, and differ only in width. Use
# 'center-bottom' if a source's canvases share a floor line rather than a top line.
$anchor = if ($mapping.anchor) { [string]$mapping.anchor } else { "center-top" }
if ($anchor -ne "center-top" -and $anchor -ne "center-bottom") {
    throw "anchor must be 'center-top' or 'center-bottom', got '$anchor'"
}

# Scanning up to half a million pixels per frame for alpha bounds is seconds per frame in
# PowerShell and instant in C#. That is the only reason there is a compiled helper here.
if (-not ("PetAlpha" -as [type])) {
    Add-Type -TypeDefinition @"
public static class PetAlpha {
    // returns {minX, minY, maxX, maxY}; maxX < 0 means the frame was fully transparent.
    public static int[] Bounds(byte[] px, int w, int h, int stride, int threshold) {
        int minX = w, minY = h, maxX = -1, maxY = -1;
        for (int y = 0; y < h; y++) {
            int row = y * stride;
            for (int x = 0; x < w; x++) {
                if (px[row + x * 4 + 3] > threshold) {
                    if (x < minX) minX = x;
                    if (x > maxX) maxX = x;
                    if (y < minY) minY = y;
                    if (y > maxY) maxY = y;
                }
            }
        }
        return new int[] { minX, minY, maxX, maxY };
    }
}
"@
}

function Read-Source([string]$Rel) {
    $path = Join-Path $SourceDir $Rel
    if (-not (Test-Path $path)) { throw "source image not found: $Rel" }
    $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
    $bmp.BeginInit()
    $bmp.UriSource = [Uri]$path
    $bmp.CacheOption = "OnLoad"
    $bmp.EndInit()
    $bmp.Freeze()
    return $bmp
}

# Draws into a fresh RenderTargetBitmap of an explicit pixel size at 96 DPI, so a source's own
# DPI metadata can never scale anything behind our back.
function New-Render([int]$W, [int]$H, [scriptblock]$Draw, [bool]$Smooth) {
    $dv = New-Object System.Windows.Media.DrawingVisual
    if ($Smooth) {
        [System.Windows.Media.RenderOptions]::SetBitmapScalingMode(
            $dv, [System.Windows.Media.BitmapScalingMode]::HighQuality)
    }
    $dc = $dv.RenderOpen()
    try { & $Draw $dc } finally { $dc.Close() }

    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(
                $W, $H, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($dv)
    return $rtb
}

function Get-AlphaBounds($Bitmap) {
    $stride = $Bitmap.PixelWidth * 4
    $buf = New-Object byte[] ($stride * $Bitmap.PixelHeight)
    $Bitmap.CopyPixels($buf, $stride, 0)
    return [PetAlpha]::Bounds($buf, $Bitmap.PixelWidth, $Bitmap.PixelHeight, $stride, 8)
}

# -------------------------------------------------- 1. compose and measure each
$composed = [ordered]@{}   # state -> list of @{ Bitmap; X; Y; W; H; NudgeX; NudgeY }

foreach ($p in $mapping.states.PSObject.Properties) {
    $state = $p.Name
    $list  = New-Object System.Collections.ArrayList
    $nudge = if ($p.Value.nudge) { $p.Value.nudge } else { @(0, 0) }

    foreach ($f in $p.Value.frames) {
        # A frame is either "body.png" or { body, overlay }.
        $bodyRel = $null; $overRel = $null
        if ($f -is [string]) { $bodyRel = $f }
        else { $bodyRel = $f.body; $overRel = $f.overlay }

        $body = Read-Source $bodyRel
        $over = if ($overRel) { Read-Source $overRel } else { $null }

        $rtb = New-Render $body.PixelWidth $body.PixelHeight ({
            param($dc)
            $dc.DrawImage($body, (New-Object System.Windows.Rect(
                0, 0, $body.PixelWidth, $body.PixelHeight)))
            if ($over) {
                $dc.DrawImage($over, (New-Object System.Windows.Rect(
                    [double]$offset[0], [double]$offset[1], $over.PixelWidth, $over.PixelHeight)))
            }
        }.GetNewClosure()) $false

        $b = Get-AlphaBounds $rtb
        if ($b[2] -lt 0) { throw "frame '$bodyRel' is fully transparent" }

        [void]$list.Add(@{
            Bitmap  = $rtb
            CanvasW = $rtb.PixelWidth; CanvasH = $rtb.PixelHeight
            X = $b[0]; Y = $b[1]
            W = ($b[2] - $b[0] + 1); H = ($b[3] - $b[1] + 1)
            NudgeX = [int]$nudge[0]; NudgeY = [int]$nudge[1]
        })
    }

    if ($list.Count -eq 0) { throw "state '$state' has no frames" }
    $composed[$state] = $list
    Write-Output ("composed {0,-9} {1} frame(s)" -f $state, $list.Count)
}

# --------------------------------------------- 2. register, then one shared crop
# The register canvas is big enough for every frame's canvas; each one is placed in it by
# the anchor, and a state may correct a stubborn pose with "nudge": [dx, dy] in source
# pixels. Only then is the alpha union taken, so the crop trims padding that ALL frames
# share and moves nobody relative to anybody.
$canvasW = 0; $canvasH = 0
foreach ($state in $composed.Keys) {
    foreach ($fr in $composed[$state]) {
        if ($fr.CanvasW -gt $canvasW) { $canvasW = $fr.CanvasW }
        if ($fr.CanvasH -gt $canvasH) { $canvasH = $fr.CanvasH }
    }
}

$minX = [int]::MaxValue; $minY = [int]::MaxValue; $maxX = -1; $maxY = -1
foreach ($state in $composed.Keys) {
    foreach ($fr in $composed[$state]) {
        $fr.OffX = [int][Math]::Round(($canvasW - $fr.CanvasW) / 2.0) + $fr.NudgeX
        $fr.OffY = $(if ($anchor -eq "center-top") { 0 } else { $canvasH - $fr.CanvasH }) + $fr.NudgeY

        # The frame's alpha bounds, expressed in register-canvas coordinates. Derived rather
        # than re-measured: placing a frame cannot change the shape of its own alpha.
        $x0 = $fr.X + $fr.OffX; $y0 = $fr.Y + $fr.OffY
        if ($x0 -lt $minX) { $minX = $x0 }
        if ($y0 -lt $minY) { $minY = $y0 }
        if (($x0 + $fr.W - 1) -gt $maxX) { $maxX = $x0 + $fr.W - 1 }
        if (($y0 + $fr.H - 1) -gt $maxY) { $maxY = $y0 + $fr.H - 1 }
    }
}

$cropW = $maxX - $minX + 1
$cropH = $maxY - $minY + 1
Write-Output ("register    {0}x{1} canvas, shared crop {2},{3} {4}x{5}" -f `
    $canvasW, $canvasH, $minX, $minY, $cropW, $cropH)

$nativeH = [int][Math]::Round($dispH * $super)
$scale   = $nativeH / $cropH
$nativeW = [int][Math]::Round($cropW * $scale)
Write-Output ("frames out  {0}x{1}  (display {2}px, supersample {3}x)" -f $nativeW, $nativeH, $dispH, $super)

# ------------------------------------------------------------ 3. scale and write
if (Test-Path $OutDir) { Remove-Item $OutDir -Recurse -Force }
New-Item -ItemType Directory -Path $OutDir | Out-Null

$manifestStates = [ordered]@{}

foreach ($p in $mapping.states.PSObject.Properties) {
    $state    = $p.Name
    $def      = $p.Value
    $stateDir = Join-Path $OutDir $state
    New-Item -ItemType Directory -Path $stateDir | Out-Null

    $i = 0
    foreach ($fr in $composed[$state]) {
        # Register placement and crop and scale collapse into one draw, so the art is
        # resampled exactly once. The whole composed canvas is drawn; whatever falls outside
        # the output is clipped, which is precisely the crop.
        $dx = ($fr.OffX - $minX) * $scale
        $dy = ($fr.OffY - $minY) * $scale
        $dw = $fr.CanvasW * $scale
        $dh = $fr.CanvasH * $scale
        $bmp = $fr.Bitmap

        $scaled = New-Render $nativeW $nativeH ({
            param($dc)
            $dc.DrawImage($bmp, (New-Object System.Windows.Rect($dx, $dy, $dw, $dh)))
        }.GetNewClosure()) $true

        $i++
        $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($scaled))
        $fs = [IO.File]::Open((Join-Path $stateDir ("{0:d2}.png" -f $i)), [IO.FileMode]::Create)
        try { $enc.Save($fs) } finally { $fs.Dispose() }
    }

    # frameMs passes through in whichever shape the mapping used. pet-sprite.ps1 takes a
    # scalar or one value per frame, and the per-frame form is what makes a blink possible:
    # an even two-frame idle loop on a human face reads as falling asleep.
    $ms = if ($def.frameMs -is [array]) { @($def.frameMs | ForEach-Object { [int]$_ }) }
          else { [int]$def.frameMs }

    $entry = [ordered]@{
        frameMs = $ms
        loop    = [bool]$def.loop
        frames  = $i
    }
    # 'pick' turns the timeline into something other than file 1..N in order, and 'group'
    # says which states may cross-fade into each other. Both pass straight through: the
    # numbers in 'pick' are positions in this state's own frames list, and that list is
    # written out as 01..NN in the same order, so they already line up.
    if ($null -ne $def.pick)  { $entry.pick  = $def.pick }
    if ($def.group)           { $entry.group = [string]$def.group }
    $manifestStates[$state] = $entry
    Write-Output ("wrote    {0,-9} {1} frame(s)" -f $state, $i)
}

$manifest = [ordered]@{
    placeholder   = $false
    source        = if ($mapping.name) { [string]$mapping.name } else { "custom character" }
    note          = if ($mapping.credit) { [string]$mapping.credit } else { "" }
    width         = $nativeW
    height        = $nativeH
    displayHeight = $dispH
    pixelArt      = $false
    states        = $manifestStates
}
if ($null -ne $mapping.crossfadeMs) { $manifest.crossfadeMs = [int]$mapping.crossfadeMs }
if ($null -ne $mapping.breathe) {
    # Breathing amplitude is a property of how big and how human the art is, so it is
    # authored next to the art rather than in the widget.
    $manifest.breathe = [ordered]@{
        scaleY   = [double]$mapping.breathe.scaleY
        scaleX   = [double]$mapping.breathe.scaleX
        periodMs = [int]$mapping.breathe.periodMs
    }
}

$manifestPath = Join-Path $OutDir "manifest.json"
$manifest | ConvertTo-Json -Depth 6 | Set-Content -Path $manifestPath -Encoding UTF8
Write-Output "manifest -> $manifestPath"
