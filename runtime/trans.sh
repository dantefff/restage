#!/bin/sh
#
# runtime/trans.sh — the initrd-side installer, run as PID 1.
#
# After `restage` schedules a boot, the machine boots a minimal Alpine
# netboot kernel with init=/trans.sh. This script:
#
#   1. performs minimal system bring-up (proc/sys/dev),
#   2. brings up networking (injected config or DHCP),
#   3. locates the target disk by PTUUID (names change, UUIDs don't),
#   4. dispatches to the requested mode: alpine | dd | linux | windows,
#   5. applies credentials/network fixups in a chroot, then reboots.
#
# Strict POSIX sh: it runs in busybox. Do not add bashisms.

set -u

# ------------------------------------------------------------------ init --
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
# Applets must exist before anything below runs (mount, mkdir, mdev, ip, ...).
[ -x /bin/busybox ] && /bin/busybox --install -s 2>/dev/null || true
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t devtmpfs devtmpfs /dev 2>/dev/null || {
    mkdir -p /dev
    mdev -s 2>/dev/null || true
}
# ------------------------------------------------------------------ load --
. /restage-common.sh
. /initrd-network.sh
. /windows.sh

install_applets
# Coldplug: load drivers (virtio, nvme, ...) via MODALIAS -> modprobe and
# create device nodes. Required or /dev/vda and eth0 never appear.
load_device_modules
load_conf /restage.conf

log "restage runtime installer v0.1 (mode=${RESTAGE_MODE:-?})"
log "booted; bringing up networking"

initrd_network_up || warn "network bring-up had issues; installs may fail"

# Pull in Alpine's modloop (extra kernel modules kept out of the base
# initramfs) now that networking is up, then re-probe hardware so any
# device whose driver only lives there — e.g. an emulated IDE/PIIX3 disk
# controller instead of virtio-blk — gets picked up before disk lookup.
if [ -n "${RESTAGE_MODLOOP_URL:-}" ]; then
    if fetch_modloop "${RESTAGE_MODLOOP_URL}"; then
        log "re-probing hardware with the expanded module set"
        load_device_modules
    fi
fi

# Persistent log file, served over HTTP for convenience.
LOG=/restage.log
exec 1>>"$LOG" 2>&1
{
    echo "==== restage runtime ===="
    date
} >>"$LOG" 2>/dev/null || true

start_logviewer() {
    port=${RESTAGE_WEB_PORT:-80}
    command -v httpd >/dev/null 2>&1 || {
        log "no httpd applet; installing busybox-extras for the log viewer"
        apk_repos "${RESTAGE_ALPINE_VER:-3.22}"
        apk add --no-cache busybox-extras >/dev/null 2>&1 && busybox --install -s 2>/dev/null || true
    }
    command -v httpd >/dev/null 2>&1 || { warn "httpd unavailable; log viewer disabled"; return 0; }
    mkdir -p /logdir
    ln -sf "$LOG" /logdir/restage.log 2>/dev/null || cp "$LOG" /logdir/restage.log 2>/dev/null || true
    httpd -p "$port" -h /logdir 2>/dev/null &
    log "log viewer: http://<ip>:$port/restage.log"
}

start_sshd() {
    port=${RESTAGE_SSH_PORT:-22}
    if command -v dropbear >/dev/null 2>&1; then
        mkdir -p /etc/dropbear
        [ -f /etc/dropbear/dropbear_rsa_host_key ] || \
            dropbearkey -t rsa -s 2048 -f /etc/dropbear/dropbear_rsa_host_key 2>/dev/null || true
        dropbear -p "$port" -r /etc/dropbear/dropbear_rsa_host_key 2>/dev/null && \
            log "dropbear listening on port $port" && return 0
    fi
    if command -v sshd >/dev/null 2>&1; then
        sshd -p "$port" 2>/dev/null && log "sshd listening on port $port" && return 0
    fi
    warn "no ssh server bundled; attempting to install dropbear"
    apk add --no-cache dropbear >/dev/null 2>&1 && start_sshd \
        || warn "could not install dropbear (no apk network access?)"
}

setup_root_auth() {
    if [ -n "${RESTAGE_PASSWORD:-}" ]; then
        echo "root:${RESTAGE_PASSWORD}" | chpasswd 2>/dev/null && \
            log "root password set" || warn "could not set root password"
    fi
    if [ -n "${RESTAGE_SSH_KEY:-}" ]; then
        mkdir -p /root/.ssh
        echo "$RESTAGE_SSH_KEY" >/root/.ssh/authorized_keys
        chmod 700 /root/.ssh
        chmod 600 /root/.ssh/authorized_keys
        log "root SSH key installed"
    fi
}

# ------------------------------------------------------------------ disk --
# Find the device whose PTUUID matches $1.
find_disk() {
    _want=$1
    _want=$(printf '%s' "$_want" | tr 'A-Z' 'a-z')
    for _dev in /sys/block/*; do
        _name=${_dev##*/}
        case "$_name" in loop* | ram* | fd* | sr*) continue ;; esac
        [ -b "/dev/$_name" ] || continue
        _uuid=""
        if command -v blkid >/dev/null 2>&1; then
            _uuid=$(blkid -s PTUUID -o value "/dev/$_name" 2>/dev/null)
        fi
        if [ -z "$_uuid" ] && command -v fdisk >/dev/null 2>&1; then
            # GPT: "Disk identifier (GUID): <uuid>"; MBR: "Disk identifier: 0x..."
            _uuid=$(fdisk -l "/dev/$_name" 2>/dev/null | \
                sed -n -e 's/.*Disk identifier (GUID): *//p' \
                       -e 's/.*Disk identifier: *//p' | \
                tr -d ' ' | head -n1)
        fi
        # fdisk prints GPT identifiers in uppercase; compare case-insensitively.
        _uuid=$(printf '%s' "$_uuid" | tr 'A-Z' 'a-z')
        if [ -n "$_uuid" ] && [ "$_uuid" = "$_want" ]; then
            printf '/dev/%s\n' "$_name"
            return 0
        fi
    done
    return 1
}

# First partition of $1 (fallback: the disk itself).
find_root_partition() {
    _disk=$1
    _base=${_disk#/dev/}
    for _part in /sys/block/"$_base"/*/; do
        _pname=${_part%%/}
        _pname=${_pname##*/}
        [ -b "/dev/$_pname" ] || continue
        case "$_pname" in
            device | queue | holders | slaves | subsystem | trace | uevent) continue ;;
        esac
        printf '/dev/%s\n' "$_pname"
        return 0
    done
    # Whole-disk image with no partition table
    printf '%s\n' "$_disk"
}

# ------------------------------------------------------------- streaming --
# Stream a (possibly compressed) image URL onto $2.
stream_write() {
    _url=$1
    _disk=$2
    log "streaming ${_url##*/} to $_disk"
    case "$_url" in
        *.tar.gz | *.tgz)
            # tar of a single disk image: extract the first file to stdout.
            _f=$(curl -fsSL "$_url" | tar -tz 2>/dev/null | head -n1)
            [ -z "$_f" ] && die "empty tar archive from $_url"
            curl -fsSL "$_url" | tar -xzO "$_f" 2>/dev/null | dd of="$_disk" bs=4M conv=fsync 2>/dev/null
            ;;
        *.tar.xz | *.txz)
            need_cmd xz
            _f=$(curl -fsSL "$_url" | tar -tJ 2>/dev/null | head -n1)
            curl -fsSL "$_url" | tar -xJOf "$_f" 2>/dev/null | dd of="$_disk" bs=4M conv=fsync 2>/dev/null
            ;;
        *.tar.zst)
            need_cmd zstd
            _f=$(curl -fsSL "$_url" | tar -tz --zstd 2>/dev/null | head -n1)
            curl -fsSL "$_url" | tar -xzOf "$_f" --zstd 2>/dev/null | dd of="$_disk" bs=4M conv=fsync 2>/dev/null
            ;;
        *.gz)
            curl -fsSL "$_url" | gzip -dc 2>/dev/null | dd of="$_disk" bs=4M conv=fsync 2>/dev/null
            ;;
        *.xz)
            need_cmd xz
            curl -fsSL "$_url" | xz -dc 2>/dev/null | dd of="$_disk" bs=4M conv=fsync 2>/dev/null
            ;;
        *.zst)
            need_cmd zstd
            curl -fsSL "$_url" | zstd -dc 2>/dev/null | dd of="$_disk" bs=4M conv=fsync 2>/dev/null
            ;;
        *)
            curl -fsSL "$_url" | dd of="$_disk" bs=4M conv=fsync 2>/dev/null
            ;;
    esac
    sync
    log "image written to $_disk"
}

# ---------------------------------------------------------------- modes --
do_alpine() {
    log "entering Alpine Live rescue mode"
    setup_root_auth
    start_sshd
    log "rescue environment ready — SSH to ${RESTAGE_NET_IFACE:-this-host} port ${RESTAGE_SSH_PORT:-22}"
    log "nothing has been erased; type 'reboot -f' on the console to leave"
    while :; do
        sleep 60
    done
}

do_dd() {
    _url=${RESTAGE_IMAGE:-}
    [ -z "$_url" ] && die "dd mode requires RESTAGE_IMAGE"
    need_cmd curl
    need_cmd dd
    log "WARNING: $disk will be completely overwritten"
    confirm "Type 'yes' to write the image to $disk" || die "aborted by operator"
    stream_write "$_url" "$disk"
    blockdev --rereadpt "$disk" 2>/dev/null || partprobe "$disk" 2>/dev/null || true
    log "dd complete"
    poweroff_decision
}

do_linux() {
    _url=${RESTAGE_IMAGE:-}
    [ -z "$_url" ] && die "linux install requires RESTAGE_IMAGE"
    need_cmd curl
    need_cmd dd
    log "installing ${RESTAGE_OS:-linux} ${RESTAGE_OS_VERSION:-}"
    confirm "Type 'yes' to install onto $disk (erases it)" || die "aborted by operator"

    case "$_url" in
        *.qcow2*)
            if ! command -v qemu-img >/dev/null 2>&1; then
                log "qcow2 image needs qemu-img; installing it"
                apk add --no-cache qemu-img >/dev/null 2>&1 || \
                    die "qemu-img unavailable and could not be installed (is apk networking working?)"
            fi
            need_cmd qemu-img
            log "downloading qcow2 image"
            curl -fsSL -o /tmp/image.qcow2 "$_url" || die "image download failed"
            log "converting qcow2 to raw on $disk"
            qemu-img convert -p -O raw /tmp/image.qcow2 "$disk" 2>/dev/null || \
                die "qcow2 conversion failed"
            ;;
        *)
            stream_write "$_url" "$disk"
            ;;
    esac
    sync
    blockdev --rereadpt "$disk" 2>/dev/null || partprobe "$disk" 2>/dev/null || true
    sleep 2
    fixup_root
    log "linux install complete"
    poweroff_decision
}

fixup_root() {
    _part=$(find_root_partition "$disk")
    log "root partition: $_part"
    mount "$_part" /os || die "could not mount $_part at /os"
    mount -t proc proc /os/proc 2>/dev/null || true
    mount -t sysfs sysfs /os/sys 2>/dev/null || true
    mount --bind /dev /os/dev 2>/dev/null || true

    # Point fstab's root entry at the freshly-written partition's UUID.
    _cur=$(blkid -s UUID -o value "$_part" 2>/dev/null)
    if [ -n "$_cur" ] && [ -f /os/etc/fstab ]; then
        sed -i "/[[:space:]]\/[[:space:]]/s/UUID=[0-9a-fA-F-]*/UUID=$_cur/" /os/etc/fstab
        log "fstab root UUID pinned to $_cur"
    fi

    [ -n "${RESTAGE_PASSWORD:-}" ] && \
        chroot /os sh -c "echo 'root:${RESTAGE_PASSWORD}' | chpasswd" 2>/dev/null || \
        warn "could not set root password on target"
    [ -n "${RESTAGE_SSH_KEY:-}" ] && {
        mkdir -p /os/root/.ssh
        echo "$RESTAGE_SSH_KEY" >/os/root/.ssh/authorized_keys
        chmod 700 /os/root/.ssh
        chmod 600 /os/root/.ssh/authorized_keys
        log "root SSH key installed on target"
    }
    [ -n "${RESTAGE_OS:-}" ] && echo "$RESTAGE_OS" >/os/etc/hostname 2>/dev/null || true

    if [ -x /os/sbin/grub-install ]; then
        chroot /os grub-install "$disk" >/dev/null 2>&1 && chroot /os update-grub >/dev/null 2>&1 && \
            log "bootloader installed on $disk" || warn "grub-install failed"
    elif [ -x /os/usr/sbin/grub-install ]; then
        chroot /os /usr/sbin/grub-install "$disk" >/dev/null 2>&1 && chroot /os update-grub >/dev/null 2>&1 && \
            log "bootloader installed on $disk" || warn "grub-install failed"
    else
        warn "no grub in the image; bootloader NOT installed"
    fi

    write_netplan
}

write_netplan() {
    [ "$RESTAGE_NET_MODE" = "static" ] || return 0
    [ -n "${RESTAGE_IPV4:-}" ] || return 0
    mkdir -p /os/etc/netplan
    _ifname=${RESTAGE_NET_IFACE:-eth0}
    {
        echo "network:"
        echo "  version: 2"
        echo "  ethernets:"
        echo "    $_ifname:"
        echo "      dhcp4: false"
        echo "      addresses:"
        echo "        - ${RESTAGE_IPV4}"
        if [ -n "${RESTAGE_GW4:-}" ]; then
            echo "      routes:"
            echo "        - to: default"
            echo "          via: ${RESTAGE_GW4}"
        fi
        if [ -n "${RESTAGE_IPV6:-}" ]; then
            echo "        - ${RESTAGE_IPV6}"
        fi
    } >/os/etc/netplan/99-restage.yaml
    log "static netplan written for $_ifname"
}

do_windows() {
    _iso=${RESTAGE_ISO_URL:-}
    log "unattended Windows install (image: ${RESTAGE_IMAGE_NAME:-autodetect})"
    confirm "Type 'yes' to erase $disk and install Windows" || die "aborted by operator"
    win_main
    poweroff_decision
}

poweroff_decision() {
    case "${RESTAGE_HOLD:-0}" in
        2)
            log "hold=2: not rebooting; target is mounted at /os for manual changes"
            while :; do
                sleep 3600
            done
            ;;
        *)
            log "install finished; rebooting in 15 seconds (interrupt on console to cancel)"
            sleep 15
            reboot -f
            ;;
    esac
}

# ------------------------------------------------------------- main run --
start_logviewer

# hold=1: verify networking interactively, install nothing.
if [ "${RESTAGE_HOLD:-0}" = "1" ]; then
    log "hold=1: network is up, install skipped (use this to verify connectivity)"
    do_alpine
fi

disk=""
if [ -n "${RESTAGE_DISK_PTUUID:-}" ]; then
    disk=$(find_disk "$RESTAGE_DISK_PTUUID") || {
        warn "no disk with PTUUID ${RESTAGE_DISK_PTUUID} found"
        log "available disks:"
        for d in /sys/block/*; do
            n=${d##*/}
            case "$n" in loop* | ram* | fd* | sr*) continue ;; esac
            log "  /dev/$n"
        done
    }
fi
[ -n "$disk" ] && log "target disk: $disk (PTUUID ${RESTAGE_DISK_PTUUID})"

case "${RESTAGE_MODE:-}" in
    alpine) do_alpine ;;
    dd) [ -n "$disk" ] && do_dd || die "cannot proceed without a target disk" ;;
    linux) [ -n "$disk" ] && do_linux || die "cannot proceed without a target disk" ;;
    windows) [ -n "$disk" ] && do_windows || die "cannot proceed without a target disk" ;;
    *)
        warn "unknown mode ${RESTAGE_MODE:-}; dropping to rescue shell"
        do_alpine
        ;;
esac
