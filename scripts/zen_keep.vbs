' zen_keep.vbs - roda o keep sem janela nenhuma.
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""C:\Users\SENAI\zen_keep.ps1""", 0, False
