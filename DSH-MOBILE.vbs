Option Explicit
' DSH-MOBILE - silent launcher (no console window).
Dim fso, sh, root, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
root = fso.GetParentFolderName(WScript.ScriptFullName)
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & root & "\scripts\start.ps1"""
sh.Run cmd, 0, False
