#!/bin/bash
P=/sys/module/zfs/parameters
rm -f /tb/*; sync
for i in 0 1 2 3; do fio --name=w --filename=/tb/g$i --rw=write --bs=1M --size=4G --end_fsync=1 --ioengine=psync --refill_buffers >/dev/null 2>&1; done
sleep 60
levels=(128 256 512 1000)
for run in 1 2; do
  for k in 0 1 2 3; do
    ar=${levels[$k]}; f=$k; [ $run = 2 ] && f=$((3-k))
    echo $ar > $P/zfs_vdev_async_read_max_active
    zpool export tb; zpool import -d /dev/sdb2 tb
    fio --name=r --filename=/tb/g$f --rw=read --bs=1M --size=4G --ioengine=psync --output-format=terse 2>&1 | awk -F';' -v ar=$ar -v f=$f -v run=$run '{printf "run%s async_read=%s file=g%s %.0f MB/s\n", run, ar, f, $7/1024}'
  done
done
echo 3 > $P/zfs_vdev_async_read_max_active
