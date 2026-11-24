---
title: "Proxmox VE にコントリビュートする実際の流れ：Bugzilla の要望からパッチ投稿まで"
emoji: "🛠️"
type: "tech"
topics: ["proxmox", "cloudinit", "oss", "debian", "git"]
published: false
---

<!-- cspell:words cloudinit cimanagehosts VMID -->

Proxmox VE が生成する cloud-init の設定には、ゲストの `/etc/hosts` を管理する `manage_etc_hosts: true` が入ります。この動作を VM ごとに無効化するパッチを書き、使い捨ての VM に Proxmox VE を入れて検証しました。

この記事では、Bugzilla の要望から変更範囲を決め、バックエンドと Web UI を別々のパッチにして、テスト VM での検証からメーリングリストへの投稿までを紹介します。パッチは投稿済みで、上流のレビューを待っています。

## Bugzilla の要望を実装条件に落とす

[Bugzilla #7100](https://bugzilla.proxmox.com/show_bug.cgi?id=7100) の要望は、カスタム user-data を用意せずに、最初の起動より前に GUI または API から `/etc/hosts` の管理を無効化できることです。コメントには、既定の動作を変えるなら既存の環境でも試す必要があるという指摘がありました。

そこで既定値は従来どおり有効にし、VM の設定に `cimanagehosts` を追加しました。値を指定しなければ `true`、`0` なら明示的に `false` を生成します。設定を削除すれば既定値に戻ります。

Proxmox は、実装前にフォーラムや開発メーリングリストで提案を議論するよう案内しています。投稿前には Bugzilla の本文とコメントに加え、開発メーリングリストのアーカイブで同じ提案や関連パッチも探します。今回、検索ドメインから生成する FQDN の修正は見つかりましたが、VM ごとに管理を無効化する同等のパッチは検索した範囲では見つかりませんでした。 [Proxmox の貢献ガイド](https://www.proxmox.com/en/about/open-source/developers) · [関連する FQDN のパッチ](https://lore.proxmox.com/pve-devel/20261116010014.88737-3-lucasbarros.kam%40gmail.com/)

## 変更をリポジトリごとに分ける

設定を保存して user-data を生成する処理は `qemu-server` にあり、Cloud-Init 画面は `pve-manager` にあります。公式 Git から両方を取得し、検証で使ったベースコミットを記録してから作業ブランチを切りました。 [Proxmox の公式 Git リポジトリ](https://git.proxmox.com/)

| リポジトリ | 変更内容 |
| --- | --- |
| `qemu-server` | 設定のスキーマ、生成する user-data、差分 API、`VM.Config.Cloudinit` による権限判定を変更しました。 |
| `pve-manager` | Cloud-Init 画面にチェックボックスを追加し、保存と削除の可否を設定しました。 |

Web UI が新しい設定を保存するには、先にバックエンドがその設定を受け付ける必要があります。検証機への導入順と、提出時のパッチ順は、どちらもバックエンドを先にしました。

## 検証用の Proxmox VE を用意する

Debian 13 の一時 VM に Proxmox VE を入れ、その中に検証用のゲストを作りました。外側の VM は Proxmox VE のホストとして使うため、Terraform の cloud-init スニペットで最初から `manage_etc_hosts: false` を渡しました。ホスト名が VM 自身の IP アドレスで解決されるよう、`/etc/hosts` も設定しました。

開発環境は公式の `README.dev` を参考にしました。`pve-test` を使い、ビルド依存関係は各リポジトリの `debian/control` に従います。Web UI の lint に必要な `proxmox-biome` は、別途 Proxmox の開発用 APT リポジトリから取得しました。 [pve-common の README.dev](https://git.proxmox.com/?p=pve-common.git;a=blob_plain;f=README.dev;hb=HEAD)

## 自動テスト、生成 ISO、ゲストを順に見る

まず、API の自動テストと Web UI の lint を実行しました。

```sh
make -C qemu-server/src/test test_api_cloudinit_dump
make -C pve-manager/www check
```

`make deb` でパッケージも作りました。`pve-manager` はビルドできましたが、`qemu-server` の全体テストでは移行・クローン関連の 5 件が失敗しました。同じ環境と固定ベースでパッチを外しても同じ 5 件が失敗したため、その結果を記録し、実機確認用のパッケージを `DEB_BUILD_OPTIONS=nocheck make deb` で作りました。

実機では、CLI の出力、生成された ISO、ゲストのファイルを順に確認しました。以下の `VMID` を検証用 VM の ID に置き換えると、設定と ISO を更新できます。

```sh
VMID=100
qm set "$VMID" --cimanagehosts 0
qm cloudinit dump "$VMID" user
qm cloudinit update "$VMID"
```

`dump` は現在の設定から生成される内容を表示します。実際の ISO が更新されたかは、NoCloud と ConfigDrive2 の ISO から user-data を取り出して確認しました。カスタム user-data を指定した場合は、その内容が引き続き使われることも確かめました。さらに、入れ子の Debian ゲストを再起動し、`false` では手書きの行が残り、`true` では cloud-init がテンプレートから `/etc/hosts` を再生成することをログとファイルの両方で確認しました。

## 実機で見つけた問題を同じ条件で再現する

初回の自動テストが通っても、実機では次の問題が残っていました。

| 確認した箇所 | 修正前 | 修正後 |
| --- | --- | --- |
| cloud-init の差分 API | `0` を未設定として扱い、`0 → 1` が反映済み、`1 → 0` が削除に見える | `0` を値として保持し、現在値と保留中の値を返す |
| Web UI の Remove | Network と Audit の権限でボタンが有効になり、押すと API が拒否する | Cloudinit の設定権限がある場合だけ有効になる |

別の検証 VM に修正前と修正後のコードを順に入れ、同じゲストと同じ権限で比較しました。差分 API には追加・適用・変更・削除を含む 5 ケースの回帰テストを追加しました。検証が終わった VM は Terraform で削除しています。

## CLA を提出する

Proxmox は、コードを貢献する前に CLA への署名を求めています。個人向けの書式に署名して案内の宛先へメールで送付し、登録されたことを返信で確認しました。パッチの `Author` と `Signed-off-by` に使う表記も、送付前に確認しました。 [Proxmox の貢献ガイドと CLA](https://www.proxmox.com/en/about/open-source/developers)

## 3 通を同じスレッドに投稿する

投稿前に、両方のパッチを公式の最新 `master` に載せ直しました。`qemu-server` では、前回失敗した 5 件に対応する上流修正が入り、API テスト 41 件がすべて通りました。Cloud-Init の回帰テストと Web UI の lint を再実行し、両パッケージの通常ビルドも成功しました。

英文カバーレターには Bugzilla の番号、設定例、既定値を維持する理由、適用順、検証結果を記載しました。AI コーディングアシスタントを使って変更を準備し、テストしたことも明記しました。カバーレターを `0/2`、`qemu-server` を `1/2`、`pve-manager` を `2/2` とし、対象リポジトリが件名から分かるようにしました。

まず `git send-email --dry-run` で宛先と順序を確認し、自分で受信できるメールアドレスへ試送しました。本送信では宛先を `pve-devel@lists.proxmox.com` にし、`--thread --no-chain-reply-to` を指定しました。これでパッチ 2 本が、どちらもカバーレターに対する返信になります。 [投稿したパッチシリーズ](https://lore.proxmox.com/pve-devel/20261124212608.12996-1-negineri@sfc.wide.ad.jp/T/)

## Bugzilla に検証結果とリンクを追記する

送付後に公開アーカイブで 3 通が同じスレッドに載ったことを確認し、Bugzilla にスレッドのリンクと検証結果を追記しました。メーリングリストにパッチが存在する段階に対応する Bugzilla のステータスは `PATCH AVAILABLE` です。現在は、上流でのレビューを待っています。 [Bugzilla #7100](https://bugzilla.proxmox.com/show_bug.cgi?id=7100) · [Proxmox スタッフによるステータスの説明](https://forum.proxmox.com/threads/general-questions-about-bugzilla-feature-requests.176005/)
