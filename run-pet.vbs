' Starts the widget with no console window at all (wscript -> powershell hidden).
Dim sh, dir
Set sh = CreateObject("WScript.Shell")
dir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File """ & dir & "pet-icon.ps1""", 0, False
