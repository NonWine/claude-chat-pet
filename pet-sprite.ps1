# Animated pet sprite for a WPF Image. Dot-source this, do not run it.
#
#     . "$PSScriptRoot\pet-sprite.ps1"
#     $pet = New-PetSprite -Image $someImage -FramesDir "$PSScriptRoot\sprites\frames"
#     $pet.SetState('working')
#
# The only contract with the art is the folder: sprites\frames\<state>\NN.png plus a
# manifest.json. Swapping the character means dropping different PNGs in - nothing here
# changes. Everything the manifest may say beyond frames/frameMs/loop is OPTIONAL, and a
# manifest written before a field existed keeps rendering exactly as it did.
#
# Per state:
#     frames    : how many PNG FILES the state has.
#     frameMs   : one number for the state, or one per TIMELINE step (see pick).
#     loop      : whether the timeline repeats.
#     pick      : optional. Turns the timeline into something other than "play file 1..N in
#                 order": one entry per step, each listing the file numbers allowed at that
#                 step. The renderer chooses among them, never the same twice running. This
#                 is what keeps an idle loop from reading as a machine - a human at rest
#                 does not hold one identical expression for ever.
#     group     : optional. Two states in the same group may cross-fade into each other.
#                 States in different groups hard-cut, because a fade between two different
#                 body poses is a four-armed ghost, not a transition.
#
# Whole-manifest:
#     displayHeight : how tall the character renders, in DIP. Width follows the art's aspect.
#     pixelArt      : true -> NearestNeighbor, false -> HighQuality.
#     crossfadeMs   : 0 (default) hard-cuts every state change, as it always did.
#     breathe       : { scaleY, scaleX, periodMs } for the caller's idle animation. Amplitude
#                     HAS to come from the art: 5% of a 16px cat is one pixel of squash, 5%
#                     of a 150px human figure is the character inflating.
#
# Frames stay at their native resolution; the caller decides display size.
#
# NOTE: this file must stay pure ASCII (PowerShell 5.1 reads a BOM-less script as ANSI).

function New-PetSprite {
    param(
        [Parameter(Mandatory = $true)] $Image,
        [Parameter(Mandatory = $true)] [string] $FramesDir,

        # A second Image stacked UNDER $Image, used only to cross-fade. Omit it and every
        # state change hard-cuts, which is what callers that never had one still get.
        $FadeImage = $null
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

        # ------------------------------------------------------------- timeline
        # Files and timeline steps are NOT the same count once 'pick' is in play: four
        # expression files can drive a two-step loop. Without pick the two collapse to the
        # old one-file-per-step timeline, so nothing about an existing manifest moves.
        $pick = New-Object System.Collections.ArrayList
        if ($null -ne $def.pick -and $def.pick -is [array] -and $def.pick.Count -gt 0) {
            foreach ($step in $def.pick) {
                $opts = New-Object System.Collections.ArrayList
                foreach ($n in @($step)) {
                    $k = [int]$n - 1          # manifest is 1-based, like the file names
                    if ($k -ge 0 -and $k -lt $imgs.Count) { [void]$opts.Add($k) }
                }
                if ($opts.Count -eq 0) { [void]$opts.Add(0) }
                [void]$pick.Add($opts)
            }
        }
        else {
            for ($i = 0; $i -lt $imgs.Count; $i++) {
                $opts = New-Object System.Collections.ArrayList
                [void]$opts.Add($i)
                [void]$pick.Add($opts)
            }
        }
        $steps = $pick.Count

        # frameMs is EITHER one number for the whole state OR one number per timeline step.
        # The per-step form exists for blinks: an even two-step loop on a human face reads as
        # falling asleep, while 3000ms open + 130ms shut reads as alive. A scalar is just the
        # even case, so both are normalised to the same array and there is one code path.
        $durs = [int[]]::new($steps)
        if ($def.frameMs -is [array]) {
            $given = $def.frameMs
            for ($i = 0; $i -lt $steps; $i++) {
                # A short array holds its last value instead of falling to 0, which would
                # otherwise run the rest of the state at the timer floor.
                $k = if ($i -lt $given.Count) { $i } else { $given.Count - 1 }
                $durs[$i] = [int]$given[$k]
            }
        }
        else {
            for ($i = 0; $i -lt $steps; $i++) { $durs[$i] = [int]$def.frameMs }
        }

        # A state animates only if it has somewhere to advance to and a real duration. A
        # one-step state is a still, whatever its frameMs says.
        $maxDur = 0
        foreach ($d in $durs) { if ($d -gt $maxDur) { $maxDur = $d } }
        $animated = ($steps -gt 1 -and $maxDur -gt 0)

        # Once it does animate, every step is floored: a stray 0 inside an array must not
        # become a zero-interval DispatcherTimer.
        if ($animated) {
            for ($i = 0; $i -lt $durs.Count; $i++) { if ($durs[$i] -lt 16) { $durs[$i] = 16 } }
        }

        $last = [int[]]::new($steps)
        for ($i = 0; $i -lt $steps; $i++) { $last[$i] = -1 }

        $states[$name] = @{
            Frames    = $imgs
            Pick      = $pick
            LastPick  = $last
            Durations = $durs
            Animated  = $animated
            Loop      = [bool]$def.loop
            Group     = [string]$def.group
        }
    }

    if ($states.Count -eq 0) { throw "no usable sprite frames under $FramesDir" }

    # ------------------------------------------------------- presentation hints
    # How big the character is, and whether it is pixel art, is a property of the ART, not of
    # the widget: a 16px cat and a 150px anime portrait need different display boxes and
    # opposite scaling filters. Reading them from the manifest keeps the promise that swapping
    # the character means swapping files.
    $dispH = 0.0
    $dispW = 0.0
    $names = $manifest.PSObject.Properties.Name
    $layers = @($Image, $FadeImage) | Where-Object { $null -ne $_ }

    if ($names -contains 'displayHeight' -and [double]$manifest.displayHeight -gt 0) {
        $dispH = [double]$manifest.displayHeight

        # Width follows the art's own aspect ratio - never configured, so art can never be
        # stretched by a stale number in the manifest.
        $ref = $null
        if ($states.ContainsKey('idle')) { $ref = $states['idle'].Frames[0] }
        else { foreach ($k in $states.Keys) { $ref = $states[$k].Frames[0]; break } }

        $dispW = [Math]::Round($dispH * $ref.PixelWidth / $ref.PixelHeight, 0)
        foreach ($l in $layers) { $l.Height = $dispH; $l.Width = $dispW }
    }

    if ($names -contains 'pixelArt') {
        $smode = if ([bool]$manifest.pixelArt) {
            [System.Windows.Media.BitmapScalingMode]::NearestNeighbor
        } else {
            [System.Windows.Media.BitmapScalingMode]::HighQuality
        }
        foreach ($l in $layers) { [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($l, $smode) }
    }

    $fadeMs = 0
    if ($names -contains 'crossfadeMs') { $fadeMs = [int]$manifest.crossfadeMs }
    if ($null -eq $FadeImage) { $fadeMs = 0 }

    # Defaults are the values the widget hardcoded before this was a manifest field, so the
    # placeholder breathes exactly as it always has.
    $breathe = @{ ScaleY = 1.05; ScaleX = 0.975; PeriodMs = 1300 }
    if ($names -contains 'breathe' -and $null -ne $manifest.breathe) {
        $b = $manifest.breathe
        if ($null -ne $b.scaleY)   { $breathe.ScaleY   = [double]$b.scaleY }
        if ($null -ne $b.scaleX)   { $breathe.ScaleX   = [double]$b.scaleX }
        if ($null -ne $b.periodMs) { $breathe.PeriodMs = [int]$b.periodMs }
    }

    $sprite = [pscustomobject]@{
        Image     = $Image
        FadeImage = $FadeImage
        States    = $states
        Current   = $null
        Frame     = 0          # timeline step, not file index
        FadeMs    = $fadeMs
        Breathe   = $breathe

        Timer = (New-Object System.Windows.Threading.DispatcherTimer)

        # 0 when the manifest gave no hint. The caller uses these to size whatever sits
        # around the character (hit area, shadow) instead of hardcoding the art's size too.
        DisplayWidth  = $dispW
        DisplayHeight = $dispH
    }

    # Which file to show at a timeline step. With one option this is the plain old behaviour;
    # with several it never repeats the previous choice, because a random walk that lands on
    # the same expression three cycles running looks like a bug rather than like chance.
    #
    # The draw excludes the previous choice instead of re-rolling until it differs. Re-rolling
    # only makes a repeat unlikely - with two options and eight tries it still slips through
    # about once in 256, which at one pick a second is several times an hour.
    Add-Member -InputObject $sprite -MemberType ScriptMethod -Name PickFrame -Value {
        param($State, [int]$Step)
        $opts = $State.Pick[$Step]
        if ($opts.Count -eq 1) { return $opts[0] }

        $last = $State.LastPick[$Step]
        $pool = New-Object System.Collections.ArrayList
        foreach ($o in $opts) { if ($o -ne $last) { [void]$pool.Add($o) } }
        if ($pool.Count -eq 0) { $pool = $opts }   # every option is the last one; nothing to vary

        $chosen = $pool[(Get-Random -Minimum 0 -Maximum $pool.Count)]
        $State.LastPick[$Step] = $chosen
        return $chosen
    }

    $sprite.Timer.Add_Tick({
        try {
            $s = $sprite.States[$sprite.Current]
            if ($null -eq $s -or -not $s.Animated) { return }
            $next = $sprite.Frame + 1
            if ($next -ge $s.Pick.Count) {
                if (-not $s.Loop) { $sprite.Timer.Stop(); return }
                $next = 0
            }
            $sprite.Frame = $next
            $sprite.Image.Source = $s.Frames[$sprite.PickFrame($s, $next)]

            # Every step carries its own dwell time, so the timer is re-armed for the step
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

        $s    = $this.States[$Name]
        $prev = if ($null -ne $this.Current) { $this.States[$this.Current] } else { $null }
        $was  = $this.Image.Source

        # Fade only between states that declared the same group. Across groups the art is a
        # different body pose, and dissolving one into the other shows both sets of arms.
        $fade = ($this.FadeMs -gt 0 -and $null -ne $was -and $null -ne $prev -and
                 -not [string]::IsNullOrEmpty($prev.Group) -and $prev.Group -eq $s.Group)

        $this.Current = $Name
        $this.Frame = 0
        $this.Image.Source = $s.Frames[$this.PickFrame($s, 0)]

        if ($fade) { $this.BeginFade($was) }

        $this.Timer.Stop()
        if ($s.Animated) {
            $this.Timer.Interval = [TimeSpan]::FromMilliseconds($s.Durations[0])
            $this.Timer.Start()
        }
    }

    # The outgoing frame sits underneath at full opacity while the incoming one fades in over
    # it. Fading BOTH would let the desktop show through the character mid-transition.
    Add-Member -InputObject $sprite -MemberType ScriptMethod -Name BeginFade -Value {
        param($PrevBitmap)
        $fi  = $this.FadeImage
        $img = $this.Image
        $fi.Source = $PrevBitmap
        $fi.Opacity = 1

        $a = New-Object System.Windows.Media.Animation.DoubleAnimation
        $a.From = 0.0
        $a.To = 1.0
        $a.Duration = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds($this.FadeMs))
        $ease = New-Object System.Windows.Media.Animation.CubicEase
        $ease.EasingMode = "EaseInOut"
        $a.EasingFunction = $ease
        $a.Add_Completed({
            # Releasing the animation matters: while one is attached it overrides the local
            # value, so a later plain assignment to Opacity would silently do nothing.
            try {
                $img.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
                $img.Opacity = 1
                $fi.Opacity = 0
                $fi.Source = $null
            } catch { }
        }.GetNewClosure())
        $img.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $a)
    }

    Add-Member -InputObject $sprite -MemberType ScriptMethod -Name Stop -Value {
        try { $this.Timer.Stop() } catch { }
        try {
            if ($null -ne $this.FadeImage) { $this.FadeImage.Opacity = 0; $this.FadeImage.Source = $null }
        } catch { }
    }

    return $sprite
}
