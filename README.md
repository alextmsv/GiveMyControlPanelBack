# Give My Control Panel Back

Restore **NVIDIA Control Panel without Microsoft Store**.

## Usage

1. [Download the EXE](https://github.com/alextmsv/GiveMyControlPanelBack/releases/latest).
2. Run it and wait — NVIDIA Control Panel opens automatically.

If the panel is already installed, the tool simply opens it.

## Requirements

- Windows 10 version 1809 or later / Windows 11, **x64**.
- An installed NVIDIA DCH graphics driver.
- Built-in Windows PowerShell and AppX components.
- Internet access and approximately 2 GB of temporary free space.

**No separate .NET installation required.**

## How It Works

The tool downloads an official NVIDIA package, verifies digital signatures, and extracts and installs only the Control Panel. Your graphics driver remains unchanged. Temporary files are cleaned up automatically.

Designed for GTX and RTX systems.
## Build

Requires the .NET 10 SDK and Visual Studio’s **Desktop development with C++** tools.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
```

The executable is generated in `artifacts`.

## Troubleshooting

The latest run log is saved at:

```text
%LOCALAPPDATA%\GiveMyControlPanelBack\last-run.log
```
