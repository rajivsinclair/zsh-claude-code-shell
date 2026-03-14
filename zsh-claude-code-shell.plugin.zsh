# zsh-claude-code-shell - Generate shell commands from natural language using Claude Code
# Usage: Type "# <description>" and press Enter to generate a command

# Configuration
: ${ZSH_CLAUDE_SHELL_DISABLED:=0}
: ${ZSH_CLAUDE_SHELL_MODEL:=}
: ${ZSH_CLAUDE_SHELL_DEBUG:=0}
: ${ZSH_CLAUDE_SHELL_FANCY_LOADING:=1}  # Set to 0 to use simple loading message
: ${ZSH_CLAUDE_SHELL_ERROR_HINT:=1}     # Set to 0 to disable error feedback hints

# Error tracking state
_ZSH_CLAUDE_LAST_GENERATED=""   # command the plugin just placed in the buffer
_ZSH_CLAUDE_WATCHING=0          # 1 = the currently executing command was plugin-generated
_ZSH_CLAUDE_FAILED_CMD=""       # last failed plugin-generated command (for context injection)
_ZSH_CLAUDE_FAILED_EXIT=0       # its exit code

# Thinking verbs (from Claude Code)
_ZSH_CLAUDE_THINKING_VERBS=(
    "Accomplishing" "Actioning" "Actualizing" "Baking" "Brewing"
    "Calculating" "Cerebrating" "Churning" "Clauding" "Coalescing"
    "Cogitating" "Computing" "Conjuring" "Considering" "Cooking"
    "Crafting" "Creating" "Crunching" "Deliberating" "Determining"
    "Doing" "Effecting" "Finagling" "Forging" "Forming" "Generating"
    "Hatching" "Herding" "Honking" "Hustling" "Ideating" "Inferring"
    "Manifesting" "Marinating" "Moseying" "Mulling" "Mustering" "Musing"
    "Noodling" "Percolating" "Pondering" "Processing" "Puttering"
    "Reticulating" "Ruminating" "Schlepping" "Shucking" "Simmering"
    "Smooshing" "Spinning" "Stewing" "Synthesizing" "Thinking"
    "Transmuting" "Vibing" "Working"
)

# Spinner animation (runs in background, writes to /dev/tty)
_zsh_claude_spinner() {
    local spinchars='✽⊹✦◈'
    local spin_len=4
    local words_len=${#_ZSH_CLAUDE_THINKING_VERBS[@]}
    local i=1
    local w=$(( RANDOM % words_len + 1 ))  # Start with random word
    local tick=0

    # Colors for shimmering effect (cyan gradient)
    local -a colors=('\033[96m' '\033[36m' '\033[96m' '\033[36m')
    local color_idx=1

    # Hide cursor
    printf '\033[?25l' > /dev/tty

    while true; do
        local char="${spinchars[$i]}"
        local word="${_ZSH_CLAUDE_THINKING_VERBS[$w]}"
        local color="${colors[$color_idx]}"

        # Print spinner with shimmering color effect
        printf '\r\033[K%b%s %s...\033[0m' "$color" "$char" "$word" > /dev/tty

        i=$(( i % spin_len + 1 ))
        tick=$(( tick + 1 ))
        color_idx=$(( color_idx % 4 + 1 ))

        # Change word every ~12 ticks (~1.2 seconds)
        if (( tick % 12 == 0 )); then
            w=$(( RANDOM % words_len + 1 ))
        fi
        sleep 0.1
    done
}

# Stop spinner and cleanup
_zsh_claude_stop_spinner() {
    local pid=$1
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        # Small delay to let the process terminate
        sleep 0.05
    fi
    # Show cursor, clear spinner line, move up one line, clear that line too
    # This returns cursor to the original query line position
    printf '\033[?25h\r\033[K\033[A\r\033[K' > /dev/tty
}

# Check if claude CLI is available (lazy check - deferred until first use)
_zsh_claude_check_cli() {
    if ! command -v claude &> /dev/null; then
        echo "zsh-claude-code-shell: 'claude' command not found. Please install Claude Code CLI."
        return 1
    fi
    return 0
}

# Sanitize output - remove markdown code blocks and trim whitespace
_zsh_claude_sanitize() {
    local input="$1"

    # Remove markdown code block markers (```bash, ```, etc.)
    input="${input#\`\`\`*$'\n'}"  # Remove opening ```lang\n
    input="${input%\`\`\`}"         # Remove closing ```
    input="${input#\`\`\`}"         # Remove opening ``` without newline

    # Remove single backticks wrapping the whole command
    if [[ "$input" == \`*\` ]]; then
        input="${input#\`}"
        input="${input%\`}"
    fi

    # Trim leading/trailing whitespace
    input="${input#"${input%%[![:space:]]*}"}"
    input="${input%"${input##*[![:space:]]}"}"

    echo "$input"
}

# preexec hook — fires just before a command executes
_zsh_claude_preexec() {
    if [[ -n "$_ZSH_CLAUDE_LAST_GENERATED" ]] && [[ "$1" == "$_ZSH_CLAUDE_LAST_GENERATED" ]]; then
        _ZSH_CLAUDE_WATCHING=1
    else
        _ZSH_CLAUDE_WATCHING=0
    fi
    _ZSH_CLAUDE_LAST_GENERATED=""
}

# precmd hook — fires after a command completes, before prompt
_zsh_claude_precmd() {
    local last_exit=$?
    if [[ "$_ZSH_CLAUDE_WATCHING" == "1" ]] && [[ $last_exit -ne 0 ]]; then
        _ZSH_CLAUDE_FAILED_CMD="$_ZSH_CLAUDE_PREEXEC_CMD"
        _ZSH_CLAUDE_FAILED_EXIT=$last_exit
        if [[ "$ZSH_CLAUDE_SHELL_ERROR_HINT" == "1" ]]; then
            print -P "%F{yellow}💡 Command failed (exit $last_exit). Type %F{cyan}?%F{yellow} to troubleshoot%f"
        fi
    fi
    _ZSH_CLAUDE_WATCHING=0
}

# Enriched preexec that also saves the command text for precmd
_zsh_claude_preexec_wrapper() {
    _ZSH_CLAUDE_PREEXEC_CMD="$1"
    _zsh_claude_preexec "$1"
}

# Main widget that intercepts Enter key
_zsh_claude_accept_line() {
    # Pass through if disabled
    if [[ "$ZSH_CLAUDE_SHELL_DISABLED" == "1" ]]; then
        zle .accept-line
        return
    fi

    # Normalize "? " prefix to "# " so both work as triggers
    if [[ "$BUFFER" =~ ^'? ' ]] || ( [[ "$BUFFER" == "?" ]] && [[ -n "$_ZSH_CLAUDE_FAILED_CMD" ]] ); then
        BUFFER="# ${BUFFER:2}"
    fi

    # Pass through if buffer doesn't start with "# "
    if [[ ! "$BUFFER" =~ ^'# ' ]]; then
        zle .accept-line
        return
    fi

    # Pass through multi-line buffers
    if [[ "$BUFFER" == *$'\n'* ]]; then
        zle .accept-line
        return
    fi

    # Extract query (remove "# " prefix)
    local query="${BUFFER:2}"

    # Skip empty queries
    if [[ -z "${query// }" ]]; then
        zle .accept-line
        return
    fi

    # Check if claude CLI is available
    if ! _zsh_claude_check_cli; then
        zle reset-prompt
        return 1
    fi

    # Inject error context for troubleshooting queries (? or why/fix/explain/etc.)
    if [[ -n "$_ZSH_CLAUDE_FAILED_CMD" ]] && [[ "$query" =~ ^(\?|why|fix|explain|what happened|debug|help) ]]; then
        query="The following shell command failed with exit code $_ZSH_CLAUDE_FAILED_EXIT: \`$_ZSH_CLAUDE_FAILED_CMD\`. ${query#\? }"
        _ZSH_CLAUDE_FAILED_CMD=""
        _ZSH_CLAUDE_FAILED_EXIT=0
    fi

    # Start spinner or show simple message
    local spinner_pid=""
    if [[ "$ZSH_CLAUDE_SHELL_FANCY_LOADING" == "1" ]]; then
        # Print newline so spinner appears below the query line
        print > /dev/tty
        # Disable job notifications to prevent [1] 12345 and terminated messages
        setopt local_options no_notify no_monitor
        _zsh_claude_spinner &
        spinner_pid=$!
        disown $spinner_pid 2>/dev/null
    else
        zle -R "Generating command with Claude..."
    fi

    # Build claude command with full tool access for local context
    local claude_args=("-p" "--output-format" "text")
    claude_args+=("--system-prompt" "You are a shell command generator. Your ONLY job is to output a single shell command that accomplishes the user's request. You can read local files, list directories, and search the web to understand context before answering. Output ONLY the raw shell command - no markdown, no code blocks, no explanations, no comments, no backticks. Just the executable command itself on a single line.")

    if [[ -n "$ZSH_CLAUDE_SHELL_MODEL" ]]; then
        claude_args+=("--model" "$ZSH_CLAUDE_SHELL_MODEL")
    fi

    # Call Claude Code CLI with output to temp file so we can use wait
    local tmpfile="${TMPDIR:-/tmp}/zsh-claude-$$"
    local claude_pid
    local exit_code
    local cmd

    if [[ "$ZSH_CLAUDE_SHELL_DEBUG" == "1" ]]; then
        claude "${claude_args[@]}" "$query" > "$tmpfile" 2>&1 &
    else
        claude "${claude_args[@]}" "$query" > "$tmpfile" 2>/dev/null &
    fi
    claude_pid=$!

    # Set up trap to clean up on interrupt (Ctrl+C)
    trap '
        kill $claude_pid 2>/dev/null
        [[ -n "$spinner_pid" ]] && _zsh_claude_stop_spinner "$spinner_pid"
        rm -f "$tmpfile"
        trap - INT
        zle reset-prompt
        return 130
    ' INT

    # Wait for claude to finish
    wait $claude_pid
    exit_code=$?

    # Reset trap and stop spinner
    trap - INT
    [[ -n "$spinner_pid" ]] && _zsh_claude_stop_spinner "$spinner_pid"

    # Read output from temp file
    cmd=$(<"$tmpfile")
    rm -f "$tmpfile"

    # Handle interrupt (Ctrl+C) - exit code 130 = 128 + SIGINT(2)
    if [[ $exit_code -eq 130 ]] || [[ $exit_code -eq 143 ]]; then
        zle reset-prompt
        return 130
    fi

    # Handle errors
    if [[ $exit_code -ne 0 ]] || [[ -z "$cmd" ]]; then
        zle -M "Error: Failed to generate command (exit code: $exit_code)"
        zle reset-prompt
        return 1
    fi

    # Sanitize the output
    cmd=$(_zsh_claude_sanitize "$cmd")

    # Replace buffer with generated command and track it for error detection
    BUFFER="$cmd"
    CURSOR=${#BUFFER}
    _ZSH_CLAUDE_LAST_GENERATED="$cmd"

    zle reset-prompt
}

# Initialize the plugin
_zsh_claude_init() {
    zle -N accept-line _zsh_claude_accept_line

    # Register preexec/precmd hooks (additive — won't clobber other hooks)
    autoload -Uz add-zsh-hook
    add-zsh-hook preexec _zsh_claude_preexec_wrapper
    add-zsh-hook precmd _zsh_claude_precmd
}

_zsh_claude_init
