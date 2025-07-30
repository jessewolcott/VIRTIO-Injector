# VirtIO Driver Injector

A PowerShell script that automatically injects VirtIO drivers into Windows disk images (WIM, VHD, VHDX) for virtualization environments like QEMU/KVM, Proxmox, and oVirt.

## 🚀 Features

- **Multi-format Support**: Works with WIM, VHD, and VHDX disk images
- **Automatic Driver Download**: Downloads the latest VirtIO drivers automatically
- **Smart Driver Installation**: Uses appropriate DISM methods for each image type
- **Flexible Commit Options**: Choose to commit, discard, or prompt for changes
- **Comprehensive Error Handling**: Robust cleanup and error recovery
- **Detailed Logging**: Full transcript logging of all operations
- **Unsigned Driver Support**: Optional installation of unsigned drivers

## 📋 Prerequisites

- **Windows 10/11** or **Windows Server 2016+**
- **PowerShell 5.1** (because of DISM)
- **Administrator privileges** (required for DISM operations)
- **Windows ADK Deployment Tools** (auto-installed if missing for WIM files)
- **Internet connection** (for driver download if not provided locally)

## 🛠️ Installation

1. Download the `Inject-VirtioDrivers.ps1` script
2. Place it in your desired directory
3. Run PowerShell as Administrator
4. Execute the script with your parameters

## 📖 Usage

### Basic Usage

#### Simple execution - will prompt for commit decision
```powershell
.\Inject-VirtioDrivers.ps1 SourceDisk "C:\Images\Windows.vhd"
```
### Advanced Usage

#### Auto-commit with unsigned drivers
```powershell
Start-DismDriverAddition -SourceDisk "C:\Images\Windows.vhd" -ForceUnsigned $true -Commit $true
```
#### Use local VirtIO ISO
```powershell
Start-DismDriverAddition -SourceDisk "C:\Images\Windows.wim" -LocalIsoPath "C:\ISOs\virtio-win.iso"
```

#### Auto-discard changes (testing mode)
```powershell
Start-DismDriverAddition -SourceDisk "C:\Images\Windows.vhdx" -Commit $false
```

### Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `SourceDisk` | String | **Required** | Path to the disk image (WIM/VHD/VHDX) |
| `ForceUnsigned` | Boolean | `$false` | Install unsigned drivers (needed for older Windows versions) |
| `LocalIsoPath` | String | `""` | Path to local VirtIO ISO (downloads if empty) |
| `Commit` | Boolean | `$null` | Auto-commit (`$true`), auto-discard (`$false`), or prompt (`$null`) |

## 🎯 What It Does

1. **Mounts your disk image** using the appropriate method:
   - **WIM files**: Uses `Mount-WindowsImage` PowerShell cmdlet
   - **VHD/VHDX files**: Uses `Mount-DiskImage` and assigns drive letters

2. **Downloads VirtIO drivers** (if not provided locally):
   - Downloads from official Fedora VirtIO repository
   - Caches locally for future use
   - Supports custom local ISO files

3. **Installs drivers** using optimal method:
   - **WIM images**: `Add-WindowsDriver` PowerShell cmdlet
   - **VHD/VHDX images**: `dism.exe` with `/Image:` parameter

4. **Handles results intelligently**:
   - ✅ **Exit Code 0**: All drivers installed successfully
   - ⚠️ **Exit Code 50**: Partial success (unsigned drivers skipped - normal behavior)
   - ❌ **Other codes**: Actual errors requiring attention

## 📊 Driver Installation Results

Based on testing with Windows 10/11 images:

- **✅ Successfully Installed**: ~270 drivers (84% success rate)
- **⚠️ Skipped (Unsigned)**: ~50 drivers (older Windows versions: 2k12, 2k12R2, w8, w8.1)
- **🎯 Critical Drivers**: All essential drivers installed (storage, network, display)

### Key Drivers Installed
- **Storage**: `vioscsi`, `viostor` (boot-critical)
- **Network**: `NetKVM` (network connectivity)
- **Display**: `qxl`, `qxldod` (graphics)
- **Input**: `vioinput` (mouse/keyboard)
- **Memory**: `balloon`, `viomem` (memory management)
- **Serial**: `vioserial` (console access)

## 🔧 Configuration

Edit the script variables at the bottom:

```powershell
# Configuration
$SourceDisk = "Z:\YourImage.vhd"     # Path to your disk image
$ForceUnsigned = $false              # Set to $true for unsigned drivers
$LocalIsoPath = ""                   # Path to local ISO or empty for download
$Commit = $true                      # Auto-commit, auto-discard, or prompt
```
## 🚨 Troubleshooting

### Common Issues

**"The parameter is incorrect" errors**
- Ensure you're running as Administrator
- Verify the image file exists and isn't corrupted
- Check that the image contains a valid Windows installation

**Exit Code 50 (Partial Success) - This is Normal!**
- ✅ **This is expected behavior** when `ForceUnsigned=$false`
- 🎯 **270 out of 320 drivers installed successfully** (84% success rate)
- ⚠️ **50 unsigned drivers were skipped** - these are primarily for older Windows versions (2k12, 2k12R2, w8, w8.1)
- 🔑 **All critical drivers were installed**: storage (vioscsi, viostor), network (NetKVM), display (qxl, qxldod)
- 💡 **Use `-ForceUnsigned $true`** only if you specifically need the older/unsigned drivers

**"WIMMount service is missing"**
- Script will auto-install Windows ADK Deployment Tools
- Requires internet connection and Administrator privileges

**"Cannot bind argument to parameter 'Path' because it is an empty string"**
- This occurs when `$PSScriptRoot` is empty (running from console vs saved script)
- Script automatically falls back to `$env:TEMP` directory
- Ensure you have write permissions to the temp directory

**VHD/VHDX mounting issues**
- Verify the VHD/VHDX file isn't corrupted
- Ensure sufficient disk space for temporary copy
- Check that no other process is using the file

**ISO download failures**
- Check internet connectivity
- Verify firewall isn't blocking the download
- Try providing a local ISO path with `-LocalIsoPath` parameter

### Understanding Exit Codes

| Exit Code | Meaning | Action Required |
|-----------|---------|-----------------|
| **0** | ✅ Complete success - all drivers installed | None - perfect result |
| **50** | ⚠️ Partial success - unsigned drivers skipped | **Normal behavior** - critical drivers installed |
| **Other** | ❌ Actual error occurred | Check DISM logs and error messages |

### Log Files

The script creates detailed logs for troubleshooting:
- **Transcript**: `DISM_Driver_Add_Transcript_YYYYMMDD_HHMMSS.txt`
- **DISM Log**: `C:\Windows\Logs\DISM\dism.log`
- **Temp files**: Automatically cleaned up after execution

### Performance Tips

**Speed up execution:**
- Use local VirtIO ISO instead of downloading: `-LocalIsoPath "C:\path\to\virtio-win.iso"`
- Run on SSD storage for faster VHD/VHDX operations
- Ensure adequate RAM (8GB+ recommended for large images)

**Reduce disk usage:**
- VHD/VHDX operations create temporary copies - ensure 2x image size free space
- Temp files are automatically cleaned up on completion

### Advanced Troubleshooting

**Enable verbose DISM logging:**
```powershell
# Add to DISM arguments for more detailed logging
$dismArgs += "/LogLevel:4"
```

## 🤝 Contributing

Contributions are welcome! Please feel free to submit issues, feature requests, or pull requests.

### Reporting Issues

When reporting issues, please include:
- PowerShell version (`$PSVersionTable.PSVersion`)
- Windows version (`Get-ComputerInfo | Select WindowsProductName, WindowsVersion`)
- Image type and size
- Complete error message and exit code
- Relevant log file excerpts from `C:\Windows\Logs\DISM\dism.log`

### Development Guidelines

- Test with multiple image types (WIM, VHD, VHDX)
- Ensure proper cleanup in all error scenarios
- Add comprehensive error handling for new features
- Update documentation for any parameter changes

### Testing Checklist

Before submitting changes, please test:
- [ ] WIM file injection with both signed and unsigned drivers
- [ ] VHD/VHDX file injection with proper temp file cleanup
- [ ] Error scenarios and emergency cleanup procedures
- [ ] Both local ISO and download functionality
- [ ] All commit modes (auto-commit, auto-discard, prompt)

## 📄 License

This project is open source and available under the MIT License. Use at your own risk and ensure you comply with Microsoft's licensing terms for Windows images and DISM tools.

## 🙏 Acknowledgments

- **Red Hat/Fedora** for maintaining the VirtIO drivers repository
- **Microsoft** for DISM and PowerShell tools
- **QEMU/KVM community** for VirtIO driver development

## 📚 Additional Resources

- [Microsoft DISM Documentation](https://docs.microsoft.com/en-us/windows-hardware/manufacture/desktop/dism)
- [VirtIO Drivers Official Repository](https://github.com/virtio-win/virtio-win-pkg-scripts)


## 🔄 Version History

### v1.0.0
- Initial release with WIM, VHD, VHDX support
- Automatic VirtIO driver download
- Flexible commit options
- Comprehensive error handling

---

**⚠️ Important**: Always test with non-production images first. This script modifies disk images and should be used with caution in production environments.

**✅ Success Indicator**: Exit code 50 with 270+ drivers installed is considered successful for most use cases. The unsigned driver warnings are expected and normal behavior.

**🔧 Pro Tip**: For production deployments, consider using `-ForceUnsigned $false` (default) to maintain security best practices, as all critical drivers will still be installed successfully.
