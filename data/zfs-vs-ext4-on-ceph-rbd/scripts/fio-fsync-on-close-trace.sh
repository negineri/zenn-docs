#!/bin/bash
# usage: smalltrace.sh <cache_label>  64 KiB のファイルを作っては fsync する負荷で、RBD への I/O を blktrace で記録する
L=$1 D=/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1 M=/mnt/t
B=$(basename $(readlink -f $D)); P=/sys/module/zfs/parameters
teardown(){ umount $M 2>/dev/null; zpool destroy -f tb 2>/dev/null; wipefs -aq $D >/dev/null 2>&1; }
mkdir -p $M /root/trace
for fs in zfs128k ext4; do
  teardown
  case $fs in
    ext4) mkfs.ext4 -q -F -E lazy_itable_init=0,lazy_journal_init=0 $D && mount $D $M ;;
    zfs128k) echo 32 > $P/zfs_vdev_async_read_max_active; echo 32 > $P/zfs_vdev_async_write_max_active
      zpool create -f -o ashift=9 -O recordsize=128K -O compression=lz4 -O xattr=sa -O atime=off -O mountpoint=$M tb $D ;;
  esac
  mkdir -p $M/small; sync; sleep 5
  z0=$(cat /proc/spl/kstat/zfs/zil 2>/dev/null | awk 'NR>2 {printf "%s=%s ", $1, $3}')
  T=/sys/kernel/tracing; echo > $T/trace; echo 16384 > $T/buffer_size_kb
  echo "dev == $(( $(cat /sys/block/$B/dev | cut -d: -f1) << 20 | $(cat /sys/block/$B/dev | cut -d: -f2) ))" > $T/events/block/filter
  echo 1 > $T/events/block/block_rq_issue/enable; echo 1 > $T/events/block/block_rq_complete/enable
  r=$(fio --name=small --directory=$M/small --rw=write --bs=64k --nrfiles=300 --filesize=64k --size=19200k --fsync_on_close=1 --ioengine=psync --output-format=json 2>/dev/null \
      | python3 -c 'import sys,json; j=json.load(sys.stdin)["jobs"][0]; print(round(300/(j["job_runtime"]/1000),1))')
  z1=$(cat /proc/spl/kstat/zfs/zil 2>/dev/null | awk 'NR>2 {printf "%s=%s ", $1, $3}')
  echo 0 > $T/events/block/enable; echo 0 > $T/events/block/filter; cp $T/trace /root/trace/$L-$fs.txt
  echo "{\"cache\":\"$L\",\"fs\":\"$fs\",\"files_per_s\":$r}"
  [ $fs = zfs128k ] && python3 -c "
a=dict(x.split('=') for x in '''$z0'''.split()); b=dict(x.split('=') for x in '''$z1'''.split())
print('  zil delta:', {k:int(b[k])-int(a[k]) for k in b if int(b[k])-int(a[k])})"
done
teardown
