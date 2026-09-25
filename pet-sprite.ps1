# Animated pet sprite for a WPF Image. Dot-source this, do not run it.
#
#     . "$PSScriptRoot\pet-sprite.ps1"
#     $pet = New-PetSprite -Image $someImage -FramesDir "$PSScriptRoot\sprites\frames"
#     $pet.SetState('working')
#
# The only contract with the art is the folder: sprites\frames\<state>\NN.png plus a
# manifest.json giving frameMs / loop / frames per state. Swapping the character means
# dropping different PNGs in - nothing here changes.
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
        $states[$name] = @{
            Frames  = $imgs
            FrameMs = [int]$def.frameMs
            Loop    = [bool]$def.loop
        }
    }

    if ($states.Count -eq 0) { throw "no usable sprite frames under $FramesDir" }

    $sprite = [pscustomobject]@{
        Image   = $Image
        States  = $states
        Current = $null
        Frame   = 0
        Timer   = (New-Object System.Windows.Threading.DispatcherTimer)
    }

    $sprite.Timer.Add_Tick({
        try {
            $s = $sprite.States[$sprite.Current]
            if ($null -eq $s -or $s.Frames.Count -le 1) { return }
            $next = $sprite.Frame + 1
            if ($next -ge $s.Frames.Count) {
                if (-not $s.Loop) { $sprite.Timer.Stop(); return }
                $next = 0
            }
            $sprite.Frame = $next
            $sprite.Image.Source = $s.Frames[$next]
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
        if ($s.Frames.Count -gt 1 -and $s.FrameMs -gt 0) {
            $this.Timer.Interval = [TimeSpan]::FromMilliseconds($s.FrameMs)
            $this.Timer.Start()
        }
    }

    Add-Member -InputObject $sprite -MemberType ScriptMethod -Name Stop -Value {
        try { $this.Timer.Stop() } catch { }
    }

    return $sprite
}
