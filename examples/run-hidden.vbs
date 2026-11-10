' Hidden launcher for portal_autologin.ps1 (Windows Task Scheduler).
' Expects the script under %APPDATA%\campus-portal-autologin\.
Dim sh, fso, base, cmd
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
base = fso.BuildPath(sh.ExpandEnvironmentStrings("%APPDATA%"), "campus-portal-autologin")
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & _
      fso.BuildPath(base, "portal_autologin.ps1") & """ run -NoProxy"
sh.Run cmd, 0, False
