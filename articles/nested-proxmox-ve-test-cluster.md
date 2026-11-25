---
title: "Proxmox VE の上の VM に Proxmox VE を建てて、クラスターの変更を試す"
emoji: "🪆"
type: "tech"
topics: ["proxmox", "ceph", "corosync", "debian", "cloudinit"]
published: false
---

<!-- cspell:ignore Dpkg EFI EPYC LXC Rome SIGPIPE UEFI VMID alpine amd64 arm64 cfg cloudinit configfile confold corosync debconf dpkg efi fe80 grub iface ifup ifupdown2 keyrings knet networkd noninteractive nvram pipefail pveam pveceph pvecm pvesh tmpl trixie -->

## 本番のクラスターを触る前に、使い捨てのクラスターで試す

corosync のリンクを足す、全ノードに exporter を入れる、といった Proxmox VE のクラスター全体に効く変更は、本番でいきなり試したくありません。
筆者の環境では、本番の Proxmox VE の上に Debian の cloud image で使い捨ての VM (以下 test-vm) を建てられるようにしています。
この test-vm に Proxmox VE を入れれば、クラスターごと試せます。

Debian 13 の cloud image に Proxmox VE 9 を入れ、3 台のクラスターと 1 台の Ceph を組んだときに、つまずいた点をまとめます。

| 項目 | 内容 |
| --- | --- |
| 外側 | Proxmox VE 9.2 |
| test-vm | Debian 13 (trixie) の cloud image、4 コア、メモリ 12 GB、ディスク 48 GB + 32 GB |
| 中に入れたもの | pve-manager 9.2 |

## Proxmox VE を入れる

### /etc/hosts は cloud-init のテンプレートで直す

Proxmox VE は、ホスト名が自分の IP アドレスに解決されることを前提にしています。
Debian の cloud image は、ホスト名を `127.0.1.1` に向けています。
`/etc/hosts` を直しても、cloud-init が起動のたびに書き戻します。
cloud-init のユーザーデータで `manage_etc_hosts` を指定していると、`/etc/cloud/cloud.cfg.d/` の設定より優先されます。

確実なのは、cloud-init が使うテンプレートの方を直すことです。

```bash
sed -i 's/^127.0.1.1 {{fqdn}} {{hostname}}/<自分の IP> {{fqdn}} {{hostname}}/' \
  /etc/cloud/templates/hosts.debian.tmpl
```

これを忘れると、pve-cluster が起動しません。

### リポジトリを足して入れる

```bash
curl -fsSL -o /usr/share/keyrings/proxmox-archive-keyring.gpg \
  https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg
cat > /etc/apt/sources.list.d/pve.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::=--force-confold \
  pve-manager ifupdown2 grub-efi-amd64
```

`grub-efi-amd64` を一緒に入れているのは、次の問題を避けるためです。

### grub が入らない、起動しない

`pve-manager` は Proxmox のカーネル (`proxmox-default-kernel`) を連れてきます。
このとき `grub-pc` も入り、インストール先のディスク (`grub-pc/install_devices`) が空のままなので、dpkg がエラーで止まります。
先に debconf で、インストール先を指定しておきます。

```bash
echo "grub-pc grub-pc/install_devices multiselect /dev/disk/by-id/<起動ディスク>" \
  | debconf-set-selections
```

これで入っても、cloud image は UEFI で起動するので、再起動すると `grub>` のプロンプトで止まることがあります。
EFI システムパーティションの `EFI/BOOT` に grub の設定が無いためです。
`grub-efi-amd64` を入れたうえで、取り外し可能なメディアの形でも grub を書いておきます。

```bash
grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable --no-nvram
```

止まってしまったら、外側のホストからシリアルコンソール (`/var/run/qemu-server/<VMID>.serial0`) につなぎ、手で設定を読み込ませて起動できます。

```text
grub> configfile (hd0,gpt1)/boot/grub/grub.cfg
```

### ネットワーク

Proxmox VE は ifupdown2 の `/etc/network/interfaces` を使いますが、cloud image のネットワークは cloud-init と systemd-networkd が管理しています。
管理用の NIC は cloud-init に任せたままにし、クラスター用に足した NIC だけを `/etc/network/interfaces` に書きました。

```text
auto lo
iface lo inet loopback

# eth0 は cloud-init (systemd-networkd) が管理する
iface eth0 inet manual

auto ens19
iface ens19 inet static
    address 192.168.100.1/24
```

入れた直後は `/run/network` が無く、`ifup` が「Another instance」と言って何もしないことがあります。
ディレクトリを作るか、再起動してから上げます。

## クラスターを組む

### 全ノードの名前を hosts に書く

ほかのノードの名前が hosts に無いと、名前が IPv6 のリンクローカルアドレスに解決されることがあります。
そうなると、`pvecm add` が `ip address show to fe80::...` で失敗します。

全ノードの名前と IP を、`/etc/hosts` と cloud-init のテンプレートの両方に書きます。
片方だけだと、再起動で消えます。
筆者は、テンプレートの `127.0.1.1` の行をコメントにし、cloud-init が hosts を触らないようにしました。

```bash
sed -i 's/^127.0.1.1 {{fqdn}} {{hostname}}/# &/' /etc/cloud/templates/hosts.debian.tmpl
echo "manage_etc_hosts: false" > /etc/cloud/cloud.cfg.d/99-keep-hosts.cfg
```

参加は、対話の要らない `pvesh create /cluster/config/join` で行いました。

### 試した例: corosync のリンクを足す

本番の corosync はリンク (ring) が 1 本だけでした。
2 本目を足す前に、test-vm の 3 台で同じスクリプトと手順を試しました。

| 何を | 結果 |
| --- | --- |
| 動いたまま 2 本目のリンクを足す | 3 台とも link 0 / 1 が connected。quorum は保たれ、優先度の高い link 0 が使われた |
| ノード 2 の link 0 の NIC を外側から切る (`qm set <VMID> --net1 ...,link_down=1`) | 1 秒以内に link 1 に移った。メンバーシップは変わらず、quorum は 3 票のまま |
| link 0 を戻す | link 0 に戻った |

本番ではリンクを切る試験ができない (管理ネットワークを止めることになる) ので、この試験で代えました。
外側から NIC を切れるのは、入れ子にした利点です。

## Ceph と、中で動かすゲスト

### 1 台の Ceph はプールのサイズを 1 にする

exporter を試すため、1 台に Ceph も入れました。
OSD は test-vm に足した 2 本目のディスク 1 本です。

`pveceph fs create` は、レプリカ 3 のプールを作ります。
OSD が 1 本だと配置できず、CephFS が使えるようになりません。
全プールの `size` と `min_size` を 1 にしてから、CephFS をストレージに足しました。

Ceph は既定でサイズ 1 のプールを許さないので、先に許可します。

```bash
ceph config set global mon_allow_pool_size_one true
for p in $(ceph osd pool ls); do
  ceph osd pool set $p size 1 --yes-i-really-mean-it
  ceph osd pool set $p min_size 1
done
```

なお、`yes | pveceph install` は、`set -o pipefail` の下では成功しても失敗扱いになります。`pveceph` が終わった後に `yes` が SIGPIPE で終わり、0 以外の終了コードを返すためです。

### 入れ子の KVM が無ければ LXC を使う

外側の VM の CPU の型によっては、入れ子の仮想化 (VMX / SVM) が見えません。
筆者の環境 (EPYC-Rome-v4 の CPU 型) もそうだったので、中のゲストは LXC にしました。

`pveam available` は arm64 のテンプレートを先に並べることがあります。
`amd64` を選ばないと、コンテナが起動しません。

長くかかる処理は `systemd-run --unit <名前>` で test-vm の中で動かしました。
ただし、`ceph` や `lxc` のような名前は既存のユニットと重なるので、別の名前にします。

## まとめ

- Debian 13 の cloud image に pve-manager を入れれば、test-vm を Proxmox VE のノードにできる
- つまずきやすいのは、cloud-init が書き戻す `/etc/hosts`、grub-pc のインストール先、UEFI の起動、ifupdown2 と cloud-init の住み分け
- クラスターを組むときは、全ノードの名前を hosts と cloud-init のテンプレートの両方に書く
- 外側から NIC を切れるので、本番ではできない障害の試験ができる
- 1 台の Ceph はプールのサイズを 1 にする。入れ子の KVM が無ければ、中のゲストは LXC にする
