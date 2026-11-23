' zen_auto.vbs - roda o vigia sem janela. Usa o proprio diretorio do script.
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "\zen_auto.ps1"" watch", 0, False
