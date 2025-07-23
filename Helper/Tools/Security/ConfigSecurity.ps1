param (
    [Parameter(Mandatory = $true)][string]$NewPassword,   # User-supplied password
    [string]$NewSecret = "1234",                          # Optional default secret
    [string]$NewSalt = "3b194da2",                        # Optional default salt
    [switch]$DisableAccessControl                         # Flag to comment out values
)

# === Logging Setup ===
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$LogPath = Join-Path $ScriptRoot "UpdateBootConfig.log"

function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"
    Write-Host $line
    Add-Content -Path $LogPath -Value $line
}

# === Drive Selection ===
function Select-BootDrive {
    $rel = "sources\boot.wim"

    $drives = @(Get-CimInstance Win32_LogicalDisk | Where-Object {
        $_.DriveType -eq 3 -and (Test-Path (Join-Path "$($_.DeviceID)\" $rel))
    })

    if (-not $drives -or $drives.Count -eq 0) {
        Write-Log "No fixed drives contain '$rel'" "ERROR"
        throw "No fixed drives contain '$rel'"
    }

    if ($drives.Count -eq 1) {
        Write-Log "Auto-selected boot drive: $($drives[0].DeviceID)"
        return "$($drives[0].DeviceID)\"
    }

    try {
        Add-Type -AssemblyName System.Windows.Forms

        $form = New-Object Windows.Forms.Form
        $form.Text = "Select Boot Drive"
        $form.Size = '300,140'
        $form.StartPosition = 'CenterScreen'

        $combo = New-Object Windows.Forms.ComboBox
        $combo.Location = '10,10'
        $combo.Size = '260,20'
        $combo.DropDownStyle = 'DropDownList'
        $combo.Items.AddRange($drives.DeviceID)
        $combo.SelectedIndex = $combo.Items.Count - 1

        $ok = New-Object Windows.Forms.Button
        $ok.Text = "OK"
        $ok.Location = '200,50'
        $ok.Add_Click({ $form.DialogResult = 'OK'; $form.Close() })

        $form.Controls.AddRange(@($combo, $ok))

        if ($form.ShowDialog() -eq 'OK') {
            Write-Log "User selected boot drive: $($combo.SelectedItem)"
            return "$($combo.SelectedItem)\"
        }
    }
    catch {
        Write-Log "GUI selection failed. Falling back to console." "WARN"
        for ($i = 0; $i -lt $drives.Count; $i++) {
            Write-Host "[$($i + 1)] $($drives[$i].DeviceID)"
        }

        do {
            $choice = Read-Host "Select drive [1-$($drives.Count)] (Enter = last)"
            if ([string]::IsNullOrWhiteSpace($choice)) {
                Write-Log "User defaulted to last boot drive: $($drives[-1].DeviceID)"
                return "$($drives[-1].DeviceID)\"
            } elseif ($choice -match '^\d+$' -and $choice -ge 1 -and $choice -le $drives.Count) {
                Write-Log "User selected boot drive: $($drives[$choice - 1].DeviceID)"
                return "$($drives[$choice - 1].DeviceID)\"
            }
        } while ($true)
    }

    Write-Log "Drive selection cancelled or failed." "ERROR"
    throw "Drive selection cancelled or failed."
}

# === Password Hashing ===
function Get-Hash {
    param(
        [string]$Password,
        [string]$Salt
    )

    $combined = $Password + $Salt
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($combined)
    $hashBytes = $sha256.ComputeHash($bytes)
    return -join ($hashBytes | ForEach-Object { $_.ToString("x2") })
}

# === INI Config Update ===
function Update-Line {
    param (
        [string[]]$Lines,
        [string]$Key,
        [string]$NewValue,
        [bool]$CommentOut = $false
    )

    $escapedKey = [Regex]::Escape($Key)

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match "^\s*;?\s*$escapedKey\s*=") {
            $prefix = if ($CommentOut) { ";" } else { "" }
            $Lines[$i] = "$prefix$NewValue"
            return $Lines
        }
    }

    $Lines += if ($CommentOut) { ";$NewValue" } else { $NewValue }
    return $Lines
}

# === DISM Mount/Unmount ===
function Mount-Wim {
    param (
        [string]$BootDrive,
        [string]$MountPath,
        [switch]$Unmount,
        [switch]$Commit
    )

    $wim = Join-Path $BootDrive "sources\boot.wim"

    if ($Unmount) {
        $mode = if ($Commit) { "/Commit" } else { "/Discard" }
        $cmd = "dism /Unmount-Image /MountDir:`"$MountPath`" $mode"
        Write-Log "Unmounting WIM with mode: $mode"
    } else {
        if (-not (Test-Path $MountPath)) {
            New-Item -ItemType Directory -Path $MountPath | Out-Null
        }
        $cmd = "dism /Mount-Image /ImageFile:`"$wim`" /Name:`"Microsoft Windows Setup (x64)`" /MountDir:`"$MountPath`" /Optimize"
        Write-Log "Mounting WIM: $wim to $MountPath"
    }

    Write-Log "Executing DISM command: $cmd"
    $output = Invoke-Expression $cmd 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Log "DISM failed: $output" "ERROR"
        throw "DISM failed with code `n$output"
    } else {
        Write-Log "DISM command succeeded."
    }
}

# === Main Execution ===
try {
    Write-Log "=== Script Started ==="

    $BootDrive = Select-BootDrive
    $MountPath = Join-Path $BootDrive "mount"
    $ConfigPath = Join-Path $MountPath "Helper\Config.ini"

    Mount-Wim -BootDrive $BootDrive -MountPath $MountPath

    if (-not (Test-Path $ConfigPath)) {
        Write-Log "Configuration file not found: $ConfigPath" "ERROR"
        throw "Configuration file not found: $ConfigPath"
    }

    $Lines = Get-Content $ConfigPath

    $Lines = Update-Line $Lines "Secret" "Secret=$NewSecret" $DisableAccessControl
    Write-Log "Updated 'Secret' to '$NewSecret'"

    $Lines = Update-Line $Lines "Salt" "Salt=$NewSalt" $DisableAccessControl
    Write-Log "Updated 'Salt' to '$NewSalt'"

    $Hash = Get-Hash $NewPassword $NewSalt
    Write-Log "Computed Password SHA256 hash: $Hash"

    $Lines = Update-Line $Lines "PasswordSHA256" "PasswordSHA256=$Hash" $DisableAccessControl
    Write-Log "Updated 'PasswordSHA256' in config"

    Set-Content -Path $ConfigPath -Value $Lines
    Write-Log "Configuration saved to $ConfigPath"
    Write-Log "✅ Config updated successfully."
}
catch {
    Write-Log "Unhandled error: $_" "ERROR"
    throw
}
finally {
    try {
        Mount-Wim -BootDrive $BootDrive -MountPath $MountPath -Unmount -Commit
        Write-Log "✅ Unmount complete."
    } catch {
        Write-Log "Failed to unmount WIM: $_" "ERROR"
    }

    Write-Log "=== Script Finished ==="
}
