#!/bin/bash

# =============================================================================
# Rclone Download Worker
# Processes the download queue in the background
# =============================================================================

# --- CONFIGURATION ---
BASE_REMOTE_NAME="pikpak"
LOG_DIR="$HOME/rclone_log"
LOG_FILE="$LOG_DIR/rclone_log.log"
QUEUE_FILE="$LOG_DIR/rclone_queue.json"
WORKER_PID_FILE="$LOG_DIR/worker.pid"
MAX_RETRIES=3
SIZE_THRESHOLD=$((2 * 1024 * 1024 * 1024))  # 2GB in bytes
POLL_INTERVAL=5  # seconds to wait before checking queue again

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

log_debug() {
    log "DEBUG: $1"
}

# =============================================================================
# QUEUE OPERATIONS (Thread-safe with file locking)
# =============================================================================

lock_queue() {
    exec 200>"${QUEUE_FILE}.lock"
    flock -x 200
}

unlock_queue() {
    flock -u 200
}

get_queue() {
    cat "$QUEUE_FILE"
}

is_paused() {
    jq -r '.paused' "$QUEUE_FILE"
}

get_pending_count() {
    jq '.pending | length' "$QUEUE_FILE"
}

get_downloading_count() {
    jq '.downloading | length' "$QUEUE_FILE"
}

# Move item from pending to downloading
start_download() {
    local item_id="$1"
    lock_queue
    local tmp_file=$(mktemp)
    jq --arg id "$item_id" '
        .downloading += [.pending[] | select(.id == $id)] |
        .pending = [.pending[] | select(.id != $id)]
    ' "$QUEUE_FILE" > "$tmp_file" && mv "$tmp_file" "$QUEUE_FILE"
    unlock_queue
}

# Move item from downloading to completed
complete_download() {
    local item_id="$1"
    lock_queue
    local tmp_file=$(mktemp)
    local timestamp=$(date -Iseconds)
    jq --arg id "$item_id" --arg ts "$timestamp" '
        .completed += [.downloading[] | select(.id == $id) | .completed_at = $ts] |
        .downloading = [.downloading[] | select(.id != $id)]
    ' "$QUEUE_FILE" > "$tmp_file" && mv "$tmp_file" "$QUEUE_FILE"
    unlock_queue
}

# Move item from downloading to failed (or back to pending for retry)
fail_download() {
    local item_id="$1"
    lock_queue
    
    local tmp_file=$(mktemp)
    local current_retries=$(jq -r --arg id "$item_id" '.downloading[] | select(.id == $id) | .retries' "$QUEUE_FILE")
    local new_retries=$((current_retries + 1))
    
    if [[ $new_retries -lt $MAX_RETRIES ]]; then
        # Move back to pending with incremented retry count
        jq --arg id "$item_id" --argjson retries "$new_retries" '
            .pending += [.downloading[] | select(.id == $id) | .retries = $retries] |
            .downloading = [.downloading[] | select(.id != $id)]
        ' "$QUEUE_FILE" > "$tmp_file" && mv "$tmp_file" "$QUEUE_FILE"
        log_info "Item $item_id failed, retry $new_retries/$MAX_RETRIES"
    else
        # Move to failed
        local timestamp=$(date -Iseconds)
        jq --arg id "$item_id" --arg ts "$timestamp" '
            .failed += [.downloading[] | select(.id == $id) | .failed_at = $ts] |
            .downloading = [.downloading[] | select(.id != $id)]
        ' "$QUEUE_FILE" > "$tmp_file" && mv "$tmp_file" "$QUEUE_FILE"
        log_error "Item $item_id failed after $MAX_RETRIES retries, moved to failed list"
    fi
    
    unlock_queue
}

# Get next items to download based on queue state
get_next_items() {
    local pending_count=$(get_pending_count)
    local downloading_count=$(get_downloading_count)
    
    # Calculate how many slots are available (max 2 concurrent)
    local available_slots=$((2 - downloading_count))
    
    if [[ $available_slots -le 0 ]]; then
        echo ""
        return
    fi
    
    if [[ $pending_count -eq 0 ]]; then
        echo ""
        return
    fi
    
    # Get next item(s) from pending
    if [[ $pending_count -eq 1 ]]; then
        # Only 1 item in queue - return it (will use 2 streams)
        jq -c '.pending[0]' "$QUEUE_FILE"
    else
        # Multiple items - return up to $available_slots items (will use 1 stream each)
        jq -c ".pending[0:$available_slots][]" "$QUEUE_FILE"
    fi
}

# =============================================================================
# DOWNLOAD FUNCTIONS
# =============================================================================

download_file() {
    local item_json="$1"
    local use_multithread="$2"
    
    local item_id=$(echo "$item_json" | jq -r '.id')
    local remote_path=$(echo "$item_json" | jq -r '.remote_path')
    local local_path=$(echo "$item_json" | jq -r '.local_path')
    local filename=$(echo "$item_json" | jq -r '.filename')
    local file_size=$(echo "$item_json" | jq -r '.size')
    
    # Ensure local directory exists
    local local_dir=$(dirname "$local_path")
    mkdir -p "$local_dir"
    
    log_info "Starting download: $filename ($(format_size $file_size))"
    log_debug "Remote: $remote_path"
    log_debug "Local: $local_path"
    log_debug "Multi-thread: $use_multithread"
    
    # Mark as downloading
    start_download "$item_id"
    
    # Build rclone command
    local rclone_cmd="rclone copy"
    
    if [[ "$use_multithread" == "true" ]]; then
        # Single file, use 2 streams
        rclone_cmd="$rclone_cmd --multi-thread-streams 2 --multi-thread-cutoff 0"
    else
        # Multiple files, use 1 stream
        rclone_cmd="$rclone_cmd --multi-thread-streams 1"
    fi
    
    # Execute download
    # Note: We copy to parent directory and rclone will create the file
    local parent_remote=$(dirname "$remote_path")
    local file_basename=$(basename "$remote_path")
    
    if $rclone_cmd "$remote_path" "$local_dir" \
        --stats=30s \
        --stats-one-line \
        --log-file="$LOG_FILE" \
        --log-level=INFO \
        2>&1; then
        
        log_info "Download completed: $filename"
        complete_download "$item_id"
        return 0
    else
        log_error "Download failed: $filename"
        fail_download "$item_id"
        return 1
    fi
}

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

# =============================================================================
# MAIN WORKER LOOP
# =============================================================================

cleanup() {
    log_info "Worker shutting down..."
    rm -f "$WORKER_PID_FILE"
    exit 0
}

trap cleanup SIGTERM SIGINT

main() {
    log_info "=========================================="
    log_info "Worker started (PID: $$)"
    log_info "=========================================="
    
    # Store PID
    echo $$ > "$WORKER_PID_FILE"
    
    local idle_count=0
    local max_idle=12  # Exit after ~60 seconds of no work (12 * 5s)
    
    while true; do
        # Check if paused
        if [[ $(is_paused) == "true" ]]; then
            log_debug "Queue is paused, waiting..."
            sleep $POLL_INTERVAL
            continue
        fi
        
        local pending_count=$(get_pending_count)
        local downloading_count=$(get_downloading_count)
        
        # If nothing pending and nothing downloading, increment idle counter
        if [[ $pending_count -eq 0 && $downloading_count -eq 0 ]]; then
            ((idle_count++))
            log_debug "Idle count: $idle_count / $max_idle"
            
            if [[ $idle_count -ge $max_idle ]]; then
                log_info "Queue empty for extended period, worker exiting."
                cleanup
            fi
            
            sleep $POLL_INTERVAL
            continue
        fi
        
        # Reset idle counter if there's work
        idle_count=0
        
        # Skip if already at max concurrent downloads
        if [[ $downloading_count -ge 2 ]]; then
            log_debug "Max concurrent downloads reached, waiting..."
            sleep $POLL_INTERVAL
            continue
        fi
        
        # Get items to download
        if [[ $pending_count -eq 0 ]]; then
            # Nothing to start, but downloads in progress
            sleep $POLL_INTERVAL
            continue
        fi
        
        # Determine download strategy
        local total_active=$((pending_count + downloading_count))
        local use_multithread="false"
        
        # If only 1 item total (pending + downloading), use multithread
        if [[ $total_active -eq 1 && $downloading_count -eq 0 ]]; then
            use_multithread="true"
        fi
        
        # Get next item(s)
        local available_slots=$((2 - downloading_count))
        
        if [[ "$use_multithread" == "true" ]]; then
            # Single item mode - download with 2 streams (blocking)
            local item=$(jq -c '.pending[0]' "$QUEUE_FILE")
            if [[ -n "$item" && "$item" != "null" ]]; then
                download_file "$item" "true"
            fi
        else
            # Multi-item mode - download up to 2 items with 1 stream each
            local items_to_download=()
            local pids=()
            
            while IFS= read -r item; do
                if [[ -n "$item" && "$item" != "null" ]]; then
                    items_to_download+=("$item")
                fi
            done < <(jq -c ".pending[0:$available_slots][]" "$QUEUE_FILE")
            
            # Start downloads in background and collect PIDs
            for item in "${items_to_download[@]}"; do
                download_file "$item" "false" &
                pids+=($!)
                sleep 1  # Small delay between starting downloads
            done
            
            # Wait for ALL downloads to complete before continuing
            for pid in "${pids[@]}"; do
                wait $pid
            done
        fi
        
        # Brief pause before next iteration
        sleep 2
    done
}

main