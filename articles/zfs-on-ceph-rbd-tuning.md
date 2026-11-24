---
title: "Ceph RBD の上の ZFS は vdev の同時実行数で頭打ちになる"
emoji: "🐢"
type: "tech"
topics: ["zfs", "ceph", "proxmox", "performance", "linux"]
published: true
---

## はじめに

本記事は、Proxmox VE の Ceph RBD の上で ZFS を使うファイルサーバー VM の、読み取りの頭打ちを調べた記録です。

結論を先に述べます。

- Ceph RBD は、同時に出す I/O を増やすほど速くなる。1 本ずつ読むと約 230 MB/s だが、64 本同時なら 2.4 GB/s 出た
- その上の ZFS は、冷えた連続読み取りが約 250 MB/s で頭打ちだった
- 原因は ZFS が vdev に同時に出す非同期の読み取りの上限 (`zfs_vdev_async_read_max_active`、既定値 3) である
- この値を 32 にすると 560 MB/s、128 にすると 1.2 GB/s になった。128 より上は伸びなかった

## 構成

| 項目 | 内容 |
| --- | --- |
| ハイパーバイザ | Proxmox VE 3 ノード |
| Ceph | OSD は SATA SSD を各ノードに 4 本、イレイジャーコーディング (2+1) の RBD |
| ネットワーク | ノードごとに 10GbE を 2 本、BGP の ECMP で振り分ける |
| ゲスト | Ubuntu 26.04、ZFS 2.4.1 |
| ディスク | OS 用とは別に、データ用の RBD を 1 本渡し、その上に ZFS のプールを作る |
| VM ディスクの設定 | `cache=none`、`aio=io_uring`、`iothread=1` |

ZFS の vdev は RBD 1 本だけです。冗長性は Ceph が持つので、ZFS はスナップショットとチェックサムのために使っています。

## 発端

「Nextcloud 越しのファイルの読み書きがやや遅い」という報告を受けて調べました。
遅く感じる主な原因は、Nextcloud の外部ストレージの作りでした。
ただ、その途中で、ZFS の上の大きいファイルの冷えた読み取りが 245 MB/s しか出ていないことに気づきました。

## RBD は並列に出すほど速い

まず、ZFS を通さない生の RBD の速さを測りました。
1 MiB ずつ `direct` で読み、同時に出す数 (キュー深さ) を変えます。
OSD 側のキャッシュに当たらないよう、各段階で別の 2 GiB を読みました。

```bash
fio --name=r --filename=/dev/sdb1 --rw=read --bs=1M --size=2G --offset=${o}G \
  --iodepth=$qd --ioengine=libaio --direct=1
```

ネットワークの上限も見るため、10GbE を 1 本に絞った状態でも測りました。
2 本目のスイッチから BGP の経路を退かせて (graceful shutdown)、全ノードの通信を 1 本に寄せています。

単位は MB/s で、2 回の値を並べています。

| キュー深さ | 10GbE × 1 | 10GbE × 2 (ECMP) |
| --- | --- | --- |
| 1 | 223 / 232 | 231 / 232 |
| 2 | 385 / 391 | 390 / 390 |
| 4 | 644 / 658 | 674 / 679 |
| 8 | 981 / 1008 | 1031 / 1054 |
| 16 | 1218 / 1313 | 1604 / 1609 |
| 32 | 1352 / 1358 | 1789 / 2046 |
| 64 | 1295 / 1385 | 2450 / 2470 |

- キュー深さ 8 までは、本数にほぼ比例して伸びた。1 回の読み取りに約 4 ms かかり、同時に出すほど速くなる
- 10GbE が 1 本だと、約 1.35 GB/s で頭打ちになった。10GbE の実効 (約 1.17 GB/s) を少し超えるのは、primary OSD が同じノードにある分は NIC を通らないためである
- 2 本にすると、キュー深さ 64 で 2.45 GB/s まで伸びた

ネットワーク越しの分散ストレージなので、1 本ずつ待つと遅く、まとめて出すと速いという性質です。

## ZFS の vdev の同時実行数

ZFS は、vdev ごとに I/O のキューを持ちます。
種類ごとに同時に出す数の上限があり、既定値は次のとおりです。

| パラメーター | 既定値 | 対象 |
| --- | --- | --- |
| `zfs_vdev_async_read_max_active` | 3 | 先読みなどの非同期の読み取り |
| `zfs_vdev_sync_read_max_active` | 10 | 同期の読み取り |
| `zfs_vdev_async_write_max_active` | 10 | TXG の書き出しなどの非同期の書き込み |
| `zfs_vdev_max_active` | 1000 | 上の全部を合わせた上限 |

この既定値は、1 本のディスクを想定したものです。
RBD のように並列で伸びるデバイスが 1 本だけの vdev では、同時に出す数が足りなくなります。
大きいファイルの連続読み取りは、先読み (prefetch) による非同期の読み取りなので、同時に出せるのは 3 本までです。
ZFS は recordsize の 128K ずつ読みます。本番で 128K ずつ 1 本で読むと約 110 MB/s だったので、3 本ならその 3 倍弱です。
ZFS で見えていた約 250 MB/s の頭打ちとも合います。

## 同時実行数を変えて測る

テスト VM を建てて測りました。
データ用の RBD は、先にディスク全体をランダムなデータで埋めてあります。
RBD は、書いたことのない領域を読むと速く返すためです。

プールは本番と同じ設定 (ashift 9、recordsize 128K) で作りました。
4 GiB のファイルを作り、`zpool export` と `zpool import` で ARC を空にしてから、連続で読みます。

```bash
echo $ar > /sys/module/zfs/parameters/zfs_vdev_async_read_max_active
zpool export tb; zpool import -d /dev/sdb2 tb
fio --name=r --filename=/tb/f$f --rw=read --bs=1M --size=4G --ioengine=psync
```

段階ごとに別のファイルを読み、2 回目はファイルの割り当てを入れ替えました。

| `async_read_max_active` | 冷えた連続読み取り (MB/s) |
| --- | --- |
| 3 (既定値) | 250 / 258 |
| 8 | 277 / 269 |
| 16 | 373 / 377 |
| 32 | 564 / 559 |
| 64 | 818 / 842 |
| 128 | 1223 / 1219 / 1209 / 1264 |
| 256 | 1273 / 1260 |
| 512 | 1346 / 1273 |
| 1000 | 1335 / 1327 |

- 3 から 128 までは、上げるほど伸びた。128 で 3 の約 4.8 倍になった
- 128 より上は、1.2〜1.35 GB/s で頭打ちになった。生の RBD (2.45 GB/s) には届かない
- 頭打ちの原因は確かめていない。1 本の読み手が先読みできる距離 (`zfetch_max_distance`) などが候補である
- 8 は 3 とほとんど変わらなかった

### 書き込み側と、ほかの設定

以前、10GbE が 1 本だったときに、書き込みとほかの設定も測りました。
単位は MB/s で、最後の列だけ IOPS です。

| 設定 | 連続書き込み | 冷えた連続読み取り | 16K の同期ランダム書き込み |
| --- | --- | --- | --- |
| 既定値 (ashift 9、128K) | 180 / 186 | 253 / 252 | 517 / 532 |
| ashift 12 | 204 | 257 | 519 |
| `async_write_max_active` を 32 に | 301 | 301 | 526 |
| 3 つとも 32 | 298 | 556 | 531 |
| recordsize 1M | 498 | 526 | 321 |

- 書き込みは `zfs_vdev_async_write_max_active` を 10 から 32 にすると 1.6 倍になった
- どちらの同時実行数を上げても、遅くなる項目はなかった
- recordsize 1M は連続の読み書きに効く。ただし大きいファイルの一部を書き換える同期書き込みは 4 割減る
- ashift は 9 と 12 で差がなかった
- `async_write_max_active` を 32 にした行は、誤って `async_read` も 10 にしていた。読み取りの 301 はその分だけ上がっている

VM ディスクのキャッシュモード (`cache=writeback`) も書き込みに大きく効きました。
こちらは安全性の試験を含めて、別の記事で扱います。

## 本番への入れ方

本番は、読み取りと書き込みの同時実行数をどちらも 32 にしました。
64 以上にした場合に、同期書き込みなどほかの I/O の遅れがどうなるかは確かめていないためです。

モジュールパラメーターは、起動時用に `/etc/modprobe.d/` に書き、動いているモジュールにも
`/sys/module/zfs/parameters/` から反映します。
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

## まとめ

- Ceph RBD は、同時に出す I/O を増やすほど速くなる。ネットワークの帯域が次の上限になる
- その上に vdev 1 本の ZFS を載せると、`zfs_vdev_async_read_max_active` の既定値 3 が冷えた読み取りの上限になる
- 32 で約 2.2 倍、128 で約 4.8 倍になった。128 より上は伸びなかった
- 1 本のディスクを想定した既定値は、ネットワーク越しのブロックデバイスには合わないことがある。実測で頭打ちを見つけたら、まず同時実行数を疑うとよい
