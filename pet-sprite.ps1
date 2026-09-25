# Animated pet sprite for a WPF Image. Dot-source this, do not run it.
#
#     . "$PSScriptRoot\pet-sprite.ps1"
#     $pet = New-PetSprite -Image $someImage -FramesDir "$PSScriptRoot\sprites\frames"
#     $pet.SetState('working')
#
# The only contract with the art is the folder: sprites\frames\<state>\NN.png plus a
# manifest.json giving frameMs / loop / frames per state, where frameMs is one number for
# the state or an array of one number per frame. Swapping the character means
# dropping different PNGs in - nothing here changes.
#
# The manifest may also carry two OPTIONAL presentation hints, so that swapping a 16px pixel
# cat for a 150px anime portrait needs no code edit either:
#     displayHeight : how tall the character renders, in DIP. Width follows the art's aspect.
#     pixelArt      : true -> NearestNeighbor, false -> HighQuality.
# Omit them and the caller's XAML decides, exactly as before they existed.
#
# Frames stay at their native resolution; the caller decides display size and should set
# RenderOptions.BitmapScalingMode="NearestNeighbor" on the Image so pixel art stays crisp.
#
# NOTE: this file must stay pure ASCII (PowerShell 5.1 reads a BOM-less script as ANSI).

function New-PetSprite {
    param(
        [Parameter(Mandatory = $true)] $Image,
        [Parameter(Mandatory = $true)] [string] $FramesDir
    )

    $manifestPath = Join-Path $FramesDir "manifest.json"
    if (-not (Test-Path $manifestPath)) {
        throw "pet sprite frames not found at $FramesDir - run sprites\build-placeholder-frames.ps1"
    }

    $manifest = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

    $states = @{}
    foreach ($p in $manifest.states.PSObject.Properties) {
        $name = $p.Name
        $def  = $p.Value
        $imgs = New-Object System.Collections.ArrayList
        for ($i = 1; $i -le [int]$def.frames; $i++) {
            $file = Join-Path $FramesDir ("{0}\{1:d2}.png" -f $name, $i)
            if (-not (Test-Path $file)) { continue }
            $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
            $bmp.BeginInit()
            $bmp.UriSource = [Uri]$file
            $bmp.CacheOption = "OnLoad"   # read now, so the file is not locked afterwards
            $bmp.EndInit()
            $bmp.Freeze()
            [void]$imgs.Add($bmp)
        }
        if ($imgs.Count -eq 0) { continue }

        # frameMs is EITHER one number for the whole state OR one number per frame. The
        # per-frame form exists for blinks: an even two-frame loop on a human face reads as
        # falling asleep, while 2600ms open + 120ms shut reads as alive. A scalar is just the
        # even case, so both are normalised to the same array and there is one code path.
        $durs = [int[]]::new($imgs.Count)
        if ($def.frameMs -is [array]) {
            $given = $def.frameMs
            for ($i = 0; $i -lt $imgs.Count; $i++) {
                # A short array holds its last value instead of falling to 0, which would
                # otherwise run the rest of the state at the timer floor.
                $k = if ($i -lt $given.Count) { $i } else { $given.Count - 1 }
                $durs[$i] = [int]$given[$k]
            }
        }
        else {
            for ($i = 0; $i -lt $imgs.Count; $i++) { $durs[$i] = [int]$def.frameMs }
        }

        # A state animates only if it has somewhere to advance to and a real duration -
        # 'hover' and 'input' are single stills with frameMs 0 and must stay that way.
        $maxDur = 0
        foreach ($d in $durs) { if ($d -gt $maxDur) { $maxDur = $d } }
        $animated = ($imgs.Count -gt 1 -and $maxDur -gt 0)

        # Once it does animate, every step is floored: a stray 0 inside an array must not
        # become a zero-interval DispatcherTimer.
        if ($animated) {
            for ($i = 0; $i -lt $durs.Count; $i++) { if ($durs[$i] -lt 16) { $durs[$i] = 16 } }
        }

        $states[$name] = @{
            Frames    = $imgs
            Durations = $durs
            Animated  = $animated
            Loop      = [bool]$def.loop
        }
    }

    if ($states.Count -eq 0) { throw "no usable sprite frames under $FramesDir" }

    # ------------------------------------------------------- presentation hints
    # How big the character is, and whether it is pixel art, is a property of the ART, not of
    # the widget: a 16px cat and a 150px anime portrait need different display boxes and
    # opposite scaling filters. Reading them from the manifest keeps the promise that swapping
    # the character means swapping files.
    #
    # Both fields are OPTIONAL. Absent -> nothing is touched and the caller's XAML wins, so a
    # manifest written before these existed renders exactly as it did.
    $dispH = 0.0
    $dispW = 0.0
    $names = $manifest.PSObject.Properties.Name

    if ($names -contains 'displayHeight' -and [double]$manifest.displayHeight -gt 0) {
        $dispH = [double]$manifest.displayHeight

        # Width follows the art's own aspect ratio - never configured, so art can never be
        # stretched by a stale number in the manifest.
        $ref = $null
        if ($states.ContainsKey('idle')) { $ref = $states['idle'].Frames[0] }
        else { foreach ($k in $states.Keys) { $ref = $states[$k].Frames[0]; break } }

        $dispW = [Math]::Round($dispH * $ref.PixelWidth / $ref.PixelHeight, 0)
        $Image.Height = $dispH
        $Image.Width  = $dispW
    }

    if ($names -contains 'pixelArt') {
        $smode = if ([bool]$manifest.pixelArt) {
            [System.Windows.Media.BitmapScalingMode]::NearestNeighbor
        } else {
            [System.Windows.Media.BitmapScalingMode]::HighQuality
        }
        [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($Image, $smode)
    }

    $sprite = [pscustomobject]@{
        Image   = $Image
        States  = $states
        Current = $null
        Frame   = 0
        Timer   = (New-Object System.Windows.Threading.DispatcherTimer)

        # 0 when the manifest gave no hint. The caller uses these to size whatever sits
        # around the character (hit area, shadow) instead of hardcoding the art's size too.
        DisplayWidth  = $dispW
        DisplayHeight = $dispH
    }

    $sprite.Timer.Add_Tick({
        try {
            $s = $sprite.States[$sprite.Current]
            if ($null -eq $s -or -not $s.Animated) { return }
            $next = $sprite.Frame + 1
            if ($next -ge $s.Frames.Count) {
                if (-not $s.Loop) { $sprite.Timer.Stop(); return }
                $next = 0
            }
            $sprite.Frame = $next
            $sprite.Image.Source = $s.Frames[$next]

            # Every frame carries its own dwell time, so the timer is re-armed for the frame
            # just shown. Assigning Interval on a running DispatcherTimer restarts its
            # countdown, which is exactly the variable-rate behaviour wanted here.
            $sprite.Timer.Interval = [TimeSpan]::FromMilliseconds($s.Durations[$next])
        } catch { }
    }.GetNewClosure())

    # Idempotent: calling it with the current state every UI tick costs nothing.
    Add-Member -InputObject $sprite -MemberType ScriptMethod -Name SetState -Value {
        param([string]$Name)
        if ([string]::IsNullOrEmpty($Name) -or -not $this.States.ContainsKey($Name)) { $Name = 'idle' }
        if ($this.Current -eq $Name) { return }

        $s = $this.States[$Name]
        $this.Current = $Name
        $this.Frame = 0
        $this.Image.Source = $s.Frames[0]

        $this.Timer.Stop()
        if ($s.Animated) {
            $this.Timer.Interval = [TimeSpan]::FromMilliseconds($s.Durations[0])
            $this.Timer.Start()
        }
    }

    Add-Member -InputObject $sprite -MemberType ScriptMethod -Name Stop -Value {
        try { $this.Timer.Stop() } catch { }
    }

    return $sprite
}
