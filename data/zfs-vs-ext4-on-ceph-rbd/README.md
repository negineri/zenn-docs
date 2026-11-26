<!-- cspell:ignore Btrfs FSLIST PGONLY VMID ashift blockdev btrfs fallocate fdatasync iothread itable noatime osync pgbench prewritten randread recordsize setra smallfiles subvolume vdev virtio wipefs writeback xattr zpool -->

# Ceph RBD の上の ZFS と ext4 の計測データ

記事 [Ceph RBD の上の VM で ZFS は ext4 より速いのか](../../articles/zfs-vs-ext4-on-ceph-rbd.md) の根拠となる計測結果と、計測に使ったスクリプト。
ホスト名、IP アドレス、VMID は伏せている。

## 環境

- Proxmox VE 9.2 (QEMU 11.1)、Ceph 20.2。イレイジャーコーディング (2+1) の RBD、64 GiB
- テスト VM: Ubuntu 26.04 (カーネル 7.0)、8 vCPU、メモリ 4 GiB、ZFS 2.4.1、PostgreSQL 18
- VM ディスク: `virtio-scsi-single`、`aio=io_uring`、`iothread=1`。キャッシュモードは記載のとおり
- 計測は 2026-11-25。同じ RBD の上でファイルシステムを作り直して順に測った

## ファイル

| ファイル | 内容 | スクリプト |
| --- | --- | --- |
| `sync-writes.jsonl` | 同期書き込み 4 種と小さいファイルの作成。`cache=none` と `cache=writeback` | `scripts/sync-writes.sh <キャッシュモードの名前>` |
| `sync-io-per-op.txt` | 1 回の fdatasync / O_SYNC で、ゲストから RBD に出た書き込みと flush の数と量 | `scripts/sync-io-per-op.sh` |
| `fs-workloads.jsonl` | 6 つの構成で 10 種の負荷。各負荷の間に RBD に出た読み書きの量も記録した (`cache=writeback`) | `scripts/fs-workloads.sh <構成>` |
| `small-files-fsync.jsonl` | 64 KiB のファイルを 1 個ずつ作り、ファイルとディレクトリを fsync する (15 秒)。`cache=none` と `cache=writeback` | `scripts/small-files-fsync.sh <キャッシュモードの名前>` |
| `fio-fsync-on-close-zfs.txt` | fio の `--fsync_on_close` で小さいファイルを作ったとき、ZFS が ZIL に何も書かずに fsync を返した記録 (ZIL の統計とブロック層のトレースの集計) | `scripts/fio-fsync-on-close-trace.sh <キャッシュモードの名前>` |
| `pgbench-interleaved.jsonl` | ext4、XFS、ZFS 128K の pgbench を交互に 3 巡 (記事の PostgreSQL の表) | `scripts/fs-workloads.sh` を `PGONLY=1` で |
| `btrfs-fs-workloads.jsonl` | ext4、Btrfs、ZFS 128K の 10 種の負荷を同じ時間帯に測ったもの。`*-snap79` は 79 世代のスナップショットを作ってから測ったもの (`snapshots_create` の行がその作成) | `scripts/fs-workloads.sh <構成>`、`SNAPS=79` を付けると世代を作る |
| `btrfs-pgbench-interleaved.jsonl` | ext4、Btrfs、ZFS 128K の pgbench を交互に 3 巡 | `scripts/fs-workloads.sh` を `PGONLY=1` で |
| `btrfs-small-files-fsync.jsonl` | ext4、Btrfs、ZFS 128K で、64 KiB のファイルを 1 個ずつ作って fsync する負荷を交互に 2 巡 (`cache=writeback`) | `scripts/small-files-fsync.sh` を `FSLIST="ext4 btrfs zfs128k"` で |
| `xattr-limits.txt` | 1 つの拡張属性に書ける大きさ | (ファイルの先頭に方法を記載) |
| `pgbench-zfs-layouts.jsonl` | ZFS で recordsize と WAL の置き方を変えた 4 構成の pgbench を交互に 3 巡。ZIL の統計の差も記録した | `scripts/pgbench-zfs-layouts.sh <構成> <巡>` |

### sync-writes.jsonl

- `fs` は `raw` (ファイルシステムなし)、`ext4`、`xfs`、`zfs` (ashift 9、recordsize 128K)
- fio はファイルを既定で `fallocate` で確保するので、`ext4` と `xfs` は「確保しただけで書いていない領域」への書き込みになっている。記事の「発端」の節を参照
- `lat_ms` は 1 回の書き込みの平均時間。fsync / fdatasync を別に呼ぶ負荷では、fsync の時間を含まない

### sync-io-per-op.txt

- `writes` はブロック層の統計の書き込み回数で、flush も 1 回として数えられている
- `fio layout` は fio が `fallocate` で確保したファイル、`dd prewritten` は先に `dd` で全体を書いたファイル

### pgbench について

- Ceph はほかの VM と共有しているので、同じ構成でも時刻によって tps が 2 割ほど変わった。構成どうしは、交互に流したファイルの中で比べる
- `pgbench-zfs-layouts.jsonl` の `zil_*` は、pgbench の 60 秒の間の ZIL の統計 (`/proc/spl/kstat/zfs/zil`) の差。`rbd_writes` は flush を除いた書き込みの回数

### Btrfs の計測について

- Btrfs は `mkfs.btrfs` の既定値で作り、`noatime` でマウントした
- `scripts/fs-workloads.sh` はサブボリューム `data` を作ってその中で測るつもりだったが、`btrfs subvolume create` に付けた `-q` がこのバージョンでは使えず、サブボリュームは作られなかった。ファイルはトップレベルのサブボリュームに置かれ、スナップショットもトップレベルから取った
- 79 世代のスナップショットは、世代ごとに 8 GiB のファイルの 4 KiB を 256 か所書き換え、`sync` してから作った。Btrfs は読み取り専用のスナップショット、ZFS は `zfs snapshot`

### fs-workloads.jsonl

| `config` | 内容 |
| --- | --- |
| `ext4` | 既定値。`mkfs.ext4 -E lazy_itable_init=0,lazy_journal_init=0` で、裏での初期化の書き込みを止めた |
| `ext4-ra4m` | `ext4` に加えて、ブロックデバイスの先読みを 4 MiB にした (`blockdev --setra 8192`) |
| `xfs` | 既定値 |
| `zfs128k` | ashift 9、recordsize 128K、lz4、xattr=sa、atime=off、`zfs_vdev_async_read_max_active` と `zfs_vdev_async_write_max_active` を 32 |
| `zfs16k` | `zfs128k` の recordsize を 16K にしたもの |
| `btrfs` | Btrfs。既定値、`noatime` (`btrfs-fs-workloads.jsonl` のみ) |
| `zfs16k-pg` | `zfs128k` のプールに、recordsize 16K のデータセットを作って PostgreSQL を置いたもの (pgbench だけ) |

| `test` | 内容 |
| --- | --- |
| `seqW_8G_incl_fsync` | 8 GiB の連続書き込み (1 MiB、最後に fsync)。値は fsync を含めた時間から求めた |
| `seqR_8G_cold` | キャッシュを空にした後、上のファイルを 1 MiB ずつ連続で読む |
| `randR4k_cold_1job` / `randR4k_cold_16jobs` | キャッシュを空にした後、上のファイルを 4 KiB ずつランダムに読む (1 本 / 16 本、30 秒) |
| `randW4k_overwrite_4jobs` | 上のファイルへの 4 KiB のランダム上書き (バッファ経由、4 本、60 秒、最後に fsync) |
| `fdatasync4k_overwrite` | 上のファイルへの 4 KiB のランダム上書き、書くたびに fdatasync (60 秒) |
| `fdatasync4k_append` | 新しいファイルへの 4 KiB の追記、書くたびに fdatasync (60 秒、`fallocate` なし) |
| `smallfiles_create_20k` | 4 KiB のファイル 20000 個 (200 ディレクトリ) を作り、最後に sync |
| `smallfiles_read_cold_20k` | キャッシュを空にした後、上のファイルを全部読む (`tar`) |
| `pgbench_s100_c8` | PostgreSQL 18、pgbench 規模 100 (約 1.5 GiB)、8 クライアント、60 秒。`shared_buffers=512MB`、`synchronous_commit` は既定 (on) |

- キャッシュを空にするには、ext4 / XFS はアンマウントとマウントと `drop_caches`、ZFS は `zpool export` と `zpool import` を使った
- `rbd_*` は、その負荷の間にゲストから RBD (データ用ディスク) に出た読み書きの回数と量 (MiB) と flush の回数
- 行は計測した順に並んでいる。`pgbench_s100_c8` は構成ごとに複数回測ったが、構成ごとにまとめて流したので、時刻による変動 (2 割ほど) を含む。記事の PostgreSQL の表には `pgbench-interleaved.jsonl` を使った
- `ext4` は 1 度測り直している。最初の計測は mkfs 直後の裏での初期化の書き込みが重なっていたので、ファイルに含めていない
