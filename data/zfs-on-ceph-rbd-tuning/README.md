# Ceph RBD の上の ZFS の計測データ

記事 [Ceph RBD の上の ZFS は vdev の同時実行数で頭打ちになる](../../articles/zfs-on-ceph-rbd-tuning.md) の根拠となる計測結果と、計測に使ったスクリプト。
ホスト名、IP アドレス、VMID は伏せている。3 台のホストは `node1`〜`node3` と呼び、テスト VM は `node3` にあった。

## 記事の最初の計測 (2026-11-24)

| ファイル | 内容 | スクリプト |
| --- | --- | --- |
| `rbd-qd-sweep.txt` | 生の RBD を 1 MiB ずつ、キュー深さを変えて読む。10GbE 1 本 (`single`) と 2 本 (`ecmp`) を 2 回ずつ | `scripts/rbd-qd-sweep.sh` |
| `zfs-async-read-sweep.txt` | ZFS の冷えた連続読み取りを `zfs_vdev_async_read_max_active` を変えて測る | `scripts/zfs-async-read-sweep.sh`、`scripts/zfs-async-read-sweep-high.sh` |
| `discarded-zfs-async-read-high.txt` | 使わなかった結果 (256 と 512 で、読んだことのあるファイルを使い回した回) | |
| `zfs-settings-bench.txt` | 書き込みとほかの設定 (ashift、recordsize、キャッシュモード)。10GbE が 1 本だったとき (2026-10) | `scripts/zfs-settings-bench.sh` |

## 頭打ちの調査 (2026-11-25)

同じ計測を、ホストの 1 秒ごとの記録を取りながらやり直した。各段階は 8 秒ずつ、別の 24 GiB の範囲を読む (ZFS は 4 GiB のファイル)。

| ファイル | 内容 | スクリプト |
| --- | --- | --- |
| `rbd-1m-qd-sweep.jsonl` | 生の RBD を 1 MiB ずつ、キュー深さ 1〜128 | `scripts/qd-sweep-sampled.sh` |
| `rbd-128k-qd-sweep.jsonl` | 生の RBD を 128 KiB ずつ、キュー深さ 1〜256 | `scripts/qd-sweep-sampled.sh` (`BS=128k`) |
| `zfs-async-read-sweep-2.jsonl` | ZFS の冷えた連続読み取り、`async_read_max_active` 3 / 32 / 128 / 1000 | `scripts/zfs-async-read-sweep-2.sh` |
| `read-patterns.jsonl` | 読み方 (連続 / ランダム、128 KiB / 1 MiB) と RBD の作り (EC / レプリカ、オブジェクトの大きさ、ストライプ) の比較 | fio (README の下を参照) |
| `host-samples/<計測>-<ノード>.log.gz` | 上の 3 つの計測の間の、各ノードの 1 秒ごとの生のカウンタ | `scripts/host-sampler.sh` |
| `osd-perf-counters.jsonl` | 全 OSD の性能カウンタ。128 KiB QD16、128 KiB QD128、1 MiB QD32 を 30 秒ずつ流した前後に取った (この 3 つの読み取りの結果は記事にない) | `scripts/osd-perf-snapshot.sh` |

- `*.jsonl` の `t0` / `t1` は各段階の開始と終了の時刻 (UNIX 時間)、`MBps` は 10^6 バイト毎秒、`clat_us` / `clat_ms` は完了までの時間の平均
- `gcpu0` / `gcpu1` は、各段階の前後のゲストの `/proc/stat` の 1 行目
- `read-patterns.jsonl` の `disk` は、`ec_4M` が EC 2+1 で 4 MiB のオブジェクト (既定)、`rep_4M` がレプリカ 3、`rep_obj1M` がレプリカ 3 で 1 MiB のオブジェクト (`rbd create --object-size 1M`)、`rep_stripe128Kx8` がレプリカ 3 で `--stripe-unit 128K --stripe-count 8`
- `osd-perf-counters.jsonl` の値は累積値で、隣り合うスナップショットの差を取って使う。`*_lat` は `sum` (秒) と `avgcount` (回数) を持つ

### ホストの記録の形式

`scripts/host-sampler.sh` が 1 秒ごとに次の行を書く。

| 行 | 内容 |
| --- | --- |
| `T <時刻>` | 記録した時刻 |
| `cpu ...` | `/proc/stat` の 1 行目 |
| `D <デバイス> <読んだセクタ数> <io_ticks (ms)>` | `/proc/diskstats` から。OSD の SSD は node1 が `sda`〜`sdd`、node2 と node3 が `sdd`〜`sdg` |
| `N <NIC> <rx_bytes> <tx_bytes>` | 物理 NIC。`enp193s0f0` と `enp193s0f1` が 10GbE で、それぞれ別のスイッチにつながる |
| `O <pid> <utime+stime>` | ceph-osd のプロセスの CPU 時間 (1/100 秒) |
| `Q <tid> <スレッド名> <utime+stime>` | テスト VM の qemu のスレッドの CPU 時間。`msgr-worker-*` と `io_context_pool` が librbd |

段階ごとに集計するには、リポジトリのこのディレクトリで次を流す。

```bash
python3 scripts/analyze-host-samples.py rbd-1m-qd-sweep.jsonl host-samples rbd-1m
```

### read-patterns.jsonl の fio

```bash
fio --name=r --filename=<デバイス> --ioengine=libaio --direct=1 --runtime=15 --time_based \
  --rw=read --bs=128k --iodepth=128 --offset=<段階ごとに 10 GiB ずらす> --size=10G
```

ランダムは `--rw=randread --offset=0 --size=30G`。どのディスクも先に全体をランダムなデータで埋めてある。
