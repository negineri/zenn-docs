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
- RBD の `writeback` は、4 KiB のランダム書き込みを 1 件ずつ出すと、`none` の約 14 倍速い。1 件ごとに fsync すると差はほぼ消える
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

まず Ceph RBD で、既定の `none` から `writeback` に変えると、ゲストの書き込みがどれだけ速くなるかを見ます。
次に、ローカルの SATA SSD で、ホストのページキャッシュが読み書きにどう効くかを確かめます。

どちらもゲストから fio でデータ用ディスクに直接アクセスしました。
`--direct=1` でゲストのページキャッシュを避け、モードを変えるたびに qemu を起動し直しています。
RBD は未使用の領域を速く読めるため、計測前に両方のディスクをランダムなデータで埋めました。
各項目の間は RBD で 10 秒、SSD で 20 秒空けました。

### RBD では、書き込みごとに fsync するかで差が変わる

まず、ランダムな位置に 4 KiB ずつ、1 件の完了を待ってから次の 1 件を書きます。
同じ負荷で、毎回 fsync して永続化を待つ場合も測りました。
表の値は 1 秒あたりの書き込み回数 (IOPS) です。RBD の `none` と `writeback` は 2 回ずつ測ったので、本文では平均値を丸めて示します。

| 4 KiB のランダム書き込み | `none` (IOPS) | `writeback` (IOPS) |
| --- | ---: | ---: |
| 書き込みの完了で次へ進む | 582 | 7,973 |
| 毎回 fsync の完了まで待つ | 548 | 574 |

書き込みの完了だけを待つと、`writeback` は約 14 倍になりました。librbd がデータをキャッシュに受け取った時点でゲストに返せるためです。
毎回 fsync すると、どちらも 500 台です。`writeback` でも、そのたびに Ceph まで書き出すのを待ちます。
同じ試験で `unsafe` は 5,837 IOPS でした。これはゲストが永続化を求めても QEMU が flush を無視した結果です。

### RBD では、並行して書くと writeback の利点が小さくなる

次に、1 MiB ずつ連続して計 4 GiB を書き、同時に何件の要求を出せるか (キュー深さ) を変えました。
ここで比べるのは 1 秒に書けたデータ量です。

| 1 MiB の連続書き込み | `none` (MB/s) | `writeback` (MB/s) |
| --- | ---: | ---: |
| 1 件ずつ | 169 | 1,091 |
| 最大 16 件を並行 | 758 | 1,408 |

1 件ずつでは `writeback` が約 6 倍速く、最大 16 件では約 1.9 倍でした。
並行して要求を出すと、`none` でも先の書き込みが終わるのを待たずに次を出せるためです。
同じ 16 件の条件で、書き込みごとに flush を待つ `writethrough` は 478 MB/s、`directsync` は 503 MB/s でした。

### 同じ範囲を読み返すと、ローカル SSD で差が出る

読み取りにもキャッシュが効くかを調べるため、16 MiB の範囲を 4 KiB ずつランダムに読み、同じ範囲で 20 回繰り返しました。

| 読み返したディスク | `none` (IOPS) | `writeback` (IOPS) |
| --- | ---: | ---: |
| Ceph RBD | 2,496 | 2,503 |
| ローカル SATA SSD | 4,960 | 29,735 |

RBD では差がほとんどありません。librbd の既定の `writearound` は読み取りをキャッシュから返さないためです。
ローカル SSD の `writeback` では、先に読んだデータをホストのページキャッシュから返せるので、約 6 倍になりました。
同じくページキャッシュを通る `writethrough` と `unsafe` も、それぞれ 31,581 IOPS、27,225 IOPS でした。

全 5 モードの各回の値と fio の条件は、[計測データの一覧](https://github.com/negineri/zenn-docs/tree/main/data/proxmox-ve-disk-cache-modes#fio-の結果) にまとめています。

### ローカル SSD では、書き込みが終わったあとも fsync が待たされる

同じ SSD に 1 MiB ずつ最大 16 件並行で書くと、`none` は 517 MB/s、`writeback` は 3,600 MB/s でした。
SSD 自体の書き込み速度は約 500 MB/s です。ゲストに完了が返ったとき、データはどこにあるのでしょうか。

そこで `writeback` で 12 GiB を一気に書き、ホストのメモリのうち書き出しを待っている量 (`/proc/meminfo` の `Dirty`) を 1 秒ごとに記録しました。
ゲストでは約 3.5 GB/s で書き終わりましたが、その直後、ホストの `Dirty` は約 12 GiB に達していました。
qemu の使用メモリ (RSS) は約 1 GB のままで、データはホストのページキャッシュに溜まっていました。

そこから `Dirty` は毎秒約 0.5 GB ずつ減り、約 25 秒でほぼ元の水準に戻りました。
この書き出しと重なるように、書き込みごとに fsync する負荷を 30 秒かけると、175 IOPS でした。
90 秒空けて同じ負荷をかけると 1,127 IOPS です。ゲストが短時間で大量に書けても、その直後に永続化を求める処理には、先に溜めた分の待ち時間が残ります。

ホストの `vm.dirty_ratio` の既定値は 20 % で、251 GB のホストなら約 50 GB まで溜まり得ます。
筆者は最初、ホストの起動ディスクと同じ SSD にある `local-lvm` で同じ試験をして、ホストを止めてしまいました。
大量の書き出しでルートのファイルシステムが待たされ、HA の watchdog が切れてノードが再起動 (fencing) されたためです。
ローカルの `writeback` を試すなら、ホストの起動ディスクとは別のディスクで行い、`Dirty` を見ながら進めることを勧めます。

## 安全性を試す

`writeback` は「速いが、電源断でデータが消える」と言われることがあります。
ゲストが fsync したデータは残るはずなので、実際に試しました。

### 試し方

RBD のディスクに ext4 を作り、ゲストで次のことを続けます。

- 4 KiB ほどのレコードに連番とチェックサムを付けてファイルに追記し、1 件ごとに fsync する
- fsync が返るたびに、その連番を SSH で外のマシンに送る (外のマシンが「保存済み」と受け取った番号を覚えておく)
- 同時に、別のファイルに 50 MB/s でランダムに書き込み、キャッシュに未書き出しのデータがある状態にする

20〜60 秒たったところで、ホストで qemu を `kill -9` で止めます。
VM を起動し直し、ファイルを先頭から検査して、受け取った最後の番号までのレコードがそろっているかを見ました。

RBD では、librbd のキャッシュは qemu のプロセスの中にあります。
qemu を止めると、キャッシュの中身はホストの電源断と同じく消えます。
ローカルのディスクではキャッシュがホストのページキャッシュにあり、qemu を止めても消えないので、この方法では試せません。

### 結果

| `cache=` | 回数 | fsync が返ったデータを失った回数 |
| --- | --- | --- |
| `none` | 5 | 0 |
| `writethrough` | 5 | 0 |
| `writeback` | 10 | 0 |
| `directsync` | 5 | 0 |
| `unsafe` | 5 | 2 |

`writeback` と `unsafe` では、レコードの検査後に `e2fsck` で ext4 の整合性も調べました。

- `writeback` でも、fsync が返ったデータは 10 回とも残っていた。flush で librbd のキャッシュが書き出されてから fsync が返るためである
- `unsafe` は 5 回のうち 2 回で、fsync が返った最後の 1〜2 件を失った。flush を無視するので当然の結果である。`e2fsck` では、どの回もファイルシステムは壊れていなかった
- fsync していないデータは、どのモードでも消えることがある。これは物理のディスクでも同じである

## RBD で writeback を使うとき

### 「安全」の意味

RBD の `writeback` は、揮発性の書き込みキャッシュを持つ物理のディスクと同じ約束をします。

- flush (fsync) が返ったデータは、qemu やホストが落ちても消えない
- flush の前に書いたデータは、落ちたときに消えることがある。量はディスク 1 本あたり最大 24 MiB (`rbd_cache_max_dirty`) である
- 消えるときに、書いた順番は守られない。後に書いたものだけが残ることもある

今のファイルシステム (ext4、XFS、ZFS など) は、ジャーナルの順番を守るために flush を送ります。
データベースも、コミットのたびに fsync します。
こうしたゲストにとって、`writeback` の RBD は書き込みキャッシュ付きの SSD と変わりません。
Ceph のドキュメントも、QEMU で librbd のキャッシュを使うときは `cache=writeback` にするよう書いています。

### 速くなる負荷

速くなるのは、書き込みのたびには fsync しない負荷です。

- ファイルのコピー、パッケージのインストール、ビルド、ログの書き出しなど。ゲストのページキャッシュからの書き出しは、fsync を待たずに次々と出る
- ZFS のように、まとめて書いてから最後に flush する作り
- キュー深さの浅い書き込み。上の計測では、ランダム書き込みのキュー深さ 1 が 14 倍、連続書き込みのキュー深さ 1 が 6 倍になった。キュー深さが深いと差は縮む (連続書き込みのキュー深さ 16 で約 1.9 倍)

速くならないのは、次の負荷です。

- 書き込みのたびに fsync する負荷。データベースのコミットの待ち時間は変わらない
- 読み取り。librbd は既定で読み取りをキャッシュから返さない

速くならない負荷でも遅くなるわけではないので、迷ったら `writeback` にしてよいでしょう。

### 使わない方がよいとき

- ゲストやアプリケーションが flush を止めているとき。ext4 の `nobarrier`、PostgreSQL の `fsync = off`、MySQL の `innodb_flush_log_at_trx_commit = 0` などである。`none` なら書き込みが返った時点で Ceph に届いているが、`writeback` では最大 24 MiB が順番も守られずに消え得る。ファイルシステムが壊れることもある
- 1 本の RBD を複数の VM につなぐとき (GFS2 や OCFS2 などのクラスタファイルシステム)。librbd のキャッシュは VM ごとに別々で、ほかの VM の書き込みを知らない。Ceph のドキュメントも、この使い方ではキャッシュを無効にするよう書いている

flush をまったく送らない古いゲストは、`rbd_cache_writethrough_until_flush` によって書き込みごとに Ceph まで書かれます。
データは失われませんが、速くもなりません。

### 変え方

```bash
qm set <VMID> --scsi1 <ストレージ>:<ディスク>,cache=writeback
```

キャッシュモードは qemu の起動時に決まるので、変えた後は Proxmox VE から VM を止めて起動し直します。
ゲストの中で再起動しても、qemu は同じプロセスのままなので変わりません。

## 選び方

| ディスク | 勧めるモード | 理由 |
| --- | --- | --- |
| Ceph RBD | `writeback` | 書き込みが速く、fsync したデータは失われない。ただし、flush を止めたゲストや、複数の VM で共有するディスクには使わない |
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
