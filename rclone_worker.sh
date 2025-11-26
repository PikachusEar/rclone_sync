#!/bin/bash

# =============================================================================
# Rclone Download Worker
# Processes the download queue in the background
# =============================================================================

# --- CONFIGURATION ---
LOG_DIR="$HOME/rclone_log"
LOG_FILE="$LOG_DIR/rclone_log.log"
QUEUE_FILE="$LOG_DIR/rclone_queue.json"
WORKER_PID_FILE="$LOG_DIR/worker.pid"
MAX_RETRIES=3
POLL_INTERVAL=5

# =============================================================================
# SINGLE INSTANCE GUARD
# =============================================================================

single_instance_guard() {
    if [[ -f "$WORKER_PID_FILE" ]]; then
        local oldpid
        oldpid=$(cat "$WORKER_PID_FILE" 2>/dev/null || echo "")
        if [[ -n "$oldpid" && "$oldpid" != "$$" && -d "/proc/$oldpid" ]]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Another worker already running (PID: $oldpid). Exiting." >> "$LOG_FILE"
            exit 1
        fi
    fi
    echo $$ > "$WORKER_PID_FILE"
}

# =============================================================================
# LOGGING
# =============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log_info() {
    log "INFO: $1"
}

log_error() {
    log "ERROR: $1"
}

# =============================================================================
# FILE LOCKING
# =============================================================================

LOCK_FILE="$LOG_DIR/queue.lock"

queue_locked() {
    (
        flock -x 200
        eval "$@"
    ) 200>"$LOCK_FILE"
}

# =============================================================================
# QUEUE OPERATIONS
# =============================================================================

get_pending_count() {
    jq '.pending | length' "$QUEUE_FILE" 2>/dev/null || echo "0"
}

is_paused() {
    jq -r '.paused' "$QUEUE_FILE" 2>/dev/null || echo "false"
}

# Get and remove items from pending (atomic operation with lock)
pop_items() {
    local count=$1
    queue_locked "
        items=\$(jq -c '.pending[0:$count]' '$QUEUE_FILE')
        tmp_file=\$(mktemp)
        jq '.pending = .pending[$count:]' '$QUEUE_FILE' > \"\$tmp_file\" && mv \"\$tmp_file\" '$QUEUE_FILE'
        echo \"\$items\"
    "
}

# Mark item as completed
mark_completed() {
    local item_json="$1"
    local timestamp=$(date -Iseconds)
    queue_locked "
        tmp_file=\$(mktemp)
        jq --argjson item '$item_json' --arg ts '$timestamp' \
            '.completed += [\$item + {completed_at: \$ts}]' \
            '$QUEUE_FILE' > \"\$tmp_file\" && mv \"\$tmp_file\" '$QUEUE_FILE'
    "
}

# Mark item as failed or retry
mark_failed_or_retry() {
    local item_json="$1"
    local current_retries=$(echo "$item_json" | jq -r '.retries')
    local new_retries=$((current_retries + 1))
    
    if [[ $new_retries -lt $MAX_RETRIES ]]; then
        queue_locked "
            tmp_file=\$(mktemp)
            jq --argjson item '$item_json' --argjson retries '$new_retries' \
                '.pending += [\$item | .retries = \$retries]' \
                '$QUEUE_FILE' > \"\$tmp_file\" && mv \"\$tmp_file\" '$QUEUE_FILE'
        "
        log_info "Retry $new_retries/$MAX_RETRIES queued"
    else
        local timestamp=$(date -Iseconds)
        queue_locked "
            tmp_file=\$(mktemp)
            jq --argjson item '$item_json' --arg ts '$timestamp' \
                '.failed += [\$item + {failed_at: \$ts}]' \
                '$QUEUE_FILE' > \"\$tmp_file\" && mv \"\$tmp_file\" '$QUEUE_FILE'
        "
        log_error "Max retries reached, moved to failed"
    fi
}

# Update downloading status (for display only)
set_downloading() {
    local items_json="$1"
    queue_locked "
        tmp_file=\$(mktemp)
        jq --argjson items '$items_json' '.downloading = \$items' '$QUEUE_FILE' > \"\$tmp_file\" && mv \"\$tmp_file\" '$QUEUE_FILE'
    "
}

clear_downloading() {
    queue_locked "
        tmp_file=\$(mktemp)
        jq '.downloading = []' '$QUEUE_FILE' > \"\$tmp_file\" && mv \"\$tmp_file\" '$QUEUE_FILE'
    "
}

recover_downloading() {
    queue_locked "
        tmp_file=\$(mktemp)
        jq '.pending = .downloading + .pending | .downloading = []' '$QUEUE_FILE' > \"\$tmp_file\" && mv \"\$tmp_file\" '$QUEUE_FILE'
    "
}

# =============================================================================
# DOWNLOAD FUNCTIONS
# =============================================================================

download_single_file() {
    local item_json="$1"
    local use_multithread="$2"
    
    local remote_path=$(echo "$item_json" | jq -r '.remote_path')
    local local_path=$(echo "$item_json" | jq -r '.local_path')
    local filename=$(echo "$item_json" | jq -r '.filename')
    local file_size=$(echo "$item_json" | jq -r '.size')
    
    local local_dir=$(dirname "$local_path")
    mkdir -p "$local_dir"
    
    local size_mb=$((file_size / 1048576))
    log_info "Downloading: $filename (${size_mb}MB) [multithread=$use_multithread]"
    
    local streams=1
    [[ "$use_multithread" == "true" ]] && streams=2
    
    if rclone copy "$remote_path" "$local_dir" \
        --multi-thread-streams $streams \
        --multi-thread-cutoff 0 \
        --timeout 5m \
        --contimeout 60s \
        --low-level-retries 3 \
        --retries 1 \
        --stats=30s \
        --stats-one-line \
        --log-file="$LOG_FILE" \
        --log-level=INFO \
        2>&1; then
        log_info "Completed: $filename"
        return 0
    else
        log_error "Failed: $filename"
        return 1
    fi
}

# =============================================================================
# MAIN WORKER LOOP
# =============================================================================

cleanup() {
    log_info "Worker shutting down..."
    clear_downloading
    rm -f "$WORKER_PID_FILE"
    exit 0
}

trap cleanup SIGTERM SIGINT EXIT

main() {
    single_instance_guard
    
    log_info "=========================================="
    log_info "Worker started (PID: $$)"
    log_info "=========================================="
    
    echo $$ > "$WORKER_PID_FILE"
    
    # Recover any stuck downloading items from previous crash
    local downloading_count=$(jq '.downloading | length' "$QUEUE_FILE" 2>/dev/null || echo "0")
    if [[ $downloading_count -gt 0 ]]; then
        log_info "Recovering $downloading_count stuck download(s) from previous crash"
        recover_downloading
    fi
    
    local idle_count=0
    local max_idle=12  # Exit after ~60 seconds idle
    
    while true; do
        # Check pause
        if [[ $(is_paused) == "true" ]]; then
            sleep $POLL_INTERVAL
            continue
        fi
        
        local pending_count=$(get_pending_count)
        
        # Idle check
        if [[ $pending_count -eq 0 ]]; then
            ((idle_count++))
            if [[ $idle_count -ge $max_idle ]]; then
                log_info "Queue empty, worker exiting."
                exit 0
            fi
            sleep $POLL_INTERVAL
            continue
        fi
        
        idle_count=0
        
        # Always: 1 file at a time, 2 streams
        local items=$(pop_items 1)
        local item=$(echo "$items" | jq -c '.[0]')
        
        set_downloading "$items"
        
        if download_single_file "$item" "true"; then
            mark_completed "$item"
        else
            mark_failed_or_retry "$item"
        fi
        
        clear_downloading
        
        # Brief pause between files
        sleep 2
    done
}

main