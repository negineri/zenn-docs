---
title: "Ceph RBD の上の Samba ファイルサーバーにどのファイルシステムを選ぶか"
emoji: "🗂️"
type: "tech"
topics: ["samba", "zfs", "btrfs", "ceph", "proxmox"]
published: false
---

<!-- cspell:ignore Btrfs CephFS DKMS NTACL acltype ashift atime catia fdatasync localtime noatime pgbench posixacl recordsize snapdir snapper vdev writeback xattr -->

## ファイル履歴と ACL が要るなら ZFS

Proxmox VE の Ceph RBD の上に、Samba のファイルサーバーの VM を置いています。
このファイルサーバーに求めているのは、次の 2 つです。

- ファイル履歴: Windows のエクスプローラーの「以前のバージョン」から、過去のファイルを取り出せる
- ACL: Windows から付けたアクセス権をそのまま保てる

この 2 つを満たすファイルシステムを、機能と、同じ RBD の上での実測で比べました。
結論は次のとおりです。

| ファイルシステム | ファイル履歴 | 拡張属性の上限 | 新しいファイルの保存 (fsync あり) | 大きいファイルの一部書き換え |
| --- | --- | --- | ---: | ---: |
| ZFS | スナップショットをそのまま見せられる | 64 KiB | 501〜516 個/s | 2,022 IOPS |
| Btrfs | スナップショットをそのまま見せられる | 16 KiB 未満 | 161〜163 個/s | 16,584 IOPS |
| ext4 | LVM thin などの別の仕組みが要る | 4 KiB 未満 (既定) | 342〜356 個/s | 29,081 IOPS |

ファイル共有でよくある「新しいファイルを作って保存する」書き込みは ZFS が最も速く、拡張属性の上限も十分です。
ZFS が大きく負けるのは大きいファイルの一部書き換えで、ファイル共有では当たりにくい負荷です。

計測の詳細とデータは、別の記事「[Ceph RBD の上の VM で ZFS は ext4 より速いのか](https://zenn.dev/negineri/articles/zfs-vs-ext4-on-ceph-rbd)」と [GitHub](https://github.com/negineri/zenn-docs/tree/main/data/zfs-vs-ext4-on-ceph-rbd) にあります。

## Samba がファイルシステムに求めるもの

### ファイル履歴

Samba は、ファイルシステムのスナップショットを「以前のバージョン」として見せられます。

| VFS モジュール | 使うスナップショット |
| --- | --- |
| `shadow_copy2` | 決まった名前の形式でディレクトリに並んだスナップショット (ZFS の `.zfs/snapshot`、Btrfs の snapper など) |
| `vfs_snapper` | Btrfs と snapper のスナップショット |
| `vfs_ceph_snapshots` | CephFS のスナップショット |

スナップショットを一瞬で作れて、数が増えても困らないことが大事です。
筆者の環境では、15 分ごと 4、毎時 24、毎日 31、毎週 8、毎月 12 の計 79 世代を残しています。

### ACL と拡張属性

Windows の ACL は POSIX ACL に収まりきらないので、`acl_xattr` で拡張属性 (`security.NTACL`) にそのまま保存するのが確実です。
Windows の代替データストリームは `streams_xattr`、macOS のメタデータは `fruit` が、やはり拡張属性に保存します。
そのため、拡張属性をどこまで大きく書けるかが効いてきます。

1 つの拡張属性に書ける大きさを確かめました。

| ファイルシステム | 4 KiB | 16 KiB | 60 KiB | 70 KiB |
| --- | --- | --- | --- | --- |
| ext4 (既定) | 書けない | 書けない | 書けない | 書けない |
| ext4 (`ea_inode` 付き) | 書ける | 書ける | 書ける | 書けない |
| XFS | 書ける | 書ける | 書ける | 書けない |
| Btrfs | 書ける | 書けない | 書けない | 書けない |
| ZFS (`xattr=sa`) | 書ける | 書ける | 書ける | 書けない |

Linux はどのファイルシステムでも 64 KiB までに制限しています。
ext4 は既定のままだと 4 KiB 未満、Btrfs は 16 KiB 未満で失敗しました。
大きな ACL や代替データストリームを書くと、これらでは保存に失敗することがあります。

## 候補

| 候補 | ファイル履歴の見せ方 | 気になる点 |
| --- | --- | --- |
| ZFS | `shadow_copy2` で `.zfs/snapshot` を見せる | DKMS のカーネルモジュールが要る。RBD の上では一部書き換えやランダム読み取りが遅い |
| Btrfs | snapper と `vfs_snapper` (または `shadow_copy2`) | 拡張属性の上限が小さい。fsync を伴う書き込みが遅い (後述) |
| ext4 / XFS + LVM thin | スナップショットごとにマウントして `shadow_copy2` で見せる | 79 世代をマウントして並べるのは運用が重い。最初の書き込みのたびにコピーが起き、遅くなる |
| CephFS | `vfs_ceph_snapshots` | RBD と ZFS を重ねずに済む。代わりにファイルサーバーに Ceph の鍵とネットワークを渡す必要があり、MDS に依存する |

ext4 / XFS と CephFS は、今回は測っていません。
以下では、ZFS と Btrfs に、比較のための ext4 を加えて比べます。

## 実測

構成は Proxmox VE 9.2、Ceph 20.2 (SATA SSD の OSD が 12 本、イレイジャーコーディング 2+1)、ゲストは Ubuntu 26.04 です。
VM のデータ用ディスクは 64 GiB の RBD で、`cache=writeback` にしています。
ZFS は ashift 9、recordsize 128K、lz4、`xattr=sa`、atime=off、Btrfs は既定値に noatime です。

### Samba で起きやすい負荷

Samba は、クライアントから「データをディスクに書き出してほしい」という flush の要求が来ると、それに従ってファイルシステムに書き出させます。
これを決める `strict sync` は、Samba 4.7.0 から既定が `yes` になりました ([smb.conf の説明](https://github.com/samba-team/samba/blob/master/docs-xml/smbdotconf/tuning/strictsync.xml))。
クライアントが flush を送るかどうかはアプリによりますが、保存のたびに fsync が起きる前提で比べておくのが安全です。

| 負荷 | ext4 | Btrfs | ZFS |
| --- | ---: | ---: | ---: |
| 64 KiB のファイルを 1 個ずつ作り、ファイルとディレクトリを fsync (個/s、2 巡) | 342 / 356 | 161 / 163 | 501 / 516 |
| 4 KiB のファイルを 20000 個作り、最後に sync (個/s) | 21,053 | 15,152 | 22,472 |
| 上の小さいファイルを冷えた状態で全部読む (個/s) | 1,465 | 1,473 | 1,185 |
| 8 GiB のファイルを連続で書く (MB/s) | 869 | 871 | 819 |
| 8 GiB のファイルを冷えた状態で連続で読む (MB/s) | 379 | 695 | 581 |

新しいファイルを作って fsync する負荷で、ZFS は ext4 の約 1.4 倍、Btrfs の約 3 倍でした。
1 個あたり RBD に出た I/O は、ZFS と ext4 が書き込み 2 回と flush 1 回、Btrfs は書き込み 18.6 回と flush 2 回です。
RBD はネットワークの先にあるので、往復の回数がそのまま速さに効きます。

連続読み取りの ext4 は、ブロックデバイスの先読みを既定の 128 KiB から 4 MiB に上げると 811 MB/s まで伸びます。

### ファイル共有では当たりにくい負荷

| 負荷 | ext4 | Btrfs | ZFS |
| --- | ---: | ---: | ---: |
| 大きいファイルへの 4 KiB のランダム上書き (IOPS) | 29,081 | 16,584 | 2,022 |
| 冷えたランダム 4 KiB 読み取り、16 本 (IOPS) | 27,084 | 24,299 | 8,663 |
| PostgreSQL の pgbench (tps、3 巡の中央値) | 2,124 | 991 | 1,722 |

ZFS は、4 KiB だけ読み書きしたいときも recordsize の 128 KiB を丸ごと読み直します。
大きいファイルの一部を書き換える負荷では ext4 の 1/14 でした。
VM のイメージやデータベースをファイルサーバーに置くと当たりますが、Office 文書のようにファイルごと書き直す使い方では当たりにくいはずです。

### スナップショットが 79 世代あるとき

| 負荷 | Btrfs | Btrfs (79 世代) | ZFS | ZFS (79 世代) |
| --- | ---: | ---: | ---: | ---: |
| 8 GiB のファイルを連続で書く (MB/s) | 871 | 888 | 819 | 560 |
| 大きいファイルへの 4 KiB の上書き (IOPS) | 16,584 | 16,306 | 2,022 | 2,015 |

ZFS の連続書き込みが 3 割落ちたほかは、ほとんど変わりませんでした。
ただし、8 GiB のファイルを世代ごとに少しずつ書き換えて作ったスナップショットです。
多くのファイルが入れ替わっていく実際の運用は再現していません。

## ZFS での設定

筆者の環境の `smb.conf` の要点です。
`/mnt/tank` が ZFS のデータセットで、スナップショットは `GMT-YYYY.MM.DD-HH.MM.SS` の名前で作っています。

```ini
[homes]
   path = /mnt/tank/home/%u
   inherit acls = yes
   map acl inherit = yes
   acl_xattr:ignore system acls = yes
   vfs objects = catia fruit acl_xattr streams_xattr shadow_copy2
   shadow:snapdir = /mnt/tank/.zfs/snapshot
   shadow:basedir = /mnt/tank
   shadow:sort = desc
   shadow:format = GMT-%Y.%m.%d-%H.%M.%S
   shadow:localtime = no
```

ZFS の側は `xattr=sa` にして、拡張属性を inode と一緒に保存します。
RBD の上では、vdev の同時実行数の調整も効きます ([前の記事](https://zenn.dev/negineri/articles/zfs-on-ceph-rbd-tuning))。

## まとめ

- ファイル履歴と Windows の ACL が要る Samba のファイルサーバーなら、Ceph RBD の上でも ZFS が合う
- 新しいファイルを作って fsync する書き込みは、ZFS が ext4 の約 1.4 倍、Btrfs の約 3 倍だった
- Btrfs はスナップショットでは ZFS と同等だが、fsync を伴う書き込みが遅く、拡張属性も 16 KiB 未満しか書けなかった
- ZFS が苦手なのは大きいファイルの一部書き換えとランダム読み取りで、ファイル共有では当たりにくい

## 試していないこと

- SMB 越しの実際の速さ。今回はゲストの中でファイルシステムを直接測った
- CephFS と `vfs_ceph_snapshots`、ext4 / XFS と LVM thin のスナップショット
- 多くのファイルが入れ替わっていく中で、スナップショットが増えたときの速さ
