#!/bin/bash
# ローカルの writeback で 12 GiB を一気に書き、直後と 90 秒後に fsync ごとの書き込みを測る
#   GUEST_SSH: テスト VM に入る ssh コマンド
#   DEV:       ゲストから見たデータ用ディスク (cache=writeback にしておく)
# 同時に、ホストで次のように 1 秒ごとに記録した (writeback-burst-host-meminfo.tsv)
#   V=$(cat /var/run/qemu-server/<VMID>.pid)
#   while true; do echo "$(date +%s) $(awk '/^Dirty:|^Writeback:/ {printf "%s ", $2}' /proc/meminfo)$(awk '/^VmRSS/ {print $2}' /proc/$V/status)"; sleep 1; done
: "${GUEST_SSH:?}" "${DEV:?}"
fj(){ $GUEST_SSH "sudo fio --name=$1 --filename=$DEV --direct=1 --ioengine=libaio --output-format=json ${*:2}" \
  | python3 -c 'import sys,json; j=json.load(sys.stdin)["jobs"][0]; o=j["write"]; p=o["clat_ns"]["percentile"]
print(json.dumps({"test":sys.argv[1],"MBps":round(o["bw"]*1024/1e6,1),"iops":round(o["iops"]),"mean_us":round(o["clat_ns"]["mean"]/1000,1),"p99_us":round(p["99.000000"]/1000,1),"max_us":round(o["clat_ns"]["max"]/1000,1)}))' "$1"; }
echo "T0 $(date +%s)"
fj seqW12G --rw=write --bs=1M --iodepth=16 --offset=24G --size=12G
echo "T1 $(date +%s)"
fj fsync_hot --rw=randwrite --bs=4k --iodepth=1 --offset=16G --size=4G --runtime=30 --time_based --fsync=1
echo "T2 $(date +%s)"
sleep 90
echo "T3 $(date +%s)"
fj fsync_cold --rw=randwrite --bs=4k --iodepth=1 --offset=16G --size=4G --runtime=30 --time_based --fsync=1
echo "T4 $(date +%s)"
