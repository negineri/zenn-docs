#!/bin/bash
# usage: fsbench.sh <config>   config: ext4 | xfs | zfs128k | zfs16k-pg
# 同じ RBD (scsi1) の上でファイルシステムを作り直し、負荷ごとの結果と RBD に出た I/O の量を JSON で 1 行ずつ出す
C=$1 D=/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1 M=/mnt/t
B=$(basename $(readlink -f $D)); P=/sys/module/zfs/parameters
st(){ awk '{print $1, $3, $5, $7, $16}' /sys/block/$B/stat; }   # reads, read_sectors, writes, write_sectors, flushes
emit(){ # test, value, unit, t_seconds, before-stat...
  local t=$1 v=$2 u=$3 s=$4; shift 4; local a=($@) b=($(st))
  python3 -c "import json; a=[$(IFS=,; echo "${a[*]}")]; b=[$(IFS=,; echo "${b[*]}")]
d=[y-x for x,y in zip(a,b)]
print(json.dumps({'config':'$C${SNAPS:+-snap$SNAPS}','test':'$t','value':$v,'unit':'$u','seconds':$s,'rbd_reads':d[0],'rbd_read_MiB':round(d[1]/2048,1),'rbd_writes':d[2],'rbd_write_MiB':round(d[3]/2048,1),'rbd_flushes':d[4]}))"
}
fj(){ fio --output-format=json --refill_buffers "$@" 2>/dev/null | python3 -c '
import sys,json; j=json.load(sys.stdin)["jobs"]; k=sys.argv[1]
print(round(sum(x[k]["iops"] for x in j)), round(sum(x[k]["bw"] for x in j)*1024/1e6,1))' $RW; }
cold(){ sync; if [ -n "$Z" ]; then zpool export tb && zpool import tb; else umount $M && mount $MO $D $M; fi; echo 3 > /proc/sys/vm/drop_caches; }
teardown(){ umount $M 2>/dev/null; blockdev --setra 256 $D 2>/dev/null; systemctl stop pgbench-pg 2>/dev/null; umount $M 2>/dev/null; zpool destroy -f tb 2>/dev/null; wipefs -aq $D >/dev/null 2>&1; }
teardown; mkdir -p $M; Z=; W=$M; MO=; case $C in btrfs*) MO="-o noatime";; esac
case $C in
  btrfs*) mkfs.btrfs -q -f $D && mount -o noatime $D $M && btrfs subvolume create -q $M/data && W=$M/data ;;
  ext4-ra4m) mkfs.ext4 -q -F -E lazy_itable_init=0,lazy_journal_init=0 $D && mount $D $M && blockdev --setra 8192 $D ;;
  ext4) mkfs.ext4 -q -F -E lazy_itable_init=0,lazy_journal_init=0 $D && mount $D $M ;;
  xfs)  mkfs.xfs -q -f $D && mount $D $M ;;
  zfs*) Z=1; echo 32 > $P/zfs_vdev_async_read_max_active; echo 32 > $P/zfs_vdev_async_write_max_active
        RS=128K; [ $C = zfs16k ] && RS=16K; SNAPDS=tb
        zpool create -f -o ashift=9 -O recordsize=$RS -O compression=lz4 -O xattr=sa -O atime=off -O mountpoint=$M tb $D ;;
esac
[ $C = zfs16k-pg ] || [ -n "$PGONLY" ] || {
# 1. 大きいファイルの連続書き込み (8 GiB、最後に fsync)
a=$(st); t0=$(date +%s.%N); RW=write; r=$(fj --name=big --filename=$W/big --rw=write --bs=1M --size=8G --end_fsync=1 --ioengine=psync); s=$(python3 -c "import time; print(round(time.time()-$t0,2))"); emit seqW_8G_incl_fsync $(python3 -c "print(round(8589.93/$s,1))") MBps $s $a
if [ -n "$SNAPS" ]; then
  a=$(st); t0=$(date +%s.%N)
  for i in $(seq 1 $SNAPS); do
    fio --name=mod --filename=$W/big --rw=randwrite --bs=4k --size=8G --number_ios=256 --ioengine=psync --refill_buffers >/dev/null 2>&1; sync
    if [ -n "$Z" ]; then zfs snapshot tb@s$i; else mkdir -p $M/.snap; btrfs subvolume snapshot -r $W $M/.snap/s$i >/dev/null; fi
  done
  s=$(python3 -c "import time; print(round(time.time()-$t0,2))"); emit snapshots_create $SNAPS snapshots $s $a
fi
# 2. 冷えた連続読み取り
cold; a=$(st); RW=read; r=$(fj --name=big --filename=$W/big --rw=read --bs=1M --size=8G --ioengine=psync); emit seqR_8G_cold ${r#* } MBps 0 $a
# 3. 冷えたランダム読み取り 4 KiB (1 本と 16 本)
cold; a=$(st); r=$(fj --name=big --filename=$W/big --rw=randread --bs=4k --size=8G --ioengine=psync --runtime=30 --time_based); emit randR4k_cold_1job ${r% *} IOPS 30 $a
cold; a=$(st); r=$(fj --name=big --filename=$W/big --rw=randread --bs=4k --size=8G --ioengine=psync --runtime=30 --time_based --numjobs=16); emit randR4k_cold_16jobs ${r% *} IOPS 30 $a
# 4. 大きいファイルへの 4 KiB のランダム上書き (バッファ経由、4 本、60 秒、最後に fsync)
cold; a=$(st); RW=write; r=$(fj --name=big --filename=$W/big --rw=randwrite --bs=4k --size=8G --ioengine=psync --runtime=60 --time_based --numjobs=4 --end_fsync=1); emit randW4k_overwrite_4jobs ${r% *} IOPS 60 $a
# 5. 4 KiB ごとに fdatasync (既存の大きいファイルの上書き、60 秒)
a=$(st); r=$(fj --name=big --filename=$W/big --rw=randwrite --bs=4k --size=8G --ioengine=psync --runtime=60 --time_based --fdatasync=1); emit fdatasync4k_overwrite ${r% *} IOPS 60 $a
# 6. 4 KiB ごとに fdatasync (新しいファイルへの追記、60 秒)
a=$(st); r=$(fj --name=app --filename=$W/append --rw=write --bs=4k --size=4G --ioengine=psync --runtime=60 --time_based --fdatasync=1 --fallocate=none); emit fdatasync4k_append ${r% *} IOPS 60 $a
rm -f $W/append
# 7. 小さいファイル 20000 個 (4 KiB) を作って最後に sync、冷えた状態で全部読む
a=$(st); s=$(python3 - $W <<'PY'
import os,sys,time
m=sys.argv[1]+'/small'; t=time.time()
for d in range(200):
    os.makedirs(f'{m}/{d}',exist_ok=True)
    for f in range(100):
        with open(f'{m}/{d}/{f}','wb') as fh: fh.write(os.urandom(4096))
os.sync(); print(round(time.time()-t,2))
PY
); emit smallfiles_create_20k $(python3 -c "print(round(20000/$s))") files_per_s $s $a
cold; a=$(st); t0=$(date +%s.%N); tar cf - -C $W small | cat > /dev/null; s=$(python3 -c "import time; print(round(time.time()-$t0,2))"); emit smallfiles_read_cold_20k $(python3 -c "print(round(20000/$s))") files_per_s $s $a
rm -rf $W/small $W/big
}
# 8. PostgreSQL (pgbench、規模 100、8 クライアント、60 秒、synchronous_commit=on)
[ -n "$Z" ] && { [ $C = zfs16k-pg ] && zfs create -o recordsize=16K tb/pg || zfs create tb/pg; W=$M; } || mkdir -p $W/pg
chown postgres:postgres $W/pg; PGB=$(ls -d /usr/lib/postgresql/*/bin | tail -1)
sudo -u postgres $PGB/initdb -D $W/pg/data >/dev/null
systemctl reset-failed pgbench-pg 2>/dev/null; systemd-run --collect --unit=pgbench-pg --uid=postgres $PGB/postgres -D $W/pg/data -p 5433 -c shared_buffers=512MB -c max_wal_size=8GB -c listen_addresses='' -k /tmp >/dev/null
sleep 3
sudo -u postgres $PGB/pgbench -h /tmp -p 5433 -i -s 100 -q postgres >/dev/null 2>&1
sudo -u postgres $PGB/psql -h /tmp -p 5433 -qc checkpoint postgres
a=$(st); tps=$(sudo -u postgres $PGB/pgbench -h /tmp -p 5433 -c 8 -j 4 -T 60 postgres 2>/dev/null | awk '/^tps/ {printf "%.0f", $3}'); emit pgbench_s100_c8 ${tps:-0} tps 60 $a
systemctl stop pgbench-pg
teardown
