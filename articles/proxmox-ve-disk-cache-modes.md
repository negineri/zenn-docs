---
title: "Proxmox VE のディスクのキャッシュモードを Ceph RBD とローカル SSD で測る"
emoji: "💾"
type: "tech"
topics: ["proxmox", "ceph", "qemu", "kvm", "performance"]
published: true
---

## はじめに

Proxmox VE の VM ディスクには、キャッシュモード (`cache=`) の設定があります。
選べるのは `none` (既定値)、`writethrough`、`writeback`、`directsync`、`unsafe` の 5 つです。
本記事では、それぞれの中身を QEMU のソースで確かめ、Ceph RBD とローカルの SATA SSD で速さと安全性を測りました。

結論を先に述べます。

- キャッシュモードは、QEMU の 3 つのフラグの組み合わせである。どこにキャッシュがあるかは、ディスクの種類で変わる
- Ceph RBD では、キャッシュは librbd が qemu の中に持つ。ホストのページキャッシュは使わない
- RBD の `writeback` は、書き込みが `none` の 5〜14 倍速い。fsync のたびに待つ書き込みと、読み取りは速くならない
- RBD の `writeback` で qemu を `kill -9` しても、fsync が返ったデータは 10 回とも失われなかった。`unsafe` では失われた
- RBD の `writethrough` は、書き込みごとに flush するので `directsync` と同じ速さになる
- ローカルの SSD の `writeback` は、ホストのページキャッシュに書く。速いが、溜まった分を書き出す間は fsync が待たされる。ホストの起動ディスクと同じ SSD でやると、ホストごと止まることがある

計測の結果とスクリプトは [GitHub](https://github.com/negineri/zenn-docs/tree/main/data/proxmox-ve-disk-cache-modes) に置いています。

## 構成

| 項目 | 内容 |
| --- | --- |
| ハイパーバイザ | Proxmox VE 9.2 (QEMU 11.1)、3 ノード、メモリ 251 GB |
| Ceph | 20.2 (Tentacle)。OSD は SATA SSD を各ノードに 4 本、イレイジャーコーディング (2+1) の RBD |
| ネットワーク | ノードごとに 10GbE を 2 本、BGP の ECMP で振り分ける |
| ローカル SSD | SATA SSD (Micron 1100 2TB) をホストから丸ごと VM に渡す |
| ゲスト | Ubuntu 26.04、8 コア、メモリ 4 GiB |
| VM ディスクの設定 | `virtio-scsi-single`、`aio=io_uring`、`iothread=1` |

RBD は librbd (QEMU の rbd ドライバ) でつないでいます。krbd ではありません。

## キャッシュモードの中身

QEMU のキャッシュモードは、次の 3 つのフラグの組み合わせです。

- `cache.direct`: ホストのページキャッシュを通さない (`O_DIRECT`)
- `cache.no-flush`: ゲストからの flush を無視する
- `write-cache`: ゲストに「揮発性の書き込みキャッシュがある」と見せる。off にすると、ゲストは flush を送らず、QEMU が書き込みごとに書き込み完了を保証する

| `cache=` | `cache.direct` | `cache.no-flush` | `write-cache` |
| --- | --- | --- | --- |
| `none` | on | off | on |
| `writethrough` | off | off | off |
| `writeback` | off | off | on |
| `directsync` | on | off | off |
| `unsafe` | off | on | on |

VM を起動したときの qemu のコマンドラインを見て、実際にこの組み合わせになることを確かめました。

### ローカルのディスク

ローカルのブロックデバイスやファイルでは、`cache.direct` が off のモード (`writethrough`、`writeback`、`unsafe`) はホストのページキャッシュを通ります。
`writeback` の書き込みはページキャッシュに置いた時点で返り、ゲストが flush したときにディスクに書かれます。

### Ceph RBD

RBD ではホストのページキャッシュを使いません。
代わりに、QEMU の rbd ドライバが librbd のキャッシュ (`rbd_cache`) を `cache.direct` から決めます。

```c
/* block/rbd.c (要約) */
rados_conf_set(cluster, "rbd_cache", (flags & BDRV_O_NOCACHE) ? "false" : "true");
```

`ceph.conf` に `rbd_cache` を書いても、QEMU のこの設定で上書きされます。
キャッシュは qemu のプロセスの中にあり、既定の大きさは 32 MiB (未書き出しは 24 MiB まで) です。

librbd のキャッシュの振る舞いは `rbd_cache_policy` で決まり、既定値は `writearound` です。
書き込みはキャッシュに置いてすぐ返しますが、読み取りはキャッシュから返しません。
そのため、RBD ではどのモードでも読み取りは速くなりません。

もう 1 つ、`rbd_cache_writethrough_until_flush` (既定値 true) があります。
ゲストから最初の flush が来るまでは、librbd は書き込みごとに Ceph まで書いてから返します。
flush を送らない古いゲストでもデータを失わないための仕組みです。
今のゲストは起動してすぐ flush を送るので、計測には影響しません。

### RBD の writethrough

`writethrough` は `rbd_cache` を有効にするので、一見 `writeback` と同じに見えます。
実際には、`write-cache` が off なので、QEMU のブロック層が書き込みのたびに FUA (Force Unit Access) を付けます。
rbd ドライバは FUA に対応していないため、QEMU は FUA を「書き込みの後に flush する」ことで代わりに実現します (`block/io.c`)。
flush は librbd のキャッシュを書き出すので、結果として書き込みごとに Ceph まで届いてから返ります。

これは後の計測でも、`writethrough` が `directsync` とほぼ同じ速さになることで確かめられます。

## 速さを測る

### 測り方

ゲストの中で、データ用のディスク (ブロックデバイス) に直接 fio を流しました。
ゲストのページキャッシュを避けるため、すべて `--direct=1` です。
キャッシュモードを変えたら、qemu を起動し直しています。

| 項目 | fio の主な設定 |
| --- | --- |
| 連続書き込み | 1 MiB、キュー深さ 1 と 16、4 GiB |
| ランダム書き込み | 4 KiB、キュー深さ 1 と 32、30 秒 |
| fsync ごとの書き込み | 4 KiB、キュー深さ 1、書き込みごとに fsync、30 秒 |
| 連続読み取り | 1 MiB、キュー深さ 1 |
| ランダム読み取り | 4 KiB、キュー深さ 1 と 32、ディスク全体から 30 秒 |
| 読み直し | 4 KiB、16 MiB の範囲を 20 回読む |

ディスクは、先に全体をランダムなデータで埋めてあります。
RBD は書いたことのない領域を読むと速く返すためです。
項目の間は 10〜20 秒空けました。

### Ceph RBD の結果

単位は、連続の項目が MB/s、ほかは IOPS です。2 回測った項目は 2 つの値を並べています。

| 項目 | none | writethrough | writeback | directsync | unsafe |
| --- | --- | --- | --- | --- | --- |
| 連続書き込み QD1 | 173 / 165 | 200 | 1080 / 1102 | 171 | 1072 |
| 連続書き込み QD16 | 768 / 748 | 478 | 1407 / 1408 | 502 | 1410 |
| ランダム書き込み QD1 | 582 / 582 | 590 | 8009 / 7937 | 557 | 7926 |
| ランダム書き込み QD32 | 10783 / 11228 | 7016 | 26494 / 26298 | 7139 | 26460 |
| fsync ごとの書き込み | 566 / 530 | 581 | 584 / 564 | 571 | 5837 |
| 連続読み取り QD1 | 234 / 235 | 230 | 230 / 238 | 235 | 234 |
| ランダム読み取り QD1 | 1391 / 1413 | 1412 | 1388 / 1444 | 1407 | 1431 |
| ランダム読み取り QD32 | 39949 / 40382 | 40314 | 40216 / 40354 | 40303 | 40348 |
| 読み直し | 2505 / 2486 | 2529 | 2492 / 2513 | 2515 | 2428 |

- `writeback` の書き込みは、`none` に比べて連続 QD1 で約 6 倍、ランダム QD1 で約 14 倍になった。librbd のキャッシュに置いて返すためである。ランダム書き込み QD1 の平均の待ち時間は 1.7 ms から 0.1 ms になった
- fsync ごとの書き込みは、`writeback` でも `none` と同じだった。fsync のたびに librbd のキャッシュが Ceph まで書き出されるためである。データベースのように fsync を多用する負荷は、`writeback` にしても速くならない
- `unsafe` だけは fsync ごとの書き込みも約 10 倍になった。flush を無視するからである
- `writethrough` と `directsync` は、キュー深さ 1 では `none` と同じで、深くすると `none` より遅い。書き込みごとに flush を待つためである
- 読み取りは、5 つのモードで差がなかった。librbd の `writearound` は読み取りをキャッシュから返さない

### ローカルの SATA SSD の結果

| 項目 | none | writethrough | writeback | directsync | unsafe |
| --- | --- | --- | --- | --- | --- |
| 連続書き込み QD1 | 300 | 289 | 2086 | 254 | 1654 |
| 連続書き込み QD16 | 517 | 460 | 3600 | 489 | 3550 |
| ランダム書き込み QD1 | 15468 | 1187 | 21761 | 1226 | 22386 |
| ランダム書き込み QD32 | 61800 | 9779 | 127054 | 21451 | 126758 |
| fsync ごとの書き込み | 1157 | 1153 | 1122 | 1196 | 12331 |
| 連続読み取り QD1 | 315 | 347 | 345 | 292 | 326 |
| ランダム読み取り QD1 | 5178 | 6080 | 6458 | 5281 | 6725 |
| ランダム読み取り QD32 | 62999 | 63542 | 67879 | 63060 | 69347 |
| 読み直し | 4960 | 31581 | 29735 | 4964 | 27225 |

- `writeback` と `unsafe` の連続書き込みは、SSD の速さ (約 500 MB/s) を大きく超えた。ホストのメモリに書いているだけである
- `none` のランダム書き込み QD1 は 15468 IOPS で、RBD の 26 倍だった。ネットワークを通らないためである
- `writethrough` と `directsync` は、ランダム書き込みが大きく落ちた。書き込みごとに SSD まで flush するためである
- 読み直しは、ページキャッシュを通るモード (`writethrough`、`writeback`、`unsafe`) で約 6 倍になった。RBD と違って、読み取りもキャッシュが効く

### ローカルの writeback の落とし穴

ローカルの `writeback` で 12 GiB を一気に書き、ホストの未書き出しのページ (`/proc/meminfo` の `Dirty`) を 1 秒ごとに見ました。

- 書き込みは 3.5 GB/s で約 3.5 秒で終わり、`Dirty` は 12.6 GB まで増えた
- そこから毎秒約 0.5 GB (SSD の書き込みの速さ) ずつ減り、約 25 秒でゼロに戻った
- qemu のメモリ (RSS) は 1.0 GB のまま変わらなかった。溜まっているのは qemu ではなく、ホストのページキャッシュである

書いた直後に fsync ごとの書き込みを 30 秒測ると、175 IOPS でした。
落ち着いてから測ると 1127 IOPS です。
最初の fsync が、溜まった 12 GB の書き出しを約 25 秒待つためです。

ホストの `vm.dirty_ratio` の既定値は 20 % で、251 GB のホストなら約 50 GB まで溜まり得ます。
筆者は最初、ホストの起動ディスクと同じ SSD にある `local-lvm` で同じ試験をして、ホストを止めてしまいました。
大量の書き出しでルートのファイルシステムが待たされ、HA の watchdog が切れてノードが再起動 (fencing) されたためです。
ローカルの `writeback` を試すなら、ホストの起動ディスクとは別のディスクで行い、`Dirty` を見ながら進めることを勧めます。

## 安全性を試す

`writeback` は「速いが、電源断でデータが消える」と言われることがあります。
ゲストが fsync したデータは残るはずなので、実際に試しました。

### 試し方

RBD のディスクにファイルシステムを作り、ゲストで次のことを続けます。

- 4 KiB ほどのレコードに連番とチェックサムを付けてファイルに追記し、1 件ごとに fsync する
- fsync が返るたびに、その連番を SSH で外のマシンに送る (外のマシンが「保存済み」と受け取った番号を覚えておく)
- 同時に、別のファイルにランダムに書き込み、キャッシュに未書き出しのデータがある状態にする

20〜60 秒たったところで、ホストで qemu を `kill -9` で止めます。
VM を起動し直し、ファイルを先頭から検査して、受け取った最後の番号までのレコードがそろっているかを見ました。

RBD では、librbd のキャッシュは qemu のプロセスの中にあります。
qemu を止めると、キャッシュの中身はホストの電源断と同じく消えます。
ローカルのディスクではキャッシュがホストのページキャッシュにあり、qemu を止めても消えないので、この方法では試せません。

### 結果

| `cache=` | ファイルシステム | 回数 | fsync が返ったデータを失った回数 |
| --- | --- | --- | --- |
| `none` | ext4 | 5 | 0 |
| `writethrough` | ext4 | 5 | 0 |
| `writeback` | ZFS | 10 | 0 |
| `directsync` | ext4 | 5 | 0 |
| `unsafe` | ZFS | 1 | 1 |

`writeback` と `unsafe` は、ZFS (ashift 9、recordsize 128K) の速さを調べたときに、先に別の VM で試したものです。
ほかの 3 つは、今回の計測の VM で ext4 を使って試しました。
ext4 の回は別のファイルへの書き込みを 50 MB/s に抑え、ZFS の回は抑えていません。

- `writeback` でも、fsync が返ったデータは 10 回とも残っていた。flush で librbd のキャッシュが書き出されてから fsync が返るためである
- `unsafe` は 1 回で、fsync が返った最後の 8 件 (約 32 KB) を失った。flush を無視するので当然の結果である
- fsync していないデータは、どのモードでも消えることがある。これは物理のディスクでも同じである

ゲストのファイルシステムやアプリケーションが fsync を正しく使う限り、RBD の `writeback` は安全と言えます。
Ceph のドキュメントも、QEMU で librbd のキャッシュを使うときは `cache=writeback` にするよう書いています。

## 選び方

| ディスク | 勧めるモード | 理由 |
| --- | --- | --- |
| Ceph RBD | `writeback` | 書き込みが速く、fsync したデータは失われない。読み取りと fsync ごとの書き込みは変わらない |
| ローカルの SSD | `none` | `writeback` はホストのメモリを使い、大量に書くとホストに負荷が移る。ホストの電源断でも安全かは今回試していない |

- `writethrough` と `directsync` は、どちらのディスクでも `none` より遅く、`none` で fsync を使う場合と比べて安全性が増すわけでもない。ゲストが flush を正しく送らない古い OS のためのモードである
- `unsafe` は、消えても困らない一時的な VM (OS のインストールの間など) に限る

## 先行事例

2021 年の記事「[OpenStackでCephを使う場合のディスクキャッシュ設定について](https://zenn.dev/tj/articles/0002-cache-settings-in-kvm-ceph)」は、QEMU 4.2 と Ceph Nautilus のソースと資料を読み、次のことを示しています。

- QEMU のキャッシュモードが `ceph.conf` の `rbd_cache` を上書きする
- QEMU の `write-cache` は librbd に渡らないので、RBD では `writeback` と `writethrough` の区別に本質的な意味はない

1 つ目は、本記事で読んだ QEMU 11.1 でも同じでした。
2 つ目は、今回の計測とは合いませんでした。
`write-cache` が librbd に渡らないのはそのとおりです。
しかし QEMU のブロック層が書き込みごとに FUA を付け、それを flush で代わりに実現するため、`writethrough` は実際に書き込みごとに Ceph まで届きます。
`writethrough` が `directsync` と同じ速さで、`writeback` よりずっと遅いことがその表れです。

また、Ceph は Octopus から `rbd_cache_policy` が入り、既定値が `writearound` になりました。
読み取りがキャッシュから返らないのはこのためです。

## まとめ

- キャッシュモードは、`cache.direct`、`cache.no-flush`、`write-cache` の 3 つのフラグの組み合わせである
- RBD ではキャッシュは librbd が qemu の中に持ち、既定の `writearound` では書き込みだけが速くなる
- RBD の `writeback` は書き込みを大きく速くし、fsync したデータは qemu を `kill -9` しても失われなかった
- ローカルの `writeback` はホストのページキャッシュを使う。溜まった分の書き出しが fsync を待たせ、起動ディスクと共有していればホストを止めることもある
