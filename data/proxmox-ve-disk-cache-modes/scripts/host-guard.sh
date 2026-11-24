#!/bin/bash
# Proxmox VE のホストで動かす見張り (usage: host-guard.sh <VMID>)。異常があれば VM の qemu を止め、/run/cachebench-abort に理由を書く
V=${1:?VMID}; LOG=/run/cachebench-guard.log; : > $LOG
since=$(date '+%Y-%m-%d %H:%M:%S')
while true; do
  dirty=$(awk '/^Dirty:/ {print $2}' /proc/meminfo)            # kB
  wb=$(awk '/^Writeback:/ {print $2}' /proc/meminfo)
  la=$(cut -d' ' -f1 /proc/loadavg)
  bad=$(journalctl --since "$since" --no-pager -q -u pve-ha-lrm -u pve-ha-crm -u pvestatd 2>/dev/null | grep -E 'loop took too long|got timeout' | tail -1)
  echo "$(date +%T) dirty_kB=$dirty wb_kB=$wb load=$la" >> $LOG
  reason=""
  [ -n "$bad" ] && reason="journal: $bad"
  [ "$dirty" -gt 20971520 ] && reason="dirty ${dirty} kB > 20 GiB"
  if [ -n "$reason" ]; then
    echo "$(date +%T) ABORT $reason" | tee -a $LOG > /run/cachebench-abort
    [ -f /var/run/qemu-server/$V.pid ] && kill -9 $(cat /var/run/qemu-server/$V.pid)
    exit 1
  fi
  sleep 2
done
