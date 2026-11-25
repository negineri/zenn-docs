# fsync 済みのレコード番号だけを stdout に出す (外のマシンがこれを ack として記録する)
import os, sys, hashlib, time

path = sys.argv[1]
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
seq = int(sys.argv[2]) if len(sys.argv) > 2 else 0
while True:
    payload = os.urandom(4000)
    rec = (
        seq.to_bytes(8, "little")
        + payload
        + hashlib.sha256(seq.to_bytes(8, "little") + payload).digest()[:8]
    )
    assert len(rec) == 4016
    os.write(fd, rec)
    os.fsync(fd)
    sys.stdout.write(f"{seq}\n")
    sys.stdout.flush()
    seq += 1
