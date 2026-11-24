# Proxmox VE のディスクのキャッシュモードの計測データ

記事 [Proxmox VE のディスクのキャッシュモードを Ceph RBD とローカル SSD で測る](../../articles/proxmox-ve-disk-cache-modes.md) の根拠となる計測結果と、計測に使ったスクリプト。
ホスト名、IP アドレス、VMID は伏せている。

## fio の結果

`scripts/fio-bench.sh` をゲストで流した結果。1 行が 1 項目。

| ファイル | ディスク | 日時 |
| --- | --- | --- |
| `fio-rbd.jsonl` | Ceph RBD (イレイジャーコーディング 2+1) | 2026-11-24 |
| `fio-local-ssd.jsonl` | ホストの SATA SSD (Micron 1100 2TB) を丸ごと VM に渡したもの | 2026-11-24 |
| `fio-local-lvm-boot-ssd.jsonl` | ホストの起動ディスクと同じ SSD にある `local-lvm` | 2026-11-24 |

- `mode` はキャッシュモード、`run` は計測の通し番号。モードを変えるたびに qemu を起動し直した (`scripts/set-cache-mode.sh`)
- `MBps` は 10^6 バイト毎秒、`mean_us` と `p99_us` は完了までの時間 (clat) の平均と 99 パーセンタイル
- `fio-rbd.jsonl` は `none` と `writeback` を 2 回ずつ測った。項目の間は 10 秒空けた
- `fio-local-ssd.jsonl` は項目の間を 20 秒空けた。ホストで `scripts/host-guard.sh` を動かし、異常があれば止める用意をしていた
- `fio-local-lvm-boot-ssd.jsonl` は記事には使っていない。`writeback` の回 (`run` 2) の `fsync_qd1` が 0 IOPS なのは、ホストに溜まった未書き出しのデータの書き出しを待ち続けたためである。この後、2 回目の `writeback` の計測中に、ホストは HA の watchdog で再起動 (fencing) された。そのため `run` 6 の結果は無い

### 項目

| `test` | fio の主な設定 |
| --- | --- |
| `seqW_qd1` / `seqW_qd16` | 連続書き込み、1 MiB、キュー深さ 1 / 16、4 GiB |
| `randW_qd1` / `randW_qd32` | ランダム書き込み、4 KiB、キュー深さ 1 / 32、30 秒 |
| `fsync_qd1` | ランダム書き込み、4 KiB、キュー深さ 1、書き込みごとに fsync、30 秒 |
| `seqR_qd1` | 連続読み取り、1 MiB、キュー深さ 1 |
| `randR_qd1` / `randR_qd32` | ランダム読み取り、4 KiB、キュー深さ 1 / 32、ディスク全体から 30 秒 |
| `reread_16M` | ランダム読み取り、4 KiB、16 MiB の範囲を 20 回 |

## ローカルの writeback で一気に書いたとき

`scripts/writeback-burst.sh` の結果 (ローカルの SATA SSD、`cache=writeback`)。

- `writeback-burst-fio.jsonl`: 1 行目は各段階の開始時刻 (`T0` からの秒)、2 行目以降は fio の結果
- `writeback-burst-host-meminfo.tsv`: ホストの `/proc/meminfo` の `Dirty` と `Writeback`、qemu の RSS を 1 秒ごとに記録したもの。`sec` は `T0` からの秒、ほかは kB

## 電源断の試験

ゲストでレコードを追記して 1 件ごとに fsync し (`scripts/writer.py`)、fsync が返った番号を外のマシンに送る。
20〜60 秒後にホストで qemu を `kill -9` し、起動し直してから、受け取った最後の番号までのレコードがそろっているかを検査した (`scripts/verify.py`)。

| ファイル | ファイルシステム | モード | 日時 | スクリプト |
| --- | --- | --- | --- | --- |
| `powerloss-ext4.jsonl` | ext4 | `none`、`writethrough`、`directsync` を各 5 回 | 2026-11-24 | `scripts/powerloss-run-ext4.sh` |
| `powerloss-zfs-writeback.txt` | ZFS (ashift 9、recordsize 128K) | `writeback` を 10 回 | 2026-10-16 | `scripts/powerloss-run-zfs.sh` |
| `powerloss-zfs-unsafe.txt` | ZFS (ashift 9、recordsize 128K) | `unsafe` を 1 回 | 2026-10-16 | `scripts/powerloss-run-zfs.sh` |

- ディスクはどれも Ceph RBD
- 各回は前の回のファイルの続きから書く。`first_seq` がその回の最初の番号、`acked` が fsync が返った最後の番号
- `powerloss-zfs-writeback-acks.txt` は、ZFS の `writeback` の各回の ack の要約
- ext4 の回は、別のファイルに 50 MB/s でランダムに書き込みながら試した。ZFS の回は速さを制限していない

## スクリプト

| ファイル | 動かす場所 | 内容 |
| --- | --- | --- |
| `scripts/fio-bench.sh` | ゲスト | fio の 9 項目を流し、JSON を 1 行ずつ出す |
| `scripts/set-cache-mode.sh` | ホスト | キャッシュモードを変えて qemu を起動し直し、実際のフラグを表示する |
| `scripts/host-guard.sh` | ホスト | `Dirty` が 20 GiB を超えるか、HA や pvestatd の遅れが出たら qemu を止める |
| `scripts/writeback-burst.sh` | 外のマシン | 12 GiB を書いた直後と 90 秒後に fsync ごとの書き込みを測る |
| `scripts/writer.py` / `scripts/verify.py` | ゲスト | 電源断の試験のレコードを書く / 検査する |
| `scripts/powerloss-run-ext4.sh` / `scripts/powerloss-run-zfs.sh` | 外のマシン | 電源断の試験の 1 回分 |
