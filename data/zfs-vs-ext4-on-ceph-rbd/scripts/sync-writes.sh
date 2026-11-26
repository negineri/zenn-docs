#!/bin/bash
# usage: syncfs.sh <cache_label>  同じ RBD の上で raw / ext4 / xfs / zfs の同期書き込みを比べる。1 行 1 項目の JSON
L=$1 D=/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1 M=/mnt/t
P=/sys/module/zfs/parameters
echo 32 > $P/zfs_vdev_async_read_max_active; echo 32 > $P/zfs_vdev_async_write_max_active
out(){ python3 -c '
import sys,json
j=json.load(sys.stdin)["jobs"][0]["write"]
print(json.dumps({"cache":sys.argv[1],"fs":sys.argv[2],"test":sys.argv[3],"iops":round(j["iops"]),"MBps":round(j["bw"]*1024/1e6,1),"lat_ms":round(j["lat_ns"]["mean"]/1e6,3),"p99_ms":round(j["clat_ns"]["percentile"]["99.000000"]/1e6,3)}))' $L $1 $2; }
teardown(){ umount $M 2>/dev/null; zpool destroy -f tb 2>/dev/null; wipefs -aq $D; }
mkdir -p $M
for fs in raw ext4 xfs zfs; do
  teardown
  case $fs in
    raw)  T="--filename=$D --direct=1 --offset=0 --size=1G"; dd if=/dev/urandom of=$D bs=1M count=1024 oflag=direct status=none ;;
    ext4) mkfs.ext4 -q -F $D && mount $D $M; T="--directory=$M --size=1G" ;;
    xfs)  mkfs.xfs -q -f $D && mount $D $M; T="--directory=$M --size=1G" ;;
    zfs)  zpool create -f -o ashift=9 -O recordsize=128K -O xattr=sa -O atime=off -O mountpoint=$M tb $D; T="--directory=$M --size=1G" ;;
  esac
  F="--ioengine=psync --runtime=20 --time_based --output-format=json --group_reporting"
  fio --name=osync16k $T $F --rw=randwrite --bs=16k --sync=1 2>/dev/null | out $fs osync16k; sleep 3
  fio --name=fsync4k $T $F --rw=randwrite --bs=4k --fsync=1 2>/dev/null | out $fs fsync4k; sleep 3
  fio --name=fdatasync4k $T $F --rw=randwrite --bs=4k --fdatasync=1 2>/dev/null | out $fs fdatasync4k; sleep 3
  fio --name=osync16k_4j $T $F --rw=randwrite --bs=16k --sync=1 --numjobs=4 --size=256M 2>/dev/null | out $fs osync16k_4jobs; sleep 3
  if [ $fs != raw ]; then
    rm -rf $M/small; mkdir -p $M/small
    fio --name=small --directory=$M/small --rw=write --bs=64k --nrfiles=1000 --filesize=64k --size=64m --fsync_on_close=1 --ioengine=psync --output-format=json 2>/dev/null | out $fs smallfiles_64k_fsync
  fi
  rm -f $M/*.0 2>/dev/null
done
teardown
