# Ollama Status

An Omarchy shell bar widget that shows the Ollama service status and lets you start or stop it from the bar — handy for freeing GPU memory when gaming or doing other GPU-intensive work.

## Features

- **Bar icon** shows Ollama status at a glance: bright when running, dimmed when stopped
- **Dropdown panel** with service details, loaded models, and all available models
- **Start/Stop toggle** switch in the panel header
- **Keyboard shortcuts**: `s` to start, `x` to stop, `r` to refresh
- **Right-click** the bar icon to quickly toggle the service
- **Middle-click** the bar icon to refresh status
- Lists all pulled models and highlights which are currently loaded in VRAM

## Install

```sh
omarchy plugin add https://github.com/LinuxGamerUK/omarchy-ollama-status.git --enable
```

## Usage

- **Click** the bar icon to open the details panel
- **Toggle switch** or press `Enter` in the panel to start/stop Ollama
- **Right-click** the bar icon to toggle the service without opening the panel
- **Middle-click** the bar icon to refresh status

The panel shows:
- Service status (running/stopped), uptime, and Ollama version
- Currently loaded models (in VRAM) with size and processor info
- All available (pulled) models, with a dot indicator for loaded ones

## Configure

```sh
# Move the widget to a different bar section
omarchy bar move com.github.linuxgameruk.ollama-status --section right

# Change refresh interval (default: 10 seconds)
omarchy bar set com.github.linuxgameruk.ollama-status refreshIntervalSec 30
```

## Remove

```sh
omarchy plugin remove com.github.linuxgameruk.ollama-status
```

## Requirements

- [Ollama](https://ollama.com) installed and on PATH
- systemd `ollama.service` for start/stop control (uses `sudo` for privilege escalation — requires passwordless sudo for systemctl, or configure Polkit for `pkexec`)

## License

MIT