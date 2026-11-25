#!/bin/bash
# usage: qdsweep.sh <dev> <label> <base_GiB>  キュー深さごとに 8 秒ずつ、別の 24 GiB の範囲を連続で読む
D=$1 L=$2 o=$3
for qd in ${QDS:-1 2 4 8 16 32 64 128}; do
  g0=$(head -1 /proc/stat); t0=$(date +%s.%N)
  r=$(fio --name=r --filename=$D --rw=read --bs=${BS:-1M} --offset=${o}G --size=24G --runtime=8 --time_based \
      --iodepth=$qd --ioengine=libaio --direct=1 --output-format=json 2>/dev/null \
      | python3 -c 'import sys,json; j=json.load(sys.stdin)["jobs"][0]["read"]; print(round(j["bw"]*1024/1e6), round(j["clat_ns"]["mean"]/1000))')
  t1=$(date +%s.%N); g1=$(head -1 /proc/stat)
  echo "{\"label\":\"$L\",\"qd\":$qd,\"t0\":$t0,\"t1\":$t1,\"MBps\":${r% *},\"clat_us\":${r#* },\"gcpu0\":\"$g0\",\"gcpu1\":\"$g1\"}"
  o=$((o+24)); sleep 5
done
