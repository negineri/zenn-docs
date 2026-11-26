#!/bin/bash
# usage: pgcmp.sh <config> <run>   PostgreSQL のデータの置き方を変えて pgbench を流し、ZIL と RBD の統計の差を JSON で出す
#   zfs128k:        プールも PostgreSQL も recordsize 128K
#   zfs16k:         プールの recordsize を 16K (PostgreSQL もそれを継ぐ)
#   zfs16k-pg:      プールは 128K、PostgreSQL のデータセットだけ 16K
#   zfs16k-wal128k: PostgreSQL のデータセットは 16K、pg_wal は別の 128K のデータセット
C=$1 R=$2 D=/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1 M=/mnt/t P=/sys/module/zfs/parameters
B=$(basename $(readlink -f $D)); PGB=$(ls -d /usr/lib/postgresql/*/bin | tail -1)
teardown(){ systemctl stop pgbench-pg 2>/dev/null; systemctl reset-failed pgbench-pg 2>/dev/null; umount $M 2>/dev/null; zpool destroy -f tb 2>/dev/null; wipefs -aq $D >/dev/null 2>&1; }
teardown; mkdir -p $M
echo 32 > $P/zfs_vdev_async_read_max_active; echo 32 > $P/zfs_vdev_async_write_max_active
RS=128K; [ $C = zfs16k ] && RS=16K
zpool create -f -o ashift=9 -O recordsize=$RS -O compression=lz4 -O xattr=sa -O atime=off -O mountpoint=$M tb $D
case $C in
  zfs16k-pg) zfs create -o recordsize=16K tb/pg ;;
  zfs16k-wal128k) zfs create -o recordsize=16K tb/pg; zfs create -o recordsize=128K tb/wal; chown postgres:postgres $M/wal; WAL="-X $M/wal/pg_wal" ;;
  *) zfs create tb/pg ;;
esac
chown postgres:postgres $M/pg
sudo -u postgres $PGB/initdb -D $M/pg/data $WAL >/dev/null 2>&1
systemd-run --collect --unit=pgbench-pg --uid=postgres $PGB/postgres -D $M/pg/data -p 5433 -c shared_buffers=512MB -c max_wal_size=8GB -c listen_addresses='' -k /tmp >/dev/null 2>&1
sleep 3
sudo -u postgres $PGB/pgbench -h /tmp -p 5433 -i -s 100 -q postgres >/dev/null 2>&1
sudo -u postgres $PGB/psql -h /tmp -p 5433 -qc checkpoint postgres
zil(){ awk 'NR>2 {printf "%s:%s,", $1, $3}' /proc/spl/kstat/zfs/zil; }
z0=$(zil); a=$(awk '{print $1, $3, $5, $7, $16}' /sys/block/$B/stat)
tps=$(sudo -u postgres $PGB/pgbench -h /tmp -p 5433 -c 8 -j 4 -T 60 postgres 2>/dev/null | awk '/^tps/ {printf "%.0f", $3}')
z1=$(zil); b=$(awk '{print $1, $3, $5, $7, $16}' /sys/block/$B/stat)
python3 - "$C" "$R" "$tps" "$z0" "$z1" "$a" "$b" <<'PY'
import sys,json
C,R,tps,z0,z1,a,b=sys.argv[1:]
p=lambda s: {k:int(v) for k,v in (x.split(':') for x in s.strip(',').split(','))}
z0,z1=p(z0),p(z1); a=list(map(int,a.split())); b=list(map(int,b.split()))
dz={k:z1[k]-z0[k] for k in z1 if z1[k]-z0[k]}
keep=['zil_commit_count','zil_itx_count','zil_itx_indirect_count','zil_itx_indirect_bytes','zil_itx_copied_count','zil_itx_copied_bytes','zil_itx_needcopy_count','zil_itx_needcopy_bytes','zil_itx_metaslab_normal_count','zil_itx_metaslab_normal_bytes','zil_itx_metaslab_normal_write']
d=[y-x for x,y in zip(a,b)]
print(json.dumps({"config":C,"run":int(R),"tps":int(tps or 0),"rbd_read_MiB":round(d[1]/2048,1),"rbd_writes":d[2]-d[4],"rbd_write_MiB":round(d[3]/2048,1),"rbd_flushes":d[4],**{k:dz.get(k,0) for k in keep}}))
PY
teardown
