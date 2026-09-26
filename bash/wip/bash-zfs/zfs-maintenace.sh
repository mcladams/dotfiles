
# mount a zfs dataset at an arbitrary location for maintence without changing its mountpoint _property_
# optionally force mounting where canmount=no or overlay overaly=off, or create new zfs datasets where not exist
mk_zfsmount() {
    local dataset=""
    local mountpoint=""
    local force=0
    local overlay=0
    local create_zfs=0

    # Parse Options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--force)      force=1; shift ;;
            -O|--overlay)    overlay=1; shift ;;
            -z|--zfs-create) create_zfs=1; shift ;;
            -*)              echo "Error: Unknown option $1" >&2; return 1 ;;
            *)
                if [[ -z "$dataset" ]]; then
                    dataset="$1"
                elif [[ -z "$mountpoint" ]]; then
                    mountpoint="$1"
                else
                    echo "Error: Too many positional arguments" >&2; return 1
                fi
                shift
                ;;
        esac
    done

    # Validate mandatory positional inputs
    if [[ -z "$dataset" || -z "$mountpoint" ]]; then
        echo "Usage: mp [options] <dataset> <mountpoint>" >&2
        echo "Options: -f|--force, -O|--overlay, -z|--zfs-create" >&2
        return 1
    fi

    # 1. Check if Dataset Exists
    if ! zfs list -Ho name | grep -qFx "$dataset"; then
        if [[ $create_zfs -eq 1 ]]; then
            echo "Dataset '$dataset' not found. Creating it and its parents..."
            # -p creates parents automatically, exactly like zfs rename/create mechanics
            if ! sudo zfs create -p "$dataset"; then
                echo "Error: Failed to create ZFS dataset '$dataset'" >&2
                return 1
            fi
        else
            echo "Error: ZFS dataset '$dataset' does not exist. Use -z/--zfs-create to provision." >&2
            return 1
        fi
    fi

    # 2. Check 'canmount' Property
    local canmount_prop
    canmount_prop=$(zfs get -H -o value canmount "$dataset")
    if [[ "$canmount_prop" == "off" && $force -ne 1 ]]; then
        echo "Error: dataset 'canmount' is off. Override with -f|--force." >&2
        return 1
    fi

    # 3. Check Directory Emptiness & 'overlay' Property
    if [[ -d "$mountpoint" && "$(ls -A "$mountpoint" 2>/dev/null)" ]]; then
        local overlay_prop
        overlay_prop=$(zfs get -H -o value overlay "$dataset")
        if [[ "$overlay_prop" == "off" && $overlay -ne 1 ]]; then
            echo "Error: Target '$mountpoint' is not empty and dataset 'overlay=off'. Override with -O|--overlay." >&2
            return 1
        fi
    fi

    # 4. Execute Mount Phase
    echo "Mounting '$dataset' to '$mountpoint'..."
    mkdir -p "$mountpoint"
    sudo mount -t zfs -o zfsutil "$dataset" "$mountpoint"
}
