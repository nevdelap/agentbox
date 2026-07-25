# The main point of agentbox is to allow this, for the specific reason that the
# auto classifiers that do Auto Mode in Claude and Codex cost tokens. So don't
# use agentbox in a directory that is not under source control.

case "$TERM" in
xterm-color | *-256color) color_prompt=yes ;;
esac

if [ "$color_prompt" = yes ]; then
  PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
else
  PS1='\u@\h:\w\$ '
fi
unset color_prompt

warn() {
  echo -ne "\033[31m$1\033[0m   "
  for ((i = 3; i >= 1; i--)); do
    echo -ne "\b\b$i "
    sleep 1
  done
  echo -ne "\r\033[2K"
}

claude() {
  warn "Running Claude with --dangerously-skip-permissions!"
  command claude --dangerously-skip-permissions "$@"
}

codex() {
  warn "Running Codex with --dangerously-bypass-approvals-and-sandbox!"
  command codex --dangerously-bypass-approvals-and-sandbox "$@"
}

export -f warn claude codex
