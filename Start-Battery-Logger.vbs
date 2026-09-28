' Battery Logger V17.4 — Hidden Launcher
Option Explicit
Dim shell, fso, root, ps1, cmd, url, i, ready
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
root = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = fso.BuildPath(root, "BatteryLogger-Companion.ps1")
url = "http://127.0.0.1:8765/"

If Not fso.FileExists(ps1) Then
  MsgBox "BatteryLogger-Companion.ps1 was not found:" & vbCrLf & root, vbCritical, "Battery Logger"
  WScript.Quit 1
End If

' If already running, reuse it; otherwise start PowerShell hidden.
ready = False
On Error Resume Next
Dim http
Set http = CreateObject("WinHttp.WinHttpRequest.5.1")
http.SetTimeouts 500, 500, 500, 500
http.Open "GET", url & "api/status", False
http.Send
If Err.Number = 0 Then
  If http.Status = 200 Then ready = True
End If
Err.Clear
On Error GoTo 0

If Not ready Then
  cmd = "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Chr(34) & ps1 & Chr(34)
  shell.Run cmd, 0, False
  For i = 1 To 30
    WScript.Sleep 500
    On Error Resume Next
    Set http = CreateObject("WinHttp.WinHttpRequest.5.1")
    http.SetTimeouts 500, 500, 500, 500
    http.Open "GET", url & "api/status", False
    http.Send
    If Err.Number = 0 Then
      If http.Status = 200 Then ready = True
    End If
    Err.Clear
    On Error GoTo 0
    If ready Then Exit For
  Next
End If

If ready Then
  shell.Run url, 1, False
Else
  MsgBox "Battery Logger companion did not start. Open BatteryLogger-StartupError.txt in this folder for details, or try Start-Companion.bat to see the error.", vbExclamation, "Battery Logger"
End If

Set http = Nothing
Set fso = Nothing
Set shell = Nothing
