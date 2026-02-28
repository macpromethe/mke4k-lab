# Skip for non-interactive shells
[[ $- != *i* ]] && return

# History
HISTCONTROL=ignoreboth
shopt -s histappend
HISTSIZE=10000
HISTFILESIZE=20000

# Terminal
shopt -s checkwinsize
export COLORTERM=truecolor

# Prompt
force_color_prompt=yes
if [ -n "$force_color_prompt" ]; then
  if [ -x /usr/bin/tput ] && tput setaf 1 &> /dev/null; then
    color_prompt=yes
  fi
fi

if [ "$color_prompt" = yes ]; then
  PS1='\n['\
'\[$(tput bold)\]\[\033[38;5;39m\]\u\[$(tput sgr0)\]]-'\
'[\[$(tput bold)\]\[\033[38;5;75m\]\h\[$(tput sgr0)\]]-'\
'[\[$(tput bold)\]\[\033[38;5;111m\]\W\[$(tput sgr0)\]]-'\
'[\[$(tput bold)\]\[\033[38;5;150m\]\A\[$(tput sgr0)\]-'\
'\[$(tput bold)\]\[\033[38;5;180m\]\d\[$(tput sgr0)\]]\n\\$ '
else
  PS1='\n[\u]-[\h]-[\W]-[\A-\d]\n\\$ '
fi
unset color_prompt force_color_prompt

# Colorized tools
if [ -x /usr/bin/dircolors ]; then
  eval "$(dircolors -b)"
  alias ls='ls --color=auto'
  alias grep='grep --color=auto'
fi

# Aliases
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias k='kubectl'
alias h='helm'

# Standalone connect shortcut — connect m1, connect w1 "uptime", etc.
connect() { t connect "$@"; }

# Autocompletion
if ! shopt -oq posix; then
  [[ -f /usr/share/bash-completion/bash_completion ]] && . /usr/share/bash-completion/bash_completion
  [[ -f /etc/bash_completion ]] && . /etc/bash_completion
fi
source <(kubectl completion bash) 2>/dev/null || true
complete -F __start_kubectl k 2>/dev/null || true
complete -C /usr/local/bin/terraform terraform 2>/dev/null || true

# Source project config (makes vars like cluster_name available at shell)
[[ -f /mke4k-lab/config ]] && source /mke4k-lab/config

# Set KUBECONFIG automatically if a cluster kubeconfig exists
[[ -f "${HOME}/.mke/mke.kubeconf" ]] && export KUBECONFIG="${HOME}/.mke/mke.kubeconf"

[[ -f /etc/motd ]] && cat /etc/motd
