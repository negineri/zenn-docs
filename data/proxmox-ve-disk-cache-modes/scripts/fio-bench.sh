#!/bin/bash
# usage: a2.sh <dev> <size_GiB> <run_index> <label>   1 行 1 項目の JSON を出す
D=$1 SZ=$2 RUN=$3 L=$4
PAUSE=${PAUSE:-10}
run(){ # name, fio args...
  local name=$1; shift
  fio --name=$name --filename=$D --direct=1 --ioengine=libaio --output-format=json "$@" 2>/dev/null \
  | python3 -c '
import sys, json
j=json.load(sys.stdin)["jobs"][0]; name, label = sys.argv[1], sys.argv[2]
for k in ("write","read"):
    o=j[k]
    if o["io_bytes"]>0:
        p=o["clat_ns"].get("percentile",{})
        print(json.dumps({"label":label,"test":name,"dir":k,"MBps":round(o["bw"]*1024/1e6,1),"iops":round(o["iops"]),
              "p99_us":round(p.get("99.000000",0)/1000,1),"mean_us":round(o["clat_ns"]["mean"]/1000,1)}))
' $name $L
  sleep $PAUSE
}
if [ $SZ -ge 64 ]; then SEQR=4; SEQR_BASE=20; else SEQR=1; SEQR_BASE=20; fi
run seqW_qd1   --rw=write --bs=1M --iodepth=1  --offset=0G --size=4G
run seqW_qd16  --rw=write --bs=1M --iodepth=16 --offset=4G --size=4G
run randW_qd1  --rw=randwrite --bs=4k --iodepth=1  --offset=8G  --size=4G --runtime=30 --time_based --io_size=2G
run randW_qd32 --rw=randwrite --bs=4k --iodepth=32 --offset=12G --size=4G --runtime=30 --time_based --io_size=2G
run fsync_qd1  --rw=randwrite --bs=4k --iodepth=1  --offset=16G --size=4G --runtime=30 --time_based --io_size=2G --fsync=1
run seqR_qd1   --rw=read --bs=1M --iodepth=1 --offset=$((SEQR_BASE + RUN*SEQR))G --size=${SEQR}G
run randR_qd1  --rw=randread --bs=4k --iodepth=1  --offset=0G --size=${SZ}G --runtime=30 --time_based
run randR_qd32 --rw=randread --bs=4k --iodepth=32 --offset=0G --size=${SZ}G --runtime=30 --time_based
run reread_16M --rw=randread --bs=4k --iodepth=1 --offset=$((SZ-1))G --size=16M --loops=20
