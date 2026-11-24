---
title: "Proxmox VE にコントリビュートする実際の流れ：Bugzilla の要望からパッチ提出準備まで"
emoji: "🛠️"
type: "tech"
topics: ["proxmox", "cloudinit", "oss", "debian", "git"]
published: false
---

<!-- cspell:words cloudinit cimanagehosts VMID -->

Proxmox VE が生成する cloud-init の設定には、ゲストの `/etc/hosts` を管理する `manage_etc_hosts: true` が入ります。この動作を VM ごとに無効化するパッチを書き、使い捨ての VM に Proxmox VE を入れて検証しました。

この記事では、Bugzilla の要望から変更範囲を決め、バックエンドと Web UI を別々のパッチにして、メーリングリストへの提出を準備した流れを紹介します。執筆時点では検証と修正まで完了し、上流への送信とレビューはこれからです。

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

## メーリングリストに送れる形にする

ここからは今回の提出準備で残っている手順です。

1. 両リポジトリの最新 `master` に載せ直し、差分、関連テスト、通常ビルドを確認する。
2. Proxmox の CLA の提出状況を確認し、必要なら本人が署名する。パッチの `Author` と `Signed-off-by` も確認する。
3. 英文カバーレターに Bugzilla の番号、従来の既定値を維持する理由、`cimanagehosts=0` の例、パッチの依存関係、実際に行った検証を記載する。
4. カバーレターとパッチ 2 本をひとつのシリーズにまとめ、`git send-email --dry-run` で宛先と順序を確認する。確認後、`pve-devel@lists.proxmox.com` に送付する。
5. 投稿後は Bugzilla にアーカイブへのリンクと検証結果を追記する。レビューで修正した場合は、変更点を書いて次の版を送る。

別々のリポジトリをまたぐ変更では、どちらを先に適用するかをカバーレターで伝えます。レビューする人が実機に触れなくても、どのバージョンで何を再現し、修正後にどの結果へ変わったかを読めるようにしました。 [Proxmox の貢献ガイドと CLA](https://www.proxmox.com/en/about/open-source/developers) · [開発メーリングリストの投稿例](https://lore.proxmox.com/pve-devel/20261116133238.83435-1-lucasbarros.kam%40gmail.com/)
