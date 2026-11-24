#!/bin/bash
# 電源断の試験の 1 回分 (ext4)。usage: powerloss-run-ext4.sh <label>
# writer.py と verify.py は先にゲストのホームに置く。ack (fsync が返ったレコード番号) は acks.<label> に残る
#   GUEST_SSH: テスト VM に入る ssh コマンド (例: "ssh -i key user@<IP>")
#   KILL_CMD:  ホストで qemu を止めて起動し直すコマンド
#              (例: ssh root@<ホスト> 'kill -9 $(cat /var/run/qemu-server/<VMID>.pid); sleep 3; qm start <VMID>')
#   DEV:       ゲストから見たデータ用ディスク (mkfs.ext4 済み)
set -u
: "${GUEST_SSH:?}" "${KILL_CMD:?}" "${DEV:?}"
L=$1; A=acks.$L
T(){ $GUEST_SSH -o ServerAliveInterval=2 -o ServerAliveCountMax=2 "$@" 2>/dev/null; }
T "sudo mkdir -p /mnt/t"
T "mountpoint -q /mnt/t || sudo mount $DEV /mnt/t"
start=$(T 'n=$(stat -c %s /mnt/t/log 2>/dev/null || echo 0); echo $((n/4016))')
T "sudo truncate -s $((start*4016)) /mnt/t/log; sudo chmod 666 /mnt/t/log"
# 別のファイルに 50 MB/s でランダムに書き、キャッシュに未書き出しのデータがある状態にする
T 'sudo nohup fio --name=bg --directory=/mnt/t --rw=randwrite --bs=64k --size=2G --ioengine=libaio --iodepth=32 --rate=50m --time_based --runtime=600 >/dev/null 2>&1 &'
T "python3 -u ~/writer.py /mnt/t/log $start" > $A &
sleep $((20 + RANDOM % 40))
eval "$KILL_CMD" >/dev/null
sleep 2; acked=$(tail -n 1 $A); kill %1 2>/dev/null; wait 2>/dev/null
for i in $(seq 1 60); do T true && break; sleep 5; done
for i in $(seq 1 12); do
  res=$(T "mountpoint -q /mnt/t || sudo mount $DEV /mnt/t 2>&1; python3 ~/verify.py /mnt/t/log $acked")
  [ -n "$res" ] && break; sleep 5
done
echo "{\"label\":\"$L\",\"fsyncs\":$(wc -l < $A),\"start\":$start,\"acked\":$acked,\"result\":\"$res\"}"
