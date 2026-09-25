# Renders placeholder pet frames from the pixel-buddy pack into sprites\frames\<state>\NN.png.
#
# The pet's visual layer does NOT read pack.json at runtime: it reads a folder of PNGs plus
# manifest.json. That is the whole contract, so swapping the character later means dropping
# different PNGs into sprites\frames - no renderer change.
#
# Frames are written at their NATIVE 16x16 resolution. Upscaling is the renderer's job
# (NearestNeighbor), so the widget's Ctrl+wheel zoom stays crisp and real 64px art can be
# dropped in later without touching anything.
#
# Source art: "Pixel Buddy" from claude-code-mascot-statusline (MIT) - see pixel-buddy-source\LICENSE.
# NOTE: this file must stay pure ASCII (PowerShell 5.1 reads a BOM-less script as ANSI).

$ErrorActionPreference = "Stop"

$root      = $PSScriptRoot
$packPath  = Join-Path $root "pixel-buddy-source\pack.json"
$framesDir = Join-Path $root "frames"

Add-Type -AssemblyName PresentationCore, WindowsBase

# state name -> source frame keys in pack.json, plus how the renderer should play them.
$states = [ordered]@{
    idle     = @{ src = @('idle_1', 'idle_2');                    frameMs = 900;  loop = $true  }
    hover    = @{ src = @('ok_1');                                frameMs = 0;    loop = $false }
    input    = @{ src = @('question_1');                          frameMs = 0;    loop = $false }
    working  = @{ src = @('tool_1', 'tool_2');                    frameMs = 180;  loop = $true  }
    thinking = @{ src = @('thinking_1', 'thinking_2', 'thinking_3'); frameMs = 300; loop = $true }
    done     = @{ src = @('done_1', 'done_2');                    frameMs = 450;  loop = $true  }
    blocking = @{ src = @('permission_1', 'fail_1');              frameMs = 1400; loop = $true  }
}

if (-not (Test-Path $packPath)) { throw "pack.json not found at $packPath" }
$pack = Get-Content $packPath -Raw -Encoding UTF8 | ConvertFrom-Json

$w = [int]$pack.sprite.width
$h = [int]$pack.sprite.height

# palette[0] is null (transparent); everything else is "#rrggbb".
$brushes = @()
foreach ($c in $pack.sprite.palette) {
    if ($null -eq $c -or $c -eq "transparent") {
        $brushes += $null
    }
    else {
        $b = New-Object System.Windows.Media.SolidColorBrush(
                [System.Windows.Media.ColorConverter]::ConvertFromString($c))
        $b.Freeze()
        $brushes += $b
    }
}

function Save-Frame {
    param([object[]]$Grid, [string]$Path)

    $visual = New-Object System.Windows.Media.DrawingVisual
    # Integer-aligned 1x1 rects at 96 DPI land exactly on pixel boundaries; Aliased keeps
    # WPF from softening the edges anyway.
    [System.Windows.Media.RenderOptions]::SetEdgeMode($visual, [System.Windows.Media.EdgeMode]::Aliased)

    $dc = $visual.RenderOpen()
    for ($y = 0; $y -lt $h; $y++) {
        $row = $Grid[$y]
        for ($x = 0; $x -lt $w; $x++) {
            $brush = $brushes[[int]$row[$x]]
            if ($null -ne $brush) {
                $dc.DrawRectangle($brush, $null, (New-Object System.Windows.Rect($x, $y, 1, 1)))
            }
        }
    }
    $dc.Close()

    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(
                $w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($visual)

    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Create)
    try { $enc.Save($fs) } finally { $fs.Dispose() }
}

if (Test-Path $framesDir) { Remove-Item $framesDir -Recurse -Force }
New-Item -ItemType Directory -Path $framesDir | Out-Null

$manifestStates = [ordered]@{}

foreach ($name in $states.Keys) {
    $def      = $states[$name]
    $stateDir = Join-Path $framesDir $name
    New-Item -ItemType Directory -Path $stateDir | Out-Null

    $i = 0
    foreach ($key in $def.src) {
        $grid = $pack.sprites.$key
        if ($null -eq $grid) { throw "frame '$key' missing from pack.json" }
        $i++
        Save-Frame -Grid $grid -Path (Join-Path $stateDir ("{0:d2}.png" -f $i))
    }

    $manifestStates[$name] = [ordered]@{
        frameMs = $def.frameMs
        loop    = $def.loop
        frames  = $i
    }
    Write-Output ("{0,-9} {1} frame(s)" -f $name, $i)
}

$manifest = [ordered]@{
    placeholder = $true
    source      = "Pixel Buddy from claude-code-mascot-statusline (MIT)"
    note        = "Placeholder art. Replace the PNGs in frames\<state>\ to swap the character."
    width       = $w
    height      = $h
    states      = $manifestStates
}

$manifestPath = Join-Path $framesDir "manifest.json"
$manifest | ConvertTo-Json -Depth 6 | Set-Content -Path $manifestPath -Encoding UTF8
Write-Output "manifest -> $manifestPath"
