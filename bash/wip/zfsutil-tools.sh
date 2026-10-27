#!/usr/bin/env bash

################################################################################
# Environmental variables default values                                       #
################################################################################

# Remember "0" = true
REMOVE_EMPTY_DIRS="0" #true: check mountpoint for empty directories & remove
FORCE_CANMOUNT="1" #false
FORCE_OVERLAY="0" #true

# Not implemented yet
#CHECK_MOUNT_USED="1" #false



################################################################################
# Predicate functions (0 = true, 1 = false)                                    #
################################################################################

_empty_dir ()
{
    local target="${1:?Error: missing directory path}"
    [[ -d "$target" && -r "$target" ]] || return 1
    # Returns 0 if empty, 1 if populated (no command substitution subshell needed)
    find "$target" -mindepth 1 -maxdepth 1 -exec false {} + -quit 2>/dev/null
}

_empty_dirtree ()
{
    local target="${1:?Error: missing directory path}"
    [[ -d "$target" && -r "$target" ]] || return 1
    # Returns 0 if tree contains only directories, 1 if any non-directory exists
    find "$target" -mindepth 1 ! -type d -exec false {} + -quit 2>/dev/null
}

_dev_mounted ()
{
    local target="${1:?Error: missing mountpoint path}"
    # Declare global output variable explicitly; -f restricts to top mount
    declare -g device_mounted
    device_mounted=$(findmnt -n -f -M "$target" -o SOURCE 2>/dev/null)
    [[ -n "$device_mounted" ]]
}

_zfs_filesystem ()
{
    local dataset="${1:?Error: missing ZFS dataset name}"
    # Restricted strictly to ZFS filesystems (excludes zvols and snapshots)
    zfs list -H -t filesystem -o name "$dataset" &>/dev/null
}

_canmount_off ()
{
    local dataset="${1:?Error: missing ZFS dataset name}"
    [[ "$(zfs get -H -o value canmount "$dataset" 2>/dev/null)" == "off" ]]
}

_overlay_off ()
{
    local dataset="${1:?Error: missing ZFS dataset name}"
    [[ "$(zfs get -H -o value overlay "$dataset" 2>/dev/null)" == "off" ]]
}



################################################################################
# Generally useful functiions                                                  #
################################################################################

get_first_children ()
{
    zfs list -Ho name -d 1  $1 | awk -v parent=$1 '$1 != parent'
}

# Audit - first children of Boot Environment should have mountpoint=/
#   for inheritence and canmount=off. Chechk that properties are inheriting

get_second_children ()
{
    for first_child in $(get_first_children $1)
    do
        get_first_children $first_child
    done
}

get_bootsets ()
# these have mountpoint / and canmount=noautok, returns a linebreak separated list
# in future willl all be {$BOOTPOOL}/BE/{$DISTRO}/{$INSTANCE}
{
    zfs list -Ho name,canmount,mountpoint "$@" | awk '$2=="noauto" && $3=="/" { print $1 }'
}

_bootsets ()
{
    mapfile -t bootsets < <(get_bootsets "$@")
}

_uniq_zfsuserprops () 
# warning slow function. enumerates all zfs properties of all datasets if scope not restricted
{
    if [ "$1" = "-t" ]; then
        local ztype="$1 $2"
        shift 2
    else
        ztype="-t filesystem"
    fi
    zfs get -H "$ztype" all "$@" | grep --color=auto -Po '^\S+\t\K[\w.-]+:[\w.-]+' | sort | uniq
}

zls_userprops ()
# warning slow function. enumerates all zfs properties of all datasets if scope not restricted
{
    local _uniq_userprops=$(_uniq_zfsuserprops "$@")
    zfs list -o name,used,referenced,usedsnap,overlay,canmount,mounted,mountpoint,$(paste -sd, "$_uniq_userprops")  "$@"
}

clean_mps ()
{
    local mp
    for mp in "$@"; do
        [[ -d "$mp" ]] && [[ _empty_dirtree "$mp" ]]; then
            if ! find "$mp" -mindepth 1 ! -type d -print -quit | grep -q .; then
                sudo rm -r "$mp"
            fi
        fi
    done
}


################################################################################
# Mount zfs datasets for offline access                                        #
################################################################################

## These have been written for my boot-enviironemnet setup where I have universally
# overlay=off; openZFS changed the default to overlay=on like other linux mount fns
# in v 2.1.0. I need to consider changign my datasets behaviour.

_zm ()
{
    local ds="$1" mp="$2"
    [ $REMOVE_EMPTY_DIRS ] && _clean_mps "$mp"
    sudo mkdir -p "$mp"
    sudo mount -t zfs -o zfsutil "$ds" "$mp"
}


_zmount ()
# Atomic mount function: mounts one dataset to one mountpoint with zfsutil
{
    local ds="$1" mp="$2"

    if [[ -d "$mp" ]] && [[ -z "$(find "$mp" -type f)" ]]; then
        sudo rm -r "$mp"
    fi
    sudo mkdir -p "$mp"

    if [[ $(zfs list -Ho canmount "$ds") != "off" || -n "$FORCE_MOUNT" ]]; then
        sudo mount -t zfs -o zfsutil "$ds" "$mp"
    fi
}

overlay_zmount ()
{
    local ds="$1" mp="$2"
    if [[ $(zfs list -Ho overlay "$ds") == "off" ]]; then
        sudo zfs set overlay=on "$ds"
        zmount "$ds" "$mp"
        sudo zfs set overlay=off "$ds"
        return
    fi
    zmount "$ds" "$mp"
}

zunmount ()
{
    local arg mountpoint
    local failed=()

    for arg in "$@"; do
        while read -r mountpoint; do
            if sudo umount "$mountpoint"; then
                sudo rmdir -p --ignore-fail-on-non-empty "$mountpoint" 2>/dev/null || true
            else
                failed+=("$mountpoint")
            fi
        done < <(awk -v target="$arg" '$1 == target || $2 == target { print $2 }' /proc/mounts)
    done

    if [[ ${#failed[@]} -ne 0 ]]; then
        echo
        echo "The following failed to unmount:"
        printf '  %s\n' "${failed[@]}"
        read -r -n1 -p "Do you wish to lazy unmount these (Y/n)? " answer
        echo
        if [[ $answer =~ [Yy] ]]; then
            sudo umount -l "${failed[@]}"
            for mountpoint in "${failed[@]}"; do
                sudo rmdir -p --ignore-fail-on-non-empty "$mountpoint" 2>/dev/null || true
            done
        fi
    fi
}

zmount_recurse ()
# Mount dataset and children recursively to given utility mountpoint
{
    local dataset="$1" util_mp="$2"
    local mount_source set_mp child_ds child_setmp

    mount_source=$(zfs get -rH -o source -t filesystem mountpoint -r "$dataset" | tail -n +2 | awk '{ print $1 }' | uniq)
    if [[ "$mount_source" != "inherited" && -n "$mount_source" ]]; then
        echo "Error: child datasets must have mountpoint inheritance"
        return 1
    fi

    set_mp=$(zfs list -Ho mountpoint "$dataset")
    for child_ds in $(zfs list -Ho name -r "$dataset"); do
        child_setmp=$(zfs list -Ho mountpoint "$child_ds")
        zmount "$child_ds" "${util_mp}${child_setmp#$set_mp}"
    done
}

zmr ()
# Recursively mount a dataset tree under an alternative root path
{
    local tomountr
    local altroot="$2"
    local dataset defmp altmp

    tomountr=$(zfs list -Ho name -r "$1")
    for dataset in $tomountr; do
        if [[ "$(zfs list -Ho canmount "$dataset")" == "off" ]]; then
            continue
        fi
        defmp="$(zfs list -Ho mountpoint "$dataset")"
        altmp="${altroot}${defmp}"
        sudo mkdir -p "$altmp"
        sudo mount -t zfs -o zfsutil "$dataset" "$altmp"
    done
}

zma ()
# Automount ZFS datasets recursively to determined alternative mountpoints
{
    local automountr ds mp dsname defaltroot
    automountr=$(zfs list -Ho name -r "$@" | sort | uniq)

    for ds in $automountr; do
        mp="$(zfs list -Ho mountpoint "$ds")"
        if [[ "$mp" == "/" ]]; then
            dsname="${ds##*/}"
            defaltroot="/${dsname}"
            echo "Mounting children of $ds under $defaltroot..."
            zmr "$ds" "$defaltroot"
        fi
    done
}



################################################################################
# Check mounted zfs datasets for inconsistencies                               #
################################################################################

zcheck_canmountoff() {
    local tmp_file
    tmp_file=$(mktemp /tmp/canmountoff.XXXXXX) || return 1
    trap 'rm -f "$tmp_file"' RETURN

    # Batch read active mounts with canmount property in a single pass
    while IFS=$'\t' read -r ds mp canmount overlay; do
        if [[ "$canmount" == "off" ]]; then
            printf "%s\t%s\t%s\t%s\n" "$ds" "$mp" "$overlay" "$canmount" >> "$tmp_file"
        fi
    done < <(
        join -t $'\t' -1 1 -2 1 \
            <(zfs mount | sort -k1,1) \
            <(zfs list -Ho name,canmount,overlay -t filesystem | sort -k1,1)
    )

    if [[ ! -s "$tmp_file" ]]; then
        echo "No mounted ZFS datasets with canmount=off."
        return 0
    fi

    column -t -N "NAME,ACTUAL_MOUNT,OVERLAY,CANMOUNT" "$tmp_file"
    read -r -p "Attempt to unmount these datasets? [y/N] " reply
    if [[ "$reply" =~ ^[Yy]$ ]]; then
        while IFS=$'\t' read -r ds mp _; do
            echo "Unmounting: $ds from $mp"
            sudo zfs unmount "$ds" 2>/dev/null || sudo umount -l "$mp"
        done < "$tmp_file"
    fi
}


check_dupedmounts() {
    local numdupes dupedmount sets=0
    local target_list

    target_list=$(awk '{ print $2 }' /proc/mounts | sort | uniq -c -d)
    [[ -z "$target_list" ]] && { echo "No duplicate mountpoints found."; return 0; }

    while read -r numdupes dupedmount; do
        (( sets++ ))
        echo -e "\nDuplicate mountpoint: $dupedmount ($numdupes instances)"
        grep " $dupedmount " /proc/mounts

        read -r -n 1 -p "Remove all but the first mounted instance above? [y/N] " answer </dev/tty
        echo
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            # Unmount from topmost down, leaving the baseline mount intact
            for (( count=1; count<numdupes; count++ )); do
                sudo umount "$dupedmount" || break
            done
        fi
    done <<< "$target_list"
}

