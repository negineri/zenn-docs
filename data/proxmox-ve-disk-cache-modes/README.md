# Proxmox VE のディスクのキャッシュモードの計測データ

記事 [Proxmox VEのVMディスクの推奨キャッシュ設定を実測から理解する](../../articles/proxmox-ve-disk-cache-modes.md) の根拠となる計測結果と、計測に使ったスクリプト。
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
- `fio-local-lvm-boot-ssd.jsonl` は起動ディスクでの障害事例に使った。`writeback` の回 (`run` 2) の `fsync_qd1` が 0 IOPS なのは、書き出し待ちによるものとみている。この後、2 回目の `writeback` の計測中に、ホストは HA の watchdog で再起動 (fencing) された。そのため `run` 6 の結果は無い

### 項目

| `test` | fio の主な設定 |
| --- | --- |
| `seqW_qd1` / `seqW_qd16` | 連続書き込み、1 MiB、キュー深さ 1 / 16、4 GiB |
| `randW_qd1` / `randW_qd32` | ランダム書き込み、4 KiB、キュー深さ 1 / 32、30 秒 |
| `fsync_qd1` | ランダム書き込み、4 KiB、キュー深さ 1、書き込みごとに fsync、30 秒 |
| `seqR_qd1` | 連続読み取り、1 MiB、キュー深さ 1 |
| `randR_qd1` / `randR_qd32` | ランダム読み取り、4 KiB、キュー深さ 1 / 32、ディスク全体から 30 秒 |
| `reread_16M` | ランダム読み取り、4 KiB、16 MiB の範囲を 20 回 |

### Ceph RBD の全測定値

各セルは [各回の記録](fio-rbd.jsonl) の値。2 回測ったモードは実施順に併記した。

| 項目 | 単位 | `none` | `writethrough` | `writeback` | `directsync` | `unsafe` |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `seqW_qd1` | MB/s | 173.0 / 165.4 | 200.2 | 1079.7 / 1101.6 | 171.4 | 1072.4 |
| `seqW_qd16` | MB/s | 768.5 / 747.9 | 477.6 | 1407.3 / 1408.2 | 502.5 | 1409.6 |
| `randW_qd1` | IOPS | 582 / 582 | 590 | 8009 / 7937 | 557 | 7926 |
| `randW_qd32` | IOPS | 10783 / 11228 | 7016 | 26494 / 26298 | 7139 | 26460 |
| `fsync_qd1` | IOPS | 566 / 530 | 581 | 584 / 564 | 571 | 5837 |
| `seqR_qd1` | MB/s | 233.7 / 235.2 | 230.2 | 230.2 / 237.7 | 235.1 | 234.4 |
| `randR_qd1` | IOPS | 1391 / 1413 | 1412 | 1388 / 1444 | 1407 | 1431 |
| `randR_qd32` | IOPS | 39949 / 40382 | 40314 | 40216 / 40354 | 40303 | 40348 |
| `reread_16M` | IOPS | 2505 / 2486 | 2529 | 2492 / 2513 | 2515 | 2428 |

### ローカル SATA SSD の全測定値

各セルは [各回の記録](fio-local-ssd.jsonl) の値。各モードを 1 回ずつ測った。

| 項目 | 単位 | `none` | `writethrough` | `writeback` | `directsync` | `unsafe` |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `seqW_qd1` | MB/s | 299.5 | 289.0 | 2085.9 | 253.9 | 1653.8 |
| `seqW_qd16` | MB/s | 516.6 | 460.0 | 3600.1 | 489.2 | 3549.6 |
| `randW_qd1` | IOPS | 15468 | 1187 | 21761 | 1226 | 22386 |
| `randW_qd32` | IOPS | 61800 | 9779 | 127054 | 21451 | 126758 |
| `fsync_qd1` | IOPS | 1157 | 1153 | 1122 | 1196 | 12331 |
| `seqR_qd1` | MB/s | 314.7 | 347.0 | 345.1 | 292.1 | 326.1 |
| `randR_qd1` | IOPS | 5178 | 6080 | 6458 | 5281 | 6725 |
| `randR_qd32` | IOPS | 62999 | 63542 | 67879 | 63060 | 69347 |
| `reread_16M` | IOPS | 4960 | 31581 | 29735 | 4964 | 27225 |

## ローカルの writeback で一気に書いたとき

`scripts/writeback-burst.sh` の結果 (ローカルの SATA SSD、`cache=writeback`)。

- `writeback-burst-fio.jsonl`: 1 行目は各段階の開始時刻 (`T0` からの秒)、2 行目以降は fio の結果
- `writeback-burst-host-meminfo.tsv`: ホストの `/proc/meminfo` の `Dirty` と `Writeback`、qemu の RSS を 1 秒ごとに記録したもの。`sec` は `T0` からの秒、ほかは kB

## qemu 強制終了の試験

ゲストでレコードを追記して 1 件ごとに fsync し (`scripts/writer.py`)、fsync が返った番号を外のマシンに送る。
20〜60 秒後にホストで qemu を `kill -9` し、起動し直してから、受け取った最後の番号までのレコードがそろっているかを検査した (`scripts/verify.py`)。

| ファイル | ファイルシステム | モード | 日時 | スクリプト |
| --- | --- | --- | --- | --- |
| `powerloss-ext4.jsonl` | ext4 | `none`、`writethrough`、`directsync`、`unsafe` を各 5 回、`writeback` を 10 回 | 2026-11-24 | `scripts/powerloss-run-ext4.sh` |
| `reference-powerloss-zfs-*.txt` | ZFS (ashift 9、recordsize 128K) | `writeback` を 10 回、`unsafe` を 1 回 | 2026-10-16 | `scripts/reference-powerloss-run-zfs.sh` |

- ディスクはどれも Ceph RBD
- 記事の表は ext4 の結果である。ZFS の結果は別の VM で先に試したもので、参考として残している (並行する書き込みの速さを制限していない)
- 各回は前の回のファイルの続きから書く (`unsafe` は毎回ファイルを作り直した)。`first_seq` がその回の最初の番号、`acked` が fsync が返った最後の番号
- 別のファイルに 50 MB/s でランダムに書き込みながら試した
- `e2fsck_n_exit` は、検査の後にファイルシステムを外して `e2fsck -fn` した終了コード (0 は異常なし)。`writeback` と `unsafe` の回だけ記録している
- `verify` が無い回は、検査に使う `verify.py` がゲストで消えていて結果が取れなかった回である (`note` を参照)。`verify.py` を毎回 fsync せずに送り直していたため、qemu を止めた後にゼロで埋まっていた。後の回のファイル全体の検査で、その回の分もそろっていたことを確かめている

## スクリプト

| ファイル | 動かす場所 | 内容 |
| --- | --- | --- |
| `scripts/fio-bench.sh` | ゲスト | fio の 9 項目を流し、JSON を 1 行ずつ出す |
| `scripts/set-cache-mode.sh` | ホスト | キャッシュモードを変えて qemu を起動し直し、実際のフラグを表示する |
| `scripts/host-guard.sh` | ホスト | `Dirty` が 20 GiB を超えるか、HA や pvestatd の遅れが出たら qemu を止める |
| `scripts/writeback-burst.sh` | 外のマシン | 12 GiB を書いた直後と 90 秒後に fsync ごとの書き込みを測る |
| `scripts/writer.py` / `scripts/verify.py` | ゲスト | 電源断の試験のレコードを書く / 検査する |
| `scripts/powerloss-run-ext4.sh` / `scripts/reference-powerloss-run-zfs.sh` | 外のマシン | 電源断の試験の 1 回分 |
