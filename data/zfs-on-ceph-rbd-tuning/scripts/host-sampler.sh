#!/bin/bash
# 1 秒ごとに生のカウンタを記録する: CPU、物理 NIC、ディスク、ceph-osd と qemu (環境変数 VMID) のスレッドの CPU 時間
OUT=/run/hostsamp.log; : > $OUT
nics=$(for n in /sys/class/net/*; do [ -e $n/device ] && basename $n; done)
while true; do
  {
    echo "T $(date +%s.%N)"
    head -1 /proc/stat
    awk '$3 ~ /^sd[a-z]+$/ {print "D", $3, $6, $13}' /proc/diskstats
    for n in $nics; do echo "N $n $(cat /sys/class/net/$n/statistics/rx_bytes) $(cat /sys/class/net/$n/statistics/tx_bytes)"; done
    for p in $(pgrep -x ceph-osd); do echo "O $p $(sed 's/.*) //' /proc/$p/stat | awk '{print $12+$13}')"; done
    if [ -f /var/run/qemu-server/${VMID:?}.pid ]; then
      Q=$(cat /var/run/qemu-server/${VMID:?}.pid)
      for t in /proc/$Q/task/*; do echo "Q $(basename $t) $(tr ' ' '_' < $t/comm) $(sed 's/.*) //' $t/stat | awk '{print $12+$13}')"; done
    fi
  } >> $OUT
  sleep 1
done
