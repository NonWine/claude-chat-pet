# Claude quick-prompt widget.
#
#   rest on pet  -> expand after hoverDelayMs; click opens at once; Esc collapses
#   camera button-> appears beside the pet on hover; grabs the screen and attaches it to
#                   the next prompt. Both send paths below carry it, unchanged.
#   Enter        -> run headless (claude -p): NO window ever opens, the reply lands in
#                   a card above the pet. This is the "do not take me to the app" path.
#   Ctrl+Enter   -> deliberately open a real chat in the app with this prompt. The app
#                   window WILL come up: claude:// has no background route.
#   Ctrl+Wheel   -> scale the whole widget (also Ctrl +/-/0), saved to config.json
#   Ctrl+Shift+Wheel -> scale only the input panel, independently of the pet
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
    # System.Drawing / Forms are here for the screen grab only: WPF has no screen capture of
    # its own, and Forms is what knows where the monitors are.
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    Add-Type -AssemblyName System.Drawing, System.Windows.Forms

    $SYM_RUN  = [char]0x25CF  # filled circle
    $SYM_OK   = [char]0x2713  # check
    $SYM_ERR  = [char]0x2715  # cross
    $SYM_WARN = [char]0x25B2  # triangle
    $SYM_SEP  = [char]0x00B7  # middle dot

    # ---------------------------------------------------------------- config
    $configPath = "$PSScriptRoot\config.json"
    $cfg = @{
        scale           = 1.0    # 0.6 .. 2.5, the whole widget
        panelScale      = 1.0    # 0.6 .. 2.5, the input panel ON TOP of the widget scale
        startCollapsed  = $true
        collapseDelayMs = 700
        hoverDelayMs    = 1200   # rest this long on the pet before the input opens; a drag
                                 # or a passing pointer never reaches it. Click opens at once.
        focusOnHover    = $false # true = hovering also grabs the keyboard (steals focus)
        panelWidth      = 330
        sendFolder      = ""     # folder a new app chat opens in; empty = let the app decide
        shotHoverDelayMs = 250   # rest this long on the pet before the camera button shows.
                                 # Much shorter than hoverDelayMs: the button does not move
                                 # the pet or cover anything, so being early costs nothing.
        shotButtonHideMs = 3500  # how long the camera button lingers after the pointer has
                                 # left. Appearing is cheap, vanishing is not: a control that
                                 # goes away mid-approach cannot be clicked at all.
        shotMaxPx       = 1568   # longest edge of a saved screenshot. Above this the model
                                 # downscales anyway, so the extra pixels are pure cost.
        shotFullDesktop = $false # false = the monitor the widget is on; true = all monitors
        shotKeep        = 30     # how many PNGs to keep in shots\ before pruning the oldest
        anchorRight     = 0      # bottom-right corner the widget grows from; 0 = screen corner
        anchorBottom    = 0
        framesDir       = "sprites\frames"
                                 # which character to wear, relative to this script (or an
                                 # absolute path). It is a setting rather than a hardcoded
                                 # path for a licensing reason: sprites\frames holds the MIT
                                 # placeholder and is tracked by git, so art that is not ours
                                 # to redistribute goes in its own gitignored folder and is
                                 # pointed at from here instead of overwriting the default.
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
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        SnapsToDevicePixels="True">
  <Grid x:Name="Root">
   <StackPanel>

    <!-- Where the answer shows up. A headless run has no chat window, so without this the
         reply would exist only inside jobs\<id>.jsonl. Deliberately OUTSIDE the collapsible
         panel: it has to survive the widget folding away, and only the X dismisses it. -->
    <Grid x:Name="AnswerCard" Visibility="Collapsed" Width="$panelW" HorizontalAlignment="Right" Margin="0,0,0,8">
      <Border CornerRadius="22" Background="#F21E2024" BorderBrush="#26FFFFFF"
              BorderThickness="1" Padding="16,12,16,12">
        <StackPanel>
          <StackPanel Orientation="Horizontal" Margin="0,0,0,4">
            <TextBlock x:Name="AnswerGlyph" Text="" FontSize="12.5" Foreground="#FF57C08D"
                       VerticalAlignment="Center" Margin="0,0,8,0"/>
            <TextBlock x:Name="AnswerTitle" Text="" Foreground="#EDEFF2" FontSize="12.5"
                       FontWeight="SemiBold" TextTrimming="CharacterEllipsis" MaxWidth="250"/>
          </StackPanel>
          <ScrollViewer MaxHeight="190" VerticalScrollBarVisibility="Auto">
            <TextBlock x:Name="AnswerText" Text="" Foreground="#C5CAD3" FontSize="12.5"
                       TextWrapping="Wrap" LineHeight="17"/>
          </ScrollViewer>
          <Border x:Name="AnswerOpen" Margin="0,12,0,0" Padding="8,4" CornerRadius="8"
                  Background="#2A2D33" Cursor="Hand" HorizontalAlignment="Left"
                  ToolTip="Open this session in a real Claude window.">
            <TextBlock Text="Open in app" Foreground="#C9CED6" FontSize="11"/>
          </Border>
        </StackPanel>
      </Border>
      <!-- The dot stays 18px because that is the size it should LOOK; the transparent
           grid around it is what the mouse actually has to hit. An 18px target is below
           what a corner control can be clicked at reliably. -->
      <Grid x:Name="AnswerClose" Width="26" Height="26" Background="Transparent"
            HorizontalAlignment="Left" VerticalAlignment="Top" Margin="-10,-10,0,0"
            Cursor="Hand" ToolTip="Dismiss">
        <Border Width="18" Height="18" CornerRadius="9" Background="#2A2D33"
                BorderBrush="#33FFFFFF" BorderThickness="1">
          <TextBlock Text="&#10005;" Foreground="#C9CED6" FontSize="10"
                     HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
      </Grid>
    </Grid>


    <!-- expanded state. PanelWrap exists only to carry the user's input-only scale: the
         panel's own LayoutTransform is already driven by the expand animation, so a second
         scale needs a second element rather than a shared transform. -->
    <Grid x:Name="PanelWrap" HorizontalAlignment="Right">
    <Border x:Name="Panel" Visibility="Collapsed" Width="$panelW" CornerRadius="22" Margin="0,0,0,4"
            Background="#EE1E1E1E" BorderBrush="#33FFFFFF" BorderThickness="1">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="48"/>
        </Grid.RowDefinitions>

        <Border x:Name="StatusBar" Grid.Row="0" Visibility="Collapsed"
                Margin="16,8,8,0" Padding="4,0,4,0" Background="Transparent" Cursor="Hand"
                ToolTip="Click to open this session in a real Claude window.">
          <StackPanel Orientation="Horizontal">
            <TextBlock x:Name="StatusDot" Text="" Foreground="#FF6EA8FE" FontSize="11" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <TextBlock x:Name="StatusText" Text="" Foreground="#CCFFFFFF" FontSize="11" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" MaxWidth="280"/>
          </StackPanel>
        </Border>

        <Grid Grid.Row="1" Margin="16,0,8,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="34"/>
          </Grid.ColumnDefinitions>

          <!-- The attached screenshot, sitting in the composer the way an attachment does.
               ONE control, one action: the whole chip detaches. A separate close dot was
               tried and dropped: the card's 18px dot is half the width of this chip, and
               shrinking it meant an 8pt glyph, i.e. inventing a type step for one control.
               What the dot was there for ("is this the right shot?") is answered better by
               the hover preview, which is built in Set-Shot.
               The image is the Border's Background so the corner radius actually clips it;
               an Image inside a rounded Border keeps its square corners. -->
          <Border x:Name="ShotChip" Grid.Column="0" Visibility="Collapsed" Margin="0,0,8,0"
                  VerticalAlignment="Center" Width="36" Height="26" CornerRadius="8"
                  Background="#2A2D33" BorderBrush="#33FFFFFF" BorderThickness="1"
                  Cursor="Hand" ToolTip="Attached screenshot. Click to detach."/>

          <Grid Grid.Column="1">
            <TextBlock x:Name="Placeholder" Text="Ask Claude..." Foreground="#88FFFFFF" VerticalAlignment="Center" IsHitTestVisible="False" FontSize="14"/>
            <TextBox x:Name="PromptBox" Background="Transparent" Foreground="White" CaretBrush="White" BorderThickness="0" VerticalAlignment="Center" FontSize="14"
                     ToolTip="Enter: run it here - no window opens, reply appears above.&#10;Ctrl+Enter: open a real chat in the app instead (raises the app window).&#10;Ctrl+Wheel: resize widget. Ctrl+Shift+Wheel: resize this input.&#10;Esc: collapse."/>
          </Grid>
          <Button x:Name="SendButton" Grid.Column="2" Width="30" Height="30" Cursor="Hand" VerticalAlignment="Center" Background="Transparent" BorderThickness="0"
                  ToolTip="Click: run it here, no window.&#10;Double-click: open an empty new chat in the app.">
            <Button.Template>
              <ControlTemplate TargetType="Button">
                <Grid>
                  <Ellipse Fill="#FF6B6B6B"/>
                  <TextBlock Text="&#10148;" Foreground="White" FontSize="14" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Grid>
              </ControlTemplate>
            </Button.Template>
          </Button>
        </Grid>
      </Grid>
    </Border>
    </Grid>

    <!-- right-click menu; an in-window panel rather than a Popup, so it inherits the
         window's transparency and cannot land behind a topmost window -->
    <Border x:Name="MenuCard" Visibility="Collapsed" Width="200" Margin="0,0,0,8"
            HorizontalAlignment="Right" CornerRadius="22" Background="#F51E2024"
            BorderBrush="#33FFFFFF" BorderThickness="1" Padding="12,12">
      <StackPanel>
        <TextBlock Text="SIZE" Foreground="#8B929C" FontSize="10" Margin="4,0,0,8"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
          <Border x:Name="MenuMinus" Width="28" Height="26" CornerRadius="8" Background="#2A2D33" Cursor="Hand">
            <TextBlock Text="&#8722;" Foreground="#C9CED6" FontSize="14"
                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <TextBlock x:Name="MenuScale" Text="100%" Foreground="#EDEFF2" FontSize="12.5" Width="56"
                     TextAlignment="Center" VerticalAlignment="Center"/>
          <Border x:Name="MenuPlus" Width="28" Height="26" CornerRadius="8" Background="#2A2D33" Cursor="Hand">
            <TextBlock Text="+" Foreground="#C9CED6" FontSize="14"
                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <Border x:Name="MenuReset" Width="28" Height="26" CornerRadius="8" Background="#2A2D33"
                  Cursor="Hand" Margin="8,0,0,0" ToolTip="Reset both sizes and the position">
            <TextBlock Text="&#8635;" Foreground="#C9CED6" FontSize="14"
                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
        </StackPanel>

        <TextBlock Text="PANEL" Foreground="#8B929C" FontSize="10" Margin="4,12,0,8"
                   ToolTip="Size of the prompt panel and the answer card.&#10;The pet keeps its own size."/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
          <Border x:Name="MenuInputMinus" Width="28" Height="26" CornerRadius="8" Background="#2A2D33" Cursor="Hand">
            <TextBlock Text="&#8722;" Foreground="#C9CED6" FontSize="14"
                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <TextBlock x:Name="MenuInputScale" Text="100%" Foreground="#EDEFF2" FontSize="12.5" Width="56"
                     TextAlignment="Center" VerticalAlignment="Center"/>
          <Border x:Name="MenuInputPlus" Width="28" Height="26" CornerRadius="8" Background="#2A2D33" Cursor="Hand">
            <TextBlock Text="+" Foreground="#C9CED6" FontSize="14"
                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
        </StackPanel>

        <Border Height="1" Background="#1AFFFFFF" Margin="0,12,0,8"/>

        <Border x:Name="MenuClose" Padding="8,8" CornerRadius="8" Background="Transparent" Cursor="Hand">
          <TextBlock Text="Close widget" Foreground="#E06C75" FontSize="12.5"/>
        </Border>
      </StackPanel>
    </Border>

    <!-- The pet is the anchor of the whole widget, so it is the LAST child and is
         right-aligned: the window is pinned by its bottom-right corner, which is
         now exactly the pet's own corner. Everything else grows up and to the
         left from here, so opening the panel no longer teleports the character.
         The status colour stays in the glow under its feet. -->
    <!-- Hover controls sit BESIDE the pet, never above or below it. The window is pinned by
         its bottom-right corner, so a row growing to the LEFT leaves the pet exactly where it
         was; the same button stacked under the pet would lift it by its own height, which is
         the one thing DESIGN.md section 1 exists to prevent. The button is also shorter than
         the pet and bottom-aligned, so the row's height stays the pet's height. -->
    <!-- Background="Transparent" is load-bearing, not decoration. The 8px gap between the
         button and the pet is the button's MARGIN, and a margin is not part of any element:
         without a background on the row it is a hole in the hit test. Crossing it on the way
         to the button raised MouseLeave, which hid the button, which shrank the window out
         from under the pointer: the button ran away from every attempt to click it. -->
    <StackPanel x:Name="PetRow" Orientation="Horizontal" HorizontalAlignment="Right"
                Background="Transparent">

      <!-- Drawn from shapes rather than a glyph: this file is ASCII-only, and a camera
           character would mean betting on a specific icon font being installed. Vector
           shapes also stay sharp under Ctrl+wheel, which a bitmap icon would not. -->
      <Grid x:Name="ShotButton" Width="26" Height="26" Visibility="Collapsed"
            VerticalAlignment="Bottom" Margin="0,0,8,12" Cursor="Hand" Background="Transparent"
            ToolTip="Grab the screen and attach it to the next prompt.">
        <Border CornerRadius="8" Background="#E61E2024" BorderBrush="#33FFFFFF" BorderThickness="1"/>
        <Canvas Width="26" Height="26">
          <Border Canvas.Left="5" Canvas.Top="9" Width="16" Height="11" CornerRadius="2"
                  BorderBrush="#C9CED6" BorderThickness="1.2"/>
          <Border Canvas.Left="9.5" Canvas.Top="6" Width="7" Height="3.5" CornerRadius="1"
                  BorderBrush="#C9CED6" BorderThickness="1.2"/>
          <Ellipse Canvas.Left="10" Canvas.Top="11.5" Width="6" Height="6"
                   Stroke="#C9CED6" StrokeThickness="1.2"/>
        </Canvas>
      </Grid>

    <Grid x:Name="PetHost" Width="56" Height="58" HorizontalAlignment="Right"
          Background="Transparent" Cursor="Hand"
          ToolTip="Hover to open. Drag to move. Right-click for options.">
      <Ellipse x:Name="PetGlow" Width="30" Height="9" Fill="#FF6B6B6B" Opacity="0.7"
               VerticalAlignment="Bottom" Margin="0,0,0,2">
        <Ellipse.Effect>
          <BlurEffect Radius="7"/>
        </Ellipse.Effect>
      </Ellipse>
      <!-- The outgoing frame during a cross-fade. It must sit BELOW PetImage and match its
           box exactly, otherwise the transition slides. Invisible and untouchable unless a
           fade is running, and unused entirely when the manifest sets no crossfadeMs. -->
      <Image x:Name="PetFade" Width="44" Height="44" Opacity="0" IsHitTestVisible="False"
             VerticalAlignment="Bottom" Margin="0,0,0,4"
             RenderOptions.BitmapScalingMode="NearestNeighbor"
             RenderTransformOrigin="0.5,1.0"/>
      <!-- Size and scaling filter here are the FALLBACK only: a manifest carrying
           displayHeight overrides both, so art of any size needs no edit in this file. -->
      <Image x:Name="PetImage" Width="44" Height="44"
             VerticalAlignment="Bottom" Margin="0,0,0,4"
             RenderOptions.BitmapScalingMode="NearestNeighbor"
             RenderTransformOrigin="0.5,1.0"/>
    </Grid>
    </StackPanel>

   </StackPanel>
  </Grid>
</Window>
"@

    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [Windows.Markup.XamlReader]::Load($reader)
    $root        = $window.FindName("Root")
    $petHost     = $window.FindName("PetHost")
    $petImage    = $window.FindName("PetImage")
    $petFade     = $window.FindName("PetFade")
    $petGlow     = $window.FindName("PetGlow")
    $panel       = $window.FindName("Panel")
    $panelWrap   = $window.FindName("PanelWrap")
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
    $menuInputScale = $window.FindName("MenuInputScale")
    $menuInputMinus = $window.FindName("MenuInputMinus")
    $menuInputPlus  = $window.FindName("MenuInputPlus")
    $menuClose   = $window.FindName("MenuClose")
    $promptBox   = $window.FindName("PromptBox")
    $placeholder = $window.FindName("Placeholder")
    $sendButton  = $window.FindName("SendButton")
    $statusBar   = $window.FindName("StatusBar")
    $statusDot   = $window.FindName("StatusDot")
    $statusText  = $window.FindName("StatusText")
    $shotButton  = $window.FindName("ShotButton")
    $shotChip    = $window.FindName("ShotChip")

    # send-to-app.ps1 is no longer wired in: it drove the app through the clipboard and
    # SendKeys, which lands nowhere when the app opens its folder picker. The prompt now
    # travels in the URL instead. The file is kept because it is the only way to press
    # Enter FOR the user, if ?q= turns out to prefill the composer rather than submit it.
    $jobsDir = "$PSScriptRoot\jobs"

    # Where the desktop app keeps one file per Code session. Each is a thin wrapper:
    # "sessionId" is the app's own local_<uuid> (the ONLY form claude://code/continue
    # accepts) and "cliSessionId" points at the CLI transcript that holds the messages.
    # A prompt sent into the app therefore becomes reachable through both.
    $sessionStore = Join-Path $env:APPDATA 'Claude\claude-code-sessions'
    $transcriptRoot = Join-Path $env:USERPROFILE '.claude\projects'
    if (-not (Test-Path $jobsDir)) { New-Item -ItemType Directory -Path $jobsDir | Out-Null }

    # Screenshots have to outlive the send: the prompt carries a PATH, and the model opens
    # it whenever it gets round to it. Deleting on send would race the run.
    #
    # They live under the project, which is under $env:USERPROFILE -- the working directory
    # of a headless run and the default folder of an app chat. That is not filing tidiness:
    # a path outside the session's folder is a read the CLI has to ask permission for, and a
    # headless run has nobody to ask.
    $shotsDir = "$PSScriptRoot\shots"
    if (-not (Test-Path $shotsDir)) { New-Item -ItemType Directory -Path $shotsDir | Out-Null }

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
    $framesDir = [string]$cfg.framesDir
    if (-not [IO.Path]::IsPathRooted($framesDir)) { $framesDir = Join-Path $PSScriptRoot $framesDir }
    $pet = New-PetSprite -Image $petImage -FadeImage $petFade -FramesDir $framesDir

    # The art decides how big its own box is. The Width/Height in the XAML above are only the
    # fallback for a manifest with no displayHeight; when there is one, everything that wraps
    # the character is re-derived from it here, so dropping in a taller character does not
    # leave it standing in a 56x58 hole under a cat-sized shadow.
    #
    # The +12 / +14 slack and the glow ratios reproduce exactly what the original 44px art had
    # (56x58 host, 30x9 glow, blur 7). That headroom is not decoration: the squash-and-stretch
    # transform scales the image to 1.05 and would clip against a tight host.
    if ($pet.DisplayHeight -gt 0) {
        $petHost.Width  = $pet.DisplayWidth  + 12
        $petHost.Height = $pet.DisplayHeight + 14
        $petGlow.Width  = [Math]::Round($pet.DisplayWidth * 0.682, 0)
        $petGlow.Height = [Math]::Round($pet.DisplayWidth * 0.205, 0)
        if ($null -ne $petGlow.Effect) {
            $petGlow.Effect.Radius = [Math]::Round($petGlow.Width * 0.233, 1)
        }
    }

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
    #
    # The amplitude belongs to the ART, not to this file. The old hardcoded 1.05 is one pixel
    # of squash on a 16px cat and seven on a 150px human figure, where it stops reading as
    # breathing and starts reading as inflating. The manifest carries it; the defaults in
    # pet-sprite.ps1 are these exact numbers, so the placeholder is untouched.
    $petScale = New-Object System.Windows.Media.ScaleTransform(1, 1)
    $petImage.RenderTransform = $petScale
    function Start-PetBreathing {
        foreach ($p in @(
            @{ prop = [System.Windows.Media.ScaleTransform]::ScaleYProperty; to = $pet.Breathe.ScaleY },
            @{ prop = [System.Windows.Media.ScaleTransform]::ScaleXProperty; to = $pet.Breathe.ScaleX }
        )) {
            $a = New-Object System.Windows.Media.Animation.DoubleAnimation
            $a.From = 1.0
            $a.To = $p.to
            $a.Duration = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds($pet.Breathe.PeriodMs))
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

    # Second, independent scale for the content surfaces. It multiplies with $rootScale
    # rather than replacing it: the pet stays the size the user picked, the panel and the
    # answer card get their own.
    #
    # The card shares this transform with the panel on purpose. They are the same class of
    # thing -- what Claude says and what you say back -- and letting only one of them scale
    # leaves a 495px card sitting on top of a 297px panel, which reads as a broken layout
    # rather than as two settings. One WPF Transform can drive several elements.
    $inputScale = New-Object System.Windows.Media.ScaleTransform(1, 1)
    $panelWrap.LayoutTransform = $inputScale
    $answerCard.LayoutTransform = $inputScale

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
            # The ANCHOR is rounded, not the result. The pet sits flush against the
            # window's bottom-right corner, so pet_edge = Left + Width = round(anchor):
            # a whole number that no longer depends on the window's (fractional) size.
            # Rounding the subtraction instead pushes that fraction straight into the
            # pet's position, which is a one-pixel twitch on every resize.
            $window.Left = [Math]::Round($script:anchorRight)  - $window.ActualWidth
            $window.Top  = [Math]::Round($script:anchorBottom) - $window.ActualHeight
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

    function Set-InputScale([double]$s) {
        $s = [Math]::Round([Math]::Max($MIN_SCALE, [Math]::Min($MAX_SCALE, $s)), 2)
        $cfg.panelScale = $s
        $inputScale.ScaleX = $s
        $inputScale.ScaleY = $s
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
    $script:answerLocalId = $null

    # Opening a run in the app takes one of two routes, and picking the wrong one silently
    # dumps the user in an empty chat.
    #
    #   local_<uuid>  the app already owns this chat  -> code/continue?session=
    #   <cli uuid>    a headless run the app has never seen. code/continue REJECTS this
    #                 (its validator takes "last" or local_<uuid> only). The route that
    #                 works is claude://resume?session=<uuid>, which calls the app's own
    #                 importCliSession: it adopts the CLI transcript into a real desktop
    #                 session, live, and navigates to it. No restart, nothing written
    #                 into the app's store by us.
    function Open-Session([string]$localId, [string]$cliId) {
        if ($localId) { Start-Process ("claude://code/continue?session=" + $localId); return $true }
        if ($cliId -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
            Start-Process ("claude://resume?session=" + $cliId)
            return $true
        }
        return $false
    }

    function Show-Answer($job) {
        $ok = ($job.State -eq 'done')
        $answerGlyph.Text = if ($ok) { [string]$SYM_OK } else { [string]$SYM_ERR }
        $answerGlyph.Foreground = $brushes[$(if ($ok) { 'done' } else { 'error' })]
        $answerTitle.Text = Get-Short ([string]$job.Prompt) 48

        $body = [string]$job.Answer
        if ([string]::IsNullOrWhiteSpace($body)) { $body = [string]$job.Detail }
        $answerText.Text = $body.Trim()

        # Both kinds of run can be opened, by different routes -- see Open-Session.
        $script:answerSession = $job.SessionId
        $script:answerLocalId = $job.LocalId
        $answerOpen.Visibility = if ($job.LocalId -or $job.SessionId) { "Visible" } else { "Collapsed" }
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

    # --------------------------------------------------------------- screenshot
    # An attachment, not a second way to send. The screenshot is taken, parked, and then
    # rides along with whatever the user types next, through EITHER send path unchanged.
    $script:shotPath = $null

    # Which rectangle of the desktop to grab.
    #
    # Trap worth knowing: Screen.Bounds is in physical pixels while everything in WPF -- the
    # anchor, the window position -- is in device-independent units. At 150% those are not
    # the same number, so the anchor has to go through the window's own device transform
    # before it can be compared against a monitor. Getting this wrong grabs the wrong
    # monitor rather than failing, which is why it is worth spelling out.
    function Get-ShotBounds {
        if ([bool]$cfg.shotFullDesktop) {
            return [System.Windows.Forms.SystemInformation]::VirtualScreen
        }
        $x = $script:anchorRight
        $y = $script:anchorBottom
        try {
            $src = [System.Windows.PresentationSource]::FromVisual($window)
            if ($src) {
                $m = $src.CompositionTarget.TransformToDevice
                $x = $script:anchorRight  * $m.M11
                $y = $script:anchorBottom * $m.M22
            }
        } catch { }
        # One pixel in from the anchor: the anchor is the widget's bottom-right EDGE, and an
        # edge point can land on the next monitor along.
        $pt = New-Object System.Drawing.Point([int]($x - 2), [int]($y - 2))
        return ([System.Windows.Forms.Screen]::FromPoint($pt)).Bounds
    }

    # Full-size grabs are mostly waste: the model downscales anything past its own limit
    # anyway, so the pixels above it cost upload time and buy nothing.
    function Save-ShotBitmap($bmp, [string]$path) {
        $max = [int]$cfg.shotMaxPx
        $long = [Math]::Max($bmp.Width, $bmp.Height)
        if ($max -gt 0 -and $long -gt $max) {
            $k = $max / $long
            $w = [Math]::Max(1, [int][Math]::Round($bmp.Width  * $k))
            $h = [Math]::Max(1, [int][Math]::Round($bmp.Height * $k))
            $small = New-Object System.Drawing.Bitmap($w, $h)
            $g = [System.Drawing.Graphics]::FromImage($small)
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.DrawImage($bmp, 0, 0, $w, $h)
            $g.Dispose()
            $small.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
            $small.Dispose()
            return
        }
        $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    }

    function Remove-OldShots {
        try {
            $keep = [int]$cfg.shotKeep
            if ($keep -le 0) { return }
            $all = @(Get-ChildItem -Path $shotsDir -Filter '*.png' -ErrorAction SilentlyContinue |
                     Sort-Object LastWriteTime -Descending)
            if ($all.Count -le $keep) { return }
            foreach ($f in $all[$keep..($all.Count - 1)]) {
                if ($f.FullName -ne $script:shotPath) { Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue }
            }
        } catch { }
    }

    # Decode once at two sizes: the chip and the hover preview. Both are decoded with OnLoad
    # and frozen rather than left pointing at the file -- a lazy BitmapImage holds a lock on
    # the PNG, and then pruning silently fails to delete it.
    function New-ShotBitmap([string]$path, [int]$w) {
        $bi = New-Object System.Windows.Media.Imaging.BitmapImage
        $bi.BeginInit()
        $bi.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bi.DecodePixelWidth = $w
        $bi.UriSource = New-Object System.Uri($path)
        $bi.EndInit()
        $bi.Freeze()
        return $bi
    }

    function Set-Shot([string]$path) {
        $script:shotPath = $path
        if (-not $path) {
            $shotChip.Background = $bc.ConvertFromString("#2A2D33")
            $shotChip.ToolTip = "Attached screenshot. Click to detach."
            $shotChip.Visibility = "Collapsed"
            Move-ToCorner
            return
        }
        try {
            $brush = New-Object System.Windows.Media.ImageBrush((New-ShotBitmap $path 96))
            $brush.Stretch = "UniformToFill"
            $shotChip.Background = $brush

            # 36x26 of a whole desktop is a marker, not a preview -- nothing on it is
            # readable. The readable version is the tooltip, which is where the question
            # "did I grab the right thing?" actually gets answered.
            $tip = New-Object System.Windows.Controls.StackPanel
            $img = New-Object System.Windows.Controls.Image
            $img.Source = (New-ShotBitmap $path 260)
            $img.Width = 260
            $tip.Children.Add($img) | Out-Null
            $cap = New-Object System.Windows.Controls.TextBlock
            $cap.Text = "Click the chip to detach"
            $cap.FontSize = 11
            $cap.Margin = New-Object System.Windows.Thickness(0, 4, 0, 0)
            $tip.Children.Add($cap) | Out-Null
            $shotChip.ToolTip = $tip
        } catch { $_ | Out-String | Add-Content -Path $errorLog }
        $shotChip.Visibility = "Visible"
        Move-ToCorner
    }

    function Clear-Shot { Set-Shot $null }

    # The capture runs on a timer tick rather than inline, and this is the whole reason the
    # widget can photograph the screen it is sitting on: the window is faded out first, and
    # the compositor needs a frame to actually stop drawing it. Capturing in the same call
    # that hides it photographs the widget.
    #
    # Opacity, not Visibility="Hidden" or Hide(): the window is inside ShowDialog(), and a
    # window that leaves the screen there can come back without its position, its topmost
    # flag or its focus. A layered window at opacity 0 contributes nothing to what BitBlt
    # reads off the desktop, and nothing about the window's state changes.
    $script:shotTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:shotTimer.Interval = [TimeSpan]::FromMilliseconds(160)
    $script:shotTimer.Add_Tick({
        $bmp = $null
        $gfx = $null
        try {
            $script:shotTimer.Stop()
            $b = Get-ShotBounds
            $bmp = New-Object System.Drawing.Bitmap($b.Width, $b.Height)
            $gfx = [System.Drawing.Graphics]::FromImage($bmp)
            $gfx.CopyFromScreen($b.X, $b.Y, 0, 0, (New-Object System.Drawing.Size($b.Width, $b.Height)))
            # The pixels are taken; come back before the encoding, not after it.
            $window.Opacity = 1

            $path = Join-Path $shotsDir ((Get-Date -Format "yyyyMMdd-HHmmss-fff") + ".png")
            Save-ShotBitmap $bmp $path
            Set-Shot $path
            Remove-OldShots

            Set-Collapsed $false
            $window.Activate() | Out-Null
            $promptBox.Focus() | Out-Null
        }
        catch {
            $_ | Out-String | Add-Content -Path $errorLog
            Set-Status 'error' "screenshot failed - see error.log"
        }
        finally {
            # A widget left at opacity 0 is a widget the user has lost, so the restore is
            # repeated here for the paths that never reached it.
            $window.Opacity = 1
            if ($gfx) { $gfx.Dispose() }
            if ($bmp) { $bmp.Dispose() }
        }
    })

    function Start-Shot {
        $script:shotTimer.Stop()
        $window.Opacity = 0
        $script:shotTimer.Start()
    }

    # ---------------------------------------------------------------- menu
    function Set-Menu([bool]$show) {
        if ($show) {
            $menuScale.Text = ("{0:n0}%" -f ([double]$cfg.scale * 100))
            $menuInputScale.Text = ("{0:n0}%" -f ([double]$cfg.panelScale * 100))
        }
        $menuCard.Visibility = if ($show) { "Visible" } else { "Collapsed" }
        Move-ToCorner
    }

    function Step-Scale([double]$delta) {
        Set-Scale ([double]$cfg.scale + $delta)
        Save-Config
        $menuScale.Text = ("{0:n0}%" -f ([double]$cfg.scale * 100))
    }

    function Step-InputScale([double]$delta) {
        Set-InputScale ([double]$cfg.panelScale + $delta)
        Save-Config
        $menuInputScale.Text = ("{0:n0}%" -f ([double]$cfg.panelScale * 100))
    }

    $collapseTimer = New-Object System.Windows.Threading.DispatcherTimer
    $collapseTimer.Interval = [TimeSpan]::FromMilliseconds([int]$cfg.collapseDelayMs)
    $collapseTimer.Add_Tick({
        try {
            $collapseTimer.Stop()
            if ($root.IsMouseOver) { return }
            if ($menuCard.Visibility -eq "Visible") { return }
            # keep it open while there is an unsent draft or the caret is in the box.
            # An attached screenshot is an unsent draft too -- folding the panel away would
            # hide the only sign that the next prompt is carrying something.
            if ($script:shotPath) { return }
            if ($promptBox.Text.Length -gt 0) { return }
            if ($promptBox.IsKeyboardFocusWithin) { return }
            Set-Collapsed $true
        } catch { $_ | Out-String | Add-Content -Path $errorLog }
    })

    # Hovering does not open the input immediately: the pointer has to REST on the pet for
    # hoverDelayMs first. Dragging the pet, or sweeping the mouse across it on the way
    # somewhere else, is not a request for a prompt box. A click still opens it at once,
    # so the delay never stands between the user and typing.
    $script:hoverTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:hoverTimer.Interval = [TimeSpan]::FromMilliseconds([int]$cfg.hoverDelayMs)
    $script:hoverTimer.Add_Tick({
        try {
            $script:hoverTimer.Stop()
            if (-not $root.IsMouseOver) { return }
            if (-not $script:collapsed) { return }
            # A held button means a drag is in progress, not a hover.
            if ([System.Windows.Input.Mouse]::LeftButton -eq [System.Windows.Input.MouseButtonState]::Pressed) { return }
            Set-Collapsed $false
            if ($cfg.focusOnHover) { $window.Activate() | Out-Null; $promptBox.Focus() | Out-Null }
        } catch { $_ | Out-String | Add-Content -Path $errorLog }
    })

    # The camera gets its own, much shorter delay than the input panel. The two are not the
    # same bet: opening the panel takes over a corner of the screen and steals the eye, so
    # 1200 ms of "did you mean it" is worth paying, while the button appears to the left of a
    # pet that does not move and covers nothing. The only thing the delay buys here is that
    # a pointer crossing the pet on its way elsewhere does not flash a control at it.
    $script:shotHoverTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:shotHoverTimer.Interval = [TimeSpan]::FromMilliseconds([int]$cfg.shotHoverDelayMs)
    $script:shotHoverTimer.Add_Tick({
        try {
            $script:shotHoverTimer.Stop()
            if (-not $root.IsMouseOver) { return }
            if ([System.Windows.Input.Mouse]::LeftButton -eq [System.Windows.Input.MouseButtonState]::Pressed) { return }
            $shotButton.Visibility = "Visible"
        } catch { $_ | Out-String | Add-Content -Path $errorLog }
    })

    # The button outlives the pointer by several seconds. Hiding it the instant the pointer
    # leaves sounds tidy and is unusable: the button sits OUTSIDE the pet, so reaching it
    # means leaving the pet, and anything that hides on leave hides while being reached for.
    # The transparent PetRow background closes the gap, and this timer covers the rest --
    # overshooting the button, coming back to it, or simply aiming slowly.
    $script:shotHideTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:shotHideTimer.Interval = [TimeSpan]::FromMilliseconds([int]$cfg.shotButtonHideMs)
    $script:shotHideTimer.Add_Tick({
        try {
            $script:shotHideTimer.Stop()
            if ($root.IsMouseOver) { return }
            $shotButton.Visibility = "Collapsed"
        } catch { $_ | Out-String | Add-Content -Path $errorLog }
    })

    $root.Add_MouseEnter({
        try {
            $collapseTimer.Stop()
            $script:shotHideTimer.Stop()
            if ($shotButton.Visibility -ne "Visible") { $script:shotHoverTimer.Stop(); $script:shotHoverTimer.Start() }
            if ($script:collapsed) { $script:hoverTimer.Stop(); $script:hoverTimer.Start() }
        } catch { $_ | Out-String | Add-Content -Path $errorLog }
    })
    $root.Add_MouseLeave({
        try {
            $script:hoverTimer.Stop()
            $script:shotHoverTimer.Stop()
            $script:shotHideTimer.Stop(); $script:shotHideTimer.Start()
            $collapseTimer.Stop(); $collapseTimer.Start()
        } catch { }
    })

    # ------------------------------------------------------------- job parsing
    # Turn one stream-json event into the job's current state.
    function Complete-AppJob($job) {
        if ($job.Done) { return }
        $job.Done = $true
        $job.Ended = Get-Date
        if (-not $job.Sticky) {
            $job.State = 'done'
            $el = [int]((Get-Date) - $job.Started).TotalSeconds
            $job.Detail = "answered in the app " + $SYM_SEP + " " + $el + "s"
        }
    }

    function Update-JobFromEvent($job, $ev) {
        # An app transcript also carries subagent traffic. Those turns end with their own
        # end_turn, which would finish the job while the main answer is still being written.
        if ($ev.isSidechain -eq $true) { return }
        # A transcript keeps growing after the answer lands (the user asks again in the same
        # chat). A finished job must not be rewritten by the next turn's events.
        if ($job.Done) { return }
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
                # A session transcript has no 'result' event -- that one is emitted by the
                # headless CLI only. The turn is over when the assistant stops for the user
                # instead of for a tool, so stop_reason is what ends an app job.
                # The app splits one API response across SEVERAL transcript lines -- the
                # thinking block lands on its own line, the visible text on the next -- and
                # stamps each with that response's stop_reason. So end_turn alone does not
                # mean "the answer is here": the first one carries no text at all. Only an
                # end_turn that actually has text ends the job; a bare one just arms the
                # timeout below, in case a turn really does end without saying anything.
                if ($job.Kind -eq 'app' -and $ev.message.stop_reason -eq 'end_turn') {
                    $txt = ""
                    foreach ($c in $ev.message.content) {
                        if ($c.type -eq 'text' -and -not [string]::IsNullOrWhiteSpace($c.text)) {
                            if ($txt.Length -gt 0) { $txt += "`r`n`r`n" }
                            $txt += [string]$c.text
                        }
                    }
                    if ($txt.Length -gt 0) {
                        $job.Answer = $txt
                        Complete-AppJob $job
                    }
                    elseif (-not $job.EndSeen) {
                        $job.EndSeen = Get-Date
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

    # ------------------------------------------------- app session discovery
    # A prompt handed to the desktop app comes back with no handle at all: the helper only
    # fires a URI. The session it creates is found afterwards, by looking for the store
    # entry that did not exist when the prompt was sent.
    function Find-NewAppSession([datetime]$since) {
        if (-not (Test-Path $sessionStore)) { return $null }
        # A few seconds of slack: the file is stamped when the app writes it, not when the
        # URI fired, and the two clocks are not the same one.
        $cut = $since.AddSeconds(-5)
        $files = @(Get-ChildItem $sessionStore -Recurse -Filter "local_*.json" -ErrorAction SilentlyContinue |
                   Where-Object { $_.LastWriteTime -ge $cut } |
                   Sort-Object LastWriteTime -Descending)
        foreach ($f in $files) {
            try {
                $j = Get-Content $f.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
                if (-not $j.sessionId -or -not $j.cliSessionId -or -not $j.createdAt) { continue }
                $born = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$j.createdAt).LocalDateTime
                if ($born -lt $cut) { continue }   # an old chat that merely got touched
                return $j
            } catch { }
        }
        return $null
    }

    # The transcript lives under a folder named after the session's cwd, with the escaping
    # rules baked into the app. Searching for the file by name skips having to reproduce them.
    function Resolve-Transcript([string]$cliSessionId) {
        if ([string]::IsNullOrWhiteSpace($cliSessionId)) { return $null }
        if (-not (Test-Path $transcriptRoot)) { return $null }
        $hit = Get-ChildItem $transcriptRoot -Recurse -Filter "$cliSessionId.jsonl" -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($hit) { return $hit.FullName }
        return $null
    }

    # Walk an app job from "URI fired" to "reading its transcript". Throttled, because both
    # halves scan directories and the tick runs every 400ms.
    function Attach-AppSession($job) {
        if ((Get-Date) -lt $job.NextProbe) { return }
        $job.NextProbe = (Get-Date).AddMilliseconds(900)

        if (-not $job.LocalId) {
            $s = Find-NewAppSession $job.Started
            if (-not $s) {
                if (((Get-Date) - $job.Started).TotalSeconds -gt 90) {
                    $job.Done = $true
                    $job.Ended = Get-Date
                    $job.State = 'error'
                    $job.Detail = "no new chat appeared in the app"
                }
                return
            }
            $job.LocalId = [string]$s.sessionId
            $job.SessionId = [string]$s.cliSessionId
            $job.Detail = "chat open"
        }
        if (-not $job.OutFile) {
            $t = Resolve-Transcript $job.SessionId
            if ($t) { $job.OutFile = $t; $job.Pos = 0 }
        }
    }

    # Read whatever new complete lines the CLI has flushed since the last tick.
    function Read-JobStream($job) {
        if ([string]::IsNullOrEmpty($job.OutFile)) { return }
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
                if ($job.Kind -eq 'app' -and -not $job.OutFile) { Attach-AppSession $job }
                if ($job.Done) { continue }
                Read-JobStream $job
                # A turn that ended without any visible text would otherwise never finish.
                if (-not $job.Done -and $job.EndSeen -and ((Get-Date) - $job.EndSeen).TotalSeconds -gt 12) {
                    Complete-AppJob $job
                }
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

    # The screenshot rides along as a PATH inside the prompt text, not as an attachment.
    # Neither send path can carry a file: claude:// takes URL parameters, and `claude -p`
    # takes a string on stdin. What is on the other end of both, though, is a Claude with a
    # Read tool and a PNG sitting inside the session's own folder -- so one line of text is
    # the whole delivery mechanism, identical for both paths. That is why adding screenshots
    # did not have to touch either send flow: they still send text.
    #
    # The cost of this choice: the image arrives as a tool read, not as an attachment in the
    # composer, so the user does not see a thumbnail in the chat. See DESIGN.md section 7.
    function Add-ShotLine([string]$text) {
        if (-not $script:shotPath) { return $text }
        return "Attached screenshot (read this image file): " + $script:shotPath + "`r`n`r`n" + $text
    }

    $sendHeadless = {
        try {
            $text = $promptBox.Text.Trim()
            if ($text.Length -eq 0) {
                # An attached screenshot makes an empty box look armed, so say why nothing
                # happened instead of swallowing the keystroke. Through the toast, because
                # a plain Set-Status is overwritten by the next status tick.
                if ($script:shotPath) { Show-Toast "type a prompt to send the screenshot" 2000; Update-StatusLine }
                return
            }
            if (-not (Test-Path $claudeCmd)) { Set-Status 'error' "claude.cmd not found"; return }

            $full = Add-ShotLine $text
            $id  = Get-Date -Format "yyyyMMdd-HHmmss-fff"
            $tmp = Write-PromptFile $full
            $out = Join-Path $jobsDir "$id.jsonl"
            $err = Join-Path $jobsDir "$id.err.txt"
            # The file records what was SENT, screenshot line and all; $job.Prompt keeps the
            # user's own words, because that is what the answer card echoes back as a title.
            Set-Content -Path (Join-Path $jobsDir "$id.prompt.txt") -Value $full -Encoding UTF8

            $proc = Start-Process -FilePath $env:ComSpec `
                -ArgumentList @('/c', "`"$claudeCmd`"", '-p', '--output-format', 'stream-json', '--verbose') `
                -WorkingDirectory $env:USERPROFILE -WindowStyle Hidden -PassThru `
                -RedirectStandardInput $tmp -RedirectStandardOutput $out -RedirectStandardError $err

            $job = @{
                Id = $id; Kind = 'cli'; Proc = $proc; OutFile = $out; ErrFile = $err; Pos = 0
                State = 'run'; Detail = 'queued'; Started = Get-Date; Ended = $null
                Done = $false; Sticky = $false; SessionId = $null; LocalId = $null; EndSeen = $null
                Prompt = $text; Answer = ""; Shown = $false; NextProbe = Get-Date
            }
            [void]$script:jobs.Add($job)
            while ($script:jobs.Count -gt 10) { $script:jobs.RemoveAt(0) }

            $promptBox.Text = ""
            Clear-Shot
            Update-StatusLine
            Start-CollapseIfAway
        }
        catch {
            $_ | Out-String | Add-Content -Path $errorLog
            Set-Status 'error' "launch failed - see error.log"
        }
    }

    # Ctrl+Enter: deliberately go TO the app with this prompt, as a real chat.
    #
    # This one always raises the Claude window, and that is not a defect to fix: every
    # claude:// route navigates the app's main window, and the app exposes no background
    # way to run a prompt. If a window is not wanted, the headless path above is the one
    # that has none -- these are different tools, not two versions of the same one.
    #
    # The prompt travels in the URL. The clipboard + SendKeys dance that used to do this
    # was silently unreliable: without ?folder= the app lands on its folder-picker screen,
    # where the paste and the Enter go nowhere and NO session is ever created. That is
    # exactly the "empty chat" symptom, and it left no trace in any log.
    $sendToApp = {
        try {
            $text = $promptBox.Text.Trim()
            if ($text.Length -eq 0) {
                if ($script:shotPath) { Show-Toast "type a prompt to send the screenshot" 2000; Update-StatusLine; return }
                Start-Process "claude://code/new"; return
            }

            $full = Add-ShotLine $text
            $id = Get-Date -Format "yyyyMMdd-HHmmss-fff"
            Set-Content -Path (Join-Path $jobsDir "$id.prompt.txt") -Value $full -Encoding UTF8

            # The app truncates q at 14336 chars; cutting it here keeps the widget honest
            # about what it actually sent.
            $q = $full
            if ($q.Length -gt 14000) { $q = $q.Substring(0, 14000) }

            # A folder is what makes the app open a real composer instead of its picker.
            $folder = [string]$cfg.sendFolder
            if ([string]::IsNullOrWhiteSpace($folder)) { $folder = $env:USERPROFILE }

            $uri = "claude://code/new?q=" + [Uri]::EscapeDataString($q) +
                   "&folder=" + [Uri]::EscapeDataString($folder)
            Start-Process $uri

            # Started is the cutoff that tells a session created by THIS prompt from the
            # hundreds already in the store, so it is stamped before the app can answer.
            $job = @{
                Id = $id; Kind = 'app'; Proc = $null; OutFile = $null; ErrFile = $null; Pos = 0
                State = 'run'; Detail = 'opening a chat'; Started = Get-Date; Ended = $null
                Done = $false; Sticky = $false; SessionId = $null; LocalId = $null; EndSeen = $null
                Prompt = $text; Answer = ""; Shown = $false; NextProbe = (Get-Date).AddSeconds(2)
            }
            [void]$script:jobs.Add($job)
            while ($script:jobs.Count -gt 10) { $script:jobs.RemoveAt(0) }

            $promptBox.Text = ""
            Clear-Shot
            Update-StatusLine
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
        try {
            # The newest run that has any id at all -- taking LocalId and SessionId from
            # separate jobs would open one chat while showing another one's status.
            $local = $null
            $cli   = $null
            foreach ($j in @($script:jobs)) {
                if ($j.LocalId -or $j.SessionId) { $local = $j.LocalId; $cli = $j.SessionId }
            }
            if (-not (Open-Session $local $cli)) {
                Start-Process "claude://code/continue?session=last"
            }
        }
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
            # A press is either a drag or a click-to-open; neither is a hover, so the
            # pending auto-open is cancelled and the button-up decides what happens.
            $script:hoverTimer.Stop()
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
            $script:hoverTimer.Stop()
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

    # -------------------------------------------------------------- shot wiring
    $shotButton.Add_MouseLeftButtonUp({
        param($s, $e)
        try { $e.Handled = $true; Start-Shot } catch { $_ | Out-String | Add-Content -Path $errorLog }
    })
    $shotChip.Add_MouseLeftButtonUp({
        param($s, $e)
        try { $e.Handled = $true; Clear-Shot } catch { $_ | Out-String | Add-Content -Path $errorLog }
    })

    # ------------------------------------------------------------ card + menu wiring
    $answerClose.Add_MouseLeftButtonUp({
        try { Hide-Answer } catch { $_ | Out-String | Add-Content -Path $errorLog }
    })
    $answerOpen.Add_MouseLeftButtonUp({
        try { [void](Open-Session $script:answerLocalId $script:answerSession) }
        catch { $_ | Out-String | Add-Content -Path $errorLog }
    })

    $menuMinus.Add_MouseLeftButtonUp({ try { Step-Scale -0.05 } catch { } })
    $menuPlus.Add_MouseLeftButtonUp({  try { Step-Scale  0.05 } catch { } })
    $menuInputMinus.Add_MouseLeftButtonUp({ try { Step-InputScale -0.05 } catch { } })
    $menuInputPlus.Add_MouseLeftButtonUp({  try { Step-InputScale  0.05 } catch { } })
    $menuReset.Add_MouseLeftButtonUp({
        try {
            $sc = [System.Windows.SystemParameters]::WorkArea
            $script:anchorRight  = $sc.Right - $margin
            $script:anchorBottom = $sc.Bottom - $margin
            $cfg.anchorRight  = 0
            $cfg.anchorBottom = 0
            Set-Scale 1.0
            Set-InputScale 1.0
            Save-Config
            $menuScale.Text = "100%"
            $menuInputScale.Text = "100%"
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
            # Shift narrows the target to the input panel; without it the whole widget scales.
            $shift = [System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Shift
            if ($shift) {
                Step-InputScale $step
                Show-Toast ("input " + ("{0:n2}" -f [double]$cfg.panelScale)) 1500
            }
            else {
                Set-Scale ([double]$cfg.scale + $step)
                Save-Config
                Show-Toast ("scale " + ("{0:n2}" -f [double]$cfg.scale)) 1500
            }
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
                Clear-Shot           # Esc discards the draft, and the attachment is part of it
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
        Set-InputScale ([double]$cfg.panelScale)
        Set-Collapsed ([bool]$cfg.startCollapsed)
        if (-not $script:collapsed) { $promptBox.Focus() | Out-Null }
    })
    $window.Add_Closed({
        try {
            $timer.Stop(); $collapseTimer.Stop(); $script:hoverTimer.Stop()
            $script:shotHoverTimer.Stop(); $script:shotHideTimer.Stop()
            $script:shotTimer.Stop(); $pet.Stop()
        } catch { }
    })

    $window.ShowDialog() | Out-Null
}
catch {
    $_ | Out-String | Set-Content -Path $errorLog
}
