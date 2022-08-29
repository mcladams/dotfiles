source '~/src/devenv/dotfiles/nu/alias-generated.nu'

alias bat = ^bat --theme GitHub --style header,grid
alias gpd = git-status-prompt-delete-cache
alias gpob = git pull origin (git rev-parse --abbrev-ref HEAD | str trim -r)
alias gpr = git-status-prompt-refresh-cache
alias grh = git-reset-hard
alias gri = git-rebase-interactive
alias ha = $nu.scope.aliases
alias hc = help commands
alias hf = help-find
alias lss = (ls | get name | str collect $"  ")
alias mk = mkdir
alias rgd = rg-delta
