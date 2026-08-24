Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""D:\Document\local\knowledge\network\scripts\auto-optimizer.ps1"" -Action Run", 0, False
