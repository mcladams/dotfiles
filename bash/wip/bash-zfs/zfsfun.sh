#!/bin/bash
# ZFS maintenance utilities

# Test if zfs filesystem
is_zfsfs () {
   zfs list -t filesystem "$1" &>/dev/null
}

# Test if directory is empty (or doesn't exist)
is_empty () {
    local dir="$1"
    [[ ! -d "$dir" ]] && return 0
    [[ -z $(find "$dir" -mindepth 1 -print -quit 2>/dev/null) ]]
}

# Alias for standard ZFS-util mounts
alias zm='zfs mount -t zfs -o zfsutil'

# Declare global associative array to store properties
make_zfs_cache () {
    local target="$1"
    if ! is_zfsfs "$target"; then 
        echo "Error: '$target' is not a zfs filesystem." && return 1 
    fi

    # -g for global scope so it persists after sourcing
    declare -gA zfs_cache
    
    while IFS=$'\t' read -r name overlay canmount mountpoint mounted; do
        zfs_cache["$name"]="$overlay|$canmount|$mountpoint|$mounted"
    done < <(zfs list -Ho name,overlay,canmount,mountpoint,mounted -p -r "$target")
}

# Mount single filesystem, creating mountpoint if needed
zm_opt () {
    local zfilesys="$1"
    local mountpt="$2"
    shift 2
    local extra_opts="$*"

    sudo mkdir -p "$mountpt"
    # Concatenate options if provided
    if [[ -n "$extra_opts" ]]; then
        sudo mount -t zfs -o zfsutil,"$extra_opts" "$zfilesys" "$mountpt"
    else
        sudo mount -t zfs -o zfsutil "$zfilesys" "$mountpt"
    fi
}

# Mount recursively with an altroot
zm_alt () {
    local target="$1"
    local altroot="$2"

    if ! is_zfsfs "$target"; then 
        echo "Error: '$target' is not a zfs filesystem." && return 1 
    fi
    
    if [[ "${altroot:0:1}" != "/" ]]; then 
        echo "Error: altroot must be an absolute path." && return 1 
    fi

    # Strip trailing slash from altroot if user provided one to avoid // paths
    altroot="${altroot%/}"

    while IFS=$'\t' read -r name overlay canmount mountpoint; do
        # Skip datasets that shouldn't be mounted automatically
        if [[ "$mountpoint" == "none" || "$mountpoint" == "legacy" || "$canmount" == "off" ]]; then
            continue
        fi

        local altmountpoint="${altroot}${mountpoint}"

        # Check emptiness for overlay=off safety
        if ! is_empty "$altmountpoint" && [[ "$overlay" == "off" ]]; then
            echo "Skipping $name: Overlay off & mountpoint '$altmountpoint' not empty."
            continue
        fi 

        sudo mkdir -p "$altmountpoint"
        sudo mount -t zfs -o zfsutil "$name" "$altmountpoint"
        echo "Mounted: $name -> $altmountpoint"

    done < <(zfs list -Ho name,overlay,canmount,mountpoint -p -r "$target")
}
