# zsh-claude-code-shell

## What This Is

A zsh plugin that translates natural language into shell commands using `claude -p` (Claude Code CLI in print mode). Users type `# <description>` or `? <description>` and press Enter — the plugin calls Claude, replaces the buffer with the generated command, and lets the user review before executing.

## Architecture

Single file: `zsh-claude-code-shell.plugin.zsh` (~280 lines of zsh)

### Core Mechanism

The plugin overrides zsh's `accept-line` widget (the Enter key). The widget chain matters:

```
User presses Enter
  → zsh-syntax-highlighting wrapper (outermost, must be sourced last)
    → zsh-autosuggestions wrapper (clears ghost text)
      → _zsh_claude_accept_line (our widget)
        → checks for # or ? prefix
        → if matched: call claude -p, replace buffer
        → if not matched: call .accept-line (built-in)
```

**Sourcing order in .zshrc matters:** This plugin must be sourced BEFORE zsh-autosuggestions, which must be sourced BEFORE zsh-syntax-highlighting. If the order is wrong, autosuggestions' ghost text cleanup on Enter breaks.

### Error Feedback Loop

Three components work together:

1. **`_zsh_claude_accept_line`** — when Claude generates a command and places it in the buffer, saves it to `_ZSH_CLAUDE_LAST_GENERATED`
2. **`_zsh_claude_preexec_wrapper`** (preexec hook) — fires just before the command executes. If it matches `_ZSH_CLAUDE_LAST_GENERATED`, sets `_ZSH_CLAUDE_WATCHING=1` to flag this as a plugin-generated command
3. **`_zsh_claude_precmd`** (precmd hook) — fires after the command completes. If `_ZSH_CLAUDE_WATCHING` is set and exit code is non-zero, saves the failed command/exit code and shows a hint

When the user then types `?` or `# why`/`# fix`/`# explain`, the plugin injects the failed command context into the Claude prompt automatically.

### Trigger Prefixes

- `# <query>` — original trigger (shell comment, harmless)
- `? <query>` — alternative trigger (normalized to `# ` internally before processing)
- `?` (bare, no space) — only activates when there's a failed plugin-generated command to diagnose

Both `#` and `?` are "dead zones" in shell syntax — neither is a valid command prefix, so interception doesn't shadow real shell behavior.

### Claude Invocation

```bash
claude -p --output-format text --system-prompt "..." [--model MODEL] QUERY
```

- `-p` = print mode (one-shot, no persistent session)
- Full tool access (Claude can read local files/dirs for context)
- System prompt constrains output to raw command only (no markdown, no explanation)
- Runs in background with `wait` — spinner shown while waiting
- Output written to temp file, sanitized (strips markdown code blocks, backticks, whitespace)

## Configuration Variables

All use `: ${VAR:=default}` pattern — only set if unset/empty, so exports in .zshrc before sourcing take precedence.

| Variable | Default | Purpose |
|----------|---------|---------|
| `ZSH_CLAUDE_SHELL_DISABLED` | `0` | Kill switch |
| `ZSH_CLAUDE_SHELL_MODEL` | (empty) | Model override (e.g., `sonnet`) |
| `ZSH_CLAUDE_SHELL_DEBUG` | `0` | Show stderr from claude CLI |
| `ZSH_CLAUDE_SHELL_FANCY_LOADING` | `1` | Animated spinner vs simple message |
| `ZSH_CLAUDE_SHELL_ERROR_HINT` | `1` | Show "Type ? to troubleshoot" on failure |

## Key Design Decisions

- **No stderr capture from failed commands.** Wrapping generated commands to capture stderr would show the wrapper in the user's buffer, breaking trust. Instead, we send the command + exit code to Claude and let it reason about likely failures.
- **Hooks use `add-zsh-hook`, not direct assignment.** This appends to the hook array rather than clobbering — safe to coexist with prompt themes and other plugins.
- **`? ` normalization happens early.** The `?` prefix is rewritten to `# ` at the top of `accept-line`, so all downstream logic (extraction, context injection, Claude call) has a single code path.
- **Spinner runs in a background subshell writing to /dev/tty.** This avoids interfering with zle's buffer management. The `no_notify no_monitor` options suppress job control noise.

## When Modifying

- If adding new trigger prefixes, add normalization next to the `? ` check (line ~149)
- If changing the error context injection, the trigger words are in a regex at line ~182
- The `_zsh_claude_sanitize` function handles Claude's tendency to wrap output in markdown — if Claude's output format changes, this is where to fix it
- The spinner cleanup (`_zsh_claude_stop_spinner`) uses ANSI escape sequences to clear lines — if the spinner looks broken in certain terminals, start here
