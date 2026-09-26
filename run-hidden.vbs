' Hidden launcher: wscript.exe is a GUI-subsystem host (no console of its own) and
' Run(..., 0, ...) starts the child with a hidden window, so a Task Scheduler action
' pointing at this script never flashes a black window.
'
'   wscript.exe //nologo run-hidden.vbs "<script.ps1>" [args...]
'
Option Explicit
Dim sh, i, cmd
Set sh = CreateObject("WScript.Shell")
cmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File"
For i = 0 To WScript.Arguments.Count - 1
  cmd = cmd & " """ & WScript.Arguments(i) & """"
Next
sh.Run cmd, 0, False