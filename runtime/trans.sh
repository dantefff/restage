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
        printf 'root:%s\n' "$RESTAGE_PASSWORD" | chpasswd 2>/dev/null && \
            log "root password set" || warn "could not set root password"
    fi
    if [ -n "${RESTAGE_SSH_KEY:-}" ]; then
        mkdir -p /root/.ssh
        printf '%s\n' "$RESTAGE_SSH_KEY" >/root/.ssh/authorized_keys
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

# Root filesystem partition of $1.
#
# Cloud images do not agree on partition numbering: some put a BIOS-boot or
# EFI partition before the root filesystem. Picking the first partition can
# therefore select one with no filesystem at all. Prefer the largest
# partition that blkid reports as a Linux filesystem; fall back to the
# largest partition, then the first one, then the disk itself (whole-disk
# image with no partition table).
find_root_partition() {
    _disk=$1
    _base=${_disk#/dev/}
    _have_blkid=0
    command -v blkid >/dev/null 2>&1 && _have_blkid=1
    _root=""
    _root_size=0
    _largest=""
    _largest_size=0
    _first=""
    for _part in /sys/block/"$_base"/*/; do
        _pname=${_part%%/}
        _pname=${_pname##*/}
        [ -b "/dev/$_pname" ] || continue
        _dev="/dev/$_pname"
        [ -n "$_first" ] || _first=$_dev
        _size=$(cat "/sys/block/$_base/$_pname/size" 2>/dev/null) || _size=0
        case "$_size" in '' | *[!0-9]*) _size=0 ;; esac
        if [ "$_size" -gt "$_largest_size" ]; then
            _largest=$_dev
            _largest_size=$_size
        fi
        if [ "$_have_blkid" = 1 ]; then
            _type=$(blkid -s TYPE -o value "$_dev" 2>/dev/null) || _type=""
            case "$_type" in
                ext2 | ext3 | ext4 | xfs | btrfs | f2fs) ;;
                *) continue ;;
            esac
        fi
        if [ "$_size" -gt "$_root_size" ]; then
            _root=$_dev
            _root_size=$_size
        fi
    done
    if [ -n "$_root" ]; then
        printf '%s\n' "$_root"
    elif [ -n "$_largest" ]; then
        printf '%s\n' "$_largest"
    elif [ -n "$_first" ]; then
        printf '%s\n' "$_first"
    else
        printf '%s\n' "$_disk"
    fi
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
    if ! command -v curl >/dev/null 2>&1; then
        apk add --no-cache curl >/dev/null 2>&1 || \
            die "curl unavailable and could not be installed (is apk networking working?)"
    fi
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

# Mount the target root filesystem. The netboot initramfs only ships
# vfat/fuse/squashfs modules; ext4/xfs/btrfs live in the modloop that was
# merged into /lib/modules earlier. They are not loaded automatically, and
# busybox mount without -t only tries filesystems already registered in
# /proc/filesystems, so an unloaded ext4 module makes mount fail with EINVAL.
mount_root() {
    _dev=$1
    _mp=$2
    _type=$(blkid -s TYPE -o value "$_dev" 2>/dev/null)
    if [ -n "$_type" ]; then
        log "root filesystem type: $_type"
        modprobe "$_type" 2>/dev/null || true
        mount -t "$_type" "$_dev" "$_mp" && return 0
        warn "mount -t $_type failed; trying other filesystem types"
    fi
    for _type in ext4 ext3 ext2 xfs btrfs f2fs; do
        modprobe "$_type" 2>/dev/null || true
        mount -t "$_type" "$_dev" "$_mp" 2>/dev/null && return 0
    done
    # Last resort: let busybox try every filesystem in /proc/filesystems.
    mount "$_dev" "$_mp"
}

fixup_root() {
    _part=$(find_root_partition "$disk")
    log "root partition: $_part"
    mkdir -p /os
    mount_root "$_part" /os || die "could not mount $_part at /os"
    mount -t proc proc /os/proc 2>/dev/null || true
    mount -t sysfs sysfs /os/sys 2>/dev/null || true
    mount --bind /dev /os/dev 2>/dev/null || true

    # Point fstab's root entry at the freshly-written partition's UUID.
    _cur=$(blkid -s UUID -o value "$_part" 2>/dev/null)
    if [ -n "$_cur" ] && [ -f /os/etc/fstab ]; then
        sed -i "/[[:space:]]\/[[:space:]]/s/UUID=[0-9a-fA-F-]*/UUID=$_cur/" /os/etc/fstab
        log "fstab root UUID pinned to $_cur"
    fi

    set_target_credentials
    write_sshd_config
    ensure_target_ssh
    configure_target_network
    write_cloud_init_override
    target_restorecon
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
}

# Write a public key into the authorized_keys of the account whose home is $1
# (a path inside /os).
install_authorized_key() {
    _home=$1
    mkdir -p "$_home/.ssh"
    printf '%s\n' "$RESTAGE_SSH_KEY" >"$_home/.ssh/authorized_keys"
    chmod 700 "$_home/.ssh"
    chmod 600 "$_home/.ssh/authorized_keys"
}

# Apply --password / --ssh-key / --username to the installed system.
# Root always keeps working (rescue path); --username additionally creates
# and configures that account. Passwords are fed through stdin so shell
# metacharacters in them are never interpreted.
set_target_credentials() {
    _user=${RESTAGE_USERNAME:-root}
    _pass=${RESTAGE_PASSWORD:-}
    _key=${RESTAGE_SSH_KEY:-}

    if [ -n "$_pass" ]; then
        printf 'root:%s\n' "$_pass" | chroot /os chpasswd 2>/dev/null && \
            log "root password set on target" || warn "could not set root password on target"
    fi
    if [ -n "$_key" ]; then
        install_authorized_key /os/root
        log "root SSH key installed on target"
    fi

    [ "$_user" = "root" ] && return 0

    if ! chroot /os id -u "$_user" >/dev/null 2>&1; then
        _shell=/bin/sh
        [ -x /os/bin/bash ] && _shell=/bin/bash
        if chroot /os useradd -m -s "$_shell" "$_user" >/dev/null 2>&1; then
            log "created target user $_user"
        else
            warn "could not create target user $_user"
        fi
    fi
    chroot /os id -u "$_user" >/dev/null 2>&1 || return 0

    if grep -q '^sudo:' /os/etc/group 2>/dev/null; then
        chroot /os usermod -aG sudo "$_user" >/dev/null 2>&1 || true
    elif grep -q '^wheel:' /os/etc/group 2>/dev/null; then
        chroot /os usermod -aG wheel "$_user" >/dev/null 2>&1 || true
    fi
    # A key-only account has no password to type for sudo, so grant it
    # passwordless sudo (what cloud-init does for its default user).
    if [ -d /os/etc/sudoers.d ]; then
        if [ -n "$_pass" ]; then
            printf '%s ALL=(ALL:ALL) ALL\n' "$_user" >"/os/etc/sudoers.d/90-restage-$_user"
        else
            printf '%s ALL=(ALL:ALL) NOPASSWD:ALL\n' "$_user" >"/os/etc/sudoers.d/90-restage-$_user"
        fi
        chmod 440 "/os/etc/sudoers.d/90-restage-$_user" 2>/dev/null || true
    fi
    if [ -n "$_pass" ]; then
        printf '%s:%s\n' "$_user" "$_pass" | chroot /os chpasswd 2>/dev/null && \
            log "password set for $_user" || warn "could not set password for $_user"
    fi
    if [ -n "$_key" ]; then
        install_authorized_key "/os/home/$_user"
        chroot /os chown -R "$_user" "/home/$_user/.ssh" 2>/dev/null || true
        log "SSH key installed for $_user"
    fi
}

# Write the sshd drop-in. Cloud images ship PasswordAuthentication no and
# root logins disabled, so a freshly-installed system has no usable SSH even
# though sshd is enabled.
write_sshd_config() {
    if [ ! -f /os/etc/ssh/sshd_config ]; then
        warn "no sshd_config on target; skipping SSH server configuration"
        return 0
    fi
    _pass=${RESTAGE_PASSWORD:-}
    _port=${RESTAGE_SSH_PORT:-22}
    _dir=/os/etc/ssh/sshd_config.d
    mkdir -p "$_dir"
    {
        printf '# generated by restage\n'
        if [ -n "$_pass" ]; then
            printf 'PermitRootLogin yes\n'
            printf 'PasswordAuthentication yes\n'
            printf 'KbdInteractiveAuthentication yes\n'
        else
            printf 'PermitRootLogin prohibit-password\n'
            printf 'PasswordAuthentication no\n'
            printf 'KbdInteractiveAuthentication no\n'
        fi
        printf 'PubkeyAuthentication yes\n'
        printf 'UsePAM yes\n'
        printf 'Port %s\n' "$_port"
    } >"$_dir/00-restage.conf"
    chmod 600 "$_dir/00-restage.conf" 2>/dev/null || true

    # Images without an Include for sshd_config.d need the directives in the
    # main file. sshd keeps the FIRST value it reads for most options, so
    # they must be prepended, not appended.
    if ! grep -qE '^[[:space:]]*Include[[:space:]]+.*sshd_config\.d' /os/etc/ssh/sshd_config 2>/dev/null; then
        _tmp=/os/etc/ssh/sshd_config.restage
        {
            printf '# restage: prepended because sshd_config has no Include\n'
            cat "$_dir/00-restage.conf"
            printf '\n'
            cat /os/etc/ssh/sshd_config
        } >"$_tmp" && mv "$_tmp" /os/etc/ssh/sshd_config
        chmod 644 /os/etc/ssh/sshd_config 2>/dev/null || true
    fi
    log "target sshd configured (port $_port, password auth $([ -n "$_pass" ] && printf yes || printf no))"
}

# Cloud images ship without SSH host keys: cloud-init deletes them and
# regenerates on first boot. If cloud-init does not run (no metadata
# service), sshd -t fails and the service never starts. Generate them here
# and make sure the service is enabled.
ensure_target_ssh() {
    if [ ! -e /os/etc/ssh/ssh_host_ed25519_key ] && [ ! -e /os/etc/ssh/ssh_host_rsa_key ]; then
        if chroot /os ssh-keygen -A >/dev/null 2>&1; then
            log "generated SSH host keys on target"
        else
            warn "could not generate SSH host keys on target"
        fi
    fi

    _unit=""
    for _sock in ssh.socket sshd.socket; do
        if [ -L "/os/etc/systemd/system/sockets.target.wants/$_sock" ]; then
            log "target ssh socket already enabled ($_sock)"
            return 0
        fi
    done
    for _u in ssh.service sshd.service; do
        if [ -f "/os/lib/systemd/system/$_u" ] || [ -f "/os/usr/lib/systemd/system/$_u" ]; then
            _unit=$_u
            break
        fi
    done
    if [ -n "$_unit" ]; then
        _wants=/os/etc/systemd/system/multi-user.target.wants
        mkdir -p "$_wants"
        _src=/lib/systemd/system/$_unit
        [ -f "/os$_src" ] || _src=/usr/lib/systemd/system/$_unit
        ln -sf "$_src" "$_wants/$_unit" 2>/dev/null || true
        log "target ssh service enabled ($_unit)"
    elif [ -x /os/etc/init.d/ssh ]; then
        for _rc in rc2.d rc3.d rc5.d; do
            mkdir -p "/os/etc/$_rc"
            ln -sf ../init.d/ssh "/os/etc/$_rc/S01ssh" 2>/dev/null || true
        done
        log "target ssh enabled (sysv)"
    else
        warn "no ssh service found on target"
    fi
}

# Bring up networking on the installed system. Cloud images have an empty
# /etc/netplan and rely on cloud-init metadata; with no metadata service
# (restage writes a plain cloud image) they boot with no network at all.
# Match the NIC by MAC because predictable names can differ from the system
# that was running before the reinstall.
configure_target_network() {
    if [ -e /os/usr/lib/systemd/system-generators/netplan ] || \
        [ -e /os/lib/systemd/system-generators/netplan ] || \
        [ -x /os/usr/sbin/netplan ] || [ -x /os/sbin/netplan ]; then
        write_netplan_config
    elif [ -d /os/etc/NetworkManager ]; then
        write_nm_config
    elif [ -d /os/etc/sysconfig/network-scripts ]; then
        write_ifcfg_config
    else
        warn "no supported network configuration system found on target"
    fi
}

# Interface identity for the installed config: captured MAC, else the live
# MAC of the installer NIC (same hardware), else nothing.
target_net_mac() {
    _mac=${RESTAGE_NET_MAC:-}
    if [ -z "$_mac" ] && [ -n "${RESTAGE_NET_IFACE:-}" ]; then
        _mac=$(cat "/sys/class/net/${RESTAGE_NET_IFACE}/address" 2>/dev/null) || _mac=""
    fi
    if [ -z "$_mac" ]; then
        # Capture failed before reboot: ask the installer's routing table.
        _if=$(ip route show default 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n1)
        [ -n "$_if" ] && _mac=$(cat "/sys/class/net/$_if/address" 2>/dev/null)
    fi
    if [ -z "$_mac" ]; then
        for _d in /sys/class/net/*; do
            _n=${_d##*/}
            case "$_n" in
                lo | docker* | br-* | veth* | virbr* | lxc* | tap* | tun*) continue ;;
            esac
            _mac=$(cat "$_d/address" 2>/dev/null) || continue
            [ -n "$_mac" ] && break
        done
    fi
    _mac=$(printf '%s' "$_mac" | tr 'A-Z' 'a-z')
    case "$_mac" in
        00:00:00:00:00:00) _mac="" ;;
    esac
    printf '%s\n' "$_mac"
}

net_is_static() {
    [ "${RESTAGE_NET_MODE:-dhcp}" = "static" ] && [ -n "${RESTAGE_IPV4:-}" ]
}

write_netplan_config() {
    _dir=/os/etc/netplan
    mkdir -p "$_dir"
    # cloud-init's fallback DHCP file would define the same NIC twice and
    # can override what we write below.
    for _f in "$_dir"/*cloud-init*.yaml; do
        if [ -e "$_f" ]; then
            rm -f "$_f" && log "removed stale cloud-init netplan ${_f##*/}"
        fi
    done
    _ifname=${RESTAGE_NET_IFACE:-}
    _mac=$(target_net_mac)
    {
        printf 'network:\n'
        printf '  version: 2\n'
        if [ -f /os/lib/systemd/system/systemd-networkd.service ] || \
            [ -f /os/usr/lib/systemd/system/systemd-networkd.service ]; then
            printf '  renderer: networkd\n'
        fi
        printf '  ethernets:\n'
        if [ -n "$_mac" ]; then
            printf '    restage0:\n'
            printf '      match:\n'
            printf '        macaddress: "%s"\n' "$_mac"
        elif [ -n "$_ifname" ]; then
            printf '    %s:\n' "$_ifname"
        else
            # Last resort: match any predictable ethernet name (eth0, ens18,
            # enp1s0, eno1...).
            printf '    restage0:\n'
            printf '      match:\n'
            printf '        name: "e*"\n'
        fi
        printf '      optional: true\n'
        if net_is_static; then
            printf '      dhcp4: false\n'
            printf '      dhcp6: false\n'
            printf '      addresses:\n'
            printf '        - %s\n' "$RESTAGE_IPV4"
            [ -n "${RESTAGE_IPV6:-}" ] && printf '        - %s\n' "$RESTAGE_IPV6"
            if [ -n "${RESTAGE_GW4:-}" ] || [ -n "${RESTAGE_GW6:-}" ]; then
                printf '      routes:\n'
                [ -n "${RESTAGE_GW4:-}" ] && \
                    printf '        - to: default\n          via: %s\n' "$RESTAGE_GW4"
                [ -n "${RESTAGE_GW6:-}" ] && \
                    printf '        - to: "::/0"\n          via: %s\n' "$RESTAGE_GW6"
            fi
        else
            printf '      dhcp4: true\n'
            printf '      dhcp6: true\n'
        fi
        if [ -n "${RESTAGE_DNS1:-}" ]; then
            printf '      nameservers:\n'
            printf '        addresses:\n'
            printf '          - %s\n' "$RESTAGE_DNS1"
        fi
    } >"$_dir/99-restage.yaml"
    chmod 600 "$_dir/99-restage.yaml" 2>/dev/null || true
    # netplan renders to networkd here, so make sure networkd actually runs.
    if [ -f /os/lib/systemd/system/systemd-networkd.service ] || \
        [ -f /os/usr/lib/systemd/system/systemd-networkd.service ]; then
        _wants=/os/etc/systemd/system/multi-user.target.wants
        mkdir -p "$_wants"
        _src=/lib/systemd/system/systemd-networkd.service
        [ -f "/os$_src" ] || _src=/usr/lib/systemd/system/systemd-networkd.service
        ln -sf "$_src" "$_wants/systemd-networkd.service" 2>/dev/null || true
    fi
    log "netplan written for ${_ifname:-any ethernet} (${RESTAGE_NET_MODE:-dhcp})"
}

# NetworkManager keyfile (RHEL family / any NM system). No interface-name:
# a profile without one applies to the ethernet device regardless of how the
# kernel named it after the reinstall.
write_nm_config() {
    _dir=/os/etc/NetworkManager/system-connections
    mkdir -p "$_dir"
    # Replace any profile cloud-init generated at first boot.
    rm -f "$_dir"/cloud-init*.nmconnection 2>/dev/null || true
    {
        printf '[connection]\n'
        printf 'id=restage\n'
        printf 'type=ethernet\n'
        printf 'autoconnect=true\n'
        printf 'autoconnect-priority=999\n'
        printf '\n[ipv4]\n'
        if net_is_static; then
            printf 'method=manual\n'
            if [ -n "${RESTAGE_GW4:-}" ]; then
                printf 'address1=%s,%s\n' "$RESTAGE_IPV4" "$RESTAGE_GW4"
            else
                printf 'address1=%s\n' "$RESTAGE_IPV4"
            fi
        else
            printf 'method=auto\n'
        fi
        [ -n "${RESTAGE_DNS1:-}" ] && printf 'dns=%s;\n' "$RESTAGE_DNS1"
        printf '\n[ipv6]\n'
        if net_is_static && [ -n "${RESTAGE_IPV6:-}" ]; then
            printf 'method=manual\n'
            if [ -n "${RESTAGE_GW6:-}" ]; then
                printf 'address1=%s,%s\n' "$RESTAGE_IPV6" "$RESTAGE_GW6"
            else
                printf 'address1=%s\n' "$RESTAGE_IPV6"
            fi
        else
            printf 'method=auto\n'
        fi
        printf '\n[proxy]\n'
    } >"$_dir/restage.nmconnection"
    chmod 600 "$_dir/restage.nmconnection" 2>/dev/null || true
    log "NetworkManager profile written (${RESTAGE_NET_MODE:-dhcp})"
}

# Legacy sysconfig/ifcfg fallback.
write_ifcfg_config() {
    _dir=/os/etc/sysconfig/network-scripts
    mkdir -p "$_dir"
    _ifname=${RESTAGE_NET_IFACE:-eth0}
    {
        printf 'NAME=restage\n'
        printf 'DEVICE=%s\n' "$_ifname"
        printf 'ONBOOT=yes\n'
        printf 'NM_CONTROLLED=yes\n'
        if net_is_static; then
            printf 'BOOTPROTO=none\n'
            printf 'IPADDR=%s\n' "${RESTAGE_IPV4%/*}"
            printf 'PREFIX=%s\n' "${RESTAGE_IPV4#*/}"
            [ -n "${RESTAGE_GW4:-}" ] && printf 'GATEWAY=%s\n' "$RESTAGE_GW4"
            [ -n "${RESTAGE_DNS1:-}" ] && printf 'DNS1=%s\n' "$RESTAGE_DNS1"
            [ -n "${RESTAGE_IPV6:-}" ] && printf 'IPV6ADDR=%s\n' "$RESTAGE_IPV6"
            [ -n "${RESTAGE_GW6:-}" ] && printf 'IPV6_DEFAULTGW=%s\n' "$RESTAGE_GW6"
        else
            printf 'BOOTPROTO=dhcp\n'
        fi
    } >"$_dir/ifcfg-restage"
    chmod 600 "$_dir/ifcfg-restage" 2>/dev/null || true
    log "ifcfg written for $_ifname (${RESTAGE_NET_MODE:-dhcp})"
}

# Stop cloud-init from overriding what we wrote on first boot: no network
# regeneration, no forced command on root's keys, no host-key deletion.
write_cloud_init_override() {
    [ -d /os/etc/cloud/cloud.cfg.d ] || return 0
    {
        printf '# generated by restage\n'
        printf 'disable_root: false\n'
        printf 'ssh_deletekeys: false\n'
        if [ -n "${RESTAGE_PASSWORD:-}" ]; then
            printf 'ssh_pwauth: true\n'
        else
            printf 'ssh_pwauth: false\n'
        fi
        printf 'network:\n'
        printf '  config: disabled\n'
    } >/os/etc/cloud/cloud.cfg.d/99-restage.cfg
    log "cloud-init overrides written"
}

# Files created from the installer have no SELinux label. On enforcing
# targets (RHEL family) sshd/networkd can be denied reading them, so relabel
# the directories we touched when the target provides restorecon.
target_restorecon() {
    if [ ! -x /os/usr/sbin/restorecon ] && [ ! -x /os/sbin/restorecon ]; then
        return 0
    fi
    for _p in /etc/ssh /etc/netplan /etc/NetworkManager/system-connections /etc/cloud; do
        [ -e "/os$_p" ] || continue
        chroot /os restorecon -R "$_p" >/dev/null 2>&1 || true
    done
    log "SELinux labels restored on generated config"
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
