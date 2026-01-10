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
    -k, --kill <name>               Kill a running delegate session
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

    # Kill a running task
    delegate.sh --kill my-task

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
