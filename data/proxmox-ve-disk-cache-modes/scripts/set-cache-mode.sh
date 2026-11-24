#!/bin/bash
# usage: set-cache-mode.sh <VMID> <disk (scsi1 など)> <mode>   Proxmox VE のホストで動かす
# ディスクのキャッシュモードを変え、qemu を起動し直して、実際のフラグを表示する
set -e
V=$1 DISK=$2 M=$3
spec=$(qm config $V | sed -n "s/^$DISK: //p" | sed -E 's/cache=[a-z]+/cache='"$M"'/')
qm set $V --$DISK "$spec" >/dev/null
qm shutdown $V --timeout 60 >/dev/null 2>&1 || qm stop $V >/dev/null
qm start $V >/dev/null
sleep 3
tr '\0' '\n' < /proc/$(cat /var/run/qemu-server/$V.pid)/cmdline > /tmp/cmdline-$V
# -blockdev の cache.direct / cache.no-flush と、-device の write-cache
grep -E "drive-$DISK" /tmp/cmdline-$V | grep -oE '"cache":\{[^}]*\}|write-cache=[a-z]+' | sort -u
qm config $V | grep -E "^$DISK" | grep -oE 'cache=[a-z]+'
