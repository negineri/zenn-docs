# 全 OSD の osd / bluestore の性能カウンタを 1 行の JSON で出す
for s in /var/run/ceph/ceph-osd.*.asok; do
  o=$(basename $s .asok); o=${o#ceph-osd.}
  ceph daemon osd.$o perf dump | python3 -c "
import sys,json
d=json.load(sys.stdin); o=d['osd']; b=d.get('bluestore',{})
keep={k:o[k] for k in ['op_r','op_r_latency','op_r_process_latency','op_before_queue_op_lat','op_before_dequeue_op_lat','subop_latency','op_r_out_bytes']}
keep.update({'bs_'+k:b[k] for k in ['read_lat','read_onode_meta_lat','read_wait_aio_lat','csum_lat'] if k in b})
print(json.dumps({'osd':$o,**keep}))"
done
