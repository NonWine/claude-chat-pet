# Claude quick-prompt widget.
#
#   hover pet    -> auto-expand           Esc          -> collapse back to the pet
#   Enter        -> run headless; the reply lands in a card above the pet
#   Ctrl+Enter   -> open a new chat in the desktop app with the prompt pasted in
#   Ctrl+Wheel   -> scale the whole widget (also Ctrl +/-/0), saved to config.json
#   drag the pet -> move the widget; the drop point is saved as the new anchor
#   right-click  -> size / reset / close menu
#   dbl-click >  -> empty new chat        click status -> open that session in a window
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
        anchorRight     = 0      # bottom-right corner the widget grows from; 0 = screen corner
        anchorBottom    = 0
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

    # The widget grows from a fixed bottom-right corner, so the input stays put while the
    # cards above it appear. Dragging moves that corner; it is not the window's top-left.
    $script:anchorRight  = $screen.Right - $margin
    $script:anchorBottom = $screen.Bottom - $margin
    if ([double]$cfg.anchorRight -gt 0 -and [double]$cfg.anchorBottom -gt 0) {
        $script:anchorRight  = [double]$cfg.anchorRight
        $script:anchorBottom = [double]$cfg.anchorBottom
    }

    [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ClaudeQuickPrompt" SizeToContent="WidthAndHeight"
        Left="0" Top="0"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize">
  <Grid x:Name="Root">
   <StackPanel>

    <!-- Where the answer shows up. A headless run has no chat window, so without this the
         reply would exist only inside jobs\<id>.jsonl. Deliberately OUTSIDE the collapsible
         panel: it has to survive the widget folding away, and only the X dismisses it. -->
    <Grid x:Name="AnswerCard" Visibility="Collapsed" Width="$panelW" Margin="0,0,0,8">
      <Border CornerRadius="18" Background="#F21E2024" BorderBrush="#26FFFFFF"
              BorderThickness="1" Padding="16,13,14,13">
        <StackPanel>
          <StackPanel Orientation="Horizontal" Margin="0,0,0,5">
            <TextBlock x:Name="AnswerGlyph" Text="" FontSize="12" Foreground="#FF57C08D"
                       VerticalAlignment="Center" Margin="0,0,7,0"/>
            <TextBlock x:Name="AnswerTitle" Text="" Foreground="#EDEFF2" FontSize="12.5"
                       FontWeight="SemiBold" TextTrimming="CharacterEllipsis" MaxWidth="250"/>
          </StackPanel>
          <ScrollViewer MaxHeight="190" VerticalScrollBarVisibility="Auto">
            <TextBlock x:Name="AnswerText" Text="" Foreground="#C5CAD3" FontSize="12.5"
                       TextWrapping="Wrap" LineHeight="17"/>
          </ScrollViewer>
          <Border x:Name="AnswerOpen" Margin="0,10,0,0" Padding="9,5" CornerRadius="9"
                  Background="#2A2D33" Cursor="Hand" HorizontalAlignment="Left"
                  ToolTip="Open this session in a real Claude window.">
            <TextBlock Text="Open in app" Foreground="#C9CED6" FontSize="11.5"/>
          </Border>
        </StackPanel>
      </Border>
      <Border x:Name="AnswerClose" Width="18" Height="18" CornerRadius="9" Background="#2A2D33"
              BorderBrush="#33FFFFFF" BorderThickness="1"
              HorizontalAlignment="Left" VerticalAlignment="Top" Margin="-6,-6,0,0"
              Cursor="Hand" ToolTip="Dismiss">
        <TextBlock Text="&#10005;" Foreground="#C9CED6" FontSize="8"
                   HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
    </Grid>

    <!-- The pet is always on screen; only the panel below it folds away. The status
         colour lives in the glow under its feet, so the character itself stays readable. -->
    <Grid x:Name="PetHost" Width="56" Height="58" HorizontalAlignment="Center"
          Background="Transparent" Cursor="Hand"
          ToolTip="Hover to open. Drag to move. Right-click for options.">
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

    <!-- right-click menu; an in-window panel rather than a Popup, so it inherits the
         window's transparency and cannot land behind a topmost window -->
    <Border x:Name="MenuCard" Visibility="Collapsed" Width="200" Margin="0,6,0,0"
            HorizontalAlignment="Center" CornerRadius="14" Background="#F51E2024"
            BorderBrush="#33FFFFFF" BorderThickness="1" Padding="12,10">
      <StackPanel>
        <TextBlock Text="SIZE" Foreground="#6E747E" FontSize="9" Margin="2,0,0,6"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
          <Border x:Name="MenuMinus" Width="28" Height="26" CornerRadius="8" Background="#2A2D33" Cursor="Hand">
            <TextBlock Text="&#8722;" Foreground="#C9CED6" FontSize="14"
                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <TextBlock x:Name="MenuScale" Text="100%" Foreground="#EDEFF2" FontSize="12" Width="56"
                     TextAlignment="Center" VerticalAlignment="Center"/>
          <Border x:Name="MenuPlus" Width="28" Height="26" CornerRadius="8" Background="#2A2D33" Cursor="Hand">
            <TextBlock Text="+" Foreground="#C9CED6" FontSize="14"
                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <Border x:Name="MenuReset" Width="28" Height="26" CornerRadius="8" Background="#2A2D33"
                  Cursor="Hand" Margin="8,0,0,0" ToolTip="Reset size and position">
            <TextBlock Text="&#8635;" Foreground="#C9CED6" FontSize="13"
                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
        </StackPanel>

        <Border Height="1" Background="#1AFFFFFF" Margin="0,10,0,8"/>

        <Border x:Name="MenuClose" Padding="8,6" CornerRadius="8" Background="Transparent" Cursor="Hand">
          <TextBlock Text="Close widget" Foreground="#E06C75" FontSize="12"/>
        </Border>
      </StackPanel>
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
    $answerCard  = $window.FindName("AnswerCard")
    $answerGlyph = $window.FindName("AnswerGlyph")
    $answerTitle = $window.FindName("AnswerTitle")
    $answerText  = $window.FindName("AnswerText")
    $answerOpen  = $window.FindName("AnswerOpen")
    $answerClose = $window.FindName("AnswerClose")
    $menuCard    = $window.FindName("MenuCard")
    $menuScale   = $window.FindName("MenuScale")
    $menuMinus   = $window.FindName("MenuMinus")
    $menuPlus    = $window.FindName("MenuPlus")
    $menuReset   = $window.FindName("MenuReset")
    $menuClose   = $window.FindName("MenuClose")
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

    # A saved anchor can point off-screen after a monitor change, which would hide the
    # widget with no way to get it back.
    function Reset-Anchors {
        $sc = [System.Windows.SystemParameters]::WorkArea
        $script:anchorRight  = [Math]::Max($sc.Left + 80, [Math]::Min($sc.Right,  $script:anchorRight))
        $script:anchorBottom = [Math]::Max($sc.Top  + 80, [Math]::Min($sc.Bottom, $script:anchorBottom))
    }
    Reset-Anchors

    function Move-ToCorner {
        try {
            $window.Left = $script:anchorRight - $window.ActualWidth
            $window.Top  = $script:anchorBottom - $window.ActualHeight
        } catch { }
    }

    # ------------------------------------------------------------- animation
    # Once a property has been animated the animation HOLDS its value and a plain
    # assignment is silently ignored, so anything set outside an animation clears it first.
    function New-PetEase([string]$mode) {
        $e = New-Object System.Windows.Media.Animation.CubicEase
        $e.EasingMode = $mode
        return $e
    }

    function Animate-Prop($target, $dp, [double]$to, [int]$ms, [string]$mode, $onDone) {
        $a = New-Object System.Windows.Media.Animation.DoubleAnimation
        $a.To = $to
        $a.Duration = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds($ms))
        $a.EasingFunction = (New-PetEase $mode)
        if ($onDone) { $a.Add_Completed($onDone) }
        $target.BeginAnimation($dp, $a)
    }

    function Set-Prop($target, $dp, [double]$v) {
        $target.BeginAnimation($dp, $null)
        $target.SetValue($dp, $v)
    }

    $OPACITY_DP = [System.Windows.UIElement]::OpacityProperty
    $SCALEY_DP  = [System.Windows.Media.ScaleTransform]::ScaleYProperty

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
    # The pet never folds away now -- only the panel under it does.
    #
    # Unfolding is a LayoutTransform, not a RenderTransform: a layout transform changes the
    # measured size, so SizeToContent + Move-ToCorner make the window grow with it and the
    # input edge stays pinned. A render transform would resize the window instantly and only
    # paint the panel smaller, which reads as a jump.
    $panelScale = New-Object System.Windows.Media.ScaleTransform(1, 1)
    $panel.LayoutTransform = $panelScale

    # Hiding happens on a plain timer rather than the animation's Completed callback.
    # Inside a .GetNewClosure() scriptblock, $script:xxx resolves against the closure's own
    # module scope, where the variable does not exist -- it reads as $null, so a guard
    # written there never fires and the panel would stay Visible at zero height forever,
    # still able to hold the keyboard focus. A normal Add_Tick body has no such problem.
    $script:panelHideTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:panelHideTimer.Interval = [TimeSpan]::FromMilliseconds(180)
    $script:panelHideTimer.Add_Tick({
        try {
            $script:panelHideTimer.Stop()
            if ($script:collapsed) {
                $panel.Visibility = "Collapsed"
                Move-ToCorner
            }
        } catch { $_ | Out-String | Add-Content -Path $errorLog }
    })

    function Set-Collapsed([bool]$c) {
        $script:collapsed = $c
        $script:panelHideTimer.Stop()

        if (-not $c) {
            if ($panel.Visibility -ne "Visible") {
                Set-Prop $panelScale $SCALEY_DP 0
                Set-Prop $panel $OPACITY_DP 0
                $panel.Visibility = "Visible"
            }
            Animate-Prop $panelScale $SCALEY_DP 1 190 "EaseOut" $null
            Animate-Prop $panel $OPACITY_DP 1 170 "EaseOut" $null
            return
        }

        if ($panel.Visibility -ne "Visible") { Move-ToCorner; return }

        # Keystrokes must never land in a panel the user cannot see.
        if ($promptBox.IsKeyboardFocusWithin) { [System.Windows.Input.Keyboard]::ClearFocus() }

        Animate-Prop $panelScale $SCALEY_DP 0 150 "EaseIn" $null
        Animate-Prop $panel $OPACITY_DP 0 130 "EaseIn" $null
        $script:panelHideTimer.Start()
    }

    # --------------------------------------------------------------- answer card
    $script:answerSession = $null

    function Show-Answer($job) {
        $ok = ($job.State -eq 'done')
        $answerGlyph.Text = if ($ok) { [string]$SYM_OK } else { [string]$SYM_ERR }
        $answerGlyph.Foreground = $brushes[$(if ($ok) { 'done' } else { 'error' })]
        $answerTitle.Text = Get-Short ([string]$job.Prompt) 48

        $body = [string]$job.Answer
        if ([string]::IsNullOrWhiteSpace($body)) { $body = [string]$job.Detail }
        $answerText.Text = $body.Trim()

        $script:answerSession = $job.SessionId
        $answerOpen.Visibility = if ($job.SessionId) { "Visible" } else { "Collapsed" }
        $answerCard.Visibility = "Visible"
        Move-ToCorner

        if ($ok -and -not [string]::IsNullOrWhiteSpace($body)) {
            try {
                [IO.File]::WriteAllText("$PSScriptRoot\last-response.txt", $body,
                                        (New-Object Text.UTF8Encoding($false)))
            } catch { }
        }
    }

    function Hide-Answer {
        $answerCard.Visibility = "Collapsed"
        Move-ToCorner
    }

    # ---------------------------------------------------------------- menu
    function Set-Menu([bool]$show) {
        if ($show) { $menuScale.Text = ("{0:n0}%" -f ([double]$cfg.scale * 100)) }
        $menuCard.Visibility = if ($show) { "Visible" } else { "Collapsed" }
        Move-ToCorner
    }

    function Step-Scale([double]$delta) {
        Set-Scale ([double]$cfg.scale + $delta)
        Save-Config
        $menuScale.Text = ("{0:n0}%" -f ([double]$cfg.scale * 100))
    }

    $collapseTimer = New-Object System.Windows.Threading.DispatcherTimer
    $collapseTimer.Interval = [TimeSpan]::FromMilliseconds([int]$cfg.collapseDelayMs)
    $collapseTimer.Add_Tick({
        try {
            $collapseTimer.Stop()
            if ($root.IsMouseOver) { return }
            if ($menuCard.Visibility -eq "Visible") { return }
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
                # The full reply only exists here -- a headless run has no window to read it
                # in, so keep it for the answer card.
                $job.Answer = [string]$ev.result
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
            foreach ($job in @($script:jobs)) {
                if ($job.Done -and -not $job.Shown) {
                    $job.Shown = $true
                    Show-Answer $job
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
                Prompt = $text; Answer = ""; Shown = $false
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
    # Drag the pet to move the widget. The press is "armed" rather than acted on, because
    # the same button also means "give me the caret": only movement past a few pixels turns
    # it into a drag, everything else stays a click.
    $script:dragArmed = $false
    $script:dragFrom  = New-Object System.Windows.Point(0, 0)

    $petHost.Add_PreviewMouseLeftButtonDown({
        param($s, $e)
        try {
            $script:dragArmed = $true
            $script:dragFrom  = $e.GetPosition($window)
        } catch { $_ | Out-String | Add-Content -Path $errorLog }
    })

    $petHost.Add_PreviewMouseMove({
        param($s, $e)
        try {
            if (-not $script:dragArmed) { return }
            if ($e.LeftButton -ne [System.Windows.Input.MouseButtonState]::Pressed) {
                $script:dragArmed = $false
                return
            }
            $p = $e.GetPosition($window)
            if ([Math]::Abs($p.X - $script:dragFrom.X) -lt 4 -and
                [Math]::Abs($p.Y - $script:dragFrom.Y) -lt 4) { return }

            $script:dragArmed = $false
            $collapseTimer.Stop()
            $window.DragMove()   # blocks until the button is released

            # Re-anchor to wherever it was dropped, by the bottom-right corner, so the
            # cards keep growing upward from the same edge.
            $script:anchorRight  = $window.Left + $window.ActualWidth
            $script:anchorBottom = $window.Top + $window.ActualHeight
            Reset-Anchors
            $cfg.anchorRight  = $script:anchorRight
            $cfg.anchorBottom = $script:anchorBottom
            Save-Config
            Move-ToCorner
        } catch { $script:dragArmed = $false; $_ | Out-String | Add-Content -Path $errorLog }
    })

    $petHost.Add_PreviewMouseLeftButtonUp({
        try {
            if ($script:dragArmed) {
                $script:dragArmed = $false
                Set-Collapsed $false
                $window.Activate() | Out-Null
                $promptBox.Focus() | Out-Null
            }
        } catch { $_ | Out-String | Add-Content -Path $errorLog }
    })

    # ------------------------------------------------------------ card + menu wiring
    $answerClose.Add_MouseLeftButtonUp({
        try { Hide-Answer } catch { $_ | Out-String | Add-Content -Path $errorLog }
    })
    $answerOpen.Add_MouseLeftButtonUp({
        try {
            # The real session id from system/init. "session=last" would be a guess, and the
            # CLI's session is not the desktop app's most recent one.
            if ($script:answerSession) {
                Start-Process ("claude://code/continue?session=" + $script:answerSession)
            }
        } catch { $_ | Out-String | Add-Content -Path $errorLog }
    })

    $menuMinus.Add_MouseLeftButtonUp({ try { Step-Scale -0.05 } catch { } })
    $menuPlus.Add_MouseLeftButtonUp({  try { Step-Scale  0.05 } catch { } })
    $menuReset.Add_MouseLeftButtonUp({
        try {
            $sc = [System.Windows.SystemParameters]::WorkArea
            $script:anchorRight  = $sc.Right - $margin
            $script:anchorBottom = $sc.Bottom - $margin
            $cfg.anchorRight  = 0
            $cfg.anchorBottom = 0
            Set-Scale 1.0
            Save-Config
            $menuScale.Text = "100%"
        } catch { $_ | Out-String | Add-Content -Path $errorLog }
    })
    $menuClose.Add_MouseLeftButtonUp({ try { $window.Close() } catch { } })

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
            # Escape backs out of the menu first, wherever the focus happens to be.
            if ($e.Key -eq "Escape" -and $menuCard.Visibility -eq "Visible") {
                $e.Handled = $true
                Set-Menu $false
                return
            }
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

    # Right-click used to close outright, which made an accidental click destructive.
    $window.Add_MouseRightButtonUp({
        param($s, $e)
        try {
            $e.Handled = $true
            Set-Menu ($menuCard.Visibility -ne "Visible")
        } catch { $_ | Out-String | Add-Content -Path $errorLog }
    })
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
