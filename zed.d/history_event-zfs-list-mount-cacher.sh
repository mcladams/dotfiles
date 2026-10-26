#!/bin/sh
# shellcheck disable=SC2154
#
# Track changes to enumerated pools for use in early-boot
set -eou pipefail

#### MODIFIED FOR MULTI-BE ROOT-ON-ZFS
# shebang changed from /bin/sh
# if an alternative list cacher exists, attempt to remove
export ZED_ZEDLET_DIR="/etc/zfs/zed.d"
[ ! -e "${ZED_ZEDLET_DIR}/history_event-zfs-list-cacher.sh" ] ||\
  rm -f "${ZED_ZEDLET_DIR}/history_event-zfs-list-cacher.sh" || exit 0
# Never persist transient (altroot) imports
[ "$("${ZPOOL}" get -H -o value altroot "${ZEVENT_POOL}")" = "-" ] || exit 0
####

FSLIST="/etc/zfs/zfs-list.cache/${ZEVENT_POOL}"
FSLIST_TMP="/run/zfs-list.cache@${ZEVENT_POOL}"

# If the pool specific cache file is not writeable, abort
[ -w "${FSLIST}" ] || exit 0

# shellcheck disable=SC1091
[ -f "${ZED_ZEDLET_DIR}/zed.rc" ] && . "${ZED_ZEDLET_DIR}/zed.rc"
# shellcheck disable=SC1091
. "${ZED_ZEDLET_DIR}/zed-functions.sh"

[ "$ZEVENT_SUBCLASS" != "history_event" ] && exit 0
zed_check_cmd "${ZFS}" sort diff

# If we are acting on a snapshot, we have nothing to do
[ "${ZEVENT_HISTORY_DSNAME%@*}" = "${ZEVENT_HISTORY_DSNAME}" ] || exit 0

# We lock the output file to avoid simultaneous writes.
# If we run into trouble, log and drop the lock
# shellcheck disable=SC2329
abort_alter() {
  zed_log_msg "Error updating zfs-list.cache for ${ZEVENT_POOL}!"
  zed_unlock "${FSLIST}"
}

finished() {
  zed_unlock "${FSLIST}"
  trap - EXIT
  exit 0
}

case "${ZEVENT_HISTORY_INTERNAL_NAME}" in
    create|"finish receiving"|import|destroy|rename)
      ;;

    export)
        zed_lock "${FSLIST}"
        trap abort_alter EXIT
        echo > "${FSLIST}"
        finished
      ;;

    set|inherit)
        # Only act if one of the tracked properties is altered.
        case "${ZEVENT_HISTORY_INTERNAL_STR%%=*}" in
            canmount|mountpoint|atime|relatime|devices|exec|readonly| \
              setuid|nbmand|encroot|keylocation|org.openzfs.systemd:requires| \
              org.openzfs.systemd:requires-mounts-for| \
              org.openzfs.systemd:before|org.openzfs.systemd:after| \
              org.openzfs.systemd:wanted-by|org.openzfs.systemd:required-by| \
              org.openzfs.systemd:nofail|org.openzfs.systemd:ignore \
            ) ;;
            *) exit 0 ;;
        esac
      ;;

    *)
        # Ignore all other events.
        exit 0
      ;;
esac

zed_lock "${FSLIST}"
trap abort_alter EXIT

PROPS="name,mountpoint,canmount,atime,relatime,devices,exec\
,readonly,setuid,nbmand,encroot,keylocation\
,org.openzfs.systemd:requires,org.openzfs.systemd:requires-mounts-for\
,org.openzfs.systemd:before,org.openzfs.systemd:after\
,org.openzfs.systemd:wanted-by,org.openzfs.systemd:required-by\
,org.openzfs.systemd:nofail,org.openzfs.systemd:ignore"

#### MODIFIED FOR MULTI-HOST-ROOT-ON-ZFS SYSTEMS
# Mounted ZFS filesystems of this pool only: exact pool match, fstype zfs,
# no snapshot automounts. set -- keeps names as discrete args without
# relying on unquoted-variable word splitting.
set -f
# shellcheck disable=SC2046
set -- $(awk -v p="${ZEVENT_POOL}" '
    $3 == "zfs" && $1 !~ /@/ && ($1 == p || index($1, p "/") == 1) { print $1 }
' /proc/self/mounts | sort -u)
[ $# -gt 0 ] || exit 0    # keep the existing cache rather than write an empty one
#
"${ZFS}" list -H -t filesystem -o "${PROPS}" "$@" > "${FSLIST_TMP}"
#### issues? https://github.com/mcladams/zfs-multiboot.git

# Sort the output so that it is stable
sort "${FSLIST_TMP}" -o "${FSLIST_TMP}"

# Dont modify the file if it hasnt changed
diff -q "${FSLIST_TMP}" "${FSLIST}" || cat "${FSLIST_TMP}" > "${FSLIST}"
rm -f "${FSLIST_TMP}"

finished
