#!/bin/sh
#
# runtime/windows.sh — unattended Windows install for the initrd installer.
#
# This implements do_windows() (sourced by trans.sh). It:
#
#   1. installs the apk packages the rest of the flow needs,
#   2. partitions the target disk (GPT+EFI or MBR+BIOS),
#   3. downloads and mounts the Windows ISO,
#   4. copies the ISO tree onto a dedicated installer partition,
#   5. patches boot.wim/install.wim when drivers or first-boot config
#      (static IP, RDP port, ping) were requested,
#   6. renders autounattend.xml and installs a one-shot boot entry,
#   7. reboots into Windows Setup.
#
# Strict POSIX sh (busybox/ash): no bashisms, no arrays. Sourced by
# trans.sh, so helpers from runtime/common.sh are available.
#
# shellcheck shell=sh

# `disk` is set by trans.sh before do_windows dispatches to win_main.
# shellcheck disable=SC2154
set -u

WINSH_ALPINE_VER="${RESTAGE_ALPINE_VER:-3.22}"
WINSH_APK_PKGS="parted dosfstools ntfs-3g ntfs-3g-progs wimlib efibootmgr grub grub-bios grub-efi util-linux libarchive-tools"
WINSH_ISO="/os/windows.iso"
WINSH_ISOMNT="/iso"
WINSH_OSMNT="/os"
WINSH_INSTMNT="/installer"
WINSH_EFIMNT="/efi"
WINSH_VIRTIO_ISO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win.iso"

# Set to 1 when custom/virtio drivers were injected into boot.wim.
WINSH_DRIVERS=0

# Log wrapper (same prefix as common.sh's log()).
win_log() {
    log "$@"
}

# ------------------------------------------------------------------ setup --

# Install the tooling the rest of the flow needs.
win_apk() {
    _ver=$1
    apk_repos "$_ver"
    apk update >/dev/null 2>&1 || warn "apk update failed; continuing anyway"
    # shellcheck disable=SC2086
    if ! apk add --no-cache $WINSH_APK_PKGS >/dev/null 2>&1; then
        die "could not install required packages (apk add failed — is networking working?)"
    fi
    modprobe fuse 2>/dev/null || true
    modprobe loop 2>/dev/null || true
}

# efi or bios
win_firmware() {
    if [ -d /sys/firmware/efi ]; then
        printf 'efi\n'
    else
        printf 'bios\n'
    fi
}

# ---------------------------------------------------------------- hardware --

# Partition device node for a disk+partition number (nvme/mmcblk use pN).
win_part_name() {
    _disk=$1
    _n=$2
    _base=${_disk#/dev/}
    case "$_base" in
        *[0-9]) printf '%s\n' "${_disk}p${_n}" ;;
        *) printf '%s\n' "${_disk}${_n}" ;;
    esac
}

# Disk size in MiB (blockdev, fdisk, then parted fallbacks).
win_disk_size_mb() {
    _disk=$1
    _sz=$(blockdev --getsz "$_disk" 2>/dev/null)
    if [ -n "$_sz" ] && [ "$_sz" -gt 0 ] 2>/dev/null; then
        printf '%s\n' "$((_sz / 2048))"
        return 0
    fi
    _fdsz=$(fdisk -l "$_disk" 2>/dev/null | sed -n 's/.*, \([0-9][0-9]*\) sectors.*/\1/p' | head -n1)
    if [ -n "$_fdsz" ]; then
        printf '%s\n' "$((_fdsz / 2048))"
        return 0
    fi
    _psz=$(parted -s "$_disk" unit MB print 2>/dev/null | sed -n 's/^Disk .*: \([0-9][0-9]*\)MB/\1/p')
    printf '%s\n' "${_psz:-0}"
}

# Create the layout: GPT = EFI(1) MSR(2) os(3) installer(4);
# MBR = os(1) installer(2). Takes the installer size from the ISO size.
win_partition() {
    _disk=$1
    _fw=$2
    _iso_mb=$3
    _total=$(win_disk_size_mb "$_disk")
    if [ "$_total" -lt 8000 ]; then
        die "target disk $_disk is ${_total}MiB — Windows needs at least 8 GiB"
    fi
    _inst_mb=$((_iso_mb + 300))
    _os_start_mb=1041
    _inst_start_mb=$((_total - _inst_mb))
    if [ "$_inst_start_mb" -le "$_os_start_mb" ]; then
        die "disk too small (${_total}MiB) for Windows plus a ${_iso_mb}MiB installer"
    fi
    win_log "partitioning $_disk (${_total}MiB): os=${_os_start_mb}-${_inst_start_mb}MiB installer=${_inst_start_mb}-100%"

    # Clear any existing partition table/GPT.
    dd if=/dev/zero of="$_disk" bs=1M count=1 conv=fsync 2>/dev/null || true
    partprobe "$_disk" 2>/dev/null || blockdev --rereadpt "$_disk" 2>/dev/null || true
    sleep 2

    if [ "$_fw" = efi ]; then
        parted -s "$_disk" mklabel gpt || die "parted: could not create GPT table"
        parted -s "$_disk" mkpart primary fat32 1MiB 1025MiB || die "parted: EFI partition failed"
        parted -s "$_disk" set 1 esp on || true
        parted -s "$_disk" set 1 boot on || true
        parted -s "$_disk" mkpart primary 1025MiB 1041MiB || die "parted: MSR partition failed"
        parted -s "$_disk" set 2 msftres on || true
        parted -s "$_disk" mkpart primary ntfs "${_os_start_mb}MiB" "${_inst_start_mb}MiB" || die "parted: OS partition failed"
        parted -s "$_disk" mkpart primary ntfs "${_inst_start_mb}MiB" 100% || die "parted: installer partition failed"
        WINSH_OSN=3
        WINSH_INSTN=4
    else
        parted -s "$_disk" mklabel msdos || die "parted: could not create MBR table"
        parted -s "$_disk" mkpart primary ntfs 1MiB "${_inst_start_mb}MiB" || die "parted: OS partition failed"
        parted -s "$_disk" set 1 boot on || true
        parted -s "$_disk" mkpart primary ntfs "${_inst_start_mb}MiB" 100% || die "parted: installer partition failed"
        WINSH_OSN=1
        WINSH_INSTN=2
    fi

    partprobe "$_disk" 2>/dev/null || blockdev --rereadpt "$_disk" 2>/dev/null || true
    sleep 3
}

# Format the partitions and record their device nodes.
win_mkfs() {
    _fw=$1
    if [ "$_fw" = efi ]; then
        _esp=$(win_part_name "$disk" 1)
        mkfs.vfat -F 32 "$_esp" >/dev/null 2>&1 || die "mkfs.vfat failed on $_esp"
        WINSH_EFIP=$(win_part_name "$disk" 1)
    fi
    WINSH_OSP=$(win_part_name "$disk" "$WINSH_OSN")
    WINSH_INSTP=$(win_part_name "$disk" "$WINSH_INSTN")
    mkfs.ntfs -Q -f -L os "$WINSH_OSP" >/dev/null 2>&1 || die "mkfs.ntfs failed on $WINSH_OSP"
    mkfs.ntfs -Q -f -L installer "$WINSH_INSTP" >/dev/null 2>&1 || die "mkfs.ntfs failed on $WINSH_INSTP"
}

win_mount_parts() {
    _fw=$1
    mkdir -p /os /installer /efi /wim /bootwim
    if [ "$_fw" = efi ]; then
        mount "$WINSH_EFIP" /efi || die "could not mount the EFI partition"
    fi
    mount "$WINSH_OSP" /os || die "could not mount the OS partition"
    mount "$WINSH_INSTP" /installer || die "could not mount the installer partition"
    win_log "partitions mounted: os=/os installer=/installer${WINSH_EFIP:+ efi=/efi}"
}

# -------------------------------------------------------------------- ISO --

# Resolve the ISO URL: RESTAGE_ISO_URL wins, then a best-effort scrape of the
# catalog hint page, then fail (installer drops to rescue mode).
win_iso_url() {
    _url=${RESTAGE_ISO_URL:-}
    if [ -n "$_url" ]; then
        printf '%s\n' "$_url"
        return 0
    fi
    _hint=${RESTAGE_ISO_HINT:-}
    if [ -n "$_hint" ]; then
        win_log "no --iso given; looking for a download link on $_hint"
        _page=$(fetch_stdout "$_hint") || {
            warn "could not fetch $_hint"
            return 1
        }
        _url=$(printf '%s\n' "$_page" | grep -oiE 'https?://[^[:space:]"'"'"'<>]*\.iso' | head -n1)
        if [ -n "$_url" ]; then
            win_log "resolved ISO link: $_url"
            printf '%s\n' "$_url"
            return 0
        fi
        warn "no direct .iso link found on $_hint"
    fi
    warn "no ISO URL available — rerun 'restage windows' with --iso <direct http(s) URL>"
    return 1
}

win_download_iso() {
    _url=$1
    if [ -f /os/windows.iso ]; then
        win_log "windows.iso already present; skipping download"
        return 0
    fi
    # TEST-ONLY: copy the ISO from a locally attached block device (e.g. a
    # second virtio drive) instead of pulling it over the network.
    if [ -n "${RESTAGE_TEST_ISO_DEV:-}" ] && [ -b "${RESTAGE_TEST_ISO_DEV}" ]; then
        win_log "copying the Windows ISO from ${RESTAGE_TEST_ISO_DEV} (test path)"
        dd if="${RESTAGE_TEST_ISO_DEV}" of=/os/windows.iso bs=4M 2>/dev/null ||
            die "ISO copy from ${RESTAGE_TEST_ISO_DEV} failed"
        win_log "ISO copied"
        return 0
    fi
    win_log "downloading the Windows ISO to /os/windows.iso (this can take a while)"
    fetch "$_url" /os/windows.iso || die "ISO download failed"
    win_log "ISO downloaded"
}

# Rough ISO size in MiB (from the server's Content-Length when available).
win_iso_size_mb() {
    _url=$1
    _len=$(wget -S --spider "$_url" 2>&1 | sed -n 's/.*[Cc]ontent-[Ll]ength: *\([0-9][0-9]*\).*/\1/p' | tail -n1)
    if [ -n "$_len" ] && [ "$_len" -gt 4000000000 ] 2>/dev/null; then
        printf '%s\n' "$((_len / 1048576))"
        return 0
    fi
    printf '7000\n'
}

win_mount_iso() {
    modprobe loop 2>/dev/null || true
    modprobe isofs 2>/dev/null || true
    modprobe udf 2>/dev/null || true
    _i=0
    while [ "$_i" -lt 8 ]; do
        [ -e "/dev/loop$_i" ] || mknod "/dev/loop$_i" b 7 "$_i" 2>/dev/null || true
        _i=$((_i + 1))
    done
    mkdir -p /iso
    if mount -o loop,ro /os/windows.iso /iso 2>/dev/null; then
        WINSH_ISO_MODE=mounted
        win_log "ISO mounted at /iso"
        return 0
    fi
    # The Alpine netboot kernel lacks isofs/udf modules, so a kernel loop
    # mount is often unavailable. Fall back to a userspace extraction of the
    # ISO tree straight onto the installer partition (already on disk).
    win_log "kernel loop mount unavailable; extracting the ISO with bsdtar (this can take a while)"
    command -v bsdtar >/dev/null 2>&1 || die "could not mount or extract the Windows ISO (no bsdtar)"
    if ! bsdtar -xf /os/windows.iso -C /installer >/dev/null 2>&1; then
        die "could not extract the Windows ISO with bsdtar"
    fi
    rmdir /iso 2>/dev/null || true
    ln -s /installer /iso 2>/dev/null || mount --bind /installer /iso 2>/dev/null || true
    WINSH_ISO_MODE=extracted
    win_log "ISO extracted to /installer (looked up as /iso)"
}

# Case-insensitive find under $1 (max depth 2).
win_find_file() {
    _dir=$1
    _name=$2
    # -L: /iso may be a symlink to /installer when the ISO was extracted.
    find -L "$_dir" -maxdepth 2 -iname "$_name" 2>/dev/null | head -n1
}

# Architecture of the WIM (x64/x86/ARM64).
win_iso_arch() {
    _wim=$1
    if [ -n "${RESTAGE_TEST_ISO_ARCH:-}" ]; then
        printf '%s\n' "$RESTAGE_TEST_ISO_ARCH"
        return 0
    fi
    wimlib-imagex info "$_wim" 2>/dev/null | awk '/Architecture:/{a=$2} END{print a}'
}

# Match the requested edition against the images in the install wim.
# Sets WINSH_IMG_NAME and WINSH_IMG_INDEX.
win_match_image() {
    _wim=$1
    _want=$2
    _names=$(wimlib-imagex info "$_wim" 2>/dev/null | sed -n 's/^Name: *//p')
    if [ -z "$_names" ]; then
        warn "wimlib could not read any image names from $_wim"
        return 1
    fi
    _count=$(printf '%s\n' "$_names" | grep -c . 2>/dev/null || true)
    if [ "$_count" -le 1 ]; then
        WINSH_IMG_NAME=$_names
        WINSH_IMG_INDEX=1
        return 0
    fi
    if [ -n "$_want" ]; then
        _match=$(printf '%s\n' "$_names" | grep -F -x -i "$_want" | head -n1)
        [ -n "$_match" ] || _match=$(printf '%s\n' "$_names" | grep -F -i "$_want" | head -n1)
        if [ -n "$_match" ]; then
            WINSH_IMG_NAME=$_match
            WINSH_IMG_INDEX=$(wimlib-imagex info "$_wim" "$_match" 2>/dev/null |
                sed -n 's/^Index: *//p' | head -n1)
            [ -n "$WINSH_IMG_INDEX" ] || WINSH_IMG_INDEX=1
            return 0
        fi
    fi
    warn "no install image matches '$_want'"
    warn "available images:"
    printf '%s\n' "$_names" | while read -r _n; do warn "  $_n"; done
    return 1
}

# Copy the ISO tree onto the installer partition (minus boot.wim which goes
# to the boot volume). Ensures a single install.wim exists there.
win_copy_iso() {
    if [ "${WINSH_ISO_MODE:-mounted}" = "extracted" ]; then
        win_log "ISO tree is already on the installer partition"
        rm -f /installer/sources/boot.wim 2>/dev/null || true
    else
        win_log "copying the ISO tree to the installer partition (this can take a while)"
        # cpio's header size field is 32-bit and silently wraps around
        # instead of failing on a file at or above 4GiB -- e.g. install.wim
        # on a modern multi-edition Windows 11 ISO. cp has no such ceiling.
        cp -a /iso/. /installer/ 2>/dev/null
        rm -f /installer/sources/boot.wim 2>/dev/null || true
    fi
    _src=$(win_find_file /iso install.wim)
    if [ -z "$_src" ]; then
        _src=$(win_find_file /iso install.esd)
        if [ -n "$_src" ]; then
            win_log "install.esd found; exporting to a single install.wim"
            wimlib-imagex export "$_src" all /installer/sources/install.wim >/dev/null 2>&1 ||
                die "could not export install.esd to install.wim"
        else
            _src=$(win_find_file /iso install.swm)
            if [ -n "$_src" ]; then
                win_log "split install.swm found; merging with wimlib"
                _ref="$(dirname "$_src")/install*.swm"
                wimlib-imagex export "$_src" all /installer/sources/install.wim \
                    --ref="$_ref" >/dev/null 2>&1 ||
                    die "could not merge install.swm files"
            else
                die "no install.wim, install.esd or install.swm found on the ISO"
            fi
        fi
        # Setup must not pick the split/esd source after we produced install.wim.
        rm -f /installer/sources/install.esd /installer/sources/install.swm 2>/dev/null
    fi
    WINSH_INST_WIM=/installer/sources/install.wim
    win_log "install image: $WINSH_INST_WIM"
}

# ----------------------------------------------------------------- drivers --

# Copy the ISO's boot files (and boot.wim) to the boot volume.
win_copy_boot_files() {
    _fw=$1
    if [ "$_fw" = efi ]; then
        mkdir -p /efi/sources
        cp -a /iso/efi/. /efi/ 2>/dev/null
        cp -a /iso/boot/. /efi/boot/ 2>/dev/null
        cp /iso/sources/boot.wim /efi/sources/boot.wim 2>/dev/null ||
            die "could not copy boot.wim to the EFI partition"
        WINSH_BOOT_WIM=/efi/sources/boot.wim
    else
        mkdir -p /os/sources
        cp /iso/bootmgr /os/bootmgr 2>/dev/null || true
        cp -a /iso/boot/. /os/boot/ 2>/dev/null
        cp /iso/sources/boot.wim /os/sources/boot.wim 2>/dev/null ||
            die "could not copy boot.wim to the OS partition"
        WINSH_BOOT_WIM=/os/sources/boot.wim
    fi
    win_log "boot files staged (boot.wim at $WINSH_BOOT_WIM)"
}

# Fetch and stage virtio drivers (only on KVM/virtio hardware).
win_fetch_virtio() {
    [ "${RESTAGE_VIRTIO:-0}" = "1" ] || return 0
    win_log "virtio hardware detected; fetching virtio-win drivers"
    if ! fetch "$WINSH_VIRTIO_ISO_URL" /os/virtio-win.iso; then
        warn "could not download virtio-win drivers; continuing with stock drivers"
        return 0
    fi
    mkdir -p /virtio /virtio-drivers
    if ! mount -o loop,ro /os/virtio-win.iso /virtio 2>/dev/null; then
        # Same isofs/udf caveat as the main ISO: extract instead.
        if ! bsdtar -xf /os/virtio-win.iso -C /virtio >/dev/null 2>&1; then
            warn "could not mount or extract the virtio ISO; continuing with stock drivers"
            return 0
        fi
        win_log "virtio-win ISO extracted (kernel loop mount unavailable)"
    fi
    # Copy the amd64 driver trees for Win10/11 (they are loaded from boot.wim).
    find /virtio -maxdepth 5 -type d \( -iname w10 -o -iname w11 \) 2>/dev/null |
        while read -r _d; do
            for _archd in amd64 x64; do
                [ -d "$_d/$_archd" ] || continue
                _name=$(echo "$_d" | awk -F/ '{print $(NF-1)}')
                cp -a "$_d/$_archd" "/virtio-drivers/$_name" 2>/dev/null || true
                break
            done
        done
    umount /virtio 2>/dev/null || true
    if [ -z "$(find /virtio-drivers -type f 2>/dev/null | head -n1)" ]; then
        warn "no virtio driver directories found; continuing with stock drivers"
    else
        win_log "virtio drivers staged"
    fi
}

# Inject drivers into boot.wim (they live at X:\custom_drivers in WinPE) when
# the user requested --add-driver or virtio drivers were staged.
# Ensure the kernel fuse module and /dev/fuse are available (wimlib
# mountrw needs them). Best-effort: returns 0 only when /dev/fuse exists.
win_fuse_up() {
    command -v modprobe >/dev/null 2>&1 && modprobe fuse 2>/dev/null
    if [ ! -e /dev/fuse ]; then
        mkdir -p /dev 2>/dev/null || true
        mknod /dev/fuse c 10 229 2>/dev/null || true
    fi
    [ -e /dev/fuse ] || return 1
    return 0
}

win_patch_bootwim() {
    [ "${WINSH_DRIVERS:-0}" = "1" ] || return 0
    win_log "injecting drivers into boot.wim"
    win_fuse_up || warn "fuse unavailable; cannot inject drivers into boot.wim"
    mkdir -p /bootwim
    wimlib-imagex mountrw "$WINSH_BOOT_WIM" 1 /bootwim >/dev/null 2>&1 ||
        die "could not mount boot.wim read-write (fuse missing?)"
    mkdir -p /bootwim/custom_drivers
    if [ -d /drivers ]; then
        cp -a /drivers/. /bootwim/custom_drivers/ 2>/dev/null
    fi
    if [ -d /virtio-drivers ]; then
        cp -a /virtio-drivers/. /bootwim/custom_drivers/ 2>/dev/null
    fi
    if ! _err=$(wimlib-imagex unmount --commit /bootwim 2>&1); then
        die "boot.wim commit failed: $_err"
    fi
    win_log "boot.wim patched with drivers"
}

# ----------------------------------------------------------------- install --

# Post-install first-boot script. Runs as SYSTEM after setup completes.
win_render_setupcomplete() {
    _out=$1
    {
        echo '@echo off'
        echo 'rem restage: post-install first-boot configuration'
        echo 'call "%SystemRoot%\Setup\Scripts\windows-netconf.bat"'
        echo 'exit /b 0'
    } >"$_out"
}

# IPv4 prefix -> dotted netmask.
win_netmask() {
    _p=$1
    case "$_p" in
        *[!0-9]*) _p=24 ;;
    esac
    if [ "$_p" -gt 32 ] 2>/dev/null; then
        _p=24
    fi
    _m=""
    _i=0
    while [ "$_i" -lt 4 ]; do
        if [ "$_p" -ge 8 ]; then
            _oct=255
            _p=$((_p - 8))
        else
            _oct=$((256 - (1 << (8 - _p))))
            [ "$_oct" -lt 0 ] && _oct=0
            _p=0
        fi
        if [ -z "$_m" ]; then
            _m=$_oct
        else
            _m=$_m.$_oct
        fi
        _i=$((_i + 1))
    done
    printf '%s\n' "$_m"
}

# First-boot network/RDP/ping batch, rendered from the captured config.
win_render_netconf() {
    _out=$1
    _mac=$(cat /sys/class/net/"${RESTAGE_NET_IFACE:-eth0}"/address 2>/dev/null |
        tr ':' '-' | tr 'a-f' 'A-F')
    {
        echo '@echo off'
        echo 'rem restage: network and RDP configuration (rendered at install time)'
        echo 'rem find the NIC that matches the install-time MAC address'
        echo 'for /f "tokens=1,2 delims=," %%a in ('"'"'getmac /fo csv /nh'"'"') do ('
        echo '    echo %%b | findstr /I "'"$_mac"'" >nul && set "IFACE=%%~a"'
        echo ')'
        if [ "${RESTAGE_RDP_PORT:-3389}" != "3389" ]; then
            echo "reg add \"HKLM\\SYSTEM\\CurrentControlSet\\Control\\Terminal Server\\WinStations\\RDP-Tcp\" /v PortNumber /t REG_DWORD /d ${RESTAGE_RDP_PORT} /f >nul"
            echo 'netsh advfirewall firewall delete rule name="RDP-TCP Port" >nul 2>&1'
            echo "netsh advfirewall firewall add rule name=\"RDP-TCP Port\" dir=in action=allow protocol=TCP localport=${RESTAGE_RDP_PORT} >nul"
        fi
        if [ "${RESTAGE_ALLOW_PING:-0}" = "1" ]; then
            echo 'netsh advfirewall firewall add rule name="ICMP Allow incoming V4 echo request" dir=in action=allow protocol=icmpv4:8,any >nul'
            echo 'netsh advfirewall firewall add rule name="ICMP Allow incoming V6 echo request" dir=in action=allow protocol=icmpv6:8,any >nul'
        fi
        echo 'reg add "HKLM\SYSTEM\CurrentControlSet\Control\Tcpip6\Parameters" /v RandomizeIdentifiers /t REG_DWORD /d 0 /f >nul'
        if [ "${RESTAGE_NET_MODE:-dhcp}" = "static" ] && [ -n "${RESTAGE_IPV4:-}" ]; then
            _ip=${RESTAGE_IPV4%/*}
            _prefix=${RESTAGE_IPV4#*/}
            _mask=$(win_netmask "$_prefix")
            _gw=${RESTAGE_GW4:-}
            _dns=${RESTAGE_DNS1:-8.8.8.8}
            echo "netsh interface ipv4 set address name=\"%IFACE%\" source=static address=$_ip mask=$_mask gateway=$_gw >nul"
            echo "netsh interface ipv4 set dnsservers name=\"%IFACE%\" static=$_dns primary >nul"
        fi
        echo 'exit /b 0'
    } >"$_out"
}

# Inject SetupComplete.cmd + the rendered netconf batch into install.wim so
# they land in the installed Windows. Skipped unless post-install work was
# requested.
win_patch_install_wim() {
    _need=0
    [ "${RESTAGE_NET_MODE:-dhcp}" = "static" ] && [ -n "${RESTAGE_IPV4:-}" ] && _need=1
    [ "${RESTAGE_RDP_PORT:-3389}" != "3389" ] && _need=1
    [ "${RESTAGE_ALLOW_PING:-0}" = "1" ] && _need=1
    [ "${WINSH_DRIVERS:-0}" = "1" ] && _need=1
    [ "$_need" = "1" ] || return 0

    win_log "injecting post-install configuration into install.wim"
    win_fuse_up || warn "fuse unavailable; cannot patch install.wim"
    mkdir -p /wim
    if ! _err=$(wimlib-imagex mountrw "$WINSH_INST_WIM" "$WINSH_IMG_INDEX" /wim 2>&1); then
        # ESD-style images cannot be mounted rw; re-export to a writable WIM.
        warn "install image is not mountable rw; re-exporting as a writable WIM (mountrw: $_err)"
        _tmp=/installer/sources/install-rw.wim
        if ! _err2=$(wimlib-imagex export "$WINSH_INST_WIM" all "$_tmp" 2>&1); then
            die "could not prepare a writable install image ($_err2)"
        fi
        mv "$_tmp" "$WINSH_INST_WIM"
        if ! _err=$(wimlib-imagex mountrw "$WINSH_INST_WIM" "$WINSH_IMG_INDEX" /wim 2>&1); then
            warn "could not mount the install image; skipping post-install injection ($_err)"
            return 0
        fi
    fi
    mkdir -p /wim/Windows/Setup/Scripts
    win_render_setupcomplete /wim/Windows/Setup/Scripts/SetupComplete.cmd
    win_render_netconf /wim/Windows/Setup/Scripts/windows-netconf.bat
    if ! _err=$(wimlib-imagex unmount --commit /wim 2>&1); then
        die "install.wim commit failed: $_err"
    fi
    win_log "install.wim patched"
}

# XML-escape a value.
win_xml_escape() {
    _s=$1
    _s=$(printf '%s' "$_s" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')
    printf '%s\n' "$_s"
}

# The offlineServicing driver-path entries (X: is the WinPE ramdisk).
win_driver_paths() {
    [ "${WINSH_DRIVERS:-0}" = "1" ] || return 0
    printf '                <PathAndCredentials wcm:action="add" wcm:keyValue="1">\n'
    printf '                    <Path>X:\\custom_drivers</Path>\n'
    printf '                </PathAndCredentials>\n'
}

# Render autounattend.xml into $1.
win_render_autounattend() {
    _out=$1
    _arch=$2
    _locale=$3
    _img=$4
    _user=$5
    _pass=$6
    _partid=$7
    _key=${RESTAGE_PRODUCT_KEY:-}
    _tpl=/windows-unattend.xml
    [ -f "$_tpl" ] || die "unattend template missing at $_tpl"
    _e_img=$(win_xml_escape "$_img")
    _e_user=$(win_xml_escape "$_user")
    _e_pass=$(win_xml_escape "$_pass")
    _e_key=$(win_xml_escape "$_key")
    # %driver_paths% expands to a multi-line XML block. Splicing embedded
    # newlines into a single sed -e "s|...|...|g" argument corrupts the
    # rest of that sed invocation's script instead of erroring out, so the
    # redirection below was silently truncating $_out to empty. Insert it
    # in its own pass with sed's read-file command instead.
    _driverf="${_out}.driverpaths"
    win_driver_paths >"$_driverf"
    sed \
        -e "s|%arch%|$_arch|g" \
        -e "s|%locale%|$_locale|g" \
        -e "s|%disk_id%|0|g" \
        -e "s|%installto_partitionid%|$_partid|g" \
        -e "s|%image_name%|$_e_img|g" \
        -e "s|%user_username%|$_e_user|g" \
        -e "s|%user_password%|$_e_pass|g" \
        -e "s|%key%|$_e_key|g" \
        "$_tpl" | sed -e "/%driver_paths%/r $_driverf" -e "/%driver_paths%/d" >"$_out"
    rm -f "$_driverf"
    [ -s "$_out" ] || die "rendering autounattend.xml produced an empty file"
    if grep -q '%[a-z_]*%' "$_out"; then
        die "autounattend.xml still has unsubstituted placeholders: $(grep -o '%[a-z_]*%' "$_out" | sort -u | tr '\n' ' ')"
    fi
    if [ -z "$_key" ]; then
        sed -i '/RS:KEY_BLOCK/,/\/RS:KEY_BLOCK/d' "$_out"
    fi
    if [ "${WINSH_DRIVERS:-0}" != "1" ]; then
        sed -i '/RS:DRIVER_BLOCK/,/\/RS:DRIVER_BLOCK/d' "$_out"
    fi
    # Drop any leftover block markers.
    sed -i '/RS:KEY_BLOCK/d; /\/RS:KEY_BLOCK/d; /RS:DRIVER_BLOCK/d; /\/RS:DRIVER_BLOCK/d' "$_out"
    win_log "unattend rendered to $_out (image: $_img, partition: $_partid)"
}

# ------------------------------------------------------------ boot loader --

# Install a one-shot boot entry that boots Windows Setup.
win_setup_boot() {
    _fw=$1
    if [ "$_fw" = efi ]; then
        win_log "creating EFI boot entry"
        efibootmgr --create --disk "$disk" --part 1 \
            --label "restage-windows" \
            --loader '\EFI\Microsoft\Boot\bootmgfw.efi' 2>&1 | while read -r _l; do win_log "$_l"; done
        # Fallback for firmwares that ignore NVRAM entries.
        if [ -f /efi/EFI/Boot/bootx64.efi ]; then
            win_log "removable bootx64.efi fallback present at /efi/EFI/Boot"
        fi
    else
        win_log "installing GRUB to boot bootmgr (BIOS)"
        grub-install --target i386-pc --boot-directory=/os/boot --force "$disk" >/dev/null 2>&1 ||
            warn "grub-install failed; the disk may not boot"
        cat >/os/boot/grub/grub.cfg <<'EOF'
set timeout=5
set default=0
menuentry "Windows Setup" {
    insmod search
    insmod ntfs
    insmod ntldr
    search --no-floppy --label --set=root os
    ntldr /bootmgr
}
EOF
        win_log "grub.cfg written; booting 'ntldr /bootmgr' from the 'os' partition"
    fi
}

# ---------------------------------------------------------------- entry --

# Main entry point, called by do_windows() in trans.sh.
win_main() {
    win_log "starting unattended Windows install"
    _fw=$(win_firmware)
    win_log "firmware: $_fw"

    _url=$(win_iso_url) || die "no Windows ISO available"
    _iso_mb=$(win_iso_size_mb "$_url")

    win_log "installing required packages (parted, wimlib, ntfs-3g, ...)"
    win_apk "$WINSH_ALPINE_VER"
    need_cmd wimlib-imagex || die "wimlib-imagex missing after apk install"
    need_cmd parted || die "parted missing after apk install"
    need_cmd mkfs.ntfs || die "mkfs.ntfs missing after apk install"

    win_partition "$disk" "$_fw" "$_iso_mb"
    win_mkfs "$_fw"
    win_mount_parts "$_fw"

    win_download_iso "$_url"
    win_mount_iso

    _arch=$(win_iso_arch "$(win_find_file /iso boot.wim)" | tr 'A-Z' 'a-z')
    case "$_arch" in
        # wimlib-imagex reports the PE-COFF machine name (x86_64), not
        # Microsoft's marketing term (x64); accept both spellings.
        x64 | x86_64 | amd64) _arch=amd64 ;;
        x86 | i386 | i686) _arch=x86 ;;
        arm64 | aarch64) _arch=arm64 ;;
        *) die "unsupported Windows image architecture: ${_arch:-unknown}" ;;
    esac
    win_log "installer architecture: $_arch"

    # Auto-injecting virtio-win into boot.wim's WinPE DriverPaths pass is
    # NOT enabled by default: it makes Windows Setup run an offline driver
    # scan that can hang indefinitely and unattended with no visible error
    # if anything about the injected package (signing, layout) doesn't
    # match what that scan expects -- and modern Windows images increasingly
    # carry inbox virtio support, so WinPE frequently sees the disk fine
    # without it. Explicit --add-driver (which populates /drivers) is
    # unaffected; that's an operator opting in and accepting the risk.
    if [ -d /drivers ]; then
        WINSH_DRIVERS=1
    fi

    win_copy_boot_files "$_fw"
    win_patch_bootwim
    win_copy_iso

    _iso_wim=$(win_find_file /iso install.wim)
    [ -n "$_iso_wim" ] || _iso_wim=$(win_find_file /iso install.esd)
    [ -n "$_iso_wim" ] || _iso_wim=$(win_find_file /iso install.swm)
    [ -n "$_iso_wim" ] || die "no install image found on the ISO"
    win_match_image "$_iso_wim" "${RESTAGE_IMAGE_NAME:-}" || die "cannot pick an install image"

    if [ "$_fw" = efi ]; then
        _partid=3
    else
        _partid=1
    fi

    _locale=${RESTAGE_LANG:-en-us}
    _user=${RESTAGE_USERNAME:-administrator}
    _pass=${RESTAGE_PASSWORD:-}
    if [ -z "$_pass" ]; then
        warn "no password was set at scheduling time; generating a random one"
        _pass=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
        warn "generated password: $_pass (change it after first login)"
    fi

    win_render_autounattend /installer/autounattend.xml \
        "$_arch" "$_locale" "$WINSH_IMG_NAME" "$_user" "$_pass" "$_partid"
    cp /installer/autounattend.xml /os/autounattend.xml
    if [ "$_fw" = efi ]; then
        cp /installer/autounattend.xml /efi/autounattend.xml
    fi

    # Inject first-boot config (static IP, RDP port, ping, drivers).
    win_patch_install_wim

    win_setup_boot "$_fw"

    win_log "Windows install staged — rebooting into Setup in 15 seconds (Ctrl-C on the console to cancel)"
}
