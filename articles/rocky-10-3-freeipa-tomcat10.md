---
title: "Rocky Linux 10.3 で FreeIPA サーバーの dnf update が依存解決で止まる (tomcat9 → tomcat 10.1)"
emoji: "🐈"
type: "tech"
topics: ["rockylinux", "freeipa", "dnf", "ansible", "tomcat"]
published: false
---

自宅の FreeIPA サーバー (Rocky Linux 10.2) を Ansible で更新したところ、`dnf` の依存解決で止まりました。
原因は、Rocky Linux 10.3 で FreeIPA の CA (Dogtag PKI) が使う Tomcat が tomcat9 から tomcat 10.1 に変わったことです。
この記事では、原因の調べ方と対処、テスト用の VM で 10.2 から 10.3 への更新を確かめた手順をまとめます。

## 環境

- Rocky Linux 10.2 (更新先は 10.3)
- FreeIPA 4.13.4 (CA、統合 DNS、ACME を有効にしたサーバー 3 台)
- 更新は Ansible の `ansible.builtin.dnf` で `name: "*"`、`state: latest`

更新前のおもなパッケージは次のとおりです。

```text
ipa-server-4.13.4-1.el10_2.x86_64
idm-pki-server-11.9.0-6.el10_2.1.rocky.0.1.noarch
tomcat9-9.0.120-1.el10_2.noarch
```

## 症状

Ansible の更新タスクが `Depsolve Error occurred` で失敗します。
同じことは `dnf upgrade` を手で実行しても起きます。
エラーは 10 個の Problem に分かれて長いのですが、要点は次の部分です。

```text
Problem 1: package tomcat-lib-1:10.1.49-5.el10_2.noarch from appstream conflicts with tomcat9 provided by tomcat9-1:9.0.120-2.el10_3.noarch from appstream
  - package idm-jss-tomcat-5.9.0-4.el10.x86_64 from appstream requires mvn(org.apache.tomcat:tomcat-catalina) >= 10.1.36, but none of the providers can be installed
...
Problem 2: package tomcat9-jsp-2.3-api-1:9.0.120-2.el10_3.noarch from appstream conflicts with tomcat provided by tomcat-1:10.1.49-5.el10_2.noarch from appstream
  - package idm-pki-server-11.9.0-9.el10_3.1.rocky.0.1.noarch from appstream requires tomcat >= 1:10.1.36, but none of the providers can be installed
...
(try to add '--allowerasing' to command line to replace conflicting packages or '--skip-broken' to skip uninstallable packages or '--nobest' to use not only best candidate packages)
```

## 原因

`idm-pki-server` の要求する Tomcat が、10.2 と 10.3 で変わっています。

```console
$ rpm -q --requires idm-pki-server | grep -i tomcat     # 10.2 (インストール済み)
tomcat9 >= 1:9.0.62

$ dnf -q repoquery --requires idm-pki-server-11.9.0-9.el10_3.1.rocky.0.1 | grep -i tomcat   # 10.3
tomcat >= 1:10.1.36
```

そして tomcat 10.1 の `tomcat-lib` は tomcat9 の各パッケージと conflicts の関係にあります。

```console
$ dnf -q repoquery --conflicts tomcat-lib
tomcat9
tomcat9-el-3.0-api
tomcat9-jsp-2.3-api
tomcat9-lib
tomcat9-servlet-4.0-api
```

tomcat9 を消さないと新しい `idm-pki-server` を入れられません。
`dnf upgrade` は既定ではパッケージを消さないので、依存解決の段階で止まります。
pki が上がらないため、それに依存する `ipa-server`、`ipa-client`、`ipa-healthcheck` も巻き込まれて、エラーが 10 個の Problem に広がっていました。

止まるのは依存解決の段階なので、ホストには何も変更が入っていません。

## 対処

`--allowerasing` を付けると、tomcat9 を消して tomcat 10.1 を入れる形で解決できます。
先に `--assumeno` で、何が消えるかを確かめます。

```console
$ sudo dnf --assumeno upgrade --allowerasing
...
Installing dependencies:
 tomcat                      noarch  1:10.1.49-5.el10_2   appstream
 tomcat-el-5.0-api           noarch  1:10.1.49-5.el10_2   appstream
 tomcat-jsp-3.1-api          noarch  1:10.1.49-5.el10_2   appstream
 tomcat-lib                  noarch  1:10.1.49-5.el10_2   appstream
 tomcat-servlet-6.0-api      noarch  1:10.1.49-5.el10_2   appstream
Installing weak dependencies:
 tomcat-jakartaee-migration  noarch  1.0.6-1.el10         appstream
Removing:
 kernel-core                 x86_64  6.12.0-211.56.1.el10_2.0.1  @baseos
 ...
Removing dependent packages:
 tomcat9                     noarch  1:9.0.120-1.el10_2   @appstream
 tomcat9-el-3.0-api          noarch  1:9.0.120-1.el10_2   @appstream
 tomcat9-jsp-2.3-api         noarch  1:9.0.120-1.el10_2   @appstream
 tomcat9-lib                 noarch  1:9.0.120-1.el10_2   @appstream
 tomcat9-servlet-4.0-api     noarch  1:9.0.120-1.el10_2   @appstream
```

消えるのは tomcat9 の 5 個と、古いカーネルだけでした。
カーネルは installonly の世代数の上限による通常の整理です。

Ansible の `ansible.builtin.dnf` では `allowerasing: true` が同じ意味です。
常に有効にすると、関係の無いパッケージまで黙って消される余地ができます。
そこで、既定は `false` の変数にして、必要なときだけ `-e` で渡すようにしました。

```yaml
- name: Update all packages (dnf)
  ansible.builtin.dnf:
    name: "*"
    state: latest
    update_cache: true
    allowerasing: "{{ update_packages_dnf_allowerasing | bool }}"
```

## テスト用の VM で更新を確かめる

パッケージの依存はこれで解決できます。
ただ、本当に気になるのは、既存の CA のインスタンス (`pki-tomcat`) が tomcat 10.1 の上でそのまま動くかどうかです。
本番の IPA サーバーでいきなり試すのは避けて、使い捨ての VM で 10.2 から 10.3 への更新を再現しました。

### 10.2 の環境を作る

手元の Rocky Linux 10 の cloud image は、初回の起動で 10.3 まで上がってしまいました。
そこで vault のリポジトリを使って 10.2 に戻しました。
10.2 のリポジトリは、10.3 のリリース後は `pub` から消えて `vault` にだけ残っています。

```bash
sudo dnf config-manager --set-disabled baseos appstream extras
sudo tee /etc/yum.repos.d/vault-10.2.repo <<'EOF'
[vault102-baseos]
name=Rocky 10.2 BaseOS (vault)
baseurl=https://dl.rockylinux.org/vault/rocky/10.2/BaseOS/x86_64/os/
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-10
[vault102-appstream]
name=Rocky 10.2 AppStream (vault)
baseurl=https://dl.rockylinux.org/vault/rocky/10.2/AppStream/x86_64/os/
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-10
EOF
sudo dnf -y distro-sync --allowerasing --releasever=10.2
sudo systemctl reboot
```

`distro-sync` にも `--allowerasing` が要りました。
cloud image に入っていた samba のライブラリが 10.3 の版で、10.2 のリポジトリには対応する版が無いためです。

戻したあと、本番と同じ版の FreeIPA を入れ、CA、統合 DNS、ACME を有効にしたサーバーを架空のドメインで構築しました。

```bash
sudo dnf -y install --releasever=10.2 ipa-server ipa-server-dns ipa-healthcheck
sudo ipa-server-install -U --realm IPATEST.TEST --domain ipatest.test \
  --hostname ipa01.ipatest.test -a "$PW" -p "$PW" \
  --setup-dns --forwarder <上位のリゾルバー> --no-reverse --no-ntp
sudo ipa-acme-manage enable
```

最後に vault のリポジトリを消し、元のリポジトリを有効に戻せば、本番と同じ「10.2 の IPA サーバーで 10.3 が見えている」状態になります。

### 結果

| 何を | 結果 |
| --- | --- |
| `allowerasing` 無しで更新 | 本番と同じ Depsolve Error で失敗 (再現) |
| `allowerasing` 有りで更新 | 成功。tomcat9 が tomcat 10.1.49 に置き換わり、`ipa-server-4.13.4-1.el10_3.1`、`idm-pki-server-11.9.0-9.el10_3.1` に上がった |
| 再起動後のサービス | `ipactl status` は全サービス RUNNING、新しく failed になった systemd ユニットは無し |
| CA | pki-tomcatd が `/usr/share/tomcat` (10.1) で起動、`ipa cert-request` で証明書を発行できる |
| ACME | `https://ipa-ca.<ドメイン>/acme/directory` が応答する |
| certmonger | 追跡している 9 件がすべて MONITORING |
| `ipa-healthcheck` | ERROR、CRITICAL は無し |

RPM の `%posttrans` で走る `ipa-server-upgrade` も成功しており、`pki-server upgrade` も含めて自動で移行されました。
手で設定を直す必要はありませんでした。

## ついでに見つけた落とし穴

### ipaupgrade.log が grep でバイナリ扱いになる

更新後の検証では、`/var/log/ipaupgrade.log` の最後の結果を grep で見ていました。

```bash
grep -o 'The ipa-server-upgrade command [a-z ]*' /var/log/ipaupgrade.log | tail -n 1
```

10.3 への更新のあと、この grep は何も出力しなくなりました。

```console
$ sudo grep -o 'The ipa-server-upgrade command [a-z ]*' /var/log/ipaupgrade.log
grep: /var/log/ipaupgrade.log: binary file matches
```

`ipa-server-upgrade` が、Kerberos の鍵などのバイナリを DEBUG 行にそのまま書き込んでいたためです。
GNU grep はバイナリを含むファイルでは一致行を出さず、stderr にこのメッセージだけを出します。
stdout は空になります。
検証側は「結果の行があれば、それが成功かどうかを見る」という作りだったので、成否の判定が何も言わずに skip されていました。

`grep -a` でテキストとして読めば、一致行が出ます。

```console
$ sudo grep -a -o 'The ipa-server-upgrade command [a-z ]*' /var/log/ipaupgrade.log
The ipa-server-upgrade command was successful
```

ログを grep で見て判定するときは、`-a` を付けておくのが安全です。

### 2 コアの VM では ipa-healthcheck がタイムアウトする

検証用の VM を 2 コアで作ったところ、更新前の時点で `ipa-healthcheck` が ERROR を出しました。

```text
ERROR: pki.server.healthcheck.certs.trustflags.CASystemCertTrustFlagCheck.audit_signing: Unable to load cert from NSSDB: Request timed out
```

`/etc/ipahealthcheck/ipahealthcheck.conf` で `timeout = 60` にすると通ったので、チェックごとのタイムアウト (既定 10 秒) に間に合っていなかっただけでした。
本番と同じ 4 コアにすると、既定のタイムアウトのままで通りました。
FreeIPA の検証用 VM は、本番に近い CPU 数で作ったほうが余計な調査をせずに済みます。

## まとめ

- Rocky Linux 10.3 では、FreeIPA の CA (idm-pki) が tomcat9 から tomcat 10.1 に移った
- `tomcat-lib` が tomcat9 と conflicts するので、`dnf upgrade` には `--allowerasing` が要る
- 消えるのは tomcat9 の 5 個だけで、CA のインスタンスは更新時に自動で移行され、そのまま動いた
- vault のリポジトリで 1 つ前のマイナーリリースに戻せば、マイナーリリースの更新を手元で再現できる
- ログを grep で判定するときは `-a` を付ける
