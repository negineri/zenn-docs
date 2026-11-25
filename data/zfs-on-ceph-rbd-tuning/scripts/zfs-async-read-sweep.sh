#!/bin/bash
# B2: zfs_vdev_async_read_max_active ごとの冷えた連続読み取り (ashift 9、recordsize 128K、sdb2)
set -e
P=/sys/module/zfs/parameters
echo 10 > $P/zfs_vdev_async_write_max_active
zpool destroy -f tb 2>/dev/null || true
zpool create -f -o ashift=9 -O recordsize=128K -O xattr=sa -O mountpoint=/tb tb /dev/sdb2
for i in 0 1 2 3 4 5; do fio --name=f$i --filename=/tb/f$i --rw=write --bs=1M --size=4G --end_fsync=1 --ioengine=psync --refill_buffers >/dev/null 2>&1; done
cold(){ zpool export tb; zpool import -d /dev/sdb2 tb; }
levels=(3 8 16 32 64 128)
for run in 1 2; do
  for k in 0 1 2 3 4 5; do
    ar=${levels[$k]}; f=$k; [ $run = 2 ] && f=$((5-k))
    echo $ar > $P/zfs_vdev_async_read_max_active
    cold
    r=$(fio --name=r --filename=/tb/f$f --rw=read --bs=1M --size=4G --ioengine=psync --output-format=terse 2>/dev/null | awk -F';' '{printf "%.0f", $7/1024}')
    printf "run%s async_read=%-3s file=f%s %5s MB/s\n" $run $ar $f "$r"
  done
done
echo 3 > $P/zfs_vdev_async_read_max_active
