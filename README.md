# Ollama Status

An Omarchy shell bar widget that shows the Ollama service status and lets you start or stop it from the bar — handy for freeing GPU memory when gaming or doing other GPU-intensive work.

## Features

- **Bar icon** shows Ollama status at a glance: bright when running, dimmed when stopped
- **Dropdown panel** with service details, loaded models, and all available models
- **Start/Stop toggle** switch in the panel header
- **Keyboard shortcuts**: `s` to start, `x` to stop, `r` to refresh
- **Right-click** the bar icon to quickly toggle the service
- **Middle-click** the bar icon to refresh status
- **API health check** with latency display (green <200ms, amber 200-500ms, red >500ms)
- Lists all pulled models with cloud model detection

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
- Service status (running/stopped), uptime, Ollama version, and API latency
- Currently loaded models with size and processor info
- All available (pulled) models, with a dot indicator for loaded ones
- Cloud models (tagged `:cloud`) shown with a ☁ icon

## Start/stop control

Start and stop go through `pkexec`, so the first toggle per session shows a
coloured graphical polkit prompt asking for your password. Omarchy ships a
polkit agent in omarchy-shell, so no extra setup is required. If you cancel
the prompt, the action is simply cancelled.

## Service setup

If Ollama is installed but the systemd service is missing, the panel shows setup instructions. To create and enable the service manually:

```sh
sudo systemctl enable ollama
```

If no unit file is packaged with your Ollama install, create one at `/etc/systemd/system/ollama.service` and then run `sudo systemctl daemon-reload && sudo systemctl enable ollama`.

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
- systemd `ollama.service` for start/stop control
- A polkit authentication agent for start/stop control (included with Omarchy's shell)

## License

MIT