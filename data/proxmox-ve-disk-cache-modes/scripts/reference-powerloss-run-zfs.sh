#!/bin/bash
# 1 回分の電源断テスト。usage: powerloss-run.sh <label>
# ack (fsync が返ったレコード番号) は $D/acks.<label> に残る。
# 電源断は KILL_CMD (PVE ホストで qemu を SIGKILL するコマンド) で起こす
set -u
D=$(dirname "$0"); L=$1
# GUEST_SSH: テスト VM に入る ssh コマンド (例: "ssh -i key user@<IP>")
: "${GUEST_SSH:?GUEST_SSH を設定する}"
T() { $GUEST_SSH "$@"; }
T=T
: "${KILL_CMD:?KILL_CMD を設定する (例: ssh root@<ホスト> 'kill -9 \$(cat /var/run/qemu-server/<VMID>.pid)')}"
# 前回のファイルの続きから書く (レコード番号はファイル先頭からの連番)
start=$($T 'n=$(stat -c %s /tank/log 2>/dev/null || echo 0); echo $((n/4016))')
$T "sudo truncate -s $((start*4016)) /tank/log 2>/dev/null; sudo chmod 666 /tank/log 2>/dev/null; sudo touch /tank/log; sudo chmod 666 /tank/log"
# 非同期の書き込みで librbd のキャッシュを汚しておく
$T 'sudo nohup fio --name=bg --directory=/tank --rw=randwrite --bs=64k --size=4G --ioengine=libaio --iodepth=32 --time_based --runtime=600 --refill_buffers >/dev/null 2>&1 &'
$T "python3 -u ~/writer.py /tank/log $start" > $D/acks.$L 2>/dev/null &
sleep $((20 + RANDOM % 40))
eval "$KILL_CMD"
sleep 2
acked=$(tail -n 1 $D/acks.$L)
wait 2>/dev/null
# 起動し直すのを待つ (HA の VM は HA が起動し直す)
for i in $(seq 1 60); do $T true 2>/dev/null && break; sleep 5; done
$T "sudo zpool status -x tank | head -1; python3 ~/verify.py /tank/log $acked" | sed "s/^/[$L] /"
