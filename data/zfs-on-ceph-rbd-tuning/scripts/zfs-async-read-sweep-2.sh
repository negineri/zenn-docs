#!/bin/bash
# ZFS の冷えた連続読み取りを async_read_max_active を変えて測る。各段階で別のファイルを読む
P=/sys/module/zfs/parameters
for i in 0 1 2 3; do fio --name=w --filename=/tb/g$i --rw=write --bs=1M --size=4G --end_fsync=1 --ioengine=psync --refill_buffers >/dev/null 2>&1; done
sleep 30
k=0
for ar in 3 32 128 1000; do
  echo $ar > $P/zfs_vdev_async_read_max_active
  zpool export tb; zpool import tb
  t0=$(date +%s.%N)
  r=$(fio --name=r --filename=/tb/g$k --rw=read --bs=1M --size=4G --ioengine=psync --output-format=json 2>/dev/null | python3 -c 'import sys,json; print(round(json.load(sys.stdin)["jobs"][0]["read"]["bw"]*1024/1e6))')
  t1=$(date +%s.%N)
  echo "{\"ar\":$ar,\"qd\":\"zfs$ar\",\"t0\":$t0,\"t1\":$t1,\"MBps\":$r,\"clat_us\":0,\"gcpu0\":\"cpu 0 0 0 1 0 0 0 0\",\"gcpu1\":\"cpu 0 0 0 1 0 0 0 0\"}"
  k=$((k+1)); sleep 5
done
echo 3 > $P/zfs_vdev_async_read_max_active
