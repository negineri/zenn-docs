#!/bin/bash
# usage: b1.sh <label> <base_GiB>   生の RBD (sdb1) を QD を変えて読む。各段階で別の 2 GiB を読む
L=$1 B=$2 D=/dev/sdb1 o=$B
for qd in 1 2 4 8 16 32 64; do
  r=$(fio --name=r --filename=$D --rw=read --bs=1M --size=2G --offset=${o}G --iodepth=$qd --ioengine=libaio --direct=1 --output-format=terse 2>/dev/null | awk -F';' '{printf "%.0f", $7/1024}')
  lat=$(fio --name=r --filename=$D --rw=read --bs=1M --size=256M --offset=$((o+2))G --iodepth=1 --ioengine=libaio --direct=1 --output-format=terse 2>/dev/null | awk -F';' '{printf "%.2f", $40/1000}') 
  printf "%-8s qd=%-3s %5s MB/s\n" "$L" $qd "$r"
  o=$((o+2)); sleep 5
done
