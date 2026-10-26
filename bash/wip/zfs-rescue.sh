#!/bin/bash
# zfs-rescue.sh — sourceable functions for offline root-on-zfs maintenance.
# Source it: source ./zfs-rescue.sh
# Everything here is read-only EXCEPT: gen_zfs_list_cache, fix_legacy_nonroot,
# mask_zfs_mount_service, mount_altroot, umount_altroot — all of which print
# what they're about to do before doing it.

set -o pipefail

# ---- primitives ------------------------------------------------------

is_zfsfs() {
    zfs list -t filesystem "$1" &>/dev/null
}

is_empty() {
    local dir="$1"
    [[ ! -d "$dir" ]] && return 0
    [[ -z $(find "$dir" -mindepth 1 -print -quit 2>/dev/null) ]]
}

# depth of a mountpoint, used to order mount/umount safely.
# "/" = 0, "/var" = 1, "/var/log" = 2, "none"/"legacy" sort last (999).
_mp_depth() {
    local mp="$1"
    [[ "$mp" == "none" || "$mp" == "legacy" || "$mp" == "-" ]] && { echo 999; return; }
    [[ "$mp" == "/" ]] && { echo 0; return; }
    echo "${mp//[^\/]/}" | awk '{print length}'
}

# ---- audit (read-only) ------------------------------------------------

# audit_pool POOL
# Reports: bootfs candidates, dataset naming violations (concatenated
# var-* siblings instead of var/* children), legacy/none datasets,
# zfs-list-cache presence, zfs-mount.service state, org.openzfs.systemd
# property coverage.
audit_pool() {
    local pool="$1"
    if ! zpool list "$pool" &>/dev/null; then
        echo "Pool '$pool' not imported." >&2
        return 1
    fi

    echo "== $pool: bootfs candidates (mountpoint=/, canmount=noauto) =="
    zfs list -Ho name,mountpoint,canmount -r -t filesystem "$pool" \
        | awk -F'\t' '$2=="/" && $3=="noauto"{print "  "$1}'

    echo "== $pool: naming violations (concatenated var-* siblings) =="
    zfs list -Ho name -r -t filesystem "$pool" \
        | grep -E '/(var|usr|opt|etc)-[a-z]+(-[a-z]+)*$' \
        | sed 's/^/  FLAG: /' \
        || echo "  none found"

    echo "== $pool: legacy/none mountpoints =="
    zfs list -Ho name,mountpoint -r -t filesystem "$pool" \
        | awk -F'\t' '$2=="legacy"||$2=="none"{print "  "$1"\t"$2}'

    echo "== $pool: org.openzfs.systemd coverage =="
    zfs get -Ho name,property,value -r \
        org.openzfs.systemd:requires,org.openzfs.systemd:wanted-by,org.openzfs.systemd:after \
        "$pool" 2>/dev/null \
        | awk -F'\t' '$3!="-"{print "  "$1"\t"$2"="$3}'
    echo "  (blank above = no datasets have these properties set)"

    echo "== $pool: zfs-mount.service state =="
    systemctl is-enabled zfs-mount.service 2>/dev/null || echo "  not found / not applicable on this image"

    echo "== $pool: candidate orphan BE slots (canmount=off, depth>0 under BE/) =="
    zfs list -Ho name,canmount -r -t filesystem "$pool" 2>/dev/null \
        | awk -F'\t' -v p="$pool/BE/" '$1 ~ "^"p && $2=="off"{print "  "$1}'
}

# audit_all — audit every currently-imported pool
audit_all() {
    local p
    for p in $(zpool list -Ho name); do
        audit_pool "$p"
        echo
    done
}

# ---- zfs-list-cache generation ----------------------------------------

# gen_zfs_list_cache POOL TARGET_ROOT
# Writes /etc/zfs/zfs-list-cache/POOL under TARGET_ROOT, the exact columns
# zfs-mount-generator(8) expects, chmod 444.
gen_zfs_list_cache() {
    local pool="$1" target_root="$2"
    if [[ -z "$pool" || -z "$target_root" ]]; then
        echo "Usage: gen_zfs_list_cache POOL TARGET_ROOT" >&2; return 1
    fi
    if ! zpool list "$pool" &>/dev/null; then
        echo "Pool '$pool' not imported." >&2; return 1
    fi
    local cache_dir="${target_root%/}/etc/zfs/zfs-list-cache"
    mkdir -p "$cache_dir"
    local cache_file="${cache_dir}/${pool}"
    zfs list -H -o name,mountpoint,canmount,atime,relatime,devices,exec,readonly,setuid,nbmand,encroot,keylocation \
        -t filesystem "$pool" > "$cache_file"
    chmod 444 "$cache_file"
    echo "Wrote $(wc -l < "$cache_file") lines to $cache_file"
}

# mask_zfs_mount_service TARGET_ROOT
# Masks zfs-mount.service inside an offline root by symlinking to /dev/null
# in its systemd config tree — works without chroot/systemctl.
mask_zfs_mount_service() {
    local target_root="$1"
    if [[ -z "$target_root" ]]; then
        echo "Usage: mask_zfs_mount_service TARGET_ROOT" >&2; return 1
    fi
    local etc_systemd="${target_root%/}/etc/systemd/system"
    mkdir -p "$etc_systemd"
    ln -sf /dev/null "${etc_systemd}/zfs-mount.service"
    echo "Masked zfs-mount.service in ${etc_systemd}"
}

# ---- legacy non-root cleanup --------------------------------------------

# fix_legacy_nonroot POOL ROOT_DATASET
# For every dataset under ROOT_DATASET that is NOT the root itself and not
# already legacy/none, sets mountpoint=legacy. Use after you've decided a
# given root dataset's children should be picked up by zfs-mount-generator
# rather than auto mountpoint inheritance. Prints every change; does not
# touch the root dataset itself.
fix_legacy_nonroot() {
    local root_ds="$1"
    if ! is_zfsfs "$root_ds"; then
        echo "Error: '$root_ds' is not a zfs filesystem." >&2; return 1
    fi
    zfs list -Ho name,mountpoint -r -t filesystem "$root_ds" \
        | awk -F'\t' -v root="$root_ds" '$1!=root && $2!="legacy" && $2!="none"{print $1}' \
        | while read -r ds; do
            echo "zfs set mountpoint=legacy $ds"
            zfs set mountpoint=legacy "$ds"
        done
}

# ---- altroot mount / unmount (depth-ordered) ----------------------------

# mount_altroot TARGET_DATASET ALTROOT
# Mounts TARGET_DATASET and all its mountable children under ALTROOT,
# strictly in mountpoint-depth order (shallowest first) regardless of
# what order `zfs list -r` happens to return.
mount_altroot() {
    local target="$1" altroot="$2"
    if ! is_zfsfs "$target"; then
        echo "Error: '$target' is not a zfs filesystem." >&2; return 1
    fi
    if [[ "${altroot:0:1}" != "/" ]]; then
        echo "Error: altroot must be an absolute path." >&2; return 1
    fi
    altroot="${altroot%/}"

    zfs list -Ho name,overlay,canmount,mountpoint -r -t filesystem "$target" \
        | while IFS=$'\t' read -r name overlay canmount mountpoint; do
            [[ "$mountpoint" == "none" || "$mountpoint" == "legacy" ]] && continue
            [[ "$canmount" == "off" ]] && continue
            printf '%s\t%s\t%s\t%s\n' "$(_mp_depth "$mountpoint")" "$name" "$overlay" "$mountpoint"
        done \
        | sort -n -k1,1 \
        | while IFS=$'\t' read -r _ name overlay mountpoint; do
            local full="${altroot}${mountpoint}"
            if ! is_empty "$full" && [[ "$overlay" == "off" ]]; then
                echo "Skip $name: overlay=off and $full not empty."
                continue
            fi
            mkdir -p "$full"
            mount -t zfs -o zfsutil "$name" "$full" \
                && echo "Mounted $name -> $full" \
                || echo "FAILED to mount $name -> $full" >&2
        done
}

# umount_altroot TARGET_DATASET ALTROOT
# Reverse of the above: unmounts deepest mountpoints first, rmdir's
# directories left empty. Refuses to rm anything non-empty.
umount_altroot() {
    local target="$1" altroot="$2"
    if ! is_zfsfs "$target"; then
        echo "Error: '$target' is not a zfs filesystem." >&2; return 1
    fi
    altroot="${altroot%/}"

    zfs list -Ho name,mountpoint -r -t filesystem "$target" \
        | while IFS=$'\t' read -r name mountpoint; do
            [[ "$mountpoint" == "none" || "$mountpoint" == "legacy" ]] && continue
            printf '%s\t%s\n' "$(_mp_depth "$mountpoint")" "${altroot}${mountpoint}"
        done \
        | sort -rn -k1,1 \
        | while IFS=$'\t' read -r _ full; do
            if mountpoint -q "$full" 2>/dev/null; then
                umount "$full" && echo "Unmounted $full" \
                    || { echo "FAILED to unmount $full" >&2; continue; }
            fi
            is_empty "$full" && rmdir "$full" 2>/dev/null && echo "Removed $full"
        done

    [[ -d "$altroot" ]] && is_empty "$altroot" && rmdir "$altroot" 2>/dev/null \
        && echo "Removed altroot $altroot"
}
