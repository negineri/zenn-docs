---
title: "Ceph RBD の上の ZFS が遅いとき: vdev の同時実行数と cache=writeback を試験してから入れた"
emoji: "🐢"
type: "tech"
topics: ["zfs", "ceph", "proxmox", "qemu", "performance"]
published: true
---

## はじめに

本記事は、Proxmox VE の Ceph RBD の上で ZFS を使うファイルサーバー VM を速くした記録です。
発端は「Nextcloud 越しのファイルの読み書きがやや遅い」という報告でした。

結論を先に述べます。

- 性能は落ちていなかった。遅く感じる主な原因は Nextcloud の外部ストレージの作りであった
- ただし、ZFS と VM ディスクの設定には、はっきりした改善の余地があった
- ZFS が Ceph に同時に出す I/O の数を 3 から 32 に上げると、冷えた連続読み取りが 252 MB/s から 550 MB/s になった
- VM ディスクを `cache=writeback` にすると、連続書き込みが 186 MB/s から 758 MB/s になった
- `cache=writeback` は、qemu を `kill -9` する電源断の試験を 10 回行い、fsync 済みのデータが失われないことを確かめてから入れた

## 構成

| 項目 | 内容 |
| --- | --- |
| ハイパーバイザ | Proxmox VE 3 ノード、Ceph の OSD は SATA SSD を各ノードに 4 本 |
| プール | イレイジャーコーディング (2+1) の RBD |
| ゲスト | Ubuntu 26.04、ZFS 2.4.1 |
| ディスク | OS 用とは別に、データ用の RBD を 1 本渡し、その上に ZFS のプールを作成 |
| 使い方 | Samba で共有し、Nextcloud から外部ストレージとしてつなぐ |

ZFS の vdev は RBD 1 本だけです。
冗長性は Ceph が持つので、ZFS はスナップショットとチェックサムのために使っています。

## 性能は落ちていたか

まず、本当に遅くなったのかを確かめました。
node_exporter のディスクのメトリクスから、データ用ディスクのレイテンシを 4 か月分さかのぼりました。

| 期間 | 読み取りのレイテンシ | 書き込みのレイテンシ |
| --- | --- | --- |
| 4 か月間 | 0.7〜2.8 ms (平均で 1.5〜2 ms 前後) | 1.6〜3.4 ms (ほぼ 1.6〜2.0 ms) |

上がっていく傾向はなく、Ceph も HEALTH_OK でした。
Nextcloud のサーバーから SMB で読むと、200〜300 MB/s 出ていました。

遅く感じる原因は Nextcloud 側の作りにあると判断しました。

- 分割アップロードは、いったん Nextcloud のサーバーのローカルディスクに溜める。最後に 1 本につないで SMB へ書き直すので、その間クライアントは待たされる
- 外部ストレージの「変更の確認」が既定の「直接アクセスするたび」なので、フォルダーを開くたびに SMB で中身を取り直す

ここは設定で速くできる余地が小さいので、下回りの ZFS と RBD を見直すことにしました。

## RBD は並列に出すほど速い

本番の VM で、生の RBD を `dd` で読んでみました (`iflag=direct` で 128 KiB ずつ)。

| 読み方 | 速さ |
| --- | --- |
| 1 本 | 約 100〜110 MB/s |
| offset を変えて 4 本同時 | 369 MB/s |
| 実データのある範囲を 10 本同時 | 約 900 MB/s |
| ZFS の上の、ARC に載っていない大きいファイル | 245 MB/s |

1 回の読み取りに約 1 ms かかり、並列に出した本数にほぼ比例して伸びます。
ネットワーク越しの分散ストレージなので、1 本ずつ待つと遅く、まとめて出すと速いという性質です。

ZFS 経由では 245 MB/s で頭打ちでした。
ZFS が vdev に同時に出す I/O の数が少ないのではないかと考えました。

## ZFS の vdev の同時実行数

ZFS は、vdev ごとに I/O のキューを持ちます。
種類ごとに同時に出す数の上限があり、既定値は次のとおりです。

| パラメーター | 既定値 | 対象 |
| --- | --- | --- |
| `zfs_vdev_async_read_max_active` | 3 | 先読みなどの非同期の読み取り |
| `zfs_vdev_sync_read_max_active` | 10 | 同期の読み取り |
| `zfs_vdev_async_write_max_active` | 10 | TXG の書き出しなどの非同期の書き込み |

この既定値は、1 本のディスクを想定したものです。
RBD のように並列で伸びるデバイスが 1 本だけの vdev では、同時に出す数が足りなくなります。
連続読み取りの先読みは非同期の読み取りなので、同時に出せるのは 3 本までです。
1 本では約 100 MB/s のデバイスに 3 本ずつしか出さないので、約 250 MB/s という頭打ちと合います。

## テスト VM で測る

本番と同じ構成のテスト VM を建てて測りました。
本番は 4 TB ほど使っているので、RBD の書いたことのない領域と上書きとの違いを避けるため、先にランダムなデータで埋めました。

```bash
sudo sgdisk -n1:0:+64G /dev/sdb
sudo fio --name=fill --filename=/dev/sdb1 --rw=write --bs=4M --iodepth=16 \
  --ioengine=libaio --direct=1 --refill_buffers
```

1 回の測定ではプールを作り直し、パラメーターを書き換えてから fio で測りました。
読み取りは、`zpool export` と `zpool import` で ARC を空にしてから測っています。

```bash
#!/bin/bash
# usage: zfs-bench.sh <ashift> <recordsize> <async_read> <sync_read> <async_write> <label>
set -e
A=$1 RS=$2 AR=$3 SR=$4 AW=$5 L=$6
P=/sys/module/zfs/parameters
echo $AR > $P/zfs_vdev_async_read_max_active
echo $SR > $P/zfs_vdev_sync_read_max_active
echo $AW > $P/zfs_vdev_async_write_max_active
zpool destroy -f tb 2>/dev/null || true
zpool create -f -o ashift=$A -O recordsize=$RS -O xattr=sa -O mountpoint=/tb tb /dev/sdb1
cold(){ zpool export tb; zpool import -d /dev/sdb1 tb; }
f(){ fio --output-format=terse --directory=/tb --ioengine=psync --refill_buffers "$@" 2>/dev/null; }
w=$(f --name=w --rw=write --bs=1M --size=8G --end_fsync=1 | awk -F';' '{printf "%.0f", $48/1024}')
cold
r=$(f --name=w --rw=read --bs=1M --size=8G | awk -F';' '{printf "%.0f", $7/1024}')
cold
r4=$(f --name=w --rw=read --bs=1M --size=2G --numjobs=4 --offset_increment=2G \
  --group_reporting | awk -F';' '{printf "%.0f", $7/1024}')
rw=$(f --name=rw --rw=randwrite --bs=16k --size=1G --sync=1 --runtime=20 --time_based \
  | awk -F';' '{printf "%.0f", $49}')
printf "%-28s seqW=%5s coldSeqR=%5s coldR4job=%5s MB/s syncRandW16k=%5s IOPS\n" \
  "$L" $w $r $r4 $rw
```

## 結果

単位は MB/s で、最後の列だけ IOPS です。

| 設定 | 連続書き込み | 冷えた連続読み取り | 4 本同時の読み取り | 16K の同期ランダム書き込み |
| --- | --- | --- | --- | --- |
| 本番と同じ (ashift 9、128K、既定値) | 180 / 186 | 253 / 252 | 601 / 576 | 517 / 532 |
| ashift 12 | 204 | 257 | 579 | 519 |
| `async_read` を 32 に | 181 | **550** | 896 | 530 |
| 3 つとも 32 | 298 | 556 | 957 | 531 |
| 3 つとも 64 | 279 | 845 | 1031 | 530 |
| recordsize 1M | 498 | 526 | 929 | **321** |
| `cache=writeback` (ほかは本番と同じ) | **758** | 258 | 591 | **636** |
| writeback と同時実行数 32 | 781 | 553 | 892 | 650 |

本番と同じ設定の冷えた読み取りは 252 MB/s で、本番で測った 245 MB/s とほぼ同じです。
テスト VM で本番を再現できていると判断しました。

- 読み取りは `zfs_vdev_async_read_max_active` だけで決まった。3 から 32 で 2.2 倍、64 で 3.4 倍である
- 書き込みは `zfs_vdev_async_write_max_active` を 32 にすると 1.6 倍になった
- どちらも、遅くなる項目はなかった
- `cache=writeback` は書き込みだけに効き、既定の同時実行数のままでも 4 倍になった
- recordsize 1M は連続の読み書きに効く。ただし大きいファイルの一部を書き換える同期書き込みは 4 割減る
- ashift は 9 と 12 で差がなかった。直すにはプールの作り直しが要るので見送った
- 小さいファイル (64K を 1000 個) は、どの設定でも約 50 MB/s で変わらなかった。Ceph への 1 往復の時間で決まっている

recordsize は使い方次第なので見送り、同時実行数と `cache=writeback` の 2 つを入れることにしました。

## cache=writeback は電源断で壊れないか

`cache=writeback` では、qemu の中の librbd が書き込みをキャッシュします。
ゲストがフラッシュを出せば、Ceph に書き出してから完了を返します。
理屈の上では、fsync したデータは失われず、ZFS も壊れません。
これを実際に確かめました。

Proxmox VE は、`cache=writeback` のとき qemu に `cache.direct=false` を渡します。
qemu の rbd ドライバーは、`direct` でないときに librbd のキャッシュを有効にします。
krbd ではなく librbd を使う構成なので、キャッシュはホストのページキャッシュではなく、qemu のプロセスの中にあります。

### 電源断の再現方法

電源断は、ホストで qemu を `kill -9` して再現しました。
次の方法では、電源断の再現になりません。

- **ゲストの中からのリセット** (`sysrq` など): qemu が生きているので、キャッシュは消えない
- **Proxmox VE の API での停止**: qemu が終了するときに、キャッシュを書き出してしまう

キャッシュが qemu のプロセスの中にあるので、qemu を落とすことは、キャッシュの観点ではホストの電源断と同じです。

### 手順

1. ゲストで fio の非同期の書き込み (randwrite 64k、iodepth 32) を流し続け、キャッシュに未書き出しのデータが常にある状態にする
2. 同時に、レコードを追記して fsync が返るたびに番号を出力するスクリプトを ssh 越しに動かす。手元で最後に受け取った番号を「保証されたはずの位置」(ack) とする
3. 20〜60 秒のランダムな時間の後、ホストで qemu を `kill -9` する
4. HA が VM を起こし直すのを待ち、ack の番号までのレコードがすべてそろい、チェックサムが合うかを確かめる

書き込み側のスクリプトは次のとおりです。
4016 バイトのレコードは、番号、乱数、SHA-256 の先頭 8 バイトから成ります。

```python
import os, sys, hashlib

path = sys.argv[1]
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
seq = int(sys.argv[2]) if len(sys.argv) > 2 else 0
while True:
    payload = os.urandom(4000)
    head = seq.to_bytes(8, "little")
    rec = head + payload + hashlib.sha256(head + payload).digest()[:8]
    os.write(fd, rec)
    os.fsync(fd)
    sys.stdout.write(f"{seq}\n")
    sys.stdout.flush()
    seq += 1
```

確かめる側は、先頭から順に番号とチェックサムを見て、最後に正しかった番号と ack を比べます。

```python
import sys, hashlib

data = open(sys.argv[1], "rb").read()
acked = int(sys.argv[2])
last = -1
for i in range(len(data) // 4016):
    r = data[i * 4016 : (i + 1) * 4016]
    s = int.from_bytes(r[:8], "little")
    if s != i or hashlib.sha256(r[:4008]).digest()[:8] != r[4008:]:
        break
    last = s
print(f"last_valid={last} acked={acked}", "OK" if last >= acked else "LOST_ACKED_DATA")
```

### 結果: writeback

| 回 | 落とすまでの fsync の回数 | ack | 残っていた最後のレコード | 判定 |
| --- | --- | --- | --- | --- |
| 1 | 14,292 | 14,291 | 14,292 | OK |
| 2 | 17,549 | 31,841 | 31,842 | OK |
| 3 | 18,032 | 49,874 | 49,875 | OK |
| 4 | 10,570 | 60,445 | 60,446 | OK |
| 5 | 24,147 | 84,593 | 84,594 | OK |
| 6 | 10,811 | 95,405 | 95,406 | OK |
| 7 | 28,433 | 123,839 | 123,840 | OK |
| 8 | 19,791 | 143,631 | 143,632 | OK |
| 9 | 15,729 | 159,361 | 159,362 | OK |
| 10 | 23,766 | 183,128 | 183,129 | OK |

- 10 回とも、ack を受け取ったレコードはすべて残っていた。プールも毎回正常で、最後の scrub もエラー 0 件であった
- 残っていた最後のレコードは毎回「ack + 1」であった。fsync は返ったものの、番号を手元へ送る前に落ちた 1 件である。書き込みの最中に落とせていることの裏付けにもなる

### 対照実験: cache=unsafe

この試験で消失を本当に検出できるのかを確かめるため、フラッシュを無視する `cache=unsafe` でも同じ手順を回しました。
消失を確認した時点で打ち切る約束で行いました。

| 回 | 落とすまでの fsync の回数 | ack | 残っていた最後のレコード | 判定 |
| --- | --- | --- | --- | --- |
| 1 | 102,965 | 102,964 | 102,956 | **ack 済みの 8 件が消えた** |

- 1 回目で、fsync が返ったはずの 8 件が残っていなかった
- プールの整合性は保たれていた。ZFS は、ディスクに届いた範囲の中で整合の取れた時点まで戻る。一方で、アプリに「保存した」と返したデータは失われている
- fsync の回数は、writeback の数倍であった。フラッシュを待たずに完了を返していることが分かる

writeback の安全性は、フラッシュが守られることによるものだと裏付けられました。

なお、`qm monitor` の `info block` は、unsafe でも「writeback」としか表示しません。
実際の設定は、qemu の起動引数で確かめます。

```bash
tr '\0' '\n' < /proc/$(cat /var/run/qemu-server/<VMID>.pid)/cmdline \
  | grep 'vm-<VMID>-disk-' | grep -oE '"cache":\{[^}]*\}' | sort -u
# writeback: "cache":{"direct":false,"no-flush":false}
# unsafe:    "cache":{"direct":false,"no-flush":true}
# none:      "cache":{"direct":true,"no-flush":false}
```

### 試験の限界

- 確かめたのは、fsync したデータとプールの整合性だけである。fsync していない書き込みは `cache=none` でも電源断で失われうるので、比べていない
- Ceph の OSD の障害が重なる場合は試していない

## 本番への入れ方

### 同時実行数

モジュールパラメーターは、起動時用に `/etc/modprobe.d/` に書き、動いているモジュールにも `/sys/module/zfs/parameters/` から反映します。
止める必要はありません。

```text
# /etc/modprobe.d/zfs-tuning.conf
options zfs zfs_vdev_async_read_max_active=32
options zfs zfs_vdev_async_write_max_active=32
```

```bash
echo 32 | sudo tee /sys/module/zfs/parameters/zfs_vdev_async_read_max_active
echo 32 | sudo tee /sys/module/zfs/parameters/zfs_vdev_async_write_max_active
```

Ubuntu では、`zfs.ko` が initramfs に入っています。
initramfs の段階で zfs を読み込む構成 (ルートが ZFS など) では、modprobe.d を変えたら `update-initramfs -u` も要ります。
今回はルートが ext4 なので、zfs は起動後に読み込まれ、modprobe.d がそのまま効きました。
テスト VM で再起動し、値が 32 のまま残ることを確かめています。

### cache=writeback

Terraform (bpg/proxmox provider) でディスクの `cache` を変えると、作り直しではなく update in-place になります。
ただし、動いている qemu はそのままなので、apply しただけでは反映されません。
VM の中からの再起動でも、qemu は同じプロセスのままです。
Proxmox VE から VM を止めて起動し直す必要があります。

```bash
ha-manager set vm:<VMID> --state stopped   # 止まったのを確かめてから
ha-manager set vm:<VMID> --state started
```

反映を待つ間は、`/etc/pve/qemu-server/<VMID>.conf` の `[PENDING]` 節に新しい値が入っています。
今回は止めてから起動するまで 34 秒でした。

止めて起動し直したとき、cloud-init が新しいインスタンスとして動き、ユーザーのパスワードの設定などを流し直しました。
設定された値は管理しているものと同じで、SSH のホスト鍵も作り直されていませんでした。
ただ、ログの監視には見慣れないログとして引っかかりました。
Proxmox VE の cloud-init を使う VM を止めて起動し直すときは、この点に注意してください。

## まとめ

- Ceph RBD のように並列で伸びるデバイスを ZFS の vdev 1 本で使うと、vdev の同時実行数の既定値が律速になる
- `zfs_vdev_async_read_max_active` を 3 から 32 に上げると、冷えた連続読み取りが 2.2 倍になった
- librbd を使う構成なら、`cache=writeback` でも fsync 済みのデータは守られる。`kill -9` による試験で確かめられる
- `cache=writeback` の反映には、qemu を起動し直す必要がある
- 体感の遅さの主な原因が、上位のアプリケーションにあることもある。下回りの改善は、まず実測で裏付けてから入れるのが確実である
