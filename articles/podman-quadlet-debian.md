---
title: "Debian 13 で使う Podman Quadlet — Docker Compose との対応と移行手順"
emoji: "📦"
type: "tech"
topics: ["podman", "quadlet", "debian", "docker", "systemd"]
published: true
---

## はじめに

本記事は、Docker の利用者、および Docker Compose の利用経験がある人を対象に、Podman の Quadlet の使い方を説明します。対象 OS は Debian 13 です。

Podman には多くの機能がありますが、本記事で扱うのは Quadlet のみです。イメージのビルド、Kubernetes 連携、Podman Machine については扱いません。

Quadlet は、コンテナの定義を systemd のユニットファイルに近い形式で書き、systemd に起動と停止を管理させる仕組みです。定義ファイルは systemd の generator が読み取り、`.service` ファイルを生成します。ファイルの読み取りは、OS の起動時と `systemctl daemon-reload` の実行時に行われます。

Docker Compose との違いは次の2点です。

- 定義の置き方：Docker Compose は `compose.yaml` の1ファイルに複数のサービスを書く。Quadlet はコンテナごとにファイルを分ける。
- 操作の方法：Docker Compose にはプロジェクト単位の操作コマンド（`docker compose up`、`down`、`ps`、`logs`）がある。Quadlet には相当するコマンドがなく、操作は `systemctl` と `journalctl` で行う。

## Debian 13 への Podman のインストール

Debian 13 のパッケージでインストールします。

```bash
sudo apt update
sudo apt install podman
```

Debian 13 に収録されている Podman のバージョンは 5.4.2 です。確認は次のとおりです。

```bash
podman --version
podman info --format '{{.Host.CgroupsVersion}}'
```

Quadlet の利用には cgroup v2 が必要です。Debian 13 の標準設定では cgroup v2 が使われます。上記の2行目で `v2` と表示されることを確認してください。

一般の利用者でコンテナを実行する（rootless）場合は、追加のパッケージが必要です。

```bash
sudo apt install uidmap passt dbus-user-session
```

注意点が1つあります。Podman のバージョンは、Debian のリリース期間中はセキュリティ修正を除いて変わりません。そのため、Podman の公式サイトにある最新版向けのドキュメントには、Debian 13 の Podman では使えない Quadlet のキーが含まれている場合があります。キーの確認は、手元の man ページを優先してください。

```bash
man podman-systemd.unit
```

## Docker Compose との対応

Docker Compose の定義項目と、Quadlet の対応する指定は次のとおりです。

| Docker Compose | Quadlet | 備考 |
| --- | --- | --- |
| `services` の各サービス | `.container` ファイル1件 | サービスごとにファイルが分かれる |
| `image` | `Image` | 必須のキーはこれだけである |
| `container_name` | `ContainerName` | 省略時は `systemd-` の後にファイル名が続いた名前になる |
| `command` | `Exec` | |
| `entrypoint` | `Entrypoint` | |
| `ports` | `PublishPort` | |
| `expose` | `ExposeHostPort` | |
| `environment` | `Environment` | 複数指定できる |
| `env_file` | `EnvironmentFile` | |
| `volumes`（名前付きボリューム） | `Volume` と `.volume` ファイル | ボリュームの定義が別ファイルになる |
| `volumes`（ホスト側のパス） | `Volume` | パスをそのまま書く |
| `networks` | `Network` と `.network` ファイル | ネットワークの定義が別ファイルになる |
| `depends_on`（順序のみ） | `[Unit]` セクションの `After`、`Requires` | 起動順の指定である |
| `depends_on` の `condition: service_healthy` | 対応する指定はない | 後述する |
| `restart` | `[Service]` セクションの `Restart` | 値の体系は systemd のものを使う |
| `healthcheck` | `HealthCmd`、`HealthInterval` など | |
| `user` | `User` | |
| `working_dir` | `WorkingDir` | |
| `secrets` | `Secret` | 秘密情報の作成は `podman secret create` で別途行う |
| `build` | `.build` ファイル | 本記事では扱わない |

`restart` の値は Docker Compose と systemd で異なります。Docker Compose の `always` と `unless-stopped` に相当する動作は、systemd ではどちらも `Restart=always` で指定します。`on-failure` はどちらの体系にもあります。

## 実習で使う Docker Compose の定義

以降の実習では、次の Docker Compose の定義を Quadlet に書き換えます。サービスは `web` と `api` の2つです。`api` は、HTTP リクエストの内容をそのまま返す `traefik/whoami` のイメージを使います。

```yaml
services:
  web:
    image: docker.io/library/nginx:alpine
    container_name: web
    ports:
      - "8080:80"
    volumes:
      - site-html:/usr/share/nginx/html
    depends_on:
      - api
    restart: always
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1/"]
      interval: 30s
    networks:
      - app
  api:
    image: docker.io/traefik/whoami:latest
    container_name: api
    environment:
      TZ: Asia/Tokyo
    networks:
      - app

volumes:
  site-html:

networks:
  app:
```

実習は root のシステムサービスとして実行します。ファイルの配置先は `/etc/containers/systemd/` で、操作は `systemctl`（`--user` なし）で行います。一般の利用者で実行する場合との違いは、最後のセクションにまとめます。

## 実習1：単一のコンテナ

まず `web` だけを Quadlet で動かします。

ホスト側に、公開する HTML を置くディレクトリを用意します。

```bash
sudo mkdir -p /srv/example/html
printf 'example\n' | sudo tee /srv/example/html/index.html
```

`/etc/containers/systemd/web.container` を次の内容で作成します。

```ini
[Unit]
Description=nginx (web)

[Container]
Image=docker.io/library/nginx:alpine
ContainerName=web
PublishPort=8080:80
Volume=/srv/example/html:/usr/share/nginx/html:ro
HealthCmd=wget -q -O /dev/null http://127.0.0.1/
HealthInterval=30s

[Service]
Restart=always

[Install]
WantedBy=multi-user.target
```

セクションの役割は次のとおりです。

- `[Container]`：コンテナの定義である。Quadlet が処理する。必須のキーは `Image` だけである。
- `[Unit]`、`[Service]`、`[Install]`：通常の systemd ユニットファイルと同じである。そのまま systemd に渡される。

定義を読み取り、サービスを起動します。ファイル名 `web.container` から、サービス名は `web.service` になります。

```bash
sudo systemctl daemon-reload
sudo systemctl start web.service
sudo systemctl status web.service
```

起動には `systemctl enable` を使いません。Quadlet が生成したユニットは生成ユニットであり、`systemctl enable` を実行するとエラーになります。OS の起動時に自動で起動するかどうかは `[Install]` セクションで指定し、`daemon-reload` の時点で有効になります。

動作を確認します。

```bash
curl http://127.0.0.1:8080/
sudo podman ps
sudo podman inspect --format '{{.State.Health.Status}}' web
```

`curl` で `example` と表示され、ヘルスチェックの状態が `healthy` になれば、単一のコンテナの移行は完了です。

なお、設定ファイルの文法に誤りがあると、`daemon-reload` の際にサービスが生成されず、`systemctl status` で「ユニットが見つからない」という表示になります。その場合は、generator を直接実行して誤りの内容を確認できます。

```bash
sudo /usr/lib/systemd/system-generators/podman-system-generator -dryrun
```

## 実習2：ネットワークとボリューム

次に `api` を追加し、ネットワークとボリュームを定義ファイルに分けます。

### ネットワーク

`/etc/containers/systemd/example.network` を作成します。

```ini
[Network]
NetworkName=example
```

両方の `.container` ファイルに、次の1行を追加します。

```ini
Network=example.network
```

`.network` ファイルは、`.container` ファイルから参照された場合にだけ読み取られます。参照したネットワークの作成と起動は、コンテナのサービスに依存関係として自動で追加されます。Docker Compose では、ネットワークは `up` の実行時に自動で作成されます。Quadlet では、定義を明示的に書く点が異なります。

### ボリューム

実習1ではホスト側のパスをそのままマウントしました。ここでは名前付きボリュームに置き換えます。`/etc/containers/systemd/site-html.volume` を作成します。

```ini
[Volume]
VolumeName=site-html
```

`web.container` の `Volume` の行を、次のように書き換えます。

```ini
Volume=site-html.volume:/usr/share/nginx/html
```

ボリュームは、`site-html-volume.service` の起動時に作成されます。参照しているコンテナの起動時にも、依存関係として自動で起動します。内容を入れるために、作成後にファイルを書き込みます。

```bash
sudo systemctl daemon-reload
sudo systemctl start site-html-volume.service
sudo podman run --rm --entrypoint sh -v site-html:/html docker.io/library/nginx:alpine -c 'printf "example\n" > /html/index.html'
```

Docker Compose では、名前付きボリュームは定義に名前を書くだけで作成されます。Quadlet では `.volume` ファイルが定義の実体になります。

### api の追加

`/etc/containers/systemd/api.container` を作成します。

```ini
[Unit]
Description=whoami (api)

[Container]
Image=docker.io/traefik/whoami:latest
ContainerName=api
Environment=TZ=Asia/Tokyo
Network=example.network

[Service]
Restart=always

[Install]
WantedBy=multi-user.target
```

`api` には `PublishPort` を指定していないため、ホスト側からは接続できません。同じネットワークに接続した `web` からは、コンテナ名 `api` で名前解決できます。

```bash
sudo systemctl daemon-reload
sudo systemctl start api.service
sudo systemctl restart web.service
sudo podman exec web wget -q -O - http://api/
```

`whoami` の出力（リクエストヘッダーなど）が表示されれば、ネットワーク経由の通信ができています。

環境変数は、ファイルに分けることもできます。その場合は `Environment` の代わりに `EnvironmentFile=/etc/example/api.env` と書き、`/etc/example/api.env` に `TZ=Asia/Tokyo` の形式で変数を書きます。Docker Compose の `.env` ファイルとは扱いが異なり、後述のとおり自動では読み込まれません。

## 実習3：複数のコンテナと依存関係

Docker Compose の `depends_on` は、Quadlet では `[Unit]` セクションの指定に書き換えます。`web.container` の `[Unit]` セクションを、次のように変更します。

```ini
[Unit]
Description=nginx (web)
After=api.service
Requires=api.service
```

意味は次のとおりです。

- `After`：`api.service` の後に `web.service` を起動する、という順序の指定である。
- `Requires`：`api.service` を一緒に起動する、という依存の指定である。`api.service` が停止すると `web.service` も停止する。

変更後は `daemon-reload` を実行し、`web.service` を再起動して確認します。

```bash
sudo systemctl daemon-reload
sudo systemctl restart web.service
systemctl status api.service web.service
```

### 対応しない指定：service_healthy

Docker Compose の `depends_on` には、`condition: service_healthy` を指定して、依存先のヘルスチェックが成功するまで起動を待つことができます。Quadlet には対応する指定がありません。`After` と `Requires` で指定できるのは起動の順序と依存関係だけであり、依存先の準備が完了したかどうかは判定しません。

依存先の準備完了を待つ必要がある場合は、接続する側のアプリケーションで再試行するか、ヘルスチェックの結果を確認する別の仕組みを組み合わせる必要があります。本記事の実習の範囲では、順序の指定のみを行います。

### Pod によるまとめ方

複数のコンテナを1つの単位としてまとめる場合は、`.pod` ファイルを使います。Pod に属するコンテナは、ネットワーク名前空間を共有します。ポートの公開とネットワークの指定は、コンテナ側ではなく Pod 側に書きます。

`/etc/containers/systemd/example.pod` の例です。

```ini
[Pod]
PodName=example
PublishPort=8080:80
Network=example.network
```

この方式を使う場合は、各 `.container` ファイルに `Pod=example.pod` を追加し、コンテナ側の `PublishPort` と `Network` は削除します。Docker Compose のプロジェクトとは異なり、Pod はあくまでネットワーク名前空間を共有するための単位であり、まとめて操作するための単位ではありません。

## Docker Compose に対応しない機能

移行にあたって、Quadlet に対応する機能がないものは次のとおりです。

- プロジェクト単位の操作コマンド：`docker compose up`、`down`、`ps`、`logs` に相当する一括操作はない。起動と停止は `systemctl`、ログの確認は `journalctl` で、サービスごとに行う。
- ネットワークとボリュームの自動削除：`docker compose down` に相当する処理はない。不要になったネットワークとボリュームは、`podman network rm`、`podman volume rm` で明示的に削除する。
- 定義の重ね合わせ：`compose.yaml` と `compose.override.yaml` のような、複数の定義ファイルを重ねる仕組みはない。
- `profiles`：サービスをグループ化して選択的に起動する指定はない。対象のサービスを個別に `systemctl` で操作する。
- `scale`：同じサービスを複数起動する指定はない。
- `.env` ファイルの自動読み込みと変数展開：`compose.yaml` と同じディレクトリにある `.env` を自動で読む動作はない。また、定義ファイル内で `${変数名}` の形式で変数を展開する仕組みも、Docker Compose と同じ形では使えない。環境変数は `Environment` か `EnvironmentFile` で渡す。
- ビルドと起動の一括実行：`docker compose up --build` に相当する操作はない。イメージの用意と、サービスの起動は別の手順になる。

## 運用

### ログの確認

ログは journald に記録されます。

```bash
sudo journalctl -u web.service
sudo journalctl -u web.service -f
```

Docker Compose の `docker compose logs` と異なり、サービスをまたいだログの表示は `journalctl` の指定で行います。たとえば `sudo journalctl -u web.service -u api.service` とすれば、2つのサービスのログを合わせて表示できます。

### イメージの更新

`.container` ファイルの `[Container]` セクションに `AutoUpdate=registry` を追加すると、そのコンテナは `podman auto-update` の対象になります。定期実行には timer が用意されています。

```bash
sudo systemctl enable --now podman-auto-update.timer
sudo systemctl list-timers podman-auto-update.timer
```

手動で更新する場合は次のとおりです。更新があったサービスは再起動されます。

```bash
sudo podman auto-update
```

タグを指定したイメージ（`nginx:alpine` など）を使う場合、更新の対象はそのタグの最新版です。バージョンを固定したい場合は、タグにバージョン番号まで含めて指定してください。

### 設定の変更と削除

Quadlet のファイルを変更した場合は、`daemon-reload` の後にサービスの再起動が必要です。

```bash
sudo systemctl daemon-reload
sudo systemctl restart web.service
```

サービスを削除する場合は、サービスを停止し、ファイルを削除してから `daemon-reload` を実行します。`[Install]` セクションによる自動起動は `systemctl disable` では解除できません。generator が `daemon-reload` のたびにリンクを作り直すためです。ファイルの削除が、無効化を兼ねます。

```bash
sudo systemctl stop web.service
sudo rm /etc/containers/systemd/web.container
sudo systemctl daemon-reload
```

## 一般の利用者で実行する場合（rootless）

本記事の実習は root のシステムサービスとして実行しました。一般の利用者で実行する場合は、次の点が異なります。

| 項目 | root（システムサービス） | 一般の利用者（rootless） |
| --- | --- | --- |
| ファイルの配置先 | `/etc/containers/systemd/` | `~/.config/containers/systemd/` |
| 操作コマンド | `systemctl` | `systemctl --user` |
| ログの確認 | `journalctl -u` | `journalctl --user -u` |
| 自動起動の指定 | `[Install] WantedBy=multi-user.target` | `[Install] WantedBy=default.target` |
| ログアウト後の継続 | 対象外（常時動く） | `loginctl enable-linger <利用者名>` が必要 |

ログアウト後もコンテナを動かし続けるには、linger の有効化が必要です。有効化されていない場合、最後のセッションが終了すると利用者の systemd インスタンスが終了し、コンテナも停止します。

```bash
sudo loginctl enable-linger <利用者名>
loginctl show-user <利用者名> | grep Linger
```

また、rootless の場合は、標準設定では1024未満のポート番号を公開できません。本記事の実習で8080番を使ったのは、この制限を避けるためでもあります。

## まとめ

- Docker Compose の `services` は、Quadlet では `.container` ファイルに分かれる。ネットワークとボリュームも、それぞれ `.network` ファイルと `.volume` ファイルに分かれる。
- 起動順と依存関係は、systemd の `[Unit]` セクションで指定する。ただし、依存先の準備完了を待つ `service_healthy` に対応する指定はない。
- 操作は `systemctl` と `journalctl` で行う。プロジェクト単位の一括操作コマンドはない。
- Debian 13 では、Podman のバージョンがリリース期間中は変わらないため、ドキュメントは手元の man ページ（`man podman-systemd.unit`）を優先して確認する。

## 参考

- `man podman-systemd.unit`（Debian 13 の Podman 5.4.2 に付属）
- Podman ドキュメント：podman-systemd.unit（Quadlet のキーの一覧）
- Docker Compose のドキュメント：Compose file reference
