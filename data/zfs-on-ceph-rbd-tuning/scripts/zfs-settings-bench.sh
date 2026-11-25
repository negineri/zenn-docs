#!/bin/bash
# テスト VM の中で root で実行する。/dev/sdb1 にプール tb を作り直して測る。
# usage: zfs-bench.sh <ashift> <recordsize> <async_read> <sync_read> <async_write> <label>
set -e
A=$1 RS=$2 AR=$3 SR=$4 AW=$5 L=$6
P=/sys/module/zfs/parameters
echo $AR > $P/zfs_vdev_async_read_max_active; echo $SR > $P/zfs_vdev_sync_read_max_active; echo $AW > $P/zfs_vdev_async_write_max_active
zpool destroy -f tb 2>/dev/null || true
zpool create -f -o ashift=$A -O recordsize=$RS -O xattr=sa -O mountpoint=/tb tb /dev/sdb1
cold(){ zpool export tb; zpool import -d /dev/sdb1 tb; }
f(){ fio --output-format=terse --directory=/tb --ioengine=psync --refill_buffers "$@" 2>/dev/null; }
w=$(f --name=w --rw=write --bs=1M --size=8G --end_fsync=1 | awk -F';' '{printf "%.0f", $48/1024}')
cold
r=$(f --name=w --rw=read --bs=1M --size=8G | awk -F';' '{printf "%.0f", $7/1024}')
cold
r4=$(f --name=w --rw=read --bs=1M --size=2G --numjobs=4 --offset_increment=2G --group_reporting | awk -F';' '{printf "%.0f", $7/1024}')
sw=$(f --name=s --rw=write --bs=64k --nrfiles=1000 --filesize=64k --size=64m --fsync_on_close=1 | awk -F';' '{printf "%.0f", $48/1024}')
cold
sr=$(f --name=s --rw=read --bs=64k --nrfiles=1000 --filesize=64k --size=64m | awk -F';' '{printf "%.0f", $7/1024}')
rw=$(f --name=rw --rw=randwrite --bs=16k --size=1G --sync=1 --runtime=20 --time_based | awk -F';' '{printf "%.0f", $49}')
printf "%-28s seqW=%5s  coldSeqR=%5s  coldR4job=%5s  smallW=%5s  smallColdR=%5s MB/s  syncRandW16k=%5s IOPS\n" "$L" $w $r $r4 $sw $sr $rw
