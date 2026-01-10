#!/bin/bash

# delegate.sh - A utility script to delegate tasks to the codex AI agent
# Runs tasks in tmux sessions for reliable background execution
# Logs are saved to /tmp/delegate-logs/ for recovery and searching

set -e

# Script directory for finding common-roles
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_ROLES_DIR="$SCRIPT_DIR/common-roles"

# Default values
ROLE=""
GOAL=""
ACCEPTANCE_CRITERIA=""
THE_WHY=""
TASK_DETAIL=""
LOG_DIR="/tmp/delegate-logs"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
FOREGROUND=false  # Run in tmux by default

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

show_help() {
    cat << EOF
${GREEN}delegate.sh${NC} - Delegate tasks to the codex AI agent

${YELLOW}USAGE:${NC}
    delegate.sh [OPTIONS]

${YELLOW}OPTIONS:${NC}
    -r, --role <text>               Role description of the ideal person for this task
    -c, --common-role <name>        Use a predefined role from common-roles/<name>.md
    -g, --goal <text>               The goal/objective of the task
    -a, --acceptance-criteria <text> Acceptance criteria for task completion
    -w, --why <text>                The reasoning behind the task
    -t, --task-detail <text>        Detailed task description
    -n, --name <text>               Task name (used for tmux session and log filenames)
    -f, --foreground                Run in foreground instead of tmux session
    -l, --list-roles                List available common roles
    -s, --status [name]             Check status of running delegate sessions
    --check <name>                  Quick check if a session is running or done
    --check-all                     Quick check status of all delegate sessions
    --clean                         Kill all idle tmux sessions (task complete, waiting on read)
    --clean-all                     Kill ALL delegate tmux sessions (including running ones)
    --purge [name]                  Kill session(s) AND delete their log files
    -k, --kill <name>               Kill a running delegate session
    --continue <name> <message>     Send a follow-up message to an existing session
    -h, --help                      Show this help message

${YELLOW}EXAMPLES:${NC}
    # Simple task (runs in tmux background)
    delegate.sh -r "Software developer" -g "Create a hello world file" \\
                -t "Create hello-world.md with 'Hello World' content" -n "hello"

    # Using a common role
    delegate.sh -c feature-analyst -g "Extract features from auth module" \\
                -t "Create .feature files for /src/auth" -n "auth-features"

    # Run in foreground (blocks until complete)
    delegate.sh -f -c architect -g "Quick documentation task" -t "..."

    # Check status of all running tasks
    delegate.sh --status

    # Quick check if a task is done
    delegate.sh --check my-task

    # Quick check all tasks
    delegate.sh --check-all

    # Send follow-up message to continue conversation
    delegate.sh --continue my-task "Now also add unit tests for that feature"

    # Kill a running task
    delegate.sh --kill my-task

    # Clean up idle sessions (completed tasks still open)
    delegate.sh --clean

    # Kill ALL delegate sessions (including running)
    delegate.sh --clean-all

    # Delete a session and its logs completely
    delegate.sh --purge my-task

    # Delete ALL sessions and logs
    delegate.sh --purge

${YELLOW}COMMON ROLES:${NC}
    Available in: ${COMMON_ROLES_DIR}/
    List with: delegate.sh --list-roles

${YELLOW}LOGS:${NC}
    Logs are saved to: ${LOG_DIR}/
    - stdout (agent comms): <timestamp>_<name>_stdout.log
    - stderr (verbose/debug): <timestamp>_<name>_stderr.log

${YELLOW}TMUX SESSION MANAGEMENT:${NC}
    Tasks run in tmux sessions prefixed with 'delegate-'
    - List sessions:  tmux list-sessions | grep delegate
    - Attach:         tmux attach -t delegate-<name>
    - Detach:         Ctrl+B, then D
    - Kill:           delegate.sh --kill <name>

EOF
}

show_status() {
    local filter="$1"
    echo -e "${GREEN}Delegate Sessions${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    
    local sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^delegate-" || true)
    
    if [[ -z "$sessions" ]]; then
        echo -e "${YELLOW}No active delegate sessions${NC}"
        echo ""
        echo -e "Recent logs in ${LOG_DIR}/:"
        ls -lt "$LOG_DIR"/*.log 2>/dev/null | head -10 | awk '{print "  " $NF}' || echo "  (no logs found)"
        return 0
    fi
    
    for session in $sessions; do
        local name="${session#delegate-}"
        if [[ -n "$filter" && "$name" != *"$filter"* ]]; then
            continue
        fi
        
        echo -e "${YELLOW}Session:${NC} $name"
        
        # Find matching log files
        local log_pattern="${LOG_DIR}/*_${name}_*.log"
        local stdout_log=$(ls -t ${LOG_DIR}/*_${name}_stdout.log 2>/dev/null | head -1)
        local stderr_log=$(ls -t ${LOG_DIR}/*_${name}_stderr.log 2>/dev/null | head -1)
        
        if [[ -n "$stdout_log" ]]; then
            echo -e "  ${BLUE}stdout:${NC} $stdout_log"
        fi
        if [[ -n "$stderr_log" ]]; then
            echo -e "  ${BLUE}stderr:${NC} $stderr_log"
        fi
        
        echo -e "  ${BLUE}Commands:${NC}"
        echo -e "    Attach:  tmux attach -t $session"
        echo -e "    Kill:    delegate.sh --kill $name"
        if [[ -n "$stderr_log" ]]; then
            echo -e "    Tail:    tail -f $stderr_log"
        fi
        echo ""
    done
}

kill_session() {
    local name="$1"
    local session="delegate-$name"
    
    if tmux has-session -t "$session" 2>/dev/null; then
        tmux kill-session -t "$session"
        echo -e "${GREEN}Killed session:${NC} $session"
    else
        echo -e "${RED}Session not found:${NC} $session"
        echo -e "Active sessions:"
        tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^delegate-" | sed 's/^delegate-/  /' || echo "  (none)"
        exit 1
    fi
}

clean_sessions() {
    local kill_running="$1"
    local killed=0
    local skipped=0
    
    local sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^delegate-" || true)
    
    if [[ -z "$sessions" ]]; then
        echo -e "${YELLOW}No delegate sessions to clean${NC}"
        return 0
    fi
    
    for session in $sessions; do
        local name="${session#delegate-}"
        local pane_pid=$(tmux list-panes -t "$session" -F '#{pane_pid}' 2>/dev/null)
        local children=$(ps --ppid "$pane_pid" -o comm= 2>/dev/null | grep -v '^$' | wc -l)
        
        if [[ "$children" -gt 0 ]]; then
            # Session is running
            if [[ "$kill_running" == "true" ]]; then
                tmux kill-session -t "$session" 2>/dev/null
                echo -e "${RED}Killed running:${NC} $name"
                killed=$((killed + 1))
            else
                echo -e "${YELLOW}Skipped running:${NC} $name"
                skipped=$((skipped + 1))
            fi
        else
            # Session is idle
            tmux kill-session -t "$session" 2>/dev/null
            echo -e "${GREEN}Killed idle:${NC} $name"
            killed=$((killed + 1))
        fi
    done
    
    echo -e "${BLUE}───────────────────────────────────────────────────────────────${NC}"
    echo -e "Cleaned: ${GREEN}$killed killed${NC}, ${YELLOW}$skipped skipped${NC}"
}

purge_session() {
    local name="$1"
    
    if [[ -z "$name" ]]; then
        # Purge ALL sessions and logs
        echo -e "${RED}⚠️  This will delete ALL delegate sessions and logs!${NC}"
        echo -n "Are you sure? (y/N): "
        read -r confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo -e "${YELLOW}Cancelled${NC}"
            return 0
        fi
        
        # Kill all sessions
        local sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^delegate-" || true)
        for session in $sessions; do
            tmux kill-session -t "$session" 2>/dev/null
            echo -e "${RED}Killed:${NC} $session"
        done
        
        # Delete all logs
        local log_count=$(ls ${LOG_DIR}/*.log ${LOG_DIR}/*.txt 2>/dev/null | wc -l)
        rm -f ${LOG_DIR}/*.log ${LOG_DIR}/*.txt 2>/dev/null
        echo -e "${RED}Deleted:${NC} $log_count log files"
    else
        # Purge specific session
        local session="delegate-$name"
        
        # Kill tmux sessions
        tmux kill-session -t "$session" 2>/dev/null && echo -e "${RED}Killed:${NC} $session"
        tmux kill-session -t "${session}-continue" 2>/dev/null && echo -e "${RED}Killed:${NC} ${session}-continue"
        
        # Delete logs for this session
        local log_files=$(ls ${LOG_DIR}/*_${name}_*.log ${LOG_DIR}/*_${name}_*.txt 2>/dev/null || true)
        if [[ -n "$log_files" ]]; then
            local count=$(echo "$log_files" | wc -l)
            rm -f ${LOG_DIR}/*_${name}_*.log ${LOG_DIR}/*_${name}_*.txt 2>/dev/null
            echo -e "${RED}Deleted:${NC} $count log files for '$name'"
        else
            echo -e "${YELLOW}No logs found for:${NC} $name"
        fi
    fi
}

check_session() {
    local name="$1"
    local session="delegate-$name"
    
    if tmux has-session -t "$session" 2>/dev/null; then
        # Check if actively running or just idle (waiting on 'read')
        local pane_pid=$(tmux list-panes -t "$session" -F '#{pane_pid}' 2>/dev/null)
        local children=$(ps --ppid "$pane_pid" -o comm= 2>/dev/null | grep -v '^$' | wc -l)
        
        if [[ "$children" -gt 0 ]]; then
            echo -e "${YELLOW}⏳ Running${NC}  $name"
        else
            echo -e "${BLUE}💤 Idle${NC}     $name (task complete, session open)"
        fi
    else
        # Check if there are log files for this session (it ran but completed)
        local log_files=$(ls -t ${LOG_DIR}/*_${name}_*.log 2>/dev/null | head -1)
        if [[ -n "$log_files" ]]; then
            echo -e "${GREEN}✅ Done${NC}     $name"
        else
            echo -e "${RED}❓ Unknown${NC}  $name (no session or logs found)"
            return 1
        fi
    fi
    return 0
}

check_all_sessions() {
    echo -e "${GREEN}Delegate Session Status${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    
    # Get all unique task names from logs and active sessions
    local all_names=""
    
    # From active tmux sessions
    local active=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^delegate-" | sed 's/^delegate-//' || true)
    
    # From log files (extract task name from filename pattern: YYYYMMDD_HHMMSS_name_stdout.log)
    # The timestamp is 15 chars: YYYYMMDD_HHMMSS
    local from_logs=$(ls ${LOG_DIR}/*_stdout.log 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/^[0-9]\{8\}_[0-9]\{6\}_//' | sed 's/_stdout\.log$//' | sort -u || true)
    
    # Combine and deduplicate
    all_names=$(echo -e "$active\n$from_logs" | grep -v '^$' | sort -u)
    
    if [[ -z "$all_names" ]]; then
        echo -e "${YELLOW}No delegate sessions found${NC}"
        return 0
    fi
    
    local running=0
    local idle=0
    local done=0
    
    for name in $all_names; do
        local session="delegate-$name"
        if tmux has-session -t "$session" 2>/dev/null; then
            # Check if actively running or just idle (waiting on 'read')
            local pane_pid=$(tmux list-panes -t "$session" -F '#{pane_pid}' 2>/dev/null)
            local children=$(ps --ppid "$pane_pid" -o comm= 2>/dev/null | grep -v '^$' | wc -l)
            
            if [[ "$children" -gt 0 ]]; then
                echo -e "${YELLOW}⏳ Running${NC}  $name"
                running=$((running + 1))
            else
                echo -e "${BLUE}💤 Idle${NC}     $name"
                idle=$((idle + 1))
            fi
        else
            echo -e "${GREEN}✅ Done${NC}     $name"
            done=$((done + 1))
        fi
    done
    
    echo -e "${BLUE}───────────────────────────────────────────────────────────────${NC}"
    echo -e "Total: ${YELLOW}$running running${NC}, ${BLUE}$idle idle${NC}, ${GREEN}$done completed${NC}"
}

continue_session() {
    local name="$1"
    local message="$2"
    local session="delegate-$name"
    
    if [[ -z "$message" ]]; then
        echo -e "${RED}Error: No message provided for --continue${NC}"
        echo -e "Usage: delegate.sh --continue <name> \"<message>\""
        exit 1
    fi
    
    # Find the most recent stderr log for this session to get the session ID
    local stderr_log=$(ls -t ${LOG_DIR}/*_${name}_stderr.log 2>/dev/null | head -1)
    
    if [[ -z "$stderr_log" ]]; then
        echo -e "${RED}Error: No logs found for session '$name'${NC}"
        echo -e "Cannot continue a session that was never started."
        exit 1
    fi
    
    # Extract the codex session ID from the log
    # Codex outputs something like "session id: abc123" or stores it in the log
    local session_id=$(grep -oP 'session id:\s*\K[a-zA-Z0-9_-]+' "$stderr_log" | tail -1)
    
    if [[ -z "$session_id" ]]; then
        # Try alternative pattern - codex might output it differently
        session_id=$(grep -oP 'Session:\s*\K[a-zA-Z0-9_-]+' "$stderr_log" | tail -1)
    fi
    
    if [[ -z "$session_id" ]]; then
        # Try to find any session-like ID in the log
        session_id=$(grep -oP 'ses_[a-zA-Z0-9]+' "$stderr_log" | tail -1)
    fi
    
    if [[ -z "$session_id" ]]; then
        echo -e "${RED}Error: Could not find codex session ID in logs${NC}"
        echo -e "Log file: $stderr_log"
        echo -e ""
        echo -e "The session may have completed without storing a session ID,"
        echo -e "or codex may not have output the session ID in a recognizable format."
        echo -e ""
        echo -e "You can try:"
        echo -e "  1. Start a new task: delegate.sh -c <role> -g \"<goal>\" -t \"<task>\" -n new-name"
        echo -e "  2. Check the log manually: tail $stderr_log"
        exit 1
    fi
    
    # Get log file base from original session - use timestamp for unique continue logs
    local log_base=$(echo "$stderr_log" | sed 's/_stderr\.log$//')
    local continue_timestamp=$(date +"%Y%m%d_%H%M%S")
    local continue_stderr="${log_base}_continue_${continue_timestamp}_stderr.log"
    local continue_stdout="${log_base}_continue_${continue_timestamp}_stdout.log"
    
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}Continuing session: $name${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}Session ID:${NC} $session_id"
    echo -e "${YELLOW}Message:${NC} $message"
    echo -e "${BLUE}───────────────────────────────────────────────────────────────${NC}"
    
    # Function to check if a tmux session is busy (has child processes running)
    is_session_busy() {
        local check_session="$1"
        
        # If tmux session doesn't exist, not busy
        if ! tmux has-session -t "$check_session" 2>/dev/null; then
            return 1
        fi
        
        # Get the pane's shell PID
        local pane_pid=$(tmux list-panes -t "$check_session" -F '#{pane_pid}' 2>/dev/null)
        
        if [[ -z "$pane_pid" ]]; then
            return 1
        fi
        
        # Check if there are any child processes (codex, tee, etc.)
        # If no children, the shell is idle (waiting on 'read')
        local children=$(ps --ppid "$pane_pid" -o comm= 2>/dev/null | grep -v '^$' | wc -l)
        
        if [[ "$children" -gt 0 ]]; then
            return 0  # Busy - has child processes
        else
            return 1  # Not busy - shell is idle
        fi
    }
    
    # Wait for any active codex processes to complete (exponential backoff)
    local wait_time=1
    local max_wait=60
    local total_waited=0
    
    while is_session_busy "$session" || is_session_busy "${session}-continue"; do
        echo -e "${YELLOW}⏳ Previous task still running, waiting ${wait_time}s...${NC}"
        sleep "$wait_time"
        total_waited=$((total_waited + wait_time))
        
        # Exponential backoff: 1, 2, 4, 8, 16, 32, 60, 60, ...
        wait_time=$((wait_time * 2))
        if [[ $wait_time -gt $max_wait ]]; then
            wait_time=$max_wait
        fi
        
        # Safety timeout after 10 minutes
        if [[ $total_waited -gt 600 ]]; then
            echo -e "${RED}Timeout: Previous task still running after 10 minutes${NC}"
            echo -e "You can:"
            echo -e "  - Kill it: delegate.sh --kill $name"
            echo -e "  - Attach:  tmux attach -t $session"
            exit 1
        fi
    done
    
    if [[ $total_waited -gt 0 ]]; then
        echo -e "${GREEN}✓ Previous task completed after ${total_waited}s${NC}"
    fi
    
    # Clean up old tmux sessions (they're just waiting on 'read' now)
    tmux kill-session -t "$session" 2>/dev/null || true
    tmux kill-session -t "${session}-continue" 2>/dev/null || true
    
    # Create a fresh tmux session for this continuation
    local new_session="${session}-continue"
    TMUX_CMD="echo '$message' | codex exec --yolo resume '$session_id' - 2> >(tee -a '$continue_stderr' >&2) | tee -a '$continue_stdout'; echo ''; echo 'Continuation completed. Press Enter to close or Ctrl+C to keep open.'; read"
    tmux new-session -d -s "$new_session" "bash -c \"$TMUX_CMD\""
    
    echo -e "${GREEN}✓ Continuation started${NC}"
    echo -e ""
    echo -e "${YELLOW}Session:${NC} $new_session"
    echo -e "${YELLOW}Logs:${NC}"
    echo -e "  stdout: $continue_stdout"
    echo -e "  stderr: $continue_stderr"
    echo -e ""
    echo -e "${YELLOW}Commands:${NC}"
    echo -e "  Attach:  tmux attach -t $new_session"
    echo -e "  Tail:    tail -f $continue_stderr"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
}

list_roles() {
    echo -e "${GREEN}Available common roles:${NC}"
    echo -e "${BLUE}───────────────────────────────────────────────────────────────${NC}"
    if [[ -d "$COMMON_ROLES_DIR" ]]; then
        for role_file in "$COMMON_ROLES_DIR"/*.md; do
            if [[ -f "$role_file" ]]; then
                local role_name=$(basename "$role_file" .md)
                local first_line=$(head -1 "$role_file" | sed 's/^# //')
                echo -e "  ${YELLOW}$role_name${NC}"
                echo -e "    $first_line"
                echo ""
            fi
        done
    else
        echo -e "${RED}No common-roles directory found at: $COMMON_ROLES_DIR${NC}"
    fi
}

load_common_role() {
    local role_name="$1"
    local role_file="$COMMON_ROLES_DIR/${role_name}.md"
    
    if [[ ! -f "$role_file" ]]; then
        echo -e "${RED}Error: Common role not found: $role_name${NC}" >&2
        echo -e "Looking for: $role_file" >&2
        echo -e "Available roles:" >&2
        ls "$COMMON_ROLES_DIR"/*.md 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\.md$//' >&2
        exit 1
    fi
    
    # Read the role file, skip the first line if it's a markdown header
    local content=$(cat "$role_file")
    if [[ "$content" == "#"* ]]; then
        # Skip the first line (title) and any empty lines after it
        content=$(echo "$content" | tail -n +2 | sed '/^$/d' | head -1)
        # If the second line is empty, get the actual content
        if [[ -z "$content" ]]; then
            content=$(cat "$role_file" | tail -n +2 | grep -v '^$' | head -1)
        fi
        # Actually, let's get everything after the title
        content=$(cat "$role_file" | tail -n +3)
    fi
    
    echo "$content"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -r|--role)
            ROLE="$2"
            shift 2
            ;;
        -c|--common-role)
            ROLE=$(load_common_role "$2")
            shift 2
            ;;
        -g|--goal)
            GOAL="$2"
            shift 2
            ;;
        -a|--acceptance-criteria)
            ACCEPTANCE_CRITERIA="$2"
            shift 2
            ;;
        -w|--why)
            THE_WHY="$2"
            shift 2
            ;;
        -t|--task-detail)
            TASK_DETAIL="$2"
            shift 2
            ;;
        -n|--name)
            TASK_NAME="$2"
            shift 2
            ;;
        -f|--foreground)
            FOREGROUND=true
            shift
            ;;
        -l|--list-roles)
            list_roles
            exit 0
            ;;
        -s|--status)
            if [[ -n "$2" && "$2" != -* ]]; then
                show_status "$2"
                shift 2
            else
                show_status ""
                shift
            fi
            exit 0
            ;;
        -k|--kill)
            kill_session "$2"
            shift 2
            exit 0
            ;;
        --check)
            check_session "$2"
            shift 2
            exit 0
            ;;
        --check-all)
            check_all_sessions
            shift
            exit 0
            ;;
        --clean)
            clean_sessions "false"
            shift
            exit 0
            ;;
        --clean-all)
            clean_sessions "true"
            shift
            exit 0
            ;;
        --purge)
            if [[ -n "$2" && "$2" != -* ]]; then
                purge_session "$2"
                shift 2
            else
                purge_session ""
                shift
            fi
            exit 0
            ;;
        --continue)
            continue_session "$2" "$3"
            shift 3
            exit 0
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            show_help
            exit 1
            ;;
    esac
done

# Validate required fields
if [[ -z "$GOAL" && -z "$TASK_DETAIL" ]]; then
    echo -e "${RED}Error: At least --goal or --task-detail must be provided${NC}"
    show_help
    exit 1
fi

# Create log directory if it doesn't exist
mkdir -p "$LOG_DIR"

# Generate log filenames
TASK_NAME="${TASK_NAME:-task}"
TASK_NAME_SAFE=$(echo "$TASK_NAME" | tr ' ' '_' | tr -cd '[:alnum:]_-')
STDOUT_LOG="${LOG_DIR}/${TIMESTAMP}_${TASK_NAME_SAFE}_stdout.log"
STDERR_LOG="${LOG_DIR}/${TIMESTAMP}_${TASK_NAME_SAFE}_stderr.log"
SESSION_NAME="delegate-${TASK_NAME_SAFE}"

# Check for existing session with same name
if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo -e "${RED}Error: Session '$SESSION_NAME' already exists${NC}"
    echo -e "Either:"
    echo -e "  - Use a different name: -n different-name"
    echo -e "  - Kill the existing session: delegate.sh --kill $TASK_NAME_SAFE"
    echo -e "  - Check its status: delegate.sh --status $TASK_NAME_SAFE"
    exit 1
fi

# Build the prompt
build_prompt() {
    local prompt=""
    
    if [[ -n "$ROLE" ]]; then
        prompt+="<role>
$ROLE
</role>
"
    fi
    
    prompt+="<task>
"
    
    if [[ -n "$GOAL" ]]; then
        prompt+="  <goal>$GOAL</goal>
"
    fi
    
    if [[ -n "$ACCEPTANCE_CRITERIA" ]]; then
        prompt+="  <acceptanceCriteria>$ACCEPTANCE_CRITERIA</acceptanceCriteria>
"
    fi
    
    if [[ -n "$THE_WHY" ]]; then
        prompt+="  <theWhy>$THE_WHY</theWhy>
"
    fi
    
    if [[ -n "$TASK_DETAIL" ]]; then
        prompt+="  <taskDetail>$TASK_DETAIL</taskDetail>
"
    fi
    
    prompt+="</task>"
    
    echo "$prompt"
}

PROMPT=$(build_prompt)

# Save prompt to a temp file for tmux to read
PROMPT_FILE="${LOG_DIR}/${TIMESTAMP}_${TASK_NAME_SAFE}_prompt.txt"
echo "$PROMPT" > "$PROMPT_FILE"

if [[ "$FOREGROUND" == true ]]; then
    # Run in foreground (original behavior)
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}Running task in foreground${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}Logs:${NC}"
    echo -e "  stdout: ${STDOUT_LOG}"
    echo -e "  stderr: ${STDERR_LOG}"
    echo -e "${BLUE}───────────────────────────────────────────────────────────────${NC}"
    echo -e "${YELLOW}Prompt being sent:${NC}"
    echo "$PROMPT"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"

    # Execute codex with the prompt
    cat "$PROMPT_FILE" | codex exec --yolo 2> >(tee "$STDERR_LOG" >&2) | tee "$STDOUT_LOG"
    EXIT_CODE=${PIPESTATUS[0]}

    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    if [[ $EXIT_CODE -eq 0 ]]; then
        echo -e "${GREEN}Task completed successfully${NC}"
    else
        echo -e "${RED}Task failed with exit code: $EXIT_CODE${NC}"
    fi
    echo -e "${YELLOW}Logs saved to:${NC}"
    echo -e "  stdout: ${STDOUT_LOG}"
    echo -e "  stderr: ${STDERR_LOG}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    exit $EXIT_CODE
else
    # Run in tmux session (default)
    
    # Create the command to run inside tmux
    TMUX_CMD="cat '$PROMPT_FILE' | codex exec --yolo 2> >(tee '$STDERR_LOG' >&2) | tee '$STDOUT_LOG'; echo ''; echo 'Task completed. Press Enter to close session or Ctrl+C to keep it open.'; read"
    
    # Start tmux session
    tmux new-session -d -s "$SESSION_NAME" "bash -c \"$TMUX_CMD\""
    
    # Output session info
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}✓ Task delegated to tmux session${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}Session:${NC}  $SESSION_NAME"
    echo -e "${YELLOW}Task:${NC}     ${GOAL:-$TASK_DETAIL}"
    echo ""
    echo -e "${BLUE}───────────────────────────────────────────────────────────────${NC}"
    echo -e "${YELLOW}Logs:${NC}"
    echo -e "  stdout: ${STDOUT_LOG}"
    echo -e "  stderr: ${STDERR_LOG}"
    echo -e "  prompt: ${PROMPT_FILE}"
    echo ""
    echo -e "${BLUE}───────────────────────────────────────────────────────────────${NC}"
    echo -e "${YELLOW}Commands:${NC}"
    echo ""
    echo -e "  ${GREEN}# Attach to watch live:${NC}"
    echo -e "  tmux attach -t $SESSION_NAME"
    echo ""
    echo -e "  ${GREEN}# Tail the logs:${NC}"
    echo -e "  tail -f $STDERR_LOG"
    echo ""
    echo -e "  ${GREEN}# Check if still running:${NC}"
    echo -e "  tmux has-session -t $SESSION_NAME 2>/dev/null && echo 'Running' || echo 'Done'"
    echo ""
    echo -e "  ${GREEN}# View all delegate sessions:${NC}"
    echo -e "  delegate.sh --status"
    echo ""
    echo -e "  ${GREEN}# Kill this session:${NC}"
    echo -e "  delegate.sh --kill $TASK_NAME_SAFE"
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
fi
