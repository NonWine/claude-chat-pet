# Pet visual layer: the floating mascot plus the progressive-disclosure shell around it.
#
#   Idle      only the mascot, breathing
#   Hover     a pill with pencil / voice / chevron slides in under the mascot
#   Compose   the pill morphs into a "Start new chat" input
#   Running   the input collapses into a card: task title + a status line that crossfades
#   Result    the card grows a check mark, a rewritten title and a reply button
#   close     back to Idle
#
# This file owns NO job logic. It exposes Set-PetState / Set-PetCard / Set-PetStatus and is
# driven from outside, so pet-icon.ps1 can adopt it without either side knowing the other's guts.
# Run it directly to click through the flow by hand; -Demo scripts the whole sequence.
#
# NOTE: this file must stay pure ASCII. Windows PowerShell 5.1 reads a BOM-less script as ANSI,
# so glyphs come from XAML entities or [char] codes, never from literals.

param(
    [switch]$Demo,
    [string]$ShotDir
)

$ErrorActionPreference = "Stop"
$errorLog = "$PSScriptRoot\error.log"

try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

    $framesDir = Join-Path $PSScriptRoot "sprites\frames"
    if (-not (Test-Path (Join-Path $framesDir "manifest.json"))) {
        throw "sprite frames not found - run sprites\build-placeholder-frames.ps1 first"
    }

    # ------------------------------------------------------------------ layout

    $PET_PX  = 64      # 16px art at an integer 4x, so nearest-neighbour stays crisp
    $HIT_PX  = 88      # slightly larger transparent hover target around the mascot
    $BAR_H   = 44
    $PILL_W  = 132
    $INPUT_W = 330
    $CARD_W  = 330
    $margin  = 24

    $screen = [System.Windows.SystemParameters]::WorkArea

    # ------------------------------------------------------------------ xaml
    # Background="{x:Null}" (not Transparent) everywhere there is no real surface: a null brush
    # is not hit-testable, so clicks fall through to whatever is under the corner of the screen.
    # x: prefix MUST be declared or XamlReader dies with "'x' is an undeclared prefix".

    $xamlText = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ClaudePetVisual" SizeToContent="WidthAndHeight"
        WindowStyle="None" AllowsTransparency="True" Background="{x:Null}"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        TextOptions.TextFormattingMode="Display">
  <Grid x:Name="Root" Background="{x:Null}">
    <StackPanel x:Name="Stack" Background="{x:Null}" Width="$CARD_W">

      <!-- ============================ card ============================ -->
      <Grid x:Name="CardWrap" Visibility="Collapsed" Margin="0,0,0,12">
        <Border x:Name="Card" CornerRadius="18" Background="#F21E2024"
                BorderBrush="#26FFFFFF" BorderThickness="1" Padding="16,13,14,13">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>

            <!-- status glyph: spins into a check when the task resolves -->
            <TextBlock x:Name="CardGlyph" Grid.Column="0" Visibility="Collapsed"
                       Text="" FontSize="13" Foreground="#3FB950"
                       VerticalAlignment="Top" Margin="0,1,8,0"/>

            <StackPanel Grid.Column="1">
              <TextBlock x:Name="CardTitle" Text="" Foreground="#EDEFF2" FontSize="13"
                         FontWeight="SemiBold" TextWrapping="Wrap"/>
              <TextBlock x:Name="CardStatus" Text="" Foreground="#9AA0AA" FontSize="12"
                         TextWrapping="Wrap" Margin="0,2,0,0"/>
            </StackPanel>

            <Border x:Name="CardReply" Grid.Column="2" Visibility="Collapsed"
                    Width="28" Height="28" CornerRadius="14" Background="#2A2D33"
                    Cursor="Hand" VerticalAlignment="Center" Margin="10,0,0,0"
                    ToolTip="Reply">
              <TextBlock Text="&#8629;" Foreground="#C9CED6" FontSize="13"
                         HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
          </Grid>
        </Border>

        <!-- close sits on the card's top-left corner, like the reference -->
        <Border x:Name="CardClose" Visibility="Collapsed"
                Width="18" Height="18" CornerRadius="9" Background="#2A2D33"
                BorderBrush="#33FFFFFF" BorderThickness="1"
                HorizontalAlignment="Left" VerticalAlignment="Top"
                Margin="-6,-6,0,0" Cursor="Hand" ToolTip="Close">
          <TextBlock Text="&#10005;" Foreground="#C9CED6" FontSize="8"
                     HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
      </Grid>

      <!-- ============================ mascot ============================ -->
      <Border x:Name="PetHit" Background="Transparent" Cursor="Hand"
              Width="$HIT_PX" Height="$HIT_PX" HorizontalAlignment="Center">
        <Image x:Name="Pet" Width="$PET_PX" Height="$PET_PX"
               RenderOptions.BitmapScalingMode="NearestNeighbor"
               RenderTransformOrigin="0.5,1.0"/>
      </Border>

      <!-- ====================== pill / input bar ====================== -->
      <Border x:Name="Bar" Visibility="Collapsed" Height="$BAR_H" Width="$PILL_W"
              CornerRadius="22" Background="#F21E2024" BorderBrush="#26FFFFFF"
              BorderThickness="1" HorizontalAlignment="Center" Margin="0,6,0,0">
        <Grid>

          <StackPanel x:Name="PillIcons" Orientation="Horizontal"
                      HorizontalAlignment="Center" VerticalAlignment="Center">
            <Border x:Name="PillEdit" Width="32" Height="32" CornerRadius="16"
                    Background="#2A2D33" Margin="4,0" Cursor="Hand" ToolTip="New prompt">
              <TextBlock Text="&#9998;" Foreground="#C9CED6" FontSize="14"
                         HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <Border x:Name="PillVoice" Width="32" Height="32" CornerRadius="16"
                    Background="#2A2D33" Margin="4,0" Cursor="Hand" ToolTip="Voice">
              <!-- drawn, not a glyph: half-block characters fall back badly in UI fonts -->
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center">
                <Rectangle Width="2" Height="6"  RadiusX="1" RadiusY="1" Fill="#C9CED6" Margin="1,0"/>
                <Rectangle Width="2" Height="12" RadiusX="1" RadiusY="1" Fill="#C9CED6" Margin="1,0"/>
                <Rectangle Width="2" Height="8"  RadiusX="1" RadiusY="1" Fill="#C9CED6" Margin="1,0"/>
                <Rectangle Width="2" Height="4"  RadiusX="1" RadiusY="1" Fill="#C9CED6" Margin="1,0"/>
              </StackPanel>
            </Border>
            <Border x:Name="PillMore" Width="32" Height="32" CornerRadius="16"
                    Background="#2A2D33" Margin="4,0" Cursor="Hand" ToolTip="More">
              <TextBlock Text="&#94;" Foreground="#C9CED6" FontSize="12"
                         HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
          </StackPanel>

          <Grid x:Name="InputArea" Visibility="Collapsed" Opacity="0" Margin="6,0,6,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>

            <Border Grid.Column="0" Width="26" Height="26" CornerRadius="13"
                    Background="#2A2D33" Cursor="Hand" ToolTip="Attach">
              <TextBlock Text="+" Foreground="#C9CED6" FontSize="14"
                         HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>

            <Grid Grid.Column="1" Margin="10,0,8,0">
              <TextBlock x:Name="Placeholder" Text="Start new chat" Foreground="#6E747E"
                         FontSize="13" VerticalAlignment="Center" IsHitTestVisible="False"/>
              <TextBox x:Name="PromptBox" Background="Transparent" Foreground="#EDEFF2"
                       CaretBrush="#EDEFF2" BorderThickness="0" FontSize="13"
                       VerticalAlignment="Center"/>
            </Grid>

            <Border x:Name="SendButton" Grid.Column="2" Width="26" Height="26"
                    CornerRadius="13" Background="#4C8DF6" Cursor="Hand" ToolTip="Send">
              <TextBlock Text="&#8593;" Foreground="White" FontSize="13"
                         HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
          </Grid>

        </Grid>
      </Border>

    </StackPanel>
  </Grid>
</Window>
"@

    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xamlText)
    $window = [Windows.Markup.XamlReader]::Load($reader)

    $ui = @{}
    foreach ($n in @('Root','Stack','CardWrap','Card','CardGlyph','CardTitle','CardStatus',
                     'CardReply','CardClose','PetHit','Pet','Bar','PillIcons','PillEdit',
                     'PillVoice','PillMore','InputArea','Placeholder','PromptBox','SendButton')) {
        $ui[$n] = $window.FindName($n)
    }

    # ------------------------------------------------------------------ sprite renderer
    # Contract with the art: sprites\frames\<state>\NN.png + manifest.json. Nothing else.
    # Swapping the character = dropping different PNGs in, no code change here.

    . "$PSScriptRoot\pet-sprite.ps1"
    $script:pet = New-PetSprite -Image $ui.Pet -FramesDir $framesDir

    function Set-PetState([string]$name) { $script:pet.SetState($name) }

    # ------------------------------------------------------------------ animation helpers

    function New-Ease([string]$mode = "EaseOut") {
        $e = New-Object System.Windows.Media.Animation.CubicEase
        $e.EasingMode = $mode
        return $e
    }

    function Animate-Double($target, $dp, [double]$to, [int]$ms, $ease) {
        $a = New-Object System.Windows.Media.Animation.DoubleAnimation
        $a.To = $to
        $a.Duration = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds($ms))
        if ($ease) { $a.EasingFunction = $ease }
        $target.BeginAnimation($dp, $a)
    }

    function Fade($element, [double]$to, [int]$ms = 160) {
        Animate-Double $element ([System.Windows.UIElement]::OpacityProperty) $to $ms (New-Ease)
    }

    function Animate-Width($element, [double]$to, [int]$ms = 260) {
        Animate-Double $element ([System.Windows.FrameworkElement]::WidthProperty) $to $ms (New-Ease)
    }

    # Once a DP has been animated, the animation HOLDS the value and a plain assignment is
    # silently ignored. Anything that sets these properties outside an animation must clear
    # the animation first, or the pill stays 330px wide forever after the input closes.
    function Set-Opacity($element, [double]$v) {
        $element.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
        $element.Opacity = $v
    }

    function Set-Width($element, [double]$v) {
        $element.BeginAnimation([System.Windows.FrameworkElement]::WidthProperty, $null)
        $element.Width = $v
    }

    function Hide-After($element, [int]$ms) {
        $t = New-Object System.Windows.Threading.DispatcherTimer
        $t.Interval = [TimeSpan]::FromMilliseconds($ms)
        $t.Add_Tick({ $t.Stop(); $element.Visibility = "Collapsed" }.GetNewClosure())
        $t.Start()
    }

    # Idle breathing: squash/stretch anchored at the feet (RenderTransformOrigin 0.5,1.0).
    $petScale = New-Object System.Windows.Media.ScaleTransform(1, 1)
    $ui.Pet.RenderTransform = $petScale

    function Start-Breathing {
        $sy = New-Object System.Windows.Media.Animation.DoubleAnimation
        $sy.From = 1.0; $sy.To = 1.045
        $sy.Duration = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(1300))
        $sy.AutoReverse = $true
        $sy.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        $sy.EasingFunction = (New-Ease "EaseInOut")

        $sx = New-Object System.Windows.Media.Animation.DoubleAnimation
        $sx.From = 1.0; $sx.To = 0.975
        $sx.Duration = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(1300))
        $sx.AutoReverse = $true
        $sx.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        $sx.EasingFunction = (New-Ease "EaseInOut")

        $petScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $sy)
        $petScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $sx)
    }

    # The status line never hard-swaps: it fades out, changes, fades back in.
    function Set-PetStatus([string]$text) {
        if ($ui.CardStatus.Text -eq $text) { return }
        $a = New-Object System.Windows.Media.Animation.DoubleAnimation
        $a.To = 0
        $a.Duration = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(130))
        $a.Add_Completed({
            try {
                $ui.CardStatus.Text = $text
                Fade $ui.CardStatus 1 170
            } catch { $_ | Out-String | Add-Content -Path $errorLog }
        }.GetNewClosure())
        $ui.CardStatus.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $a)
    }

    function Set-PetCard {
        param(
            [string]$Title,
            [string]$Status,
            [switch]$Resolved,   # green check + reply button + close
            [switch]$Hide
        )
        if ($Hide) {
            if ($ui.CardWrap.Visibility -ne "Visible") { return }
            Fade $ui.CardWrap 0 140
            Hide-After $ui.CardWrap 150
            return
        }

        if ($ui.CardWrap.Visibility -ne "Visible") {
            Set-Opacity $ui.CardWrap 0
            $ui.CardWrap.Visibility = "Visible"
            Fade $ui.CardWrap 1 200
        }
        if ($PSBoundParameters.ContainsKey('Title'))  { $ui.CardTitle.Text = $Title }
        if ($PSBoundParameters.ContainsKey('Status')) { Set-PetStatus $Status }

        $vis = if ($Resolved) { "Visible" } else { "Collapsed" }
        $ui.CardGlyph.Text = if ($Resolved) { [string][char]0x2713 } else { "" }
        $ui.CardGlyph.Visibility = $vis
        $ui.CardReply.Visibility = $vis
        $ui.CardClose.Visibility = $vis
    }

    # ------------------------------------------------------------------ shell state machine

    $script:shell = 'Idle'

    function Set-Shell([string]$to) {
        if ($script:shell -eq $to) { return }
        $script:shell = $to

        switch ($to) {
            'Idle' {
                Set-PetState 'idle'
                if ($ui.Bar.Visibility -eq "Visible") {
                    Fade $ui.Bar 0 140
                    Hide-After $ui.Bar 150
                }
                $ui.InputArea.Visibility = "Collapsed"
                $ui.PillIcons.Visibility = "Visible"
                Set-Opacity $ui.PillIcons 1
                Set-Width $ui.Bar $PILL_W
                Set-PetCard -Hide
            }
            'Hover' {
                Set-PetState 'hover'
                Set-PetCard -Hide
                $ui.PillIcons.Visibility = "Visible"
                $ui.InputArea.Visibility = "Collapsed"
                Fade $ui.PillIcons 1
                if ($ui.Bar.Visibility -ne "Visible") {
                    Set-Opacity $ui.Bar 0
                    Set-Width $ui.Bar $PILL_W
                    $ui.Bar.Visibility = "Visible"
                    Fade $ui.Bar 1 180
                }
                else {
                    Animate-Width $ui.Bar $PILL_W
                }
            }
            'Compose' {
                Set-PetState 'input'
                $ui.Bar.Visibility = "Visible"
                Fade $ui.Bar 1 120
                # pill morphs into the input: icons fade out, the bar widens, the field fades in
                Fade $ui.PillIcons 0 120
                Animate-Width $ui.Bar $INPUT_W 280
                Set-Opacity $ui.InputArea 0
                $ui.InputArea.Visibility = "Visible"
                Fade $ui.InputArea 1 260
            }
            'Running' {
                Set-PetState 'working'
                if ($ui.Bar.Visibility -eq "Visible") {
                    Fade $ui.Bar 0 160
                    Hide-After $ui.Bar 170
                }
            }
            'Result' {
                Set-PetState 'done'
            }
            'Blocked' {
                Set-PetState 'blocking'
            }
        }
    }

    # ------------------------------------------------------------------ positioning
    # The window is anchored by its BOTTOM-RIGHT corner, so growing the card upward pushes the
    # mascot up instead of dragging the whole widget off the corner.

    $script:anchorRight  = $screen.Right - $margin
    $script:anchorBottom = $screen.Bottom - $margin

    function Move-ToCorner {
        try {
            $window.Left = $script:anchorRight - $window.ActualWidth
            $window.Top  = $script:anchorBottom - $window.ActualHeight
        } catch { }
    }
    $window.Add_SizeChanged({ Move-ToCorner })

    # ------------------------------------------------------------------ interaction

    $script:collapseTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:collapseTimer.Interval = [TimeSpan]::FromMilliseconds(700)
    $script:collapseTimer.Add_Tick({
        try {
            $script:collapseTimer.Stop()
            if ($script:shell -eq 'Hover') { Set-Shell 'Idle' }
        } catch { $_ | Out-String | Add-Content -Path $errorLog }
    })

    $onEnter = {
        try {
            $script:collapseTimer.Stop()
            if ($script:shell -eq 'Idle') { Set-Shell 'Hover' }
        } catch { $_ | Out-String | Add-Content -Path $errorLog }
    }
    $onLeave = {
        try {
            if ($script:shell -eq 'Hover') { $script:collapseTimer.Start() }
        } catch { $_ | Out-String | Add-Content -Path $errorLog }
    }

    # Hovering must never steal keyboard focus - otherwise the widget eats typing in whatever
    # window the user is actually working in. The caret only appears on a real click.
    $ui.PetHit.Add_MouseEnter($onEnter)
    $ui.PetHit.Add_MouseLeave($onLeave)
    $ui.Bar.Add_MouseEnter($onEnter)
    $ui.Bar.Add_MouseLeave($onLeave)

    $ui.PillEdit.Add_MouseLeftButtonUp({
        try { Set-Shell 'Compose'; $ui.PromptBox.Focus() | Out-Null }
        catch { $_ | Out-String | Add-Content -Path $errorLog }
    })
    $ui.PetHit.Add_MouseLeftButtonUp({
        try { if ($script:shell -eq 'Hover') { Set-Shell 'Compose'; $ui.PromptBox.Focus() | Out-Null } }
        catch { $_ | Out-String | Add-Content -Path $errorLog }
    })

    $ui.PromptBox.Add_TextChanged({
        $ui.Placeholder.Visibility = if ($ui.PromptBox.Text.Length -gt 0) { "Collapsed" } else { "Visible" }
    })

    $submit = {
        try {
            $text = $ui.PromptBox.Text.Trim()
            if ($text.Length -eq 0) { return }
            $ui.PromptBox.Text = ""
            Set-PetCard -Title $text -Status "Starting your task"
            Set-Shell 'Running'
        } catch { $_ | Out-String | Add-Content -Path $errorLog }
    }
    $ui.SendButton.Add_MouseLeftButtonUp($submit)
    $ui.PromptBox.Add_KeyDown({
        param($s, $e)
        try {
            if ($e.Key -eq "Return") { $e.Handled = $true; & $submit }
            elseif ($e.Key -eq "Escape") { $e.Handled = $true; $ui.PromptBox.Text = ""; Set-Shell 'Idle' }
        } catch { $_ | Out-String | Add-Content -Path $errorLog }
    })

    $ui.CardClose.Add_MouseLeftButtonUp({
        try { Set-PetCard -Hide; Set-Shell 'Idle' }
        catch { $_ | Out-String | Add-Content -Path $errorLog }
    })

    $window.Add_MouseRightButtonUp({ $window.Close() })
    $window.Add_Closed({ try { $script:pet.Stop() } catch { } })

    # ------------------------------------------------------------------ demo / screenshots

    function Save-Shot([string]$path) {
        $w = [int][Math]::Ceiling($ui.Root.ActualWidth)
        $h = [int][Math]::Ceiling($ui.Root.ActualHeight)
        if ($w -le 0 -or $h -le 0) { return }

        $pad = 24

        # Render the tree first, THEN composite. A VisualBrush would re-align the visual's
        # rendered content bounds instead of its layout box, which shoves a narrow state
        # (just the mascot + pill) against the left edge and fakes a centering bug.
        $layer = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(
                    $w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        $layer.Render($ui.Root)

        $visual = New-Object System.Windows.Media.DrawingVisual
        $dc = $visual.RenderOpen()
        $bg = New-Object System.Windows.Media.SolidColorBrush(
                [System.Windows.Media.ColorConverter]::ConvertFromString("#0B0B0D"))
        $dc.DrawRectangle($bg, $null, (New-Object System.Windows.Rect(0, 0, ($w + $pad * 2), ($h + $pad * 2))))
        $dc.DrawImage($layer, (New-Object System.Windows.Rect($pad, $pad, $w, $h)))
        $dc.Close()

        $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(
                    ($w + $pad * 2), ($h + $pad * 2), 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        $rtb.Render($visual)
        $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
        $fs = [IO.File]::Open($path, [IO.FileMode]::Create)
        try { $enc.Save($fs) } finally { $fs.Dispose() }
    }

    if ($Demo) {
        if ($ShotDir -and -not (Test-Path $ShotDir)) { New-Item -ItemType Directory -Path $ShotDir | Out-Null }

        # Mirrors the reference recording: idle -> hover -> compose -> type -> run -> resolve -> close.
        $script:steps = @(
            @{ ms = 600;  shot = 'idle';     do = { Set-Shell 'Idle' } }
            @{ ms = 1200; shot = 'hover';    do = { Set-Shell 'Hover' } }
            @{ ms = 1200; shot = 'compose';  do = { Set-Shell 'Compose' } }
            @{ ms = 900;  shot = 'typing';   do = { $ui.PromptBox.Text = "asdsaads" } }
            @{ ms = 900;  shot = 'starting'; do = {
                    Set-PetCard -Title "asdsaads" -Status "Starting your task"
                    Set-Shell 'Running' } }
            @{ ms = 1400; shot = 'thinking'; do = {
                    Set-PetState 'thinking'
                    Set-PetStatus "Thinking" } }
            @{ ms = 1400; shot = 'tool';     do = { Set-PetStatus "Read: CONTEXT.md" } }
            @{ ms = 1600; shot = 'result';   do = {
                    Set-PetCard -Title "Locate asdsaads" `
                                -Status "Nikito, what needs to happen? Describe the task in one sentence." `
                                -Resolved
                    Set-Shell 'Result' } }
            @{ ms = 1600; shot = 'blocked';  do = {
                    Set-PetCard -Title "Locate asdsaads" -Status "needs approval - click to open" -Resolved
                    Set-Shell 'Blocked' } }
            @{ ms = 1400; shot = 'closed';   do = { Set-PetCard -Hide; Set-Shell 'Idle' } }
        )
        $script:stepIndex = 0

        $demoTimer = New-Object System.Windows.Threading.DispatcherTimer
        $demoTimer.Interval = [TimeSpan]::FromMilliseconds(600)
        $demoTimer.Add_Tick({
            try {
                if ($script:stepIndex -ge $script:steps.Count) {
                    $demoTimer.Stop()
                    $window.Close()
                    return
                }
                $step = $script:steps[$script:stepIndex]
                $script:stepIndex++
                & $step.do

                if ($ShotDir) {
                    # capture into locals: $script:stepIndex has already moved on by the time
                    # the deferred tick runs
                    $shotName = "{0:d2}-{1}.png" -f $script:stepIndex, $step.shot
                    # let the transition land before capturing
                    $shotTimer = New-Object System.Windows.Threading.DispatcherTimer
                    $shotTimer.Interval = [TimeSpan]::FromMilliseconds(420)
                    $shotTimer.Add_Tick({
                        try {
                            $shotTimer.Stop()
                            Save-Shot (Join-Path $ShotDir $shotName)
                        } catch { $_ | Out-String | Add-Content -Path $errorLog }
                    }.GetNewClosure())
                    $shotTimer.Start()
                }

                $demoTimer.Interval = [TimeSpan]::FromMilliseconds($step.ms)
            } catch { $_ | Out-String | Add-Content -Path $errorLog }
        })
        $demoTimer.Start()
    }

    $window.Add_ContentRendered({
        try {
            Set-PetState 'idle'
            Start-Breathing
            Move-ToCorner
        } catch { $_ | Out-String | Add-Content -Path $errorLog }
    })

    $window.ShowDialog() | Out-Null
}
catch {
    $_ | Out-String | Add-Content -Path $errorLog
    throw
}
