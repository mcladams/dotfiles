#!/usr/bin/env bash

################################################################################
# Environmental variables default values                                       #
################################################################################

REMOVE_EMPTY_DIRS="0" #true: check mountpoint for empty directories & remove
FORCE_CANMOUNT="1" #false
FORCE_OVERLAY="0" #true
CHECK_MOUNT_USED="1" #false



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
        get_first_children $fiirst_child
    done
}

get_boot_datasets ()
# these have mountpoint / and canmount=noauto


################################################################################
# Boolean test functiions                                                      #
################################################################################

_empty_dir ()
{
    [ $(find "$1" -print -quit) ] && return 1 || return 0
}

_empty_dirtree ()
{
    [ $(find "$1" ! -type d -print -quit) ] && return 1 || return 0
}

_dev_mounted ()
# returns 0 (true) and $device_mounted if a device is mounted at directory
{
    device_mounted=$(awk -v mp="$1" ' $2==mp { print $1 }' /proc/self/mounts);
    [ -z $device_mounted ] && return 1 || return 0
}

_zfs_filesystem ()
{
     zfs list -Ho name $1 &>/dev/null
}

_canmount_off ()
{
    [ "$(zfs list -Ho canmount $1)" = "off" ] &>/dev/null && return 0 || return 1
}

_overlay_ff ()
{
    [ "$(zfs list -Ho overlay $1)" = "off" ] &>/dev/null && return 0
}



################################################################################
# Mount zfs datasets for offline access                                        #
################################################################################

_zut_simple_mount()
{



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

zcheck_canmountoff ()
# Checks datasets from 'zfs mount' command for canmount=off
{
    local dataset mount_actual
    > /tmp/canmountoff

    while read -r dataset mount_actual; do
        [ "$(zfs list -Ho canmount $dataset)" = "off" ] &&\
            printf "%s \t %s \t %s \n" "$dataset" "$mount_actual" "$(zfs list -Ho overlay,canmount,mountpoint $dataset)"
        fi
    done < <(zfs mount) > /tmp/canmountoff

    if [[ ! -s /tmp/canmountoff ]]; then
        echo "No mounted zfs datasets with canmount=off"
        return
    fi

    column -t -N NAME,ACTUAL_MOUNT,OVERLAY,CANMOUNT,SET_MOUNT /tmp/canmountoff
    read -r -p "Attempt to fix Y/N? "

    if [[ $REPLY =~ [Yy] ]]; then
        while read -r _dataset _mount_actual _remaining; do
            sudo zfs unmount "$(zfs list -Ho name -r "$_dataset")" && sudo umount -lf "$_mount_actual" 2>/dev/null
        done < /tmp/canmountoff
    fi
}

check_dupedmounts ()
{
    local numdupes dupedmount answer sets=0

    while read -r numdupes dupedmount; do
        (( sets++ ))
        echo
        echo "Duplicate mountpoint: $dupedmount"
        echo "Number of mounts: $numdupes"
        echo

        grep " $dupedmount " /proc/mounts

        echo
        read -r -n 1 -p \
            "Remove all but the first mounted device above? [y/N] " answer </dev/tty
        echo

        if [[ $answer =~ ^[Yy]$ ]]; then
            for (( count=1; count<numdupes; count++ )); do
                sudo umount "$dupedmount" || break
            done
        fi
    done < <(awk '{ print $2 }' /proc/mounts | sort | uniq -c -d )

    [[ $sets -eq 0 ]] && echo "No duplicated mountpoints found."
}
