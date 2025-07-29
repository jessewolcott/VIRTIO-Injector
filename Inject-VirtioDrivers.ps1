# Function to get an available drive letter
function Get-AvailableDriveLetter {
    $used = (Get-Volume).DriveLetter | Where-Object { $_ }
    for ($letter = [char]'D'; $letter -le [char]'Z'; $letter = [char]([byte]$letter + 1)) {
        if ($used -notcontains $letter) {
            return $letter
        }
    }
    throw "No available drive letters found."
}

# Function to ensure the WimMount driver is installed
function Ensure-WimMountDriver {
    $servicePath = 'HKLM:\SYSTEM\CurrentControlSet\Services\WIMMount'
    if (-not (Test-Path $servicePath)) {
        Write-Host "WIMMount service is missing. Attempting to install Windows ADK Deployment Tools..." -ForegroundColor Yellow

        $adkUrl = "https://go.microsoft.com/fwlink/?linkid=2266288"
        $adkSetupPath = "$env:TEMP\adksetup.exe"
        
        try {
            Invoke-WebRequest -Uri $adkUrl -OutFile $adkSetupPath -ErrorAction Stop
            Start-Process -FilePath $adkSetupPath -ArgumentList "/quiet /features OptionIds.DeploymentTools" -Wait -NoNewWindow
            
            if (Test-Path $servicePath) {
                Write-Host "WIMMount service successfully installed." -ForegroundColor Green
            } else {
                throw "Failed to install WIMMount service."
            }
        } catch {
            throw "Failed to download or install Windows ADK: $_"
        } finally {
            if (Test-Path $adkSetupPath) {
                Remove-Item $adkSetupPath -Force -ErrorAction SilentlyContinue
            }
        }
    } else {
        Write-Host "WIMMount service is already installed." -ForegroundColor Green
    }

    # Clean up stale mounted images registry entries
    $mountedImagesPath = 'HKLM:\SOFTWARE\Microsoft\WIMMount\Mounted Images'
    if (Test-Path $mountedImagesPath) {
        Remove-Item -Path $mountedImagesPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Cleared stale mounted images registry entries." -ForegroundColor Green
    }
}

# Function to verify and mount the image from $SourceDisk
function Mount-ImageFromSource {
    param (
        [Parameter(Mandatory=$true)]
        [string]$SourceDisk,
        [string]$MountPath = "$env:TEMP\WimMount"
    )
    
    if (-not (Test-Path $SourceDisk)) {
        throw "Source file $SourceDisk does not exist."
    }
    
    $extension = [System.IO.Path]::GetExtension($SourceDisk).ToLower()
    $supportedExtensions = @('.wim', '.vhd', '.vhdx')
    if ($extension -notin $supportedExtensions) {
        throw "Unsupported file type: $extension. Supported types are .wim, .vhd, .vhdx."
    }
    
    if ($extension -eq '.wim') {
        Ensure-WimMountDriver
        
        if (-not (Test-Path $MountPath)) {
            New-Item -Path $MountPath -ItemType Directory -Force | Out-Null
        }
        
        try {
            Write-Host "Mounting WIM image..." -ForegroundColor Yellow
            Mount-WindowsImage -ImagePath $SourceDisk -Index 1 -Path $MountPath -ErrorAction Stop
            Write-Host "Successfully mounted WIM $SourceDisk to $MountPath." -ForegroundColor Green
            
            return @{
                Type = 'wim'
                Path = $MountPath
                TempDisk = $null
                Original = $SourceDisk
                DiskNumber = $null
            }
        } catch {
            throw "Failed to mount WIM image: $_"
        }
        
    } elseif ($extension -in @('.vhd', '.vhdx')) {
        $tempDisk = "$env:TEMP\temp_image_$(Get-Date -Format 'yyyyMMdd_HHmmss')$extension"
        
        try {
            Write-Host "Creating temporary copy for VHD/VHDX modifications..." -ForegroundColor Yellow
            Copy-Item -Path $SourceDisk -Destination $tempDisk -ErrorAction Stop
            Write-Host "Created temporary copy at $tempDisk." -ForegroundColor Green
            
            Write-Host "Mounting VHD/VHDX..." -ForegroundColor Yellow
            $mounted = Mount-DiskImage -ImagePath $tempDisk -PassThru -ErrorAction Stop
            $diskNumber = $mounted.Number
            
            Start-Sleep -Seconds 3  # Allow time for disk to be recognized
            
            $partitions = Get-Partition -DiskNumber $diskNumber
            $assignedLetters = @()
            
            foreach ($part in $partitions) {
                if (-not $part.DriveLetter -and $part.Type -ne 'Reserved' -and $part.Size -gt 100MB) {
                    $letter = Get-AvailableDriveLetter
                    Set-Partition -DiskNumber $diskNumber -PartitionNumber $part.PartitionNumber -NewDriveLetter $letter
                    $assignedLetters += $letter
                    Write-Host "Assigned drive letter $letter to partition $($part.PartitionNumber)" -ForegroundColor Cyan
                } elseif ($part.DriveLetter) {
                    $assignedLetters += $part.DriveLetter
                }
            }
            
            # Find Windows installation
            $imagePath = $null
            foreach ($letter in $assignedLetters) {
                $potentialPath = "$letter`:"
                if (Test-Path "$potentialPath\Windows\System32\config\SYSTEM") {
                    $imagePath = $potentialPath
                    break
                }
            }
            
            if (-not $imagePath) {
                throw "No Windows installation found in the mounted VHD/VHDX partitions."
            }
            
            Write-Host "Successfully mounted VHD/VHDX to $imagePath." -ForegroundColor Green
            
            return @{
                Type = 'vhd'
                Path = $imagePath
                TempDisk = $tempDisk
                Original = $SourceDisk
                DiskNumber = $diskNumber
            }
        } catch {
            if (Test-Path $tempDisk) {
                Dismount-DiskImage -ImagePath $tempDisk -ErrorAction SilentlyContinue
                Remove-Item $tempDisk -Force -ErrorAction SilentlyContinue
            }
            throw "Failed to mount VHD/VHDX: $_"
        }
    }
}

# Function to check for virtio-win.iso
function Get-VirtioISO {
    param (
        [string]$ScriptRoot = '',
        [string]$LocalIsoPath = ''
    )
    
    # Handle empty or null ScriptRoot
    if ([string]::IsNullOrWhiteSpace($ScriptRoot)) {
        $ScriptRoot = if ($PSScriptRoot) { 
            $PSScriptRoot 
        } else { 
            $env:TEMP
        }
    }
    
    Write-Host "Using ScriptRoot: $ScriptRoot" -ForegroundColor Green
    
    $isoName = "virtio-win.iso"
    $defaultIsoPath = Join-Path $ScriptRoot $isoName
    
    # If a local ISO path is specified, use it
    if (-not [string]::IsNullOrWhiteSpace($LocalIsoPath)) {
        Write-Host "Local ISO path specified: $LocalIsoPath" -ForegroundColor Yellow
        if (-not (Test-Path $LocalIsoPath)) {
            throw "Provided local ISO path $LocalIsoPath does not exist."
        }
        if ([System.IO.Path]::GetExtension($LocalIsoPath) -ne '.iso') {
            throw "Provided local path $LocalIsoPath is not an ISO file."
        }
        try {
            Copy-Item -Path $LocalIsoPath -Destination $defaultIsoPath -Force -ErrorAction Stop
            Write-Host "Copied provided local ISO to $defaultIsoPath." -ForegroundColor Green
            return $defaultIsoPath
        } catch {
            throw "Failed to copy local ISO: $_"
        }
    }
    
    # No local ISO specified - check if default exists, otherwise download
    if (Test-Path $defaultIsoPath) {
        Write-Host "$isoName already exists at $defaultIsoPath." -ForegroundColor Green
        return $defaultIsoPath
    } else {
        Write-Host "$isoName not found at $defaultIsoPath. Downloading..." -ForegroundColor Yellow
        try {
            $url = "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.271-1/virtio-win.iso"
            
            Write-Host "Downloading from: $url" -ForegroundColor Cyan
            Write-Host "Saving to: $defaultIsoPath" -ForegroundColor Cyan
            
            Invoke-WebRequest -Uri $url -OutFile $defaultIsoPath -ErrorAction Stop
            
            # Verify the file was created and has content
            if (Test-Path $defaultIsoPath) {
                $fileSize = (Get-Item $defaultIsoPath).Length
                Write-Host "Download complete. File size: $($fileSize / 1MB) MB" -ForegroundColor Green
                return $defaultIsoPath
            } else {
                throw "Download appeared to succeed but file was not created at $defaultIsoPath"
            }
        } catch {
            throw "Failed to download virtio-win.iso: $_"
        }
    }
}

# Function to mount the ISO
function Mount-VirtioISO {
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$IsoPath
    )
    
    Write-Host "Attempting to mount ISO: $IsoPath" -ForegroundColor Cyan
    
    # Validate the ISO path exists and is a file
    if (-not (Test-Path $IsoPath)) {
        throw "ISO file does not exist at path: $IsoPath"
    }
    
    $item = Get-Item $IsoPath
    if ($item.PSIsContainer) {
        throw "Path is a directory, not a file: $IsoPath"
    }
    
    if ($item.Extension -ne '.iso') {
        throw "File is not an ISO: $IsoPath"
    }
    
    try {
        Write-Host "Mounting ISO file..." -ForegroundColor Yellow
        $mountedIso = Mount-DiskImage -ImagePath $IsoPath -PassThru -ErrorAction Stop
        Start-Sleep -Seconds 3  # Allow more time for mount
        
        $volume = $mountedIso | Get-Volume
        if (-not $volume -or -not $volume.DriveLetter) {
            throw "Failed to get drive letter for mounted ISO"
        }
        
        $driveLetter = $volume.DriveLetter + ":"
        Write-Host "ISO successfully mounted at $driveLetter." -ForegroundColor Green
        return $driveLetter
    } catch {
        throw "Failed to mount ISO: $_"
    }
}

# Function to add drivers to the image - handles both WIM and VHD/VHDX
function Add-DriversToImage {
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$MountPath,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$DriverSource,
        [bool]$ForceUnsigned = $false,
        [Parameter(Mandatory=$true)]
        [ValidateSet('wim', 'vhd')]
        [string]$ImageType
    )
    
    Write-Host "Adding drivers from $DriverSource to $ImageType image at $MountPath..." -ForegroundColor Yellow
    Write-Host "Force unsigned drivers: $ForceUnsigned" -ForegroundColor Cyan
    
    try {
        if ($ImageType -eq 'wim') {
            # For WIM images, use Add-WindowsDriver PowerShell cmdlet
            Write-Host "Using Add-WindowsDriver for WIM image..." -ForegroundColor Cyan
            Add-WindowsDriver -Path $MountPath -Driver $DriverSource -Recurse -ForceUnsigned:$ForceUnsigned -ErrorAction Stop
            Write-Host "All drivers successfully added to WIM image." -ForegroundColor Green
            
        } elseif ($ImageType -eq 'vhd') {
            # For VHD/VHDX, use DISM.exe directly with /Image parameter
            Write-Host "Using DISM.exe for VHD/VHDX image..." -ForegroundColor Cyan
            
            # Verify Windows directory exists
            $windowsPath = Join-Path $MountPath "Windows"
            if (-not (Test-Path $windowsPath)) {
                throw "Windows directory not found at $windowsPath. This may not be a valid Windows installation."
            }
            
            # Build DISM arguments
            $dismArgs = @(
                "/Image:$MountPath",
                "/Add-Driver",
                "/Driver:$DriverSource",
                "/Recurse"
            )
            
            if ($ForceUnsigned) {
                $dismArgs += "/ForceUnsigned"
            }
            
            Write-Host "Running: dism.exe $($dismArgs -join ' ')" -ForegroundColor Cyan
            
            # Create temp files for output capture
            $outputFile = "$env:TEMP\dism_output_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
            $errorFile = "$env:TEMP\dism_error_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
            
            try {
                $process = Start-Process -FilePath "dism.exe" -ArgumentList $dismArgs -Wait -PassThru -NoNewWindow -RedirectStandardOutput $outputFile -RedirectStandardError $errorFile
                
                # Read and display output
                if (Test-Path $outputFile) {
                    $output = Get-Content $outputFile -Raw
                    if ($output) {
                        Write-Host "DISM Output:" -ForegroundColor Cyan
                        Write-Host $output -ForegroundColor White
                        
                        # Parse output for success/failure counts
                        if ($output -match "Installing (\d+) of (\d+)") {
                            $totalDrivers = $matches[2]
                            Write-Host "Total drivers processed: $totalDrivers" -ForegroundColor Cyan
                        }
                    }
                }
                
                # Handle different exit codes
                switch ($process.ExitCode) {
                    0 { 
                        Write-Host "✅ DISM driver injection completed successfully - all drivers installed." -ForegroundColor Green 
                    }
                    50 { 
                        Write-Host "⚠️  DISM completed with partial success - some unsigned drivers were skipped." -ForegroundColor Yellow
                        Write-Host "   This is normal when ForceUnsigned=false. Critical drivers were likely installed." -ForegroundColor Yellow
                        if (-not $ForceUnsigned) {
                            Write-Host "   💡 Tip: Use -ForceUnsigned `$true to install unsigned drivers if needed." -ForegroundColor Cyan
                        }
                    }
                    default {
                        $errorContent = ""
                        if (Test-Path $errorFile) {
                            $errorContent = Get-Content $errorFile -Raw
                        }
                        throw "DISM failed with exit code: $($process.ExitCode). Error: $errorContent"
                    }
                }
            } finally {
                # Clean up temp files
                Remove-Item $outputFile -ErrorAction SilentlyContinue
                Remove-Item $errorFile -ErrorAction SilentlyContinue
            }
        }
    } catch {
        throw "Failed to add drivers: $_"
    }
}


# Function to handle cleanup and commit
function Complete-ImageProcessing {
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$MountInfo,
        [string]$IsoPath,
        [bool]$Commit = $null  # $null = prompt user, $true = auto-commit, $false = auto-discard
    )
    
    $transcriptFile = "DISM_Driver_Add_Transcript_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
    Start-Transcript -Path $transcriptFile
    
    Write-Host "`n=== Driver Addition Process Completed ===" -ForegroundColor Green
    Write-Host "Image Type: $($MountInfo.Type)" -ForegroundColor Cyan
    Write-Host "Mount Path: $($MountInfo.Path)" -ForegroundColor Cyan
    
    # Dismount ISO first
    if ($IsoPath -and (Get-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue).Attached) {
        Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue
        Write-Host "ISO dismounted." -ForegroundColor Green
    }
    
    # Determine commit action
    $commitAction = $false
    if ($Commit -eq $null) {
        # Prompt user for decision
        do {
            Write-Host "`nWould you like to commit the changes? (Y/N): " -ForegroundColor Yellow -NoNewline
            $response = Read-Host
        } while ($response -notin @('Y', 'y', 'N', 'n'))
        
        $commitAction = ($response -eq 'Y' -or $response -eq 'y')
    } else {
        # Use the provided parameter value
        $commitAction = $Commit
        if ($commitAction) {
            Write-Host "`nAuto-committing changes (Commit parameter = True)..." -ForegroundColor Green
        } else {
            Write-Host "`nAuto-discarding changes (Commit parameter = False)..." -ForegroundColor Yellow
        }
    }
    
    try {
        if ($MountInfo.Type -eq 'wim') {
            if ($commitAction) {
                Write-Host "Committing changes to WIM image..." -ForegroundColor Yellow
                Dismount-WindowsImage -Path $MountInfo.Path -Save
                Write-Host "✅ Changes committed and WIM image unmounted." -ForegroundColor Green
            } else {
                Write-Host "Discarding changes to WIM image..." -ForegroundColor Yellow
                Dismount-WindowsImage -Path $MountInfo.Path -Discard
                Write-Host "❌ Changes discarded and WIM image unmounted." -ForegroundColor Yellow
            }
        } elseif ($MountInfo.Type -eq 'vhd') {
            Write-Host "Dismounting VHD/VHDX..." -ForegroundColor Yellow
            Dismount-DiskImage -ImagePath $MountInfo.TempDisk
            
            if ($commitAction) {
                Write-Host "Committing changes by replacing original image..." -ForegroundColor Yellow
                Copy-Item -Path $MountInfo.TempDisk -Destination $MountInfo.Original -Force
                Write-Host "✅ Changes committed by replacing original with modified image." -ForegroundColor Green
            } else {
                Write-Host "❌ Changes discarded." -ForegroundColor Yellow
            }
            
            # Clean up temp file
            Remove-Item $MountInfo.TempDisk -Force
            Write-Host "Temporary file cleaned up." -ForegroundColor Green
        }
    } catch {
        Write-Error "Error during cleanup: $_"
    } finally {
        Stop-Transcript
        Write-Host "Transcript saved to $transcriptFile." -ForegroundColor Cyan
    }
}


# Main orchestration function
function Start-DismDriverAddition {
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$SourceDisk,
        [bool]$ForceUnsigned = $false,
        [string]$LocalIsoPath = '',
        [bool]$Commit = $null  # $null = prompt, $true = auto-commit, $false = auto-discard
    )
    
    $mountInfo = $null
    $isoPath = $null
    $driverSource = $null
    
    try {
        Write-Host "=== Starting DISM Driver Addition Process ===" -ForegroundColor Green
        Write-Host "Source disk: $SourceDisk" -ForegroundColor Cyan
        Write-Host "Force unsigned: $ForceUnsigned" -ForegroundColor Cyan
        Write-Host "Local ISO path: '$LocalIsoPath'" -ForegroundColor Cyan
        Write-Host "Commit mode: $(if ($Commit -eq $null) { 'Prompt User' } elseif ($Commit) { 'Auto-Commit' } else { 'Auto-Discard' })" -ForegroundColor Cyan
        
        # Mount the source image
        Write-Host "`n--- Mounting Source Image ---" -ForegroundColor Magenta
        $mountInfo = Mount-ImageFromSource -SourceDisk $SourceDisk
        
        # Get the virtio ISO
        Write-Host "`n--- Getting VirtIO ISO ---" -ForegroundColor Magenta
        $isoPath = Get-VirtioISO -LocalIsoPath $LocalIsoPath
        
        # Validate isoPath is a string
        if (-not $isoPath -or $isoPath -isnot [string]) {
            throw "Get-VirtioISO did not return a valid string path. Returned: $($isoPath.GetType().Name)"
        }
        
        # Mount the ISO
        Write-Host "`n--- Mounting VirtIO ISO ---" -ForegroundColor Magenta
        $driverSource = Mount-VirtioISO -IsoPath $isoPath
        
        # Add drivers
        Write-Host "`n--- Adding Drivers ---" -ForegroundColor Magenta
        Add-DriversToImage -MountPath $mountInfo.Path -DriverSource $driverSource -ForceUnsigned $ForceUnsigned -ImageType $mountInfo.Type
        
        # Complete processing with commit parameter
        Write-Host "`n--- Completing Process ---" -ForegroundColor Magenta
        Complete-ImageProcessing -MountInfo $mountInfo -IsoPath $isoPath -Commit $Commit
        
    } catch {
        Write-Error "Process failed: $_"
        Write-Host "Error details: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Error at line: $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Red
        
        # Emergency cleanup (same as before)
        if ($driverSource -and $isoPath) {
            try {
                if ((Get-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue).Attached) {
                    Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue
                    Write-Host "Emergency: ISO dismounted" -ForegroundColor Yellow
                }
            } catch {
                Write-Host "Emergency cleanup warning: Could not dismount ISO" -ForegroundColor Red
            }
        }
        
        if ($mountInfo) {
            try {
                if ($mountInfo.Type -eq 'wim' -and (Test-Path $mountInfo.Path)) {
                    Dismount-WindowsImage -Path $mountInfo.Path -Discard -ErrorAction SilentlyContinue
                    Write-Host "Emergency: WIM dismounted" -ForegroundColor Yellow
                } elseif ($mountInfo.Type -eq 'vhd' -and $mountInfo.TempDisk) {
                    Dismount-DiskImage -ImagePath $mountInfo.TempDisk -ErrorAction SilentlyContinue
                    Remove-Item $mountInfo.TempDisk -Force -ErrorAction SilentlyContinue
                    Write-Host "Emergency: VHD dismounted and temp file removed" -ForegroundColor Yellow
                }
            } catch {
                Write-Host "Emergency cleanup warning: Could not clean up mounted image" -ForegroundColor Red
            }
        }
        
        throw
    }
}


# Usage examples and parameter setup
$SourceDisk = "Z:\DFS.vhd"
$ForceUnsigned = $false
$LocalIsoPath = ""
$Commit = $true  # Add this line for auto-commit

# Run the main function
Start-DismDriverAddition -SourceDisk $SourceDisk -ForceUnsigned $ForceUnsigned -LocalIsoPath $LocalIsoPath -Commit $Commit

