# Opens a new chat in the Claude desktop app and types the prompt into it.
# Runs as a separate hidden process so the widget UI never blocks.
param(
    [Parameter(Mandatory = $true)][string]$TextFile,
    [string]$Folder = "",
    [int]$SettleMs = 1400,
    [switch]$NoSend
)

$ErrorActionPreference = "Stop"
$log = "$PSScriptRoot\send.log"

function Write-Log([string]$m) {
    "$([DateTime]::Now.ToString('HH:mm:ss'))  $m" | Add-Content -Path $log -Encoding UTF8
}

try {
    Add-Type -AssemblyName System.Windows.Forms

    if (-not (Test-Path $TextFile)) { throw "text file not found: $TextFile" }
    $text = [IO.File]::ReadAllText($TextFile, [Text.Encoding]::UTF8)
    Remove-Item $TextFile -Force -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($text)) { throw "empty prompt" }

    # Remember the clipboard so we can put it back afterwards.
    $oldClip = $null
    try { if ([Windows.Forms.Clipboard]::ContainsText()) { $oldClip = [Windows.Forms.Clipboard]::GetText() } } catch { }

    [Windows.Forms.Clipboard]::SetText($text)

    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class FgWin {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr hWnd, out int pid);
}
"@

    # ?folder= decides which project the new chat runs in. Without it the app reuses
    # whatever folder it had last, which is rarely the one the prompt is about.
    $uri = "claude://code/new"
    if (-not [string]::IsNullOrWhiteSpace($Folder)) {
        $uri += "?folder=" + [Uri]::EscapeDataString($Folder)
    }
    Start-Process $uri

    # Wait until a Claude window is actually in the foreground before typing.
    $deadline = (Get-Date).AddSeconds(30)
    $ready = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
        $h = [FgWin]::GetForegroundWindow()
        if ($h -eq [IntPtr]::Zero) { continue }
        $procId = 0
        [void][FgWin]::GetWindowThreadProcessId($h, [ref]$procId)
        if ($procId -le 0) { continue }
        $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
        if ($null -ne $p -and $p.ProcessName -like 'claude*') { $ready = $true; break }
    }

    if (-not $ready) {
        Write-Log "timeout: Claude window never came to the foreground. Prompt left on the clipboard."
        return
    }

    # Let the new chat finish rendering and focus its composer.
    Start-Sleep -Milliseconds $SettleMs

    [Windows.Forms.SendKeys]::SendWait('^v')
    Start-Sleep -Milliseconds 350
    if (-not $NoSend) {
        [Windows.Forms.SendKeys]::SendWait('{ENTER}')
    }

    Start-Sleep -Milliseconds 600
    try { if ($null -ne $oldClip) { [Windows.Forms.Clipboard]::SetText($oldClip) } } catch { }

    Write-Log "sent ($($text.Length) chars)"
}
catch {
    Write-Log ("ERROR: " + ($_ | Out-String))
}
