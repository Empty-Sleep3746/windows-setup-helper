[CmdletBinding()]
param (
    [switch]$Rollback 
)
$RecoveryPartitionSizeMB = 16384
$RecoveryLabel = "Recovery"
$ISOPath = "C:\WINPE\win11-tailscale.iso"
$WinPEFolder = "C:\WinPE_Recovery\media"

$BCDBackupPath = "$env:SystemDrive\BCD_Backup"
$PartitionLayoutBackup = "$env:TEMP\partitionLayout.xml"
$RecoveryStepsLog = "$env:TEMP\RecoverySteps.log"

$usedLetters = (Get-Volume).DriveLetter
$alphabet = [char[]](67..90) # C to Z
$availableLetters = $alphabet | Where-Object { $_ -notin $usedLetters }
$RecoveryDriveLetter = if ($availableLetters.Count -ge 3) {
    "$($availableLetters[-3]):"
}
else {
    throw "Not enough unused drive letters available."
}

if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole] "Administrator")) {
    throw "This script must be run as Administrator."
}

if ($Rollback) {
    try {
        Write-Host "Rollback mode initiated..." -ForegroundColor Yellow

        if (Test-Path "$BCDBackupPath\bcd_backup") {
            bcdedit /import "$BCDBackupPath\bcd_backup"
            Write-Host "BCD configuration restored." -ForegroundColor Green
        }
        else {
            Write-Warning "No BCD backup found."
        }

        if (Test-Path $PartitionLayoutBackup) {
            $layout = Import-Clixml $PartitionLayoutBackup
            Write-Host "Previous partition layout loaded. Manual inspection recommended."
        }
        else {
            Write-Warning "Partition layout backup not found."
        }

        Write-Host "Rollback completed." -ForegroundColor Green
    }
    catch {
        Write-Error "Rollback failed: $_"
    }
    return
}

Start-Transcript -Path "$env:TEMP\RecoverySetup.log" -Force
notepad "$env:TEMP\RecoverySetup.log"
try {
    if (-not (Test-Path $BCDBackupPath)) {
        New-Item -ItemType Directory -Path $BCDBackupPath -Force | Out-Null
    }
    bcdedit /export "$BCDBackupPath\bcd_backup"
    Get-Partition | Select-Object DiskNumber, PartitionNumber, DriveLetter, Size, Type |
    Export-Clixml -Path $PartitionLayoutBackup
    Write-Host "System state backed up."
}
catch {
    Write-Warning "Failed to back up system state: $_"
}

function Shrink-SystemVolume {
    [CmdletBinding()]
    param ([int]$ShrinkSizeMB)

    $osDrive = (Get-CimInstance -ClassName Win32_OperatingSystem).SystemDrive.TrimEnd('\') -replace ':', ''
    $volume = Get-Volume -DriveLetter $osDrive
    $partition = Get-Partition -DriveLetter $osDrive

    if (-not $volume -or -not $partition) {
        throw "System volume not found."
    }

    $supported = Get-PartitionSupportedSize -DriveLetter $osDrive
    $newSize = $volume.Size - ($ShrinkSizeMB * 1MB)

    if ($newSize -lt $supported.SizeMin) {
        throw "Insufficient space to shrink drive $osDrive"
    }

    Resize-Partition -DriveLetter $osDrive -Size $newSize
}

function Create-RecoveryPartition {
    [CmdletBinding()]
    param (
        [int]$SizeMB,
        [string]$Label,
        [string]$DriveLetter
    )

    $Disk = Get-Disk | Where-Object IsBoot -EQ $true
    if ($Disk.Count -gt 1) {
        throw "Multiple bootable disks found."
    }

    $NewPartition = New-Partition -DiskNumber $Disk.Number -GptType '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}' -Size ($SizeMB * 1MB)
    Format-Volume -Partition $NewPartition -FileSystem NTFS -NewFileSystemLabel $Label -Force
    Add-PartitionAccessPath -DiskNumber $Disk.Number -PartitionNumber $NewPartition.PartitionNumber -AccessPath $DriveLetter

    # Return the CIM objects for further processing
    return $Disk, $NewPartition
}

function Set-RecoveryPartitionAttributes {
    [CmdletBinding()]
    param (
        [int]$DiskNumber,
        [int]$PartitionNumber
    )

    $script = @"
select disk $DiskNumber
select partition $PartitionNumber
set id=de94bba4-06d1-4d40-a16a-bfd50179d6ac
gpt attributes=0x8000000000000001
exit
"@
    $tempScript = "$env:TEMP\diskpart.txt"
    $script | Out-File $tempScript -Encoding ascii
    diskpart /s $tempScript | Out-Null
    Remove-Item $tempScript -Force
}

function Copy-RecoveryFiles {
    [CmdletBinding()]
    param (
        [string]$SourceFolder,
        [string]$TargetDrive
    )

    if (-not (Test-Path "$SourceFolder\sources\boot.wim")) {
        throw "Missing boot.wim in $SourceFolder\sources"
    }
    if (-not (Test-Path "$SourceFolder\boot\boot.sdi")) {
        throw "Missing boot.sdi in $SourceFolder\boot"
    }

    New-Item -Path "$TargetDrive\sources" -ItemType Directory -Force | Out-Null
    New-Item -Path "$TargetDrive\boot" -ItemType Directory -Force | Out-Null

    Copy-Item "$SourceFolder\sources\boot.wim" "$TargetDrive\sources" -Force
    Copy-Item "$SourceFolder\boot\boot.sdi" "$TargetDrive\boot" -Force
}

function Copy-IsoToPartition {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$ISOPath,
        [Parameter(Mandatory = $true)][string]$Destination,
        [switch]$UnmountAfter
    )

    if (-not (Test-Path $ISOPath)) {
        throw "ISO file not found: $ISOPath"
    }

    if (-not (Test-Path $Destination)) {
        throw "Destination drive $Destination not found."
    }

    $iso = Mount-DiskImage -ImagePath $ISOPath -PassThru
    Start-Sleep -Seconds 2
    $isoDriveLetter = (Get-Volume -DiskImage $iso).DriveLetter
    if (-not $isoDriveLetter) {
        throw "Failed to get mounted ISO drive letter."
    }

    robocopy "$isoDriveLetter`:\" "$Destination\" /E /COPYALL /R:1 /W:1 #| Out-Null

    if ($UnmountAfter) {
        Dismount-DiskImage -ImagePath $ISOPath
    }
}

function Add-WindowsRamInstallerBootEntry {
    param (
        [Parameter(Mandatory = $true)]
        [string]$InstallerDriveLetter
    )

    # Normalize drive letter
    if ($InstallerDriveLetter.Length -eq 1) {
        $InstallerDriveLetter += ":"
    }

    # Define paths
    $BootWimPath = "\sources\boot.wim"
    $BootSdiPath = "\boot\boot.sdi"
    $BootWimFull = "$InstallerDriveLetter$BootWimPath"
    $BootSdiFull = "$InstallerDriveLetter$BootSdiPath"

    # Check for required files
    if (-not (Test-Path $BootWimFull)) {
        Write-Error "Missing boot.wim at $BootWimFull"
        return $null
    }

    if (-not (Test-Path $BootSdiFull)) {
        Write-Error "Missing boot.sdi at $BootSdiFull"
        return $null
    }

    Write-Host "`nCreating Windows RAM Installer boot entry..."

    # Create BCD entry
    $CreateEntryOut = cmd /c 'bcdedit /create /d "Windows RAM Installer" /application osloader'
    $GUID = ($CreateEntryOut | Where-Object { $_ -match '{.+}' }) -replace '.*({.*}).*', '$1'

    if (-not $GUID) {
        Write-Error "Failed to create BCD entry."
        return $null
    }

    # Clear any existing ramdiskoptions object (optional safety)
    cmd /c 'bcdedit /delete {ramdiskoptions} /f' | Out-Null

    # Create new ramdisk options
    cmd /c 'bcdedit /create {ramdiskoptions} /d "Ramdisk Options"' | Out-Null

    # Set ramdisk options
    cmd /c "bcdedit /set {ramdiskoptions} ramdisksdidevice partition=$InstallerDriveLetter"
    cmd /c "bcdedit /set {ramdiskoptions} ramdisksdipath $BootSdiPath"

    # Set boot entry parameters
    cmd /c "bcdedit /set $GUID device ramdisk=[$InstallerDriveLetter]$BootWimPath,{ramdiskoptions}"
    cmd /c "bcdedit /set $GUID osdevice ramdisk=[$InstallerDriveLetter]$BootWimPath,{ramdiskoptions}"
    cmd /c "bcdedit /set $GUID path \windows\system32\boot\winload.efi"
    cmd /c "bcdedit /set $GUID systemroot \windows"
    cmd /c "bcdedit /set $GUID winpe Yes"
    cmd /c "bcdedit /set $GUID detecthal Yes"
    cmd /c "bcdedit /displayorder $GUID /addlast"
    cmd /c "bcdedit /timeout 5"

    Write-Host "Boot entry 'Windows RAM Installer' created successfully!"
    Write-Host "GUID: $GUID"
    Write-Host "Reboot and select it from the boot menu."

    # Return the GUID
    return $GUID
}


function Create-BootCmd {
    param (
        [Parameter(Mandatory = $true)]
        [string]$DriveLetter,

        [Parameter()]
        [string]$ExistingBootEntryGuid,

        [switch]$RunNow
    )

    # Normalize and validate drive letter
    $DriveLetter = $DriveLetter.TrimEnd(':').ToUpper()
    $volume = Get-Volume -DriveLetter $DriveLetter
    if (-not $volume) {
        Write-Error "Volume with drive letter $DriveLetter not found."
        return
    }

    $ramdiskGuid = "{7619dcc9-fafe-11d9-b411-000476eba25f}"
    $bootEntryID = $null

    # Create new boot entry if not supplied
    if ($ExistingBootEntryGuid) {
        $bootEntryID = $ExistingBootEntryGuid
    } else {
        $cmdOutput = cmd.exe /c 'bcdedit /create /d "Windows Installer" /application osloader'
        $guidMatch = $cmdOutput | Select-String -Pattern '{[0-9a-fA-F\-]+}'
        if ($guidMatch.Matches.Count -gt 0) {
            $bootEntryID = $guidMatch.Matches[0].Value
        } else {
            Write-Error "Failed to extract boot entry GUID from bcdedit output."
            return
        }
    }

    # Generate boot configuration commands
    $script = @"
bcdedit /delete $ramdiskGuid /f
bcdedit /create $ramdiskGuid /d "Ramdisk Options" /application ramdiskoptions
bcdedit /set $bootEntryID device ramdisk=[${DriveLetter}:]\sources\boot.wim,$ramdiskGuid
bcdedit /set $bootEntryID osdevice ramdisk=[${DriveLetter}:]\sources\boot.wim,$ramdiskGuid
bcdedit /set $bootEntryID path \windows\system32\boot\winload.efi
bcdedit /set $bootEntryID systemroot \Windows
bcdedit /set $ramdiskGuid ramdisksdidevice partition=${DriveLetter}:
bcdedit /set $ramdiskGuid ramdisksdipath \boot\boot.sdi
bcdedit /displayorder $bootEntryID /addlast
bcdedit /timeout 5
"@

    # Write script to file
    $tempScript = "$env:TEMP\bootconfig.cmd"
    $script | Out-File $tempScript -Encoding ASCII -Force

    if ($RunNow) {
        Start-Process -FilePath $tempScript -Verb RunAs -Wait
        Remove-Item $tempScript -Force
        Write-Host "Boot configuration applied and script removed."
    } else {
        Write-Host "Boot script created at: $tempScript"
    }

    return $script
}





try {
    Shrink-SystemVolume -ShrinkSizeMB $RecoveryPartitionSizeMB
    $partitionInfo = Create-RecoveryPartition -SizeMB $RecoveryPartitionSizeMB -Label $RecoveryLabel -DriveLetter $RecoveryDriveLetter

    # Extract numeric DiskNumber and PartitionNumber from the returned objects
    $DiskNumber = $partitionInfo[0].Number
    $PartitionNumber = $partitionInfo[1].PartitionNumber
 Copy-IsoToPartition -ISOPath $ISOPath -Destination $RecoveryDriveLetter -UnmountAfter
    set-RecoveryPartitionAttributes -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber
    #Copy-RecoveryFiles -SourceFolder $WinPEFolder -TargetDrive $RecoveryDriveLetter
#    $bootguid = Add-WindowsInstallerBootEntry -DriveLetter $RecoveryDriveLetter

    $bootguid = Add-WindowsRamInstallerBootEntry -InstallerDriveLetter $RecoveryDriveLetter
    $bootguid
    #Create-BootCmd -DriveLetter $RecoveryDriveLetter -RunNow
    #Create-BootCmd -DriveLetter "X"#-RunNow
   

    Write-Host "Recovery partition setup completed successfully." -ForegroundColor Green
}

catch {
    Write-Error "Recovery setup failed: $_"
}
finally {
    Stop-Transcript
}
