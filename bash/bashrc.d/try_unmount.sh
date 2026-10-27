try_unmount() {
    local force=0
    local non_interactive=0
    local mp=""

    # 1. Parse options and arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--force)
                force=1
                shift
                ;;
            -n|--non-interactive)
                non_interactive=1
                shift
                ;;
            -nf|-fn)
                force=1
                non_interactive=1
                shift
                ;;
            -h|--help)
                echo "Usage: try_unmount [-f|--force] [-n|--non-interactive] <mountpoint>"
                return 0
                ;;
            --)
                shift
                break
                ;;
            -*)
                echo "Error: Unknown option '$1'" >&2
                echo "Usage: try_unmount [-f|--force] [-n|--non-interactive] <mountpoint>" >&2
                return 1
                ;;
            *)
                if [[ -z "$mp" ]]; then
                    mp="$1"
                else
                    echo "Error: Too many arguments provided." >&2
                    return 1
                fi
                shift
                ;;
        esac
    done

    # Handle path passed after '--'
    if [[ -z "$mp" && $# -gt 0 ]]; then
        mp="$1"
    fi

    # Strip trailing slash (unless the target is literally '/')
    [[ "$mp" != "/" ]] && mp="${mp%/}"

    if [[ -z "$mp" ]]; then
        echo "Usage: try_unmount [-f|--force] [-n|--non-interactive] <mountpoint>" >&2
        return 1
    fi

    # 2. Configure sudo behavior based on interactivity mode
    local sudo_cmd=(sudo)
    if [[ $non_interactive -eq 1 ]]; then
        # -n (--non-interactive) prevents sudo from prompting for a password
        sudo_cmd=(sudo -n)
    fi

    # 3. Sanity checks
    if [[ ! -d "$mp" ]]; then
        echo "Error: '$mp' is not a valid directory." >&2
        return 1
    fi

    if ! findmnt --mountpoint "$mp" >/dev/null 2>&1; then
        echo "Notice: '$mp' is not currently a mountpoint."
        return 0
    fi

    # 4. Attempt standard clean unmount first
    [[ $non_interactive -eq 0 ]] && echo "Attempting to unmount '$mp'..."

    local err_msg
    if err_msg=$("${sudo_cmd[@]}" umount "$mp" 2>&1); then
        echo "Success: '$mp' unmounted cleanly."
        return 0
    fi

    # 5. Fallback to lazy unmount if --force was specified
    if [[ $force -eq 1 ]]; then
        echo "Warning: Standard unmount failed ($err_msg). Attempting lazy unmount (-l)..." >&2
        
        # Flush filesystem buffers before detaching namespace
        sync
        
        local lazy_err
        if lazy_err=$("${sudo_cmd[@]}" umount -l "$mp" 2>&1); then
            echo "Notice: '$mp' lazy-unmounted. Filesystem is detached from the namespace but kernel writes/handles may still be flushing." >&2
            return 0
        else
            echo "Error: Lazy unmount also failed for '$mp': $lazy_err" >&2
            return 1
        fi
    fi

    # 6. Standard unmount failed and --force was not set
    echo "Error: Failed to unmount '$mp': $err_msg" >&2

    # In non-interactive mode, fail fast without running noisy/slow diagnostics
    if [[ $non_interactive -eq 1 ]]; then
        return 1
    fi

    echo "--------------------------------------------------------" >&2
    echo "Checking for nested mounts and open file handles..." >&2
    echo "--------------------------------------------------------" >&2

    echo "--- Mount Hierarchy (via findmnt -R) ---" >&2
    findmnt -R --mountpoint "$mp" >&2
    echo "" >&2

    if command -v fuser >/dev/null 2>&1; then
        echo "--- Active Processes (via fuser -vm) ---" >&2
        "${sudo_cmd[@]}" fuser -vm "$mp" 2>&1 >&2
        echo "" >&2
    fi

    if command -v lsof >/dev/null 2>&1; then
        echo "--- Open File Handles (via lsof) ---" >&2
        "${sudo_cmd[@]}" lsof +f -- "$mp" 2>/dev/null >&2
        echo "" >&2
    fi

    return 1
}
