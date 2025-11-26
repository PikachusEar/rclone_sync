# Rclone Browser with Queue Management

A smart rclone download manager with persistent queue, background downloads, and intelligent connection management optimized for PikPak.

## Features

- **Persistent Queue**: Downloads survive script restarts, stored in JSON format
- **Smart Connection Management**: 
  - 1 file in queue → 2 streams for faster single-file download
  - 2+ files in queue → 2 files simultaneously, 1 stream each
  - Never exceeds 2 total connections (PikPak limit)
- **Folder Scanning**: Downloads folders recursively while preserving directory structure
- **Auto-spawn Worker**: Background worker starts automatically, exits when idle
- **Queue Management**: Pause, resume, remove items, retry failed downloads
- **Retry Logic**: Failed downloads retry 3 times before moving to failed list

## Installation

1. **Dependencies**: Ensure `jq` is installed:
   ```bash
   sudo apt install jq
   ```

2. **Place scripts together**: Both scripts must be in the same directory:
   ```bash
   chmod +x rclone_browser.sh rclone_worker.sh
   ```

3. **Configure**: Edit the top of `rclone_browser.sh` to set:
   - `BASE_REMOTE_NAME`: Your rclone remote name (default: "pikpak")
   - `BASE_REMOTE_PATH`: Root folder on cloud (default: "/Sync")
   - `BASE_LOCAL_DIR`: Local download directory (default: "$HOME/pikpak_sync")

## Usage

### Start the Browser
```bash
./rclone_browser.sh
```

### Navigation Commands
| Command | Description |
|---------|-------------|
| `<number>` | Enter folder (e.g., `1` to enter first folder) |
| `b` / `back` | Go up one directory |
| `q` | Quit |

### Download Commands
| Command | Description |
|---------|-------------|
| `d <numbers>` | Download items (e.g., `d 1` or `d 1,3,5`) |
| Works for both files and folders | Folders are scanned recursively |

### Queue Management Commands
| Command | Description |
|---------|-------------|
| `s` / `status` | Show full queue status |
| `p` / `pause` | Pause all downloads |
| `resume` | Resume downloads |

### Status Screen Commands
| Command | Description |
|---------|-------------|
| `r <number>` | Remove item from pending queue |
| `c` / `clear` | Clear entire pending queue |
| `cc` | Clear completed list |
| `cf` | Clear failed list |
| `retry` | Move all failed items back to queue |
| `b` | Back to browser |

## File Locations

| File | Location |
|------|----------|
| Queue File | `~/rclone_log/rclone_queue.json` |
| Log File | `~/rclone_log/rclone_log.log` |
| Worker PID | `~/rclone_log/worker.pid` |
| Downloads | `~/pikpak_sync/` |

## Monitoring

### Watch Live Logs
```bash
tail -f ~/rclone_log/rclone_log.log
```

### Check Queue Status (without opening browser)
```bash
cat ~/rclone_log/rclone_queue.json | jq .
```

### Check if Worker is Running
```bash
cat ~/rclone_log/worker.pid && ps aux | grep rclone_worker
```

## How It Works

### Connection Strategy
```
Queue State          → Strategy
─────────────────────────────────────
1 file pending       → 1 file × 2 streams = 2 connections
2+ files pending     → 2 files × 1 stream = 2 connections
```

### Worker Behavior
1. Worker auto-starts when you add items to queue
2. Processes queue in background
3. Auto-exits after 60 seconds of idle time
4. Respects pause/resume commands

### Retry Logic
- Failed downloads retry up to 3 times
- After 3 failures, moved to "failed" list
- Use `retry` command to move failed items back to queue

## Troubleshooting

### Worker Not Starting
```bash
# Check if worker script is in same directory
ls -la $(dirname $(which rclone_browser.sh))/rclone_worker.sh

# Manually start worker for debugging
bash ~/rclone_worker.sh
```

### Reset Everything
```bash
rm -rf ~/rclone_log/
# Restart browser to reinitialize
```

### Check for Stuck Downloads
```bash
# View downloading items
jq '.downloading' ~/rclone_log/rclone_queue.json

# If stuck, clear downloading array
jq '.downloading = []' ~/rclone_log/rclone_queue.json > /tmp/q.json && mv /tmp/q.json ~/rclone_log/rclone_queue.json
```

## License

Free to use and modify.
