---
title: "Proxmox VE で Ubuntu cloud image が固定 IP を無視して DHCP で起動する問題と修正版イメージの配布"
emoji: "💿"
type: "tech"
topics: ["proxmox", "ubuntu", "cloudinit", "linux"]
published: true
---

## はじめに

Proxmox VE では、VM の `ipconfig0` で固定 IP を指定できます。
cloud-init の network-config として渡され、ゲスト側でネットワーク設定に反映される仕組みです。
しかし Ubuntu 26.04 の cloud image では、固定 IP を指定しても DHCP のアドレスで起動する場合があります。
本記事では、この問題が発生する仕組みと、修正版イメージをビルドして配布する運用を説明します。
対象のバージョンで確認した組み合わせは、cloud-init 26.1、netplan 1.2、dracut 110 です。

## 問題が発生する仕組み

起動の順序を追うと、問題は3段階で発生します。

第1段階では、initramfs 内の systemd-networkd が NIC を先に上げます。
Ubuntu 26.04 の initramfs は dracut で構成され、その中の systemd-networkd が NIC を `ens18` として認識します。
dracut のデフォルト設定により、この段階で DHCP のアドレスを取得します。

第2段階では、実ルートの cloud-init が netplan の設定を生成します。
Proxmox が渡す NoCloud の network-config には、`set-name: eth0` と固定 IP が含まれています。
cloud-init は、この内容から netplan の設定ファイルを生成します。
生成される systemd-networkd 向けの設定は、MAC アドレスに加えて `Name=eth0` への一致を要求します。

第3段階で、NIC のリネームが失敗します。
NIC は `ens18` として使用中のため、`eth0` へリネームできません。
ログには、リネームの失敗を示すエラーが残ります。
その結果、生成された固定 IP の設定はどの NIC にも一致しません。
NIC には initramfs が取得した DHCP の設定が残り、そのまま起動が完了します。

重要なのは、Proxmox 側の設定も cloud-init の設定生成も正しい点です。
network-config と netplan のファイルを確認すると、固定 IP は正しく反映されています。
問題は、初期の NIC 名と、後から生成される設定が要求する名前の不一致です。
この問題は上流の cloud-init でも既知の問題として報告されています。
initramfs の動的アドレスを、NIC 名の変更ができない理由とみなさない修正が提案されています。
ただし、確認した時点ではその修正は未マージです。

## 修正の方針は initramfs で NIC を上げないことにする

修正の目的は、cloud-init がリネームできる状態で NIC を渡すことです。
採用した方法は、initramfs 内の systemd-networkd を mask することです。
具体的には、GRUB の設定に次の2つの引数を追加します。

- `rd.systemd.mask=systemd-networkd.service` を追加する
- `rd.systemd.mask=systemd-networkd.socket` を追加する

`rd.systemd.mask=` は initramfs 内でのみ有効な引数です。
実ルートの systemd には影響しないため、起動後のネットワーク設定は通常どおり行われます。
initramfs が NIC を上げなければ、NIC は実ルートが設定するまで未使用のままになります。
そのため、cloud-init が生成した設定どおりに `eth0` へリネームできます。
この挙動は、従来の Ubuntu の cloud image と同じです。
制約として、ルートファイルシステムがネットワーク上にある構成では使えません。
iSCSI や NFS から起動する構成では、initramfs のネットワーク自体が必要なためです。
ローカルディスクから起動する VM だけを対象とする場合は、この制約は問題になりません。

## 選ばなかった修正方法

検討した方法は、ほかに3つあります。

1つ目は、cloud-init の修正をバックポートしたパッケージをイメージに入れる方法です。
根本的な修正に近いですが、cloud-init のバージョンに固定されます。
上流の更新のたびに追従が必要になり、日次ビルドへの追跡と相性が悪いです。
GRUB の引数による方法は、イメージの中身のバージョンに依存しません。

2つ目は、dracut の network モジュールを initramfs から外す方法です。
この方法では initramfs の作り直しが必要になります。
ネットワークブートに関係するモジュールまで巻き込むおそれもあります。
mask の方法は、引数を削除すれば元の状態に戻せます。

3つ目は、Proxmox 側の network-config を変える方法です。
MAC アドレスだけで一致させ、リネームを要求しない設定に変える方法が考えられます。
しかし Proxmox が生成する設定は VM ごとに変わらないため、共有モジュールのデフォルトを全 VM 分変更することになります。
不具合があるのは Ubuntu 26.04 のイメージ側であるため、修正する場所もイメージ側に統一します。

## 修正版イメージのビルド

修正は、イメージを起動せずに `virt-customize` で行います。
加工の内容は次の3点です。

- GRUB の設定ファイルに mask の引数を追加し、`update-grub` を実行する
- `qemu-guest-agent` をインストールする
- `/etc/machine-id` を空に戻す

`qemu-guest-agent` を入れる理由は、初回起動の直後から agent を有効にするためです。
user-data の cloud-init でもインストールできますが、その場合は初回起動時のパッケージ取得に依存します。
イメージに入れておけば、Proxmox の IP 表示や正常終了の処理が初回起動から使えます。
agent の起動は、パッケージの udev ルールが virtio ポートの出現を検出して行います。
unit の `[Install]` セクションは空で、`systemctl enable` による有効化は行いません。

`machine-id` を空に戻すのは、`virt-customize` が加工時に ID を書き込むためです。
そのまま配布すると、すべてのクローンが同じ ID になります。
DHCP のクライアント ID まで重なるため、配布前に必ず空に戻します。
上流のイメージは、もともと空の状態で出荷されています。

加工の後は、イメージを起動せずに `guestfish` で検証します。
検証する項目は次の3点です。

- `grub.cfg` に mask の引数が入っている
- `qemu-guest-agent` のバイナリと udev ルールがある
- `machine-id` が空である

加工の内容を変更した場合は、ビルドスクリプトの `PATCH_VERSION` を上げます。
公開済みのイメージでも、記録された `patch_version` が古ければ作り直して差し替えます。
これにより、上流の日次ビルドを待たずに加工の変更を反映できます。

## 配布の運用

ビルドは systemd の timer で6時間ごとに実行します。
処理の流れは次のとおりです。

- 上流のサイトから最新のイメージを取得する
- 上流の `SHA256SUMS` と照合する
- `virt-customize` で加工し、`guestfish` で検証する
- 別のディレクトリで作成し、rename で公開する

失敗した場合は、公開中のイメージがそのまま残ります。
公開するファイルは、Proxmox が使う amd64 系の `.img` と `.manifest` だけに絞ります。
全形式を配布すると、1世代で約25 GB になるためです。
保持する世代は直近3世代で、1世代は約1.7 GB です。
チェックサムは加工後の値で `SHA256SUMS` を作り直します。
加工したイメージは上流の署名済みハッシュと一致しないため、署名ファイルは置きません。
代わりに、上流の `SHA256SUMS` を別の名前で併置し、加工前の値を確認できるようにします。
加工内容と上流の取得日時は、専用の JSON ファイルに記録します。

配布先では nginx が静的ファイルを返します。
イメージは800 MB 級の大きさになるため、Range 要求への対応が必要です。
nginx の静的配信は Range 要求に応答するので、取得が途中で切れても続きから再開できます。
Proxmox への取り込みは Terraform の `proxmox_download_file` で行います。
ファイル名は上流版と区別できる名前にし、既存の VM が使う従来イメージの経路には触りません。
上流で修正がマージされ、修正済みのイメージが配布されるようになれば、GRUB の加工は不要になります。
その場合は、上流の追跡と配布だけが残ります。

## まとめ

要点は次の4点です。

- 問題の原因は、initramfs が NIC を先に上げることによる名前の不一致である
- Proxmox の設定と cloud-init の設定生成は、どちらも正しく行われている
- 修正は、initramfs 内の systemd-networkd を GRUB の引数で mask して行う
- 修正版イメージは、検証後に差し替える形で配布し、世代を絞って保持する

固定 IP が効かない場合は、まずゲスト内の設定ファイルを確認することが有効です。
設定が正しく生成されているのに DHCP になる場合は、本記事のような起動順序の問題を疑う対象にできます。
