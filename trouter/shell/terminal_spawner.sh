#!/bin/bash
# ============================================================================
# Terminal Spawner Library — Self-Contained (trouter package)
# ============================================================================
# Functions to spawn agents in fresh terminal windows/sessions.
# Supports macOS Terminal.app, iTerm2, tmux, and GNU screen.
#
# Benefits:
#   - Visual feedback: See agent output in real-time in dedicated windows
#   - Process isolation: Each agent runs independently
#   - Independent context: Each terminal gets its own 200K token budget
#   - Session persistence: tmux/screen sessions survive disconnects
#
# Self-contained: no external dependencies required.
# Source this file in wrapper scripts:
#   source "$(dirname "$0")/../shell/terminal_spawner.sh"
# ============================================================================

# ============================================================================
# Self-contained logging (no external deps)
# ============================================================================

_ts_log_info()    { echo "[INFO]  $(date +%H:%M:%S) $*"; }
_ts_log_warn()    { echo "[WARN]  $(date +%H:%M:%S) $*" >&2; }
_ts_log_error()   { echo "[ERROR] $(date +%H:%M:%S) $*" >&2; }
_ts_log_success() { echo "[OK]    $(date +%H:%M:%S) $*"; }
_ts_log_debug()   { [[ "${TROUTER_DEBUG:-0}" == "1" ]] && echo "[DEBUG] $(date +%H:%M:%S) $*" || true; }

# Use external log functions if available, else use builtins
log_info()    { type -t _ext_log_info    &>/dev/null && _ext_log_info "$@"    || _ts_log_info "$@"; }
log_warn()    { type -t _ext_log_warn    &>/dev/null && _ext_log_warn "$@"    || _ts_log_warn "$@"; }
log_error()   { type -t _ext_log_error   &>/dev/null && _ext_log_error "$@"   || _ts_log_error "$@"; }
log_success() { type -t _ext_log_success &>/dev/null && _ext_log_success "$@" || _ts_log_success "$@"; }
log_debug()   { type -t _ext_log_debug   &>/dev/null && _ext_log_debug "$@"   || _ts_log_debug "$@"; }

# ============================================================================
# Self-contained get_background_output_file (no external deps)
# ============================================================================

get_background_output_file() {
    local prefix="${1:-agent}"
    local dir="${TROUTER_LOG_DIR:-$HOME/.claude/terminal_health/logs}"
    mkdir -p "${dir}"
    echo "${dir}/${prefix}_$(date +%Y%m%d_%H%M%S)_$$.log"
}

# ============================================================================
# AppleScript injection prevention
# ============================================================================

_escape_applescript() {
    # Escape a string for safe interpolation into AppleScript double-quoted
    # strings.  AppleScript uses backslash-escaping inside double-quoted
    # strings, so we must escape backslashes first, then double-quotes.
    local s="$1"
    # Double all backslashes
    s="${s//\\/\\\\}"
    # Escape double quotes
    s="${s//\"/\\\"}"
    echo "${s}"
}

# ============================================================================
# Configuration defaults
# ============================================================================

TERMINAL_METHOD="${AGENT_TERMINAL_METHOD:-auto}"
TERMINAL_ATTACH="${AGENT_TERMINAL_ATTACH:-false}"
TERMINAL_SESSION_PREFIX="${AGENT_SESSION_PREFIX:-agent}"
TERMINAL_ITERM_ATTACH="${AGENT_ITERM_ATTACH:-true}"  # Auto-attach iTerm to tmux sessions

# Track spawned sessions
declare -a SPAWNED_SESSIONS=()

# Health directory for watchdog heartbeats
WATCHDOG_HEALTH_DIR="${WATCHDOG_HEALTH_DIR:-$HOME/.claude/terminal_health}"

# ============================================================================
# Terminal Detection
# ============================================================================

# Detect available terminal emulators
# Returns: tmux-iterm, osascript, iterm, tmux, screen, or none
# Priority: tmux-iterm (best for watchdog) > tmux > iterm > osascript > screen
detect_terminal_app() {
    local os_type
    os_type=$(uname -s)

    case "${os_type}" in
        Darwin)
            # macOS - prioritize tmux-iterm for watchdog compatibility
            # tmux-iterm: spawn in tmux first (for watchdog control), then attach iTerm for visibility
            if command -v tmux &>/dev/null; then
                if osascript -e 'tell application "System Events" to (name of processes) contains "iTerm2"' 2>/dev/null | grep -q "true"; then
                    # BEST: tmux for watchdog control + iTerm for visibility
                    echo "tmux-iterm"
                    return 0
                else
                    # tmux only (still watchdog compatible)
                    echo "tmux"
                    return 0
                fi
            fi
            # Fallback to standalone iTerm (NOT watchdog compatible)
            if osascript -e 'tell application "System Events" to (name of processes) contains "iTerm2"' 2>/dev/null | grep -q "true"; then
                echo "iterm"
                return 0
            elif command -v osascript &>/dev/null; then
                echo "osascript"
                return 0
            fi
            ;;
    esac

    # Cross-platform - check for tmux and screen
    if command -v tmux &>/dev/null; then
        echo "tmux"
        return 0
    elif command -v screen &>/dev/null; then
        echo "screen"
        return 0
    fi

    echo "none"
    return 1
}

# Get configured terminal method or auto-detect
get_terminal_method() {
    local method="${TERMINAL_METHOD}"

    if [[ "${method}" == "auto" ]]; then
        method=$(detect_terminal_app)
    fi

    # Validate the method is available
    case "${method}" in
        tmux-iterm)
            # tmux-iterm: Best option - tmux for watchdog control + iTerm for visibility
            if [[ "$(uname -s)" != "Darwin" ]]; then
                log_warn "tmux-iterm only available on macOS, falling back to tmux"
                method="tmux"
            elif ! command -v tmux &>/dev/null; then
                log_warn "tmux not installed, falling back to iterm"
                method="iterm"
            fi
            ;;
        osascript|iterm)
            if [[ "$(uname -s)" != "Darwin" ]]; then
                log_warn "osascript/iterm only available on macOS, falling back to tmux"
                method="tmux"
            fi
            ;;
        tmux)
            if ! command -v tmux &>/dev/null; then
                log_warn "tmux not installed, falling back to screen"
                method="screen"
            fi
            ;;
        screen)
            if ! command -v screen &>/dev/null; then
                log_warn "screen not installed, falling back to background"
                method="background"
            fi
            ;;
        background)
            # Background mode - use existing run_in_background functionality
            ;;
        *)
            log_warn "Unknown terminal method: ${method}, using background"
            method="background"
            ;;
    esac

    echo "${method}"
}

# ============================================================================
# Session Name Generation
# ============================================================================

# Generate a unique session name
generate_session_name() {
    local prefix="${1:-${TERMINAL_SESSION_PREFIX}}"
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local random_suffix
    random_suffix=$(printf '%04d' $((RANDOM % 10000)))

    echo "${prefix}_${timestamp}_${random_suffix}"
}

# ============================================================================
# macOS Terminal.app (osascript)
# ============================================================================

spawn_terminal_osascript() {
    local command="$1"
    local title="${2:-Agent}"
    local working_dir="${3:-$(pwd)}"

    log_info "Spawning Terminal.app window: ${title}"

    # Escape for AppleScript injection prevention
    local safe_title safe_cmd safe_dir
    safe_title=$(_escape_applescript "${title}")
    safe_dir=$(_escape_applescript "${working_dir}")
    local quoted_dir_as
    quoted_dir_as=$(printf '%q' "${working_dir}")
    safe_cmd=$(_escape_applescript "cd ${quoted_dir_as} && ${command}")

    # Use osascript to open a new Terminal window
    osascript <<EOF
tell application "Terminal"
    activate
    set newTab to do script "${safe_cmd}"
    set custom title of newTab to "${safe_title}"
end tell
EOF

    local exit_code=$?
    if [[ ${exit_code} -eq 0 ]]; then
        log_success "Terminal window spawned: ${title}"
        return 0
    else
        log_error "Failed to spawn Terminal window"
        return 1
    fi
}

# ============================================================================
# macOS iTerm2
# ============================================================================

spawn_terminal_iterm() {
    local command="$1"
    local title="${2:-Agent}"
    local working_dir="${3:-$(pwd)}"

    log_info "Spawning iTerm2 window: ${title}"

    # Escape for AppleScript injection prevention
    local safe_title safe_cmd
    safe_title=$(_escape_applescript "${title}")
    local quoted_dir_iterm
    quoted_dir_iterm=$(printf '%q' "${working_dir}")
    safe_cmd=$(_escape_applescript "cd ${quoted_dir_iterm} && ${command}")

    # Use osascript to open a new iTerm2 window
    osascript <<EOF
tell application "iTerm2"
    create window with default profile
    tell current session of current window
        write text "${safe_cmd}"
        set name to "${safe_title}"
    end tell
    activate
end tell
EOF

    local exit_code=$?
    if [[ ${exit_code} -eq 0 ]]; then
        log_success "iTerm2 window spawned: ${title}"
        return 0
    else
        log_error "Failed to spawn iTerm2 window"
        return 1
    fi
}

# ============================================================================
# tmux-iterm: RECOMMENDED - Best for watchdog compatibility
# ============================================================================
# Spawns agent in tmux session first (for watchdog control: /compact, kill, etc.)
# Then attaches an iTerm window to the tmux session (for visual monitoring)

spawn_tmux_with_iterm_attach() {
    local command="$1"
    local session_name="${2:-$(generate_session_name)}"
    local working_dir="${3:-$(pwd)}"
    local log_file="${4:-}"
    local attach_iterm="${5:-${TERMINAL_ITERM_ATTACH}}"

    log_info "Spawning tmux-iterm session: ${session_name}"

    # Build the command with optional logging
    local quoted_dir
    quoted_dir=$(printf '%q' "${working_dir}")
    local full_cmd="cd ${quoted_dir} && ${command}"
    if [[ -n "${log_file}" ]]; then
        full_cmd="${full_cmd} 2>&1 | tee '${log_file}'"
    fi

    # Step 1: Create tmux session first (this enables watchdog control)
    tmux new-session -d -s "${session_name}" -c "${working_dir}" "${full_cmd}; echo '=== Session complete. Press any key to close. ==='; read -n1"

    local exit_code=$?
    if [[ ${exit_code} -ne 0 ]]; then
        log_error "Failed to create tmux session: ${session_name}"
        return 1
    fi

    SPAWNED_SESSIONS+=("tmux-iterm:${session_name}")
    log_success "tmux session created: ${session_name}"

    # Write initial heartbeat for watchdog
    write_initial_heartbeat "${session_name}" "${working_dir}" "${command}"

    # Step 2: Attach iTerm window to the tmux session (for visibility)
    if [[ "${attach_iterm}" == "true" ]]; then
        log_info "Attaching iTerm window to tmux session..."
        attach_iterm_to_tmux "${session_name}"
    else
        log_info "tmux-only mode. To attach: tmux attach-session -t ${session_name}"
        log_info "Or open iTerm: iterm_attach_tmux ${session_name}"
    fi

    echo "${session_name}"
    return 0
}

# Attach iTerm window to an existing tmux session
attach_iterm_to_tmux() {
    local session_name="$1"

    if [[ -z "${session_name}" ]]; then
        log_error "Session name required"
        return 1
    fi

    # Verify tmux session exists
    if ! tmux has-session -t "${session_name}" 2>/dev/null; then
        log_error "tmux session not found: ${session_name}"
        return 1
    fi

    # Escape for AppleScript injection prevention
    local safe_session_name
    safe_session_name=$(_escape_applescript "${session_name}")

    # Open iTerm window attached to tmux session using iTerm's tmux integration
    osascript <<EOF
tell application "iTerm2"
    create window with default profile
    tell current session of current window
        set name to "linked: ${safe_session_name}"
        -- Attach to tmux session using tmux integration mode
        write text "tmux attach-session -t '${safe_session_name}'"
    end tell
    activate
end tell
EOF

    local exit_code=$?
    if [[ ${exit_code} -eq 0 ]]; then
        log_success "iTerm attached to tmux session: ${session_name}"
        return 0
    else
        log_error "Failed to attach iTerm to tmux session"
        return 1
    fi
}

# Detach iTerm from tmux session (leaves tmux running)
detach_iterm_from_tmux() {
    local session_name="$1"

    if [[ -z "${session_name}" ]]; then
        log_error "Session name required"
        return 1
    fi

    # Send detach command to the tmux session
    tmux detach-client -s "${session_name}" 2>/dev/null || true
    log_info "Detached from tmux session: ${session_name}"
}

# Write initial heartbeat for watchdog tracking
write_initial_heartbeat() {
    local session_name="$1"
    local working_dir="$2"
    local command="$3"

    # Sanitize session_name to prevent path traversal — strip all path-unsafe chars
    session_name="$(basename -- "${session_name}" 2>/dev/null || echo "${session_name}")"
    session_name="${session_name//\//_}"

    local heartbeats_dir="${WATCHDOG_HEALTH_DIR}/heartbeats"
    mkdir -p "${heartbeats_dir}" 2>/dev/null

    # Escape values for safe JSON embedding (backslashes, quotes, newlines, tabs, CRs)
    local safe_session safe_dir safe_cmd
    safe_session="${session_name//\\/\\\\}"
    safe_session="${safe_session//\"/\\\"}"
    safe_session="${safe_session//$'\n'/\\n}"
    safe_session="${safe_session//$'\t'/\\t}"
    safe_session="${safe_session//$'\r'/\\r}"
    safe_dir="${working_dir//\\/\\\\}"
    safe_dir="${safe_dir//\"/\\\"}"
    safe_dir="${safe_dir//$'\n'/\\n}"
    safe_dir="${safe_dir//$'\t'/\\t}"
    safe_dir="${safe_dir//$'\r'/\\r}"
    safe_cmd="${command//\\/\\\\}"
    safe_cmd="${safe_cmd//\"/\\\"}"
    safe_cmd="${safe_cmd//$'\n'/\\n}"
    safe_cmd="${safe_cmd//$'\t'/\\t}"
    safe_cmd="${safe_cmd//$'\r'/\\r}"

    local hb_file="${heartbeats_dir}/${session_name}.heartbeat"
    local hb_tmp="${hb_file}.tmp"
    cat > "${hb_tmp}" <<EOF
{
  "session_id": "${safe_session}",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "unix_time": $(date +%s),
  "pid": $$,
  "status": "starting",
  "working_dir": "${safe_dir}",
  "command": "${safe_cmd}",
  "last_tool": null,
  "context_tokens": null,
  "spawned_by": "terminal_spawner"
}
EOF
    mv "${hb_tmp}" "${hb_file}"
    log_debug "Heartbeat written: ${hb_file}"
}

# List tmux-iterm sessions with health status
list_tmux_iterm_sessions() {
    local heartbeats_dir="${WATCHDOG_HEALTH_DIR}/heartbeats"

    echo "=== tmux-iterm sessions (watchdog-managed) ==="
    printf "%-25s  %-8s  %-10s  %-15s\n" "Session" "Age" "Status" "Last Tool"
    printf '%.0s-' {1..65}
    echo

    while IFS= read -r session; do
        local hb_file="${heartbeats_dir}/${session}.heartbeat"
        if [[ -f "${hb_file}" ]]; then
            python3 -c "
import json, time, sys
session = sys.argv[1]
hb_file = sys.argv[2]
data = json.load(open(hb_file))
age = time.time() - data.get('unix_time', 0)
status = 'healthy' if age < 30 else 'warning' if age < 60 else 'alert' if age < 90 else 'FROZEN'
tool = (data.get('last_tool') or '-')[:15]
print(f'{session:25}  {age:6.1f}s   {status:10}  {tool}')
" "${session}" "${hb_file}" 2>/dev/null || printf "%-25s  %-8s  %-10s  %-15s\n" "${session}" "?" "unknown" "-"
        else
            printf "%-25s  %-8s  %-10s  %-15s\n" "${session}" "-" "no heartbeat" "-"
        fi
    done < <(tmux list-sessions -F "#{session_name}" 2>/dev/null | grep "^${TERMINAL_SESSION_PREFIX}")
}

# ============================================================================
# tmux
# ============================================================================

spawn_terminal_tmux() {
    local command="$1"
    local session_name="${2:-$(generate_session_name)}"
    local working_dir="${3:-$(pwd)}"
    local log_file="${4:-}"

    log_info "Spawning tmux session: ${session_name}"

    # Build the command with optional logging
    local quoted_dir
    quoted_dir=$(printf '%q' "${working_dir}")
    local full_cmd="cd ${quoted_dir} && ${command}"
    if [[ -n "${log_file}" ]]; then
        full_cmd="${full_cmd} 2>&1 | tee '${log_file}'"
    fi

    # Create new detached tmux session
    tmux new-session -d -s "${session_name}" -c "${working_dir}" "${full_cmd}; echo '=== Session complete. Press any key to close. ==='; read -n1"

    local exit_code=$?
    if [[ ${exit_code} -eq 0 ]]; then
        SPAWNED_SESSIONS+=("tmux:${session_name}")
        log_success "tmux session created: ${session_name}"

        # Optionally attach to the session
        if [[ "${TERMINAL_ATTACH}" == "true" ]]; then
            log_info "Attaching to tmux session..."
            tmux attach-session -t "${session_name}"
        else
            log_info "To attach: tmux attach-session -t ${session_name}"
        fi

        echo "${session_name}"
        return 0
    else
        log_error "Failed to create tmux session"
        return 1
    fi
}

# List active tmux agent sessions
list_tmux_sessions() {
    tmux list-sessions 2>/dev/null | grep "^${TERMINAL_SESSION_PREFIX}" || true
}

# Attach to a tmux session
attach_tmux_session() {
    local session_name="${1:-}"

    if [[ -z "${session_name}" ]]; then
        # Attach to most recent agent session
        session_name=$(tmux list-sessions -F "#{session_name}" 2>/dev/null | grep "^${TERMINAL_SESSION_PREFIX}" | tail -1)
    fi

    if [[ -n "${session_name}" ]]; then
        log_info "Attaching to: ${session_name}"
        tmux attach-session -t "${session_name}"
    else
        log_warn "No agent sessions found"
        return 1
    fi
}

# Kill a tmux session
kill_tmux_session() {
    local session_name="$1"

    if [[ -z "${session_name}" ]]; then
        log_error "Session name required"
        return 1
    fi

    if tmux has-session -t "${session_name}" 2>/dev/null; then
        tmux kill-session -t "${session_name}"
        log_success "Killed session: ${session_name}"
        return 0
    else
        log_warn "Session not found: ${session_name}"
        return 1
    fi
}

# ============================================================================
# GNU Screen
# ============================================================================

spawn_terminal_screen() {
    local command="$1"
    local session_name="${2:-$(generate_session_name)}"
    local working_dir="${3:-$(pwd)}"
    local log_file="${4:-}"

    log_info "Spawning screen session: ${session_name}"

    # Build the command with optional logging
    local quoted_dir
    quoted_dir=$(printf '%q' "${working_dir}")
    local full_cmd="cd ${quoted_dir} && ${command}"
    if [[ -n "${log_file}" ]]; then
        full_cmd="${full_cmd} 2>&1 | tee '${log_file}'"
    fi

    # Create new detached screen session
    screen -dmS "${session_name}" bash -c "${full_cmd}; echo '=== Session complete. Press any key to close. ==='; read -n1"

    local exit_code=$?
    if [[ ${exit_code} -eq 0 ]]; then
        SPAWNED_SESSIONS+=("screen:${session_name}")
        log_success "screen session created: ${session_name}"

        # Optionally attach to the session
        if [[ "${TERMINAL_ATTACH}" == "true" ]]; then
            log_info "Attaching to screen session..."
            screen -r "${session_name}"
        else
            log_info "To attach: screen -r ${session_name}"
        fi

        echo "${session_name}"
        return 0
    else
        log_error "Failed to create screen session"
        return 1
    fi
}

# List active screen agent sessions
list_screen_sessions() {
    screen -ls 2>/dev/null | grep "\.${TERMINAL_SESSION_PREFIX}" || true
}

# Attach to a screen session
attach_screen_session() {
    local session_name="${1:-}"

    if [[ -z "${session_name}" ]]; then
        # Attach to most recent agent session
        session_name=$(screen -ls 2>/dev/null | grep "\.${TERMINAL_SESSION_PREFIX}" | tail -1 | awk '{print $1}')
    fi

    if [[ -n "${session_name}" ]]; then
        log_info "Attaching to: ${session_name}"
        screen -r "${session_name}"
    else
        log_warn "No agent sessions found"
        return 1
    fi
}

# Kill a screen session
kill_screen_session() {
    local session_name="$1"

    if [[ -z "${session_name}" ]]; then
        log_error "Session name required"
        return 1
    fi

    if screen -ls 2>/dev/null | grep -qF "${session_name}"; then
        screen -S "${session_name}" -X quit
        log_success "Killed session: ${session_name}"
        return 0
    else
        log_warn "Session not found: ${session_name}"
        return 1
    fi
}

# ============================================================================
# Main Entry Point
# ============================================================================

# Spawn an agent in a fresh terminal using configured method
# Usage: spawn_agent_terminal "command" ["title"] ["working_dir"] ["log_file"]
spawn_agent_terminal() {
    local command="$1"
    local title="${2:-Agent-$(date +%H%M%S)}"
    local working_dir="${3:-$(pwd)}"
    local log_file="${4:-}"

    if [[ -z "${command}" ]]; then
        log_error "Command argument required"
        return 1
    fi

    local method
    method=$(get_terminal_method)

    log_debug "Terminal method: ${method}"

    case "${method}" in
        tmux-iterm)
            # RECOMMENDED: tmux for watchdog control + iTerm for visibility
            spawn_tmux_with_iterm_attach "${command}" "${title}" "${working_dir}" "${log_file}"
            ;;
        osascript)
            spawn_terminal_osascript "${command}" "${title}" "${working_dir}"
            ;;
        iterm)
            spawn_terminal_iterm "${command}" "${title}" "${working_dir}"
            ;;
        tmux)
            spawn_terminal_tmux "${command}" "${title}" "${working_dir}" "${log_file}"
            ;;
        screen)
            spawn_terminal_screen "${command}" "${title}" "${working_dir}" "${log_file}"
            ;;
        background)
            # Fall back to background execution with file output
            log_info "Using background execution (no terminal spawning)"
            if [[ -z "${log_file}" ]]; then
                log_file=$(get_background_output_file "terminal")
            fi
            (
                cd "${working_dir}" || exit 1
                echo "=== ${title} ===" > "${log_file}"
                echo "Started: $(date)" >> "${log_file}"
                echo "Command: ${command}" >> "${log_file}"
                echo "---" >> "${log_file}"
                bash -c "${command}" >> "${log_file}" 2>&1
                echo "---" >> "${log_file}"
                echo "Finished: $(date)" >> "${log_file}"
            ) &
            log_info "Background PID: $!"
            log_info "Output: ${log_file}"
            echo "${log_file}"
            ;;
        *)
            log_error "Unknown terminal method: ${method}"
            return 1
            ;;
    esac
}

# Spawn agent terminal with logging enabled
terminal_spawn_with_logging() {
    local command="$1"
    local title="${2:-Agent-$(date +%H%M%S)}"
    local working_dir="${3:-$(pwd)}"

    # Always create a log file
    local log_file
    log_file=$(get_background_output_file "terminal")

    spawn_agent_terminal "${command}" "${title}" "${working_dir}" "${log_file}"
}

# ============================================================================
# Session Management Interface
# ============================================================================

# List all agent sessions (tmux + screen) with health status
list_agent_sessions() {
    local method
    method=$(get_terminal_method)

    case "${method}" in
        tmux-iterm)
            # Show tmux-iterm sessions with watchdog health status
            list_tmux_iterm_sessions
            ;;
        *)
            # Legacy: show tmux and screen sessions without health
            echo "=== tmux sessions ==="
            list_tmux_sessions
            echo ""
            echo "=== screen sessions ==="
            list_screen_sessions
            ;;
    esac
}

# Attach to most recent agent session
attach_agent_session() {
    local session="${1:-}"
    local method
    method=$(get_terminal_method)

    case "${method}" in
        tmux-iterm)
            # For tmux-iterm, attach iTerm to existing tmux session
            if [[ -n "${session}" ]]; then
                attach_iterm_to_tmux "${session}"
            else
                # Find most recent session and attach
                session=$(tmux list-sessions -F "#{session_name}" 2>/dev/null | grep "^${TERMINAL_SESSION_PREFIX}" | tail -1)
                if [[ -n "${session}" ]]; then
                    attach_iterm_to_tmux "${session}"
                else
                    log_warn "No agent sessions found"
                    return 1
                fi
            fi
            ;;
        tmux)
            attach_tmux_session "${session}"
            ;;
        screen)
            attach_screen_session "${session}"
            ;;
        *)
            log_warn "Terminal session attachment not supported for method: ${method}"
            return 1
            ;;
    esac
}

# Kill an agent session
kill_agent_session() {
    local session="$1"

    if [[ -z "${session}" ]]; then
        log_error "Session name required"
        return 1
    fi

    # Try tmux first, then screen
    if tmux has-session -t "${session}" 2>/dev/null; then
        kill_tmux_session "${session}"
    elif screen -ls 2>/dev/null | grep -qF "${session}"; then
        kill_screen_session "${session}"
    else
        log_warn "Session not found: ${session}"
        return 1
    fi
}

# Kill all agent sessions
kill_all_agent_sessions() {
    log_warn "Killing all agent sessions..."

    # Kill tmux sessions
    while IFS= read -r session; do
        kill_tmux_session "${session}"
    done < <(tmux list-sessions -F "#{session_name}" 2>/dev/null | grep "^${TERMINAL_SESSION_PREFIX}")

    # Kill screen sessions
    while IFS= read -r session; do
        kill_screen_session "${session}"
    done < <(screen -ls 2>/dev/null | grep "\.${TERMINAL_SESSION_PREFIX}" | awk -F. '{print $1"."$2}')

    log_success "All agent sessions killed"
}

# Export functions for use in subshells
export -f _ts_log_info _ts_log_warn _ts_log_error _ts_log_success _ts_log_debug
export -f log_info log_warn log_error log_success log_debug
export -f get_background_output_file _escape_applescript
export -f detect_terminal_app get_terminal_method generate_session_name
export -f spawn_terminal_osascript spawn_terminal_iterm
export -f spawn_terminal_tmux list_tmux_sessions attach_tmux_session kill_tmux_session
export -f spawn_terminal_screen list_screen_sessions attach_screen_session kill_screen_session
export -f spawn_agent_terminal terminal_spawn_with_logging
export -f list_agent_sessions attach_agent_session kill_agent_session kill_all_agent_sessions
# tmux-iterm functions (recommended for watchdog compatibility)
export -f spawn_tmux_with_iterm_attach attach_iterm_to_tmux detach_iterm_from_tmux
export -f write_initial_heartbeat list_tmux_iterm_sessions
