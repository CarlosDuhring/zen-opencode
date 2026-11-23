' zen_auto.vbs - roda o vigia sem janela nenhuma.
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""C:\Users\SENAI\zen_auto.ps1"" watch", 0, False
