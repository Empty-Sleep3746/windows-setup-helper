#include <GUIConstantsEx.au3>
#include <EditConstants.au3>
#include <WindowsConstants.au3>
#include <ButtonConstants.au3>
#include <MsgBoxConstants.au3>
#include <WinAPIFiles.au3>
#include <Array.au3>

Opt("MustDeclareVars", 1)

Global $hGUI = GUICreate("Configuration Launcher", 300, 180)

GUICtrlCreateLabel("New Password:", 10, 20, 90, 20)
Global $inputPassword = GUICtrlCreateInput("", 110, 20, 150, 20, $ES_PASSWORD)

Global $chkDisable = GUICtrlCreateCheckbox("Disable Access Control", 10, 60, 200, 20)

Global $btnRun = GUICtrlCreateButton("Run", 10, 100, 60, 30)

GUISetState(@SW_SHOW)

While 1
    Switch GUIGetMsg()
        Case $GUI_EVENT_CLOSE
            Exit

        Case $btnRun
            Local $password = GUICtrlRead($inputPassword)
            Local $disable = GUICtrlRead($chkDisable) = $GUI_CHECKED
            Local $disableFlag = $disable ? "-DisableAccessControl" : ""

            Local $scriptPath = @ScriptDir & "\ConfigSecurity.ps1"

            If Not FileExists($scriptPath) Then
                MsgBox($MB_ICONERROR, "Error", "Script not found: " & $scriptPath)
                ContinueLoop
            EndIf

            ; Build command
            Local $cmd = 'powershell.exe -ExecutionPolicy Bypass -File "' & $scriptPath & '" -NewPassword "' & $password & '" ' & $disableFlag

            ; Show feedback popup
            Local $hWaitGUI = GUICreate("Please wait...", 250, 100, -1, -1, BitOR($WS_CAPTION, $WS_POPUPWINDOW))
            GUICtrlCreateLabel("Running configuration...", 50, 30, 160, 20)
            GUISetState(@SW_SHOW, $hWaitGUI)

            ; Run the PowerShell script and wait
            Local $pid = Run($cmd, "", @SW_HIDE, $STDOUT_CHILD + $STDERR_CHILD)

            ; Wait for PowerShell to finish
            ProcessWaitClose($pid)

            ; Close wait window
            GUIDelete($hWaitGUI)

            MsgBox($MB_ICONINFORMATION, "Done", "Configuration completed.")
            Exit
    EndSwitch
WEnd
