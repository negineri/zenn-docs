#!/bin/bash
# 1 回の fdatasync / O_SYNC で、ゲストから RBD に出る書き込みと flush の数を /sys/block/sdb/stat から数える
D=/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1 M=/mnt/t B=$(basename $(readlink -f $D))
st(){ awk '{print $5, $7, $16}' /sys/block/$B/stat; }  # writes, write_sectors, flushes
run(){ # label, fio args
  a=($(st)); r=$(fio --name=x --ioengine=psync --output-format=json --runtime=15 --time_based "${@:2}" 2>/dev/null | python3 -c 'import sys,json; j=json.load(sys.stdin)["jobs"][0]["write"]; print(j["total_ios"], round(j["iops"]))'); b=($(st))
  n=${r% *}; python3 -c "n=$n; w=${b[0]}-${a[0]}; s=${b[1]}-${a[1]}; f=${b[2]}-${a[2]}; print(f'$1: {${r#* }} IOPS  per op: writes {w/n:.2f}  flushes {f/n:.2f}  KiB {s/2/n:.1f}')"
}
teardown(){ umount $M 2>/dev/null; zpool destroy -f tb 2>/dev/null; wipefs -aq $D >/dev/null 2>&1; }
mkdir -p $M
teardown; dd if=/dev/urandom of=$D bs=1M count=1024 oflag=direct status=none
run "raw  fdatasync4k" --filename=$D --direct=1 --size=1G --rw=randwrite --bs=4k --fdatasync=1
for fs in ext4 xfs; do
  teardown; [ $fs = ext4 ] && mkfs.ext4 -q -F $D || mkfs.xfs -q -f $D; mount $D $M
  run "$fs fdatasync4k (fio layout)"          --directory=$M --size=1G --rw=randwrite --bs=4k --fdatasync=1
  run "$fs osync16k    (fio layout)"          --directory=$M --size=1G --rw=randwrite --bs=16k --sync=1
  rm -f $M/x.*; dd if=/dev/urandom of=$M/pre bs=1M count=1024 conv=fsync status=none
  run "$fs fdatasync4k (dd prewritten)"       --filename=$M/pre --size=1G --rw=randwrite --bs=4k --fdatasync=1
  run "$fs fdatasync4k (dd prewritten,direct)" --filename=$M/pre --size=1G --rw=randwrite --bs=4k --fdatasync=1 --direct=1
done
teardown; zpool create -f -o ashift=9 -O recordsize=128K -O xattr=sa -O atime=off -O mountpoint=$M tb $D
run "zfs fdatasync4k (fio layout)" --directory=$M --size=1G --rw=randwrite --bs=4k --fdatasync=1
run "zfs osync16k    (fio layout)" --directory=$M --size=1G --rw=randwrite --bs=16k --sync=1
teardown
