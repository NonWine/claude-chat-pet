# Claude quick-prompt widget.
#
#   hover sprite -> auto-expand          Esc          -> collapse back to the sprite
#   Enter        -> run headless, live status above the input
#   Ctrl+Enter   -> open a new chat in the desktop app with the prompt pasted in
#   Ctrl+Wheel   -> scale the whole widget (also Ctrl +/-/0), saved to config.json
#   dbl-click >  -> empty new chat        click status -> open that session in a window
#   right-click  -> close
#
# While collapsed the sprite itself is the status light: grey idle, blue running,
# amber needs-approval, green done, red error.
#
# NOTE: this file must stay pure ASCII. Windows PowerShell 5.1 reads a BOM-less
# script as ANSI, so any non-ASCII literal would be mangled. Glyphs come from
# XAML entities or [char] codes below.

$ErrorActionPreference = "Stop"
$errorLog = "$PSScriptRoot\error.log"

try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

    $SYM_RUN  = [char]0x25CF  # filled circle
    $SYM_OK   = [char]0x2713  # check
    $SYM_ERR  = [char]0x2715  # cross
    $SYM_WARN = [char]0x25B2  # triangle
    $SYM_SEP  = [char]0x00B7  # middle dot

    # ---------------------------------------------------------------- config
    $configPath = "$PSScriptRoot\config.json"
    $cfg = @{
        scale           = 1.0    # 0.6 .. 2.5
        startCollapsed  = $true
        collapseDelayMs = 700
        focusOnHover    = $false # true = hovering also grabs the keyboard (steals focus)
        panelWidth      = 330
    }
    if (Test-Path $configPath) {
        try {
            $raw = Get-Content $configPath -Raw -ErrorAction Stop | ConvertFrom-Json
            foreach ($k in @($cfg.Keys)) {
                if ($null -ne $raw.$k) { $cfg[$k] = $raw.$k }
            }
        } catch { }
    }
    function Save-Config {
        try { (New-Object psobject -Property $cfg) | ConvertTo-Json | Set-Content -Path $configPath -Encoding UTF8 } catch { }
    }

    $MIN_SCALE = 0.6
    $MAX_SCALE = 2.5
    $panelW = [int]$cfg.panelWidth

    $margin = 24
    $screen = [System.Windows.SystemParameters]::WorkArea
    $rightAnchor  = $screen.Right - $margin
    $bottomAnchor = $screen.Bottom - $margin

    [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ClaudeQuickPrompt" SizeToContent="WidthAndHeight"
        Left="0" Top="0"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize">
  <Grid x:Name="Root">
   <StackPanel>

    <!-- The pet is always on screen; only the panel below it folds away. The status
         colour lives in the glow under its feet, so the character itself stays readable. -->
    <Grid x:Name="PetHost" Width="56" Height="58" HorizontalAlignment="Center"
          Background="Transparent" Cursor="Hand"
          ToolTip="Hover to open. Ctrl+Wheel to resize. Right-click to close.">
      <Ellipse x:Name="PetGlow" Width="30" Height="9" Fill="#FF6B6B6B" Opacity="0.7"
               VerticalAlignment="Bottom" Margin="0,0,0,2">
        <Ellipse.Effect>
          <BlurEffect Radius="7"/>
        </Ellipse.Effect>
      </Ellipse>
      <Image x:Name="PetImage" Width="44" Height="44"
             VerticalAlignment="Bottom" Margin="0,0,0,4"
             RenderOptions.BitmapScalingMode="NearestNeighbor"
             RenderTransformOrigin="0.5,1.0"/>
    </Grid>

    <!-- expanded state -->
    <Border x:Name="Panel" Visibility="Collapsed" Width="$panelW" CornerRadius="22" Margin="0,4,0,0"
            Background="#EE1E1E1E" BorderBrush="#33FFFFFF" BorderThickness="1">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="48"/>
        </Grid.RowDefinitions>

        <Border x:Name="StatusBar" Grid.Row="0" Visibility="Collapsed"
                Margin="14,10,10,0" Padding="2,0,2,0" Background="Transparent" Cursor="Hand"
                ToolTip="Click to open this session in a real Claude window.">
          <StackPanel Orientation="Horizontal">
            <TextBlock x:Name="StatusDot" Text="" Foreground="#FF6EA8FE" FontSize="11" VerticalAlignment="Center" Margin="0,0,6,0"/>
            <TextBlock x:Name="StatusText" Text="" Foreground="#CCFFFFFF" FontSize="11" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" MaxWidth="280"/>
          </StackPanel>
        </Border>

        <Grid Grid.Row="1" Margin="16,0,8,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="34"/>
          </Grid.ColumnDefinitions>
          <Grid Grid.Column="0">
            <TextBlock x:Name="Placeholder" Text="Send prompt (no window)..." Foreground="#88FFFFFF" VerticalAlignment="Center" IsHitTestVisible="False" FontSize="13"/>
            <TextBox x:Name="PromptBox" Background="Transparent" Foreground="White" CaretBrush="White" BorderThickness="0" VerticalAlignment="Center" FontSize="14"
                     ToolTip="Enter: run headless, no window - progress shown above.&#10;Ctrl+Enter: open a new chat in the app with this prompt.&#10;Ctrl+Wheel / Ctrl +-0: resize.&#10;Esc: collapse."/>
          </Grid>
          <Button x:Name="SendButton" Grid.Column="1" Width="30" Height="30" Cursor="Hand" VerticalAlignment="Center" Background="Transparent" BorderThickness="0"
                  ToolTip="Click: run headless.&#10;Double-click: open an empty new chat.">
            <Button.Template>
              <ControlTemplate TargetType="Button">
                <Grid>
                  <Ellipse Fill="#FF6B6B6B"/>
                  <TextBlock Text="&#10148;" Foreground="White" FontSize="13" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Grid>
              </ControlTemplate>
            </Button.Template>
          </Button>
        </Grid>
      </Grid>
    </Border>

   </StackPanel>
  </Grid>
</Window>
"@

    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [Windows.Markup.XamlReader]::Load($reader)
    $root        = $window.FindName("Root")
    $petHost     = $window.FindName("PetHost")
    $petImage    = $window.FindName("PetImage")
    $petGlow     = $window.FindName("PetGlow")
    $panel       = $window.FindName("Panel")
    $promptBox   = $window.FindName("PromptBox")
    $placeholder = $window.FindName("Placeholder")
    $sendButton  = $window.FindName("SendButton")
    $statusBar   = $window.FindName("StatusBar")
    $statusDot   = $window.FindName("StatusDot")
    $statusText  = $window.FindName("StatusText")

    $helper  = "$PSScriptRoot\send-to-app.ps1"
    $jobsDir = "$PSScriptRoot\jobs"
    if (-not (Test-Path $jobsDir)) { New-Item -ItemType Directory -Path $jobsDir | Out-Null }

    # `claude` is a .cmd shim, not a .exe. Start-Process -FilePath "claude" throws
    # "%1 is not a valid Win32 application", so it has to go through cmd.exe.
    $claudeCmd = Join-Path $env:APPDATA 'npm\claude.cmd'
    if (-not (Test-Path $claudeCmd)) {
        $c = Get-Command claude.cmd -ErrorAction SilentlyContinue
        if ($c) { $claudeCmd = $c.Source }
    }

    $script:jobs = New-Object System.Collections.ArrayList
    $script:collapsed = $true
    $script:toastText = ""
    $script:toastUntil = [DateTime]::MinValue

    $brushes = @{}
    $bc = New-Object System.Windows.Media.BrushConverter
    foreach ($kv in @{
        idle    = "#FF6B6B6B"
        run     = "#FF6EA8FE"
        approve = "#FFE0A33E"
        done    = "#FF57C08D"
        error   = "#FFE06C75"
        info    = "#FFAAAAAA"
    }.GetEnumerator()) { $brushes[$kv.Key] = $bc.ConvertFromString($kv.Value) }

    # -------------------------------------------------------------------- pet
    # The animated character. Shared with pet-visual.ps1 so there is one renderer,
    # and the art is swappable by replacing the PNGs under sprites\frames.
    . "$PSScriptRoot\pet-sprite.ps1"
    $pet = New-PetSprite -Image $petImage -FramesDir "$PSScriptRoot\sprites\frames"

    # status kind (what the job parser already produces) -> pet state.
    # An empty kind is normalised to 'idle' before the lookup, and 'info' is deliberately
    # absent so a scale toast does not disturb the character.
    $petStateFor = @{
        'idle'    = 'idle'
        'run'     = 'working'
        'approve' = 'blocking'
        'error'   = 'blocking'
        'done'    = 'done'
    }

    # Breathing, anchored at the feet, so an idle pet still looks alive.
    $petScale = New-Object System.Windows.Media.ScaleTransform(1, 1)
    $petImage.RenderTransform = $petScale
    function Start-PetBreathing {
        foreach ($p in @(
            @{ prop = [System.Windows.Media.ScaleTransform]::ScaleYProperty; to = 1.05 },
            @{ prop = [System.Windows.Media.ScaleTransform]::ScaleXProperty; to = 0.975 }
        )) {
            $a = New-Object System.Windows.Media.Animation.DoubleAnimation
            $a.From = 1.0
            $a.To = $p.to
            $a.Duration = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(1300))
            $a.AutoReverse = $true
            $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
            $ease = New-Object System.Windows.Media.Animation.CubicEase
            $ease.EasingMode = "EaseInOut"
            $a.EasingFunction = $ease
            $petScale.BeginAnimation($p.prop, $a)
        }
    }

    # ----------------------------------------------------------- scale / layout
    $rootScale = New-Object System.Windows.Media.ScaleTransform
    $root.LayoutTransform = $rootScale

    function Move-ToCorner {
        try {
            $window.Left = $rightAnchor - $window.ActualWidth
            $window.Top  = $bottomAnchor - $window.ActualHeight
        } catch { }
    }

    function Set-Scale([double]$s) {
        $s = [Math]::Round([Math]::Max($MIN_SCALE, [Math]::Min($MAX_SCALE, $s)), 2)
        $cfg.scale = $s
        $rootScale.ScaleX = $s
        $rootScale.ScaleY = $s
        Move-ToCorner
    }

    function Show-Toast([string]$text, [int]$ms) {
        $script:toastText = $text
        $script:toastUntil = (Get-Date).AddMilliseconds($ms)
    }

    # ----------------------------------------------------------------- status
    function Set-Status([string]$kind, [string]$text) {
        $key = $kind
        if ([string]::IsNullOrEmpty($key)) { $key = 'idle' }
        $petGlow.Fill = $brushes[$key]

        if ($petStateFor.ContainsKey($key)) { $pet.SetState($petStateFor[$key]) }

        if ([string]::IsNullOrEmpty($kind)) {
            $statusBar.Visibility = "Collapsed"
            return
        }
        $glyph = $SYM_RUN
        switch ($kind) {
            'approve' { $glyph = $SYM_WARN }
            'done'    { $glyph = $SYM_OK }
            'error'   { $glyph = $SYM_ERR }
            'info'    { $glyph = $SYM_SEP }
        }
        $statusDot.Text = [string]$glyph
        $statusDot.Foreground = $brushes[$key]
        $statusText.Text = $text
        $statusBar.Visibility = "Visible"
    }

    function Get-Short([string]$s, [int]$max) {
        if ([string]::IsNullOrEmpty($s)) { return "" }
        $s = ($s -replace '\s+', ' ').Trim()
        if ($s.Length -le $max) { return $s }
        return $s.Substring(0, $max - 1) + [string]([char]0x2026)
    }

    # --------------------------------------------------------- collapse / hover
    function Set-Collapsed([bool]$c) {
        $script:collapsed = $c
        # The pet never folds away now -- only the panel under it does.
        $panel.Visibility = if ($c) { "Collapsed" } else { "Visible" }
        Move-ToCorner
    }

    $collapseTimer = New-Object System.Windows.Threading.DispatcherTimer
    $collapseTimer.Interval = [TimeSpan]::FromMilliseconds([int]$cfg.collapseDelayMs)
    $collapseTimer.Add_Tick({
        try {
            $collapseTimer.Stop()
            if ($root.IsMouseOver) { return }
            # keep it open while there is an unsent draft or the caret is in the box
            if ($promptBox.Text.Length -gt 0) { return }
            if ($promptBox.IsKeyboardFocusWithin) { return }
            Set-Collapsed $true
        } catch { $_ | Out-String | Add-Content -Path $errorLog }
    })

    $root.Add_MouseEnter({
        try {
            $collapseTimer.Stop()
            if ($script:collapsed) {
                Set-Collapsed $false
                if ($cfg.focusOnHover) { $window.Activate() | Out-Null; $promptBox.Focus() | Out-Null }
            }
        } catch { $_ | Out-String | Add-Content -Path $errorLog }
    })
    $root.Add_MouseLeave({
        try { $collapseTimer.Stop(); $collapseTimer.Start() } catch { }
    })

    # ------------------------------------------------------------- job parsing
    # Turn one stream-json event into the job's current state.
    function Update-JobFromEvent($job, $ev) {
        switch ($ev.type) {
            'system' {
                if ($ev.subtype -eq 'init') {
                    $job.SessionId = $ev.session_id
                    $job.Detail = "starting"
                }
                elseif ($ev.subtype -eq 'api_retry') {
                    # 401 is retried up to 10 times before the CLI gives up, so this is
                    # only a hint -- the run is not over yet. But surface it right away
                    # and stop later chatter from overwriting it.
                    if ($ev.error_status -eq 401) {
                        $job.State = 'error'
                        $job.Detail = "auth failing - run: claude auth login"
                        $job.Sticky = $true
                    }
                    else {
                        $job.Detail = "retrying (API " + $ev.error_status + ")"
                    }
                }
            }
            'assistant' {
                foreach ($c in $ev.message.content) {
                    if ($c.type -eq 'tool_use') {
                        $arg = ""
                        if ($c.input.command) { $arg = ": " + (Get-Short $c.input.command 26) }
                        elseif ($c.input.file_path) { $arg = ": " + (Split-Path $c.input.file_path -Leaf) }
                        elseif ($c.input.pattern) { $arg = ": " + (Get-Short $c.input.pattern 26) }
                        $job.State = 'run'
                        $job.Detail = $c.name + $arg
                    }
                    elseif ($c.type -eq 'text' -and -not [string]::IsNullOrWhiteSpace($c.text)) {
                        # When the run already failed, the CLI still emits the error as
                        # assistant text -- do not let it overwrite the real reason.
                        if (-not $job.Sticky) {
                            $job.State = 'run'
                            $job.Detail = "writing answer"
                        }
                    }
                    elseif ($c.type -eq 'thinking') {
                        if (-not $job.Sticky) {
                            $job.State = 'run'
                            $job.Detail = "thinking"
                        }
                    }
                }
            }
            'user' {
                foreach ($c in $ev.message.content) {
                    if ($c.type -eq 'tool_result' -and $c.is_error) {
                        $t = ($c.content | Out-String)
                        if ($t -match 'permission|not been granted|requested permissions|denied|approve') {
                            $job.State = 'approve'
                            $job.Detail = "needs approval - click to open"
                        }
                    }
                }
            }
            'result' {
                $job.Done = $true
                $job.Ended = Get-Date
                # NOTE: subtype stays "success" even for a failed run -- is_error is the
                # field that actually decides.
                if ($ev.is_error -or $ev.subtype -ne 'success') {
                    $job.State = 'error'
                    $msg = [string]$ev.result
                    if ($msg -match '401|OAuth|authenticate') {
                        $job.Detail = "CLI not logged in - run: claude auth login"
                    }
                    else {
                        $job.Detail = Get-Short $msg 60
                    }
                }
                else {
                    $job.State = 'done'
                    $d = "done"
                    if ($ev.duration_ms) { $d += " " + $SYM_SEP + " " + ("{0:n1}s" -f ($ev.duration_ms / 1000.0)) }
                    if ($ev.total_cost_usd) { $d += " " + $SYM_SEP + " $" + ("{0:n3}" -f $ev.total_cost_usd) }
                    $job.Detail = $d
                }
            }
        }
    }

    # Read whatever new complete lines the CLI has flushed since the last tick.
    function Read-JobStream($job) {
        if (-not (Test-Path $job.OutFile)) { return }
        $chunk = $null
        $fs = $null
        try {
            $fs = [IO.File]::Open($job.OutFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            if ($fs.Length -le $job.Pos) { return }
            $fs.Seek($job.Pos, [IO.SeekOrigin]::Begin) | Out-Null
            $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
            $chunk = $sr.ReadToEnd()
            $sr.Dispose()
            $fs = $null
        }
        catch { return }
        finally { if ($fs) { $fs.Dispose() } }

        if (-not $chunk) { return }
        $cut = $chunk.LastIndexOf("`n")
        if ($cut -lt 0) { return }
        $complete = $chunk.Substring(0, $cut + 1)
        $job.Pos += [Text.Encoding]::UTF8.GetByteCount($complete)

        foreach ($line in ($complete -split "`r?`n")) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $ev = $null
            try { $ev = $line | ConvertFrom-Json } catch { continue }
            try { Update-JobFromEvent $job $ev } catch { }
        }
    }

    # Decide what the single status line should show right now.
    function Update-StatusLine {
        if ((Get-Date) -lt $script:toastUntil) {
            Set-Status 'info' $script:toastText
            return
        }
        $active = @($script:jobs | Where-Object { -not $_.Done })
        if ($active.Count -gt 0) {
            $j = $active[$active.Count - 1]
            $el = [int]((Get-Date) - $j.Started).TotalSeconds
            $t = $j.Detail + " " + $SYM_SEP + " " + $el + "s"
            if ($active.Count -gt 1) { $t = "[" + $active.Count + "] " + $t }
            $kind = 'run'
            if ($j.State -eq 'approve' -or $j.State -eq 'error') { $kind = $j.State }
            Set-Status $kind $t
            return
        }
        $finished = @($script:jobs | Where-Object { $_.Done })
        if ($finished.Count -gt 0) {
            $j = $finished[$finished.Count - 1]
            # A clean result fades out; an error or a pending approval stays put until
            # the next prompt, because it is something the user has to act on.
            if ($j.State -eq 'done' -and $j.Ended -and ((Get-Date) - $j.Ended).TotalSeconds -gt 25) {
                Set-Status "" ""
            }
            else {
                Set-Status $j.State $j.Detail
            }
            return
        }
        Set-Status "" ""
    }

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(400)
    $timer.Add_Tick({
        try {
            foreach ($job in @($script:jobs)) {
                if ($job.Done) { continue }
                Read-JobStream $job
                if ($job.Proc -and $job.Proc.HasExited) {
                    Read-JobStream $job
                    if (-not $job.Done) {
                        $job.Done = $true
                        $job.Ended = Get-Date
                        if ($job.State -ne 'error') {
                            $job.State = 'error'
                            $err = ""
                            if (Test-Path $job.ErrFile) { $err = (Get-Content $job.ErrFile -Raw -ErrorAction SilentlyContinue) }
                            if ([string]::IsNullOrWhiteSpace($err)) { $err = "exited with code " + $job.Proc.ExitCode }
                            $job.Detail = Get-Short $err 60
                        }
                    }
                }
            }
            Update-StatusLine
        }
        catch { $_ | Out-String | Add-Content -Path $errorLog }
    })
    $timer.Start()

    $promptBox.Add_TextChanged({
        $placeholder.Visibility = if ($promptBox.Text.Length -gt 0) { "Collapsed" } else { "Visible" }
    })

    # ---------------------------------------------------------------- sending
    # The prompt reaches the child through a temp file, never the command line:
    # no quoting, newline or non-ASCII problems.
    function Write-PromptFile([string]$text) {
        $tmp = [IO.Path]::Combine($env:TEMP, "claude-prompt-" + [Guid]::NewGuid().ToString('N') + ".txt")
        [IO.File]::WriteAllText($tmp, $text, (New-Object Text.UTF8Encoding($false)))
        return $tmp
    }

    function Start-CollapseIfAway {
        if (-not $root.IsMouseOver) { $collapseTimer.Stop(); $collapseTimer.Start() }
    }

    $sendHeadless = {
        try {
            $text = $promptBox.Text.Trim()
            if ($text.Length -eq 0) { return }
            if (-not (Test-Path $claudeCmd)) { Set-Status 'error' "claude.cmd not found"; return }

            $id  = Get-Date -Format "yyyyMMdd-HHmmss-fff"
            $tmp = Write-PromptFile $text
            $out = Join-Path $jobsDir "$id.jsonl"
            $err = Join-Path $jobsDir "$id.err.txt"
            Set-Content -Path (Join-Path $jobsDir "$id.prompt.txt") -Value $text -Encoding UTF8

            $proc = Start-Process -FilePath $env:ComSpec `
                -ArgumentList @('/c', "`"$claudeCmd`"", '-p', '--output-format', 'stream-json', '--verbose') `
                -WorkingDirectory $env:USERPROFILE -WindowStyle Hidden -PassThru `
                -RedirectStandardInput $tmp -RedirectStandardOutput $out -RedirectStandardError $err

            $job = @{
                Id = $id; Proc = $proc; OutFile = $out; ErrFile = $err; Pos = 0
                State = 'run'; Detail = 'queued'; Started = Get-Date; Ended = $null
                Done = $false; Sticky = $false; SessionId = $null
            }
            [void]$script:jobs.Add($job)
            while ($script:jobs.Count -gt 10) { $script:jobs.RemoveAt(0) }

            $promptBox.Text = ""
            Update-StatusLine
            Start-CollapseIfAway
        }
        catch {
            $_ | Out-String | Add-Content -Path $errorLog
            Set-Status 'error' "launch failed - see error.log"
        }
    }

    # Ctrl+Enter: fall back to opening a real chat window with the prompt pasted in.
    $sendToApp = {
        try {
            $text = $promptBox.Text.Trim()
            if ($text.Length -eq 0) { Start-Process "claude://code/new"; return }
            $tmp = Write-PromptFile $text
            Start-Process -FilePath "powershell.exe" `
                -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
                                '-WindowStyle', 'Hidden', '-File', "`"$helper`"",
                                '-TextFile', "`"$tmp`"") `
                -WindowStyle Hidden
            $promptBox.Text = ""
            Set-Status 'run' "opening a chat window"
            Start-CollapseIfAway
        }
        catch {
            $_ | Out-String | Add-Content -Path $errorLog
            Set-Status 'error' "open failed - see error.log"
        }
    }

    # ------------------------------------------------------------------ input
    # Clicking the status line opens that session in a real window (to approve, or to read it).
    $statusBar.Add_MouseLeftButtonUp({
        try { Start-Process "claude://code/continue?session=last" }
        catch { $_ | Out-String | Add-Content -Path $errorLog }
    })

    $sendButton.Add_PreviewMouseLeftButtonDown({
        param($s, $e)
        try {
            if ($e.ClickCount -eq 2) {
                $e.Handled = $true
                Start-Process "claude://code/new"
            }
        } catch { $_ | Out-String | Add-Content -Path $errorLog }
    })

    # Clicking the widget is the deliberate way to get the caret -- hovering alone
    # does not steal focus from whatever the user is typing in elsewhere.
    $panel.Add_PreviewMouseLeftButtonDown({
        try { $window.Activate() | Out-Null; $promptBox.Focus() | Out-Null } catch { }
    })
    $petHost.Add_PreviewMouseLeftButtonDown({
        try {
            Set-Collapsed $false
            $window.Activate() | Out-Null
            $promptBox.Focus() | Out-Null
        } catch { }
    })

    $window.Add_PreviewMouseWheel({
        param($s, $e)
        try {
            $ctrl = [System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control
            if (-not $ctrl) { return }
            $e.Handled = $true
            $step = 0.05
            if ($e.Delta -lt 0) { $step = -0.05 }
            Set-Scale ([double]$cfg.scale + $step)
            Save-Config
            Show-Toast ("scale " + ("{0:n2}" -f [double]$cfg.scale)) 1500
            Update-StatusLine
        } catch { $_ | Out-String | Add-Content -Path $errorLog }
    })

    $window.Add_PreviewKeyDown({
        param($s, $e)
        try {
            $ctrl = [System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control
            if (-not $ctrl) { return }
            $delta = $null
            switch ($e.Key) {
                'OemPlus'  { $delta =  0.05 }
                'Add'      { $delta =  0.05 }
                'OemMinus' { $delta = -0.05 }
                'Subtract' { $delta = -0.05 }
                'D0'       { $delta = 0.0 }
                'NumPad0'  { $delta = 0.0 }
            }
            if ($null -eq $delta) { return }
            $e.Handled = $true
            if ($delta -eq 0.0) { Set-Scale 1.0 } else { Set-Scale ([double]$cfg.scale + $delta) }
            Save-Config
            Show-Toast ("scale " + ("{0:n2}" -f [double]$cfg.scale)) 1500
            Update-StatusLine
        } catch { $_ | Out-String | Add-Content -Path $errorLog }
    })

    $promptBox.Add_KeyDown({
        param($s, $e)
        try {
            if ($e.Key -eq "Return") {
                $e.Handled = $true
                $ctrl = [System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control
                if ($ctrl) { & $sendToApp } else { & $sendHeadless }
            }
            elseif ($e.Key -eq "Escape") {
                $e.Handled = $true
                $promptBox.Text = ""
                Set-Collapsed $true
            }
        } catch { $_ | Out-String | Add-Content -Path $errorLog }
    })

    $sendButton.Add_Click({ & $sendHeadless })

    $window.Add_MouseRightButtonUp({ $window.Close() })
    $window.Add_SizeChanged({ Move-ToCorner })
    $window.Add_ContentRendered({
        $pet.SetState('idle')
        Start-PetBreathing
        Set-Scale ([double]$cfg.scale)
        Set-Collapsed ([bool]$cfg.startCollapsed)
        if (-not $script:collapsed) { $promptBox.Focus() | Out-Null }
    })
    $window.Add_Closed({
        try { $timer.Stop(); $collapseTimer.Stop(); $pet.Stop() } catch { }
    })

    $window.ShowDialog() | Out-Null
}
catch {
    $_ | Out-String | Set-Content -Path $errorLog
}
