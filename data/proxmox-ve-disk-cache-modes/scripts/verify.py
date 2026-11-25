# usage: verify.py <file> <acked_seq>  -> 報告済み (<= acked) のレコードが全部そろい、チェックサムが合うか
import sys, hashlib

data = open(sys.argv[1], "rb").read()
acked = int(sys.argv[2])
n = len(data) // 4016
bad = 0
last = -1
for i in range(n):
    r = data[i * 4016 : (i + 1) * 4016]
    s = int.from_bytes(r[:8], "little")
    if s != i or hashlib.sha256(r[:4008]).digest()[:8] != r[4008:]:
        bad += 1
        break
    last = s
print(
    f"records_on_disk={n} last_valid={last} acked={acked} torn_tail_bytes={len(data)%4016} "
    + (
        "OK"
        if last >= acked and bad == 0
        else "LOST_ACKED_DATA" if last < acked else "CORRUPT"
    )
)
