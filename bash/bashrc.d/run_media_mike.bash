# Common argument rewriter for /run/media/mike
_expand_media_args() {
    local target_prefix="/run/media/mike"
    _rewritten_args=()
    for arg in "$@"; do
        case "$arg" in
            m)
                _rewritten_args+=("$target_prefix")
                ;;
            m/*)
                _rewritten_args+=("${target_prefix}/${arg#m/}")
                ;;
            *)
                _rewritten_args+=("$arg")
                ;;
        esac
    done
}

# Function wrappers
cd() {
    _expand_media_args "$@"
    builtin cd "${_rewritten_args[@]}"
}

lsm() {
    _expand_media_args "$@"
    command ls "${_rewritten_args[@]}"
}

cp() {
    _expand_media_args "$@"
    command cp "${_rewritten_args[@]}"
}

mv() {
    _expand_media_args "$@"
    command mv "${_rewritten_args[@]}"
}

mkdir() {
    _expand_media_args "$@"
    command mkdir "${_rewritten_args[@]}"
}

rmdir() {
    _expand_media_args "$@"
    command rmdir "${_rewritten_args[@]}"
}

_complete_media_prefix() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local media_root="/run/media/mike"

    if [[ "$cur" == m/* ]]; then
        local subpath="${cur#m/}"
        local matches=()

        # Generate completions relative to /run/media/mike
        while IFS= read -r match; do
            matches+=("m/${match#"$media_root"/}")
        done < <(compgen -d -- "$media_root/$subpath")

        COMPREPLY=("${matches[@]}")
        return 0
    fi

    # Fallback to standard directory completion for non-m/ paths
    COMPREPLY=($(compgen -d -- "$cur"))
}

# Apply completion to all wrapped directory commands
complete -o filenames -o nospace -F _complete_media_prefix cd ls cp mv mkdir rmdir
