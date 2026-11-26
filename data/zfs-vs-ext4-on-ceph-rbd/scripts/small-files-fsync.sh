#!/bin/bash
# usage: smallfsync.sh <cache_label>  64 KiB のファイルを 1 個ずつ作って書き、ファイルとディレクトリを fsync する (15 秒)
L=$1 D=/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1 M=/mnt/t P=/sys/module/zfs/parameters
B=$(basename $(readlink -f $D))
teardown(){ umount $M 2>/dev/null; zpool destroy -f tb 2>/dev/null; wipefs -aq $D >/dev/null 2>&1; }
mkdir -p $M
for fs in ${FSLIST:-ext4 xfs zfs128k}; do
  teardown
  case $fs in
    ext4) mkfs.ext4 -q -F -E lazy_itable_init=0,lazy_journal_init=0 $D && mount $D $M ;;
    xfs) mkfs.xfs -q -f $D && mount $D $M ;;
    btrfs) mkfs.btrfs -q -f $D && mount -o noatime $D $M ;;
    zfs128k) echo 32 > $P/zfs_vdev_async_read_max_active; echo 32 > $P/zfs_vdev_async_write_max_active
      zpool create -f -o ashift=9 -O recordsize=128K -O compression=lz4 -O xattr=sa -O atime=off -O mountpoint=$M tb $D ;;
  esac
  mkdir -p $M/w; sync; sleep 3
  a=$(awk '{print $5, $7, $16}' /sys/block/$B/stat)
  python3 - $L $fs "$a" $B <<'PY'
import os,sys,time,json
L,fs,a,B=sys.argv[1],sys.argv[2],list(map(int,sys.argv[3].split())),sys.argv[4]
d='/mnt/t/w'; dfd=os.open(d,os.O_RDONLY); t0=time.time(); n=0
while time.time()-t0<15:
    fd=os.open(f'{d}/{n}',os.O_WRONLY|os.O_CREAT,0o644); os.write(fd,os.urandom(65536)); os.fsync(fd); os.close(fd); os.fsync(dfd); n+=1
el=time.time()-t0
b=list(map(int,open(f'/sys/block/{B}/stat').read().split()))
b=[b[4],b[6],b[15]]
print(json.dumps({"cache":L,"fs":fs,"files_per_s":round(n/el),"writes_per_file":round((b[0]-a[0]-(b[2]-a[2]))/n,2),"flushes_per_file":round((b[2]-a[2])/n,2),"KiB_per_file":round((b[1]-a[1])/2/n,1)}))
PY
done
teardown
