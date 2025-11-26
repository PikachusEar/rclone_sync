#!/bin/bash

# =============================================================================
# Rclone Browser with Queue Management
# =============================================================================

# --- CONFIGURATION ---
BASE_REMOTE_NAME="pikpak"
BASE_REMOTE_PATH="/Sync"
BASE_LOCAL_DIR="$HOME/pikpak_sync"
LOG_DIR="$HOME/rclone_log"
LOG_FILE="$LOG_DIR/rclone_log.log"
QUEUE_FILE="$LOG_DIR/rclone_queue.json"
WORKER_PID_FILE="$LOG_DIR/worker.pid"
WORKER_SCRIPT="$(dirname "$(realpath "$0")")/rclone_worker.sh"
SIZE_THRESHOLD=$((2 * 1024 * 1024 * 1024))  # 2GB in bytes

# Colors
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BLUE='\033[1;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# Track current path
SUBPATH=""

# =============================================================================
# INITIALIZATION
# =============================================================================

init_environment() {
    mkdir -p "$LOG_DIR"
    mkdir -p "$BASE_LOCAL_DIR"
    
    # Initialize queue file if it doesn't exist
    if [[ ! -f "$QUEUE_FILE" ]]; then
        echo '{"pending":[],"downloading":[],"completed":[],"failed":[],"paused":false}' > "$QUEUE_FILE"
    fi
    
    # Check for jq dependency
    if ! command -v jq &> /dev/null; then
        echo -e "${RED}Error: 'jq' is required but not installed.${NC}"
        echo "Install it with: sudo apt install jq"
        exit 1
    fi
    
    # Recover any stuck downloading items (from previous crash)
    local downloading_count=$(jq '.downloading | length' "$QUEUE_FILE" 2>/dev/null || echo "0")
    if [[ $downloading_count -gt 0 ]]; then
        echo -e "${YELLOW}Recovering $downloading_count stuck download(s)...${NC}"
        recover_downloading
    fi
}

# =============================================================================
# FILE LOCKING
# =============================================================================

LOCK_FILE="$LOG_DIR/queue.lock"

queue_locked() {
    # Execute a command with exclusive lock on queue
    (
        flock -x 200
        eval "$@"
    ) 200>"$LOCK_FILE"
}

# =============================================================================
# QUEUE MANAGEMENT FUNCTIONS
# =============================================================================

get_queue() {
    cat "$QUEUE_FILE"
}

get_pending_count() {
    jq '.pending | length' "$QUEUE_FILE"
}

get_downloading_count() {
    jq '.downloading | length' "$QUEUE_FILE"
}

is_paused() {
    jq -r '.paused' "$QUEUE_FILE"
}

add_to_queue() {
    local remote_path="$1"
    local local_path="$2"
    local size="$3"
    local filename="$4"
    local timestamp=$(date -Iseconds)
    local id=$(date +%s%N | md5sum | head -c 8)
    
    queue_locked "
        tmp_file=\$(mktemp)
        jq --arg id '$id' \
           --arg remote '$remote_path' \
           --arg local '$local_path' \
           --arg size '$size' \
           --arg name '$filename' \
           --arg ts '$timestamp' \
           '.pending += [{
               \"id\": \$id,
               \"remote_path\": \$remote,
               \"local_path\": \$local,
               \"size\": (\$size | tonumber),
               \"filename\": \$name,
               \"added_at\": \$ts,
               \"retries\": 0
           }]' '$QUEUE_FILE' > \"\$tmp_file\" && mv \"\$tmp_file\" '$QUEUE_FILE'
    "
}

remove_from_queue() {
    local index=$1
    queue_locked "
        tmp_file=\$(mktemp)
        jq --argjson idx '$index' 'del(.pending[\$idx])' '$QUEUE_FILE' > \"\$tmp_file\" && mv \"\$tmp_file\" '$QUEUE_FILE'
    "
}

clear_pending_queue() {
    queue_locked "
        tmp_file=\$(mktemp)
        jq '.pending = []' '$QUEUE_FILE' > \"\$tmp_file\" && mv \"\$tmp_file\" '$QUEUE_FILE'
    "
}

set_paused() {
    local state=$1
    queue_locked "
        tmp_file=\$(mktemp)
        jq --argjson paused '$state' '.paused = \$paused' '$QUEUE_FILE' > \"\$tmp_file\" && mv \"\$tmp_file\" '$QUEUE_FILE'
    "
}

clear_completed() {
    queue_locked "
        tmp_file=\$(mktemp)
        jq '.completed = []' '$QUEUE_FILE' > \"\$tmp_file\" && mv \"\$tmp_file\" '$QUEUE_FILE'
    "
}

clear_failed() {
    queue_locked "
        tmp_file=\$(mktemp)
        jq '.failed = []' '$QUEUE_FILE' > \"\$tmp_file\" && mv \"\$tmp_file\" '$QUEUE_FILE'
    "
}

retry_failed() {
    queue_locked "
        tmp_file=\$(mktemp)
        jq '.pending += [.failed[] | .retries = 0] | .failed = []' '$QUEUE_FILE' > \"\$tmp_file\" && mv \"\$tmp_file\" '$QUEUE_FILE'
    "
}

recover_downloading() {
    # Move any stuck downloading items back to pending
    queue_locked "
        tmp_file=\$(mktemp)
        jq '.pending = .downloading + .pending | .downloading = []' '$QUEUE_FILE' > \"\$tmp_file\" && mv \"\$tmp_file\" '$QUEUE_FILE'
    "
}

# =============================================================================
# WORKER MANAGEMENT
# =============================================================================

is_worker_running() {
    [[ -f "$WORKER_PID_FILE" ]] || return 1
    local pid
    pid=$(cat "$WORKER_PID_FILE" 2>/dev/null || echo "")
    [[ -n "$pid" && -d "/proc/$pid" ]]
}

start_worker() {
    if is_worker_running; then
        return 0
    fi
    
    if [[ ! -f "$WORKER_SCRIPT" ]]; then
        echo -e "${RED}Error: Worker script not found at $WORKER_SCRIPT${NC}"
        return 1
    fi
    
    nohup bash "$WORKER_SCRIPT" >> "$LOG_FILE" 2>&1 &
    echo $! > "$WORKER_PID_FILE"
    echo -e "${GREEN}Worker started (PID: $!)${NC}"
}

stop_worker() {
    if [[ -f "$WORKER_PID_FILE" ]]; then
        local pid=$(cat "$WORKER_PID_FILE")
        if [[ -n "$pid" && -d "/proc/$pid" ]]; then
            kill "$pid" 2>/dev/null
            echo -e "${YELLOW}Worker stopped.${NC}"
        fi
        rm -f "$WORKER_PID_FILE"
    fi
}

# =============================================================================
# FILE SIZE & SCANNING
# =============================================================================

get_file_size() {
    local remote_path="$1"
    rclone size "$remote_path" --json 2>/dev/null | jq -r '.bytes // 0'
}

get_file_info() {
    local remote_path="$1"
    rclone lsjson "$remote_path" 2>/dev/null
}

scan_and_queue_folder() {
    local remote_folder="$1"
    local relative_path="$2"
    
    echo -e "${CYAN}Scanning folder contents...${NC}"
    
    # Get all files recursively with sizes
    local files_json=$(rclone lsjson "$remote_folder" --recursive --files-only 2>/dev/null)
    
    if [[ -z "$files_json" || "$files_json" == "[]" ]]; then
        echo -e "${YELLOW}No files found in folder.${NC}"
        return
    fi
    
    local count=0
    while IFS= read -r file_info; do
        local file_path=$(echo "$file_info" | jq -r '.Path')
        local file_size=$(echo "$file_info" | jq -r '.Size')
        local file_name=$(basename "$file_path")
        
        local full_remote="${remote_folder}/${file_path}"
        local full_local="${BASE_LOCAL_DIR}${relative_path}/${file_path}"
        
        add_to_queue "$full_remote" "$full_local" "$file_size" "$file_name"
        ((count++))
        echo -e "  Queued: ${file_path} ($(format_size $file_size))"
    done < <(echo "$files_json" | jq -c '.[]')
    
    echo -e "${GREEN}Added $count files to queue.${NC}"
}

queue_single_file() {
    local remote_path="$1"
    local local_path="$2"
    local filename="$3"
    
    echo -e "${CYAN}Getting file info...${NC}"
    local file_info=$(rclone lsjson "$remote_path" 2>/dev/null | jq -c '.[0] // empty')
    
    if [[ -z "$file_info" ]]; then
        echo -e "${RED}Error: Could not get file info.${NC}"
        return 1
    fi
    
    local file_size=$(echo "$file_info" | jq -r '.Size')
    add_to_queue "$remote_path" "$local_path" "$file_size" "$filename"
    echo -e "${GREEN}Queued: $filename ($(format_size $file_size))${NC}"
}

# =============================================================================
# DISPLAY FUNCTIONS
# =============================================================================

format_size() {
    local bytes=$1
    if [[ $bytes -ge 1073741824 ]]; then
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1073741824}")GB"
    elif [[ $bytes -ge 1048576 ]]; then
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1048576}")MB"
    elif [[ $bytes -ge 1024 ]]; then
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1024}")KB"
    else
        echo "${bytes}B"
    fi
}

show_status() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}              ${BOLD}RCLONE DOWNLOAD QUEUE STATUS${NC}                        ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    local queue=$(get_queue)
    local paused=$(echo "$queue" | jq -r '.paused')
    local pending=$(echo "$queue" | jq '.pending | length')
    local downloading=$(echo "$queue" | jq '.downloading | length')
    local completed=$(echo "$queue" | jq '.completed | length')
    local failed=$(echo "$queue" | jq '.failed | length')
    
    # Worker status
    if is_worker_running; then
        echo -e "Worker Status: ${GREEN}● RUNNING${NC}"
    else
        echo -e "Worker Status: ${RED}● STOPPED${NC}"
    fi
    
    if [[ "$paused" == "true" ]]; then
        echo -e "Queue Status:  ${YELLOW}● PAUSED${NC}"
    else
        echo -e "Queue Status:  ${GREEN}● ACTIVE${NC}"
    fi
    echo ""
    
    # Summary
    echo -e "${BOLD}Summary:${NC}"
    echo -e "  Pending:     ${YELLOW}$pending${NC}"
    echo -e "  Downloading: ${CYAN}$downloading${NC}"
    echo -e "  Completed:   ${GREEN}$completed${NC}"
    echo -e "  Failed:      ${RED}$failed${NC}"
    echo ""
    
    # Currently downloading
    if [[ $downloading -gt 0 ]]; then
        echo -e "${BOLD}${CYAN}Currently Downloading:${NC}"
        echo "$queue" | jq -r '.downloading[] | "  ► \(.filename) (\(.size | tonumber | . / 1048576 | floor)MB)"'
        echo ""
    fi
    
    # Pending queue
    if [[ $pending -gt 0 ]]; then
        echo -e "${BOLD}${YELLOW}Pending Queue:${NC}"
        local idx=1
        echo "$queue" | jq -r '.pending[] | "\(.filename)|\(.size)"' | while IFS='|' read -r name size; do
            local size_fmt=$(format_size $size)
            echo -e "  ${GREEN}[$idx]${NC} $name ($size_fmt)"
            ((idx++))
        done
        echo ""
    fi
    
    # Failed items
    if [[ $failed -gt 0 ]]; then
        echo -e "${BOLD}${RED}Failed:${NC}"
        echo "$queue" | jq -r '.failed[] | "  ✗ \(.filename) (retries: \(.retries))"'
        echo ""
    fi
    
    # Recent completed (last 5)
    if [[ $completed -gt 0 ]]; then
        echo -e "${BOLD}${GREEN}Recently Completed (last 5):${NC}"
        echo "$queue" | jq -r '.completed | .[-5:] | .[] | "  ✓ \(.filename)"'
        echo ""
    fi
    
    echo -e "${CYAN}───────────────────────────────────────────────────────────────────${NC}"
    echo -e "Commands: ${GREEN}r <num>${NC} remove pending | ${YELLOW}c${NC} clear pending | ${MAGENTA}retry${NC} retry failed"
    echo -e "          ${YELLOW}p${NC} pause | ${GREEN}resume${NC} | ${CYAN}cc${NC} clear completed | ${RED}b${NC} back"
    echo -e "Download: ${RED}kd${NC} kill & delete | ${YELLOW}kp${NC} kill & re-queue | ${MAGENTA}ka${NC} kill all"
    echo ""
    read -p "Action: " status_input
    
    case "$status_input" in
        r\ *)
            local num=${status_input#r }
            num=$(echo "$num" | xargs)
            if [[ "$num" =~ ^[0-9]+$ ]]; then
                local idx=$((num - 1))
                remove_from_queue $idx
                echo -e "${GREEN}Item removed from queue.${NC}"
                sleep 1
                show_status
            fi
            ;;
        c|clear)
            clear_pending_queue
            echo -e "${GREEN}Pending queue cleared.${NC}"
            sleep 1
            show_status
            ;;
        cc)
            clear_completed
            echo -e "${GREEN}Completed list cleared.${NC}"
            sleep 1
            show_status
            ;;
        cf)
            clear_failed
            echo -e "${GREEN}Failed list cleared.${NC}"
            sleep 1
            show_status
            ;;
        retry)
            retry_failed
            echo -e "${GREEN}Failed items moved back to queue.${NC}"
            if [[ $(is_paused) != "true" ]]; then
                start_worker
            fi
            sleep 1
            show_status
            ;;
        p|pause)
            set_paused true
            echo -e "${YELLOW}Queue paused.${NC}"
            sleep 1
            show_status
            ;;
        resume)
            set_paused false
            echo -e "${GREEN}Queue resumed.${NC}"
            start_worker
            sleep 1
            show_status
            ;;
        b|back|q)
            return
            ;;
        kd)
            # Kill downloads and delete from queue
            pkill -f "rclone copy" 2>/dev/null
            queue_locked "
                tmp_file=\$(mktemp)
                jq '.downloading = []' '$QUEUE_FILE' > \"\$tmp_file\" && mv \"\$tmp_file\" '$QUEUE_FILE'
            "
            echo -e "${RED}Downloads killed and removed from queue.${NC}"
            sleep 1
            show_status
            ;;
        kp)
            # Kill downloads and move back to pending
            pkill -f "rclone copy" 2>/dev/null
            queue_locked "
                tmp_file=\$(mktemp)
                jq '.pending = .downloading + .pending | .downloading = []' '$QUEUE_FILE' > \"\$tmp_file\" && mv \"\$tmp_file\" '$QUEUE_FILE'
            "
            echo -e "${YELLOW}Downloads killed and moved back to pending queue.${NC}"
            sleep 1
            show_status
            ;;
        ka)
            # Kill all (worker + rclone) and pause
            pkill -f "rclone_worker.sh" 2>/dev/null
            pkill -f "rclone copy" 2>/dev/null
            rm -f "$WORKER_PID_FILE"
            queue_locked "
                tmp_file=\$(mktemp)
                jq '.pending = .downloading + .pending | .downloading = [] | .paused = true' '$QUEUE_FILE' > \"\$tmp_file\" && mv \"\$tmp_file\" '$QUEUE_FILE'
            "
            echo -e "${RED}All downloads killed, queue paused.${NC}"
            echo -e "Use ${GREEN}resume${NC} to restart."
            sleep 2
            show_status
            ;;
        *)
            show_status
            ;;
    esac
}

show_browser() {
    clear
    CURRENT_REMOTE="${BASE_REMOTE_NAME}:${BASE_REMOTE_PATH}${SUBPATH}"
    CURRENT_LOCAL="${BASE_LOCAL_DIR}${SUBPATH}"
    
    mkdir -p "$CURRENT_LOCAL"
    
    # Header
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}                    ${BOLD}RCLONE FILE BROWSER${NC}                           ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo -e "Location: ${YELLOW}${BASE_REMOTE_PATH}${SUBPATH:-/}${NC}"
    
    # Queue status mini
    local pending=$(get_pending_count)
    local downloading=$(get_downloading_count)
    if [[ $pending -gt 0 || $downloading -gt 0 ]]; then
        echo -e "Queue: ${CYAN}$downloading downloading${NC} | ${YELLOW}$pending pending${NC}"
    fi
    echo -e "${CYAN}───────────────────────────────────────────────────────────────────${NC}"
    
    # Fetch file list
    if ! mapfile -t FILE_LIST < <(rclone lsf "$CURRENT_REMOTE" 2>/dev/null); then
        echo -e "${RED}Error reading remote path.${NC}"
        sleep 2
        return
    fi
    
    if [[ ${#FILE_LIST[@]} -eq 0 ]]; then
        echo -e "${RED}(Empty Folder)${NC}"
    fi
    
    # Display files
    local count=1
    for file in "${FILE_LIST[@]}"; do
        if [[ "$file" == */ ]]; then
            echo -e "${GREEN}[$count]${NC} ${BLUE}📁 ${file}${NC}"
        else
            echo -e "${GREEN}[$count]${NC} 📄 $file"
        fi
        ((count++))
    done
    
    echo -e "${CYAN}───────────────────────────────────────────────────────────────────${NC}"
    echo -e "NAVIGATION:  ${GREEN}<number>${NC} enter folder | ${YELLOW}b${NC} back | ${RED}q${NC} quit"
    echo -e "DOWNLOAD:    ${CYAN}d <numbers>${NC} download (e.g., 'd 1,3,5' or 'd 2')"
    echo -e "QUEUE:       ${MAGENTA}s${NC} status | ${YELLOW}p${NC} pause | ${GREEN}resume${NC}"
    echo ""
    read -p "Action: " INPUT
    
    args=($INPUT)
    cmd="${args[0]}"
    params="${INPUT#$cmd}"
    params="$(echo -e "${params}" | sed -e 's/^[[:space:]]*//')"
    
    # Navigation - number
    if [[ "$cmd" =~ ^[0-9]+$ ]]; then
        local idx=$((cmd - 1))
        local selected="${FILE_LIST[$idx]}"
        
        if [[ -z "$selected" ]]; then
            echo -e "${RED}Invalid number.${NC}"
            sleep 1
            return
        fi
        
        if [[ "$selected" == */ ]]; then
            local dir_name="${selected%/}"
            SUBPATH="${SUBPATH}/${dir_name}"
        else
            echo -e "${RED}That is a file, not a folder.${NC}"
            echo -e "To download it, type: ${CYAN}d $cmd${NC}"
            sleep 2
        fi
        return
    fi
    
    # Back
    if [[ "$cmd" == "b" || "$cmd" == "back" || "$cmd" == ".." ]]; then
        if [[ -z "$SUBPATH" ]]; then
            echo "Already at root."
            sleep 1
        else
            SUBPATH=$(dirname "$SUBPATH")
            if [[ "$SUBPATH" == "." || "$SUBPATH" == "/" ]]; then
                SUBPATH=""
            fi
        fi
        return
    fi
    
    # Quit
    if [[ "$cmd" == "q" || "$cmd" == "exit" ]]; then
        echo "Exiting."
        exit 0
    fi
    
    # Status
    if [[ "$cmd" == "s" || "$cmd" == "status" ]]; then
        show_status
        return
    fi
    
    # Pause
    if [[ "$cmd" == "p" || "$cmd" == "pause" ]]; then
        set_paused true
        echo -e "${YELLOW}Queue paused.${NC}"
        sleep 1
        return
    fi
    
    # Resume
    if [[ "$cmd" == "resume" ]]; then
        set_paused false
        start_worker
        echo -e "${GREEN}Queue resumed.${NC}"
        sleep 1
        return
    fi
    
    # Download
    if [[ "$cmd" == "d" || "$cmd" == "download" ]]; then
        if [[ -z "$params" ]]; then
            echo -e "${RED}Please specify what to download (e.g., 'd 1' or 'd 1,3,5').${NC}"
            sleep 2
            return
        fi
        
        # Parse comma-separated values
        IFS=',' read -ra ADDR <<< "$params"
        local queued_count=0
        
        for i in "${ADDR[@]}"; do
            local index=$(echo "$i" | xargs)
            if [[ "$index" =~ ^[0-9]+$ ]]; then
                local idx=$((index - 1))
                local selected="${FILE_LIST[$idx]}"
                
                if [[ -z "$selected" ]]; then
                    echo -e "${RED}Invalid index: $index${NC}"
                    continue
                fi
                
                if [[ "$selected" == */ ]]; then
                    # It's a folder
                    local dir_name="${selected%/}"
                    local remote_folder="${CURRENT_REMOTE}/${dir_name}"
                    local relative_path="${SUBPATH}/${dir_name}"
                    scan_and_queue_folder "$remote_folder" "$relative_path"
                    ((queued_count++))
                else
                    # It's a file
                    local remote_path="${CURRENT_REMOTE}/${selected}"
                    local local_path="${CURRENT_LOCAL}/${selected}"
                    queue_single_file "$remote_path" "$local_path" "$selected"
                    ((queued_count++))
                fi
            fi
        done
        
        if [[ $queued_count -gt 0 ]]; then
            echo -e "${GREEN}Items added to queue.${NC}"
            if [[ $(is_paused) != "true" ]]; then
                start_worker
            fi
        fi
        sleep 2
        return
    fi
    
    echo -e "${RED}Unknown command.${NC}"
    sleep 1
}

# =============================================================================
# MAIN LOOP
# =============================================================================

main() {
    init_environment
    
    # Check if worker should be running (pending items exist)
    if [[ $(get_pending_count) -gt 0 && $(is_paused) != "true" ]]; then
        start_worker
    fi
    
    while true; do
        show_browser
    done
}

main