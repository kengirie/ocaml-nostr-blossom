# Azure VM で `ocaml-nostr-blossom` を動かす（Azure Files 統合版）

このドキュメントは、Ubuntu ベースの Azure VM を用意し、**Azure Files をデータストレージとして使用**しながら Blossom HTTP サーバー（`bin/main.exe`）を運用するまでの手順をまとめたものです。

## 目次
1. [アーキテクチャ概要](#1-アーキテクチャ概要)
2. [前提条件](#2-前提条件)
3. [Azure リソースのプロビジョニング](#3-azure-リソースのプロビジョニング)
4. [Azure Files の設定](#4-azure-files-の設定)
5. [VM への Azure Files マウント](#5-vm-への-azure-files-マウント)
6. [OCaml 環境セットアップ](#6-ocaml-環境セットアップ)
7. [Blossom サーバーの設定と起動](#7-blossom-サーバーの設定と起動)
8. [systemd による常駐化](#8-systemd-による常駐化)
9. [運用とメンテナンス](#9-運用とメンテナンス)
10. [トラブルシューティング](#10-トラブルシューティング)

---

## 1. アーキテクチャ概要

```
┌─────────────────────────────────────────────────────────────┐
│                      Azure Cloud                            │
│  ┌─────────────────┐      ┌─────────────────────────────┐  │
│  │   Azure VM      │      │    Azure Storage Account    │  │
│  │  (Ubuntu 22.04) │      │                             │  │
│  │                 │ SMB  │  ┌───────────────────────┐  │  │
│  │  Blossom Server │◄────►│  │    Azure Files        │  │  │
│  │                 │      │  │  /blossom-data        │  │  │
│  │  /mnt/blossom/  │      │  │  ├── blossom.db       │  │  │
│  │   data/         │      │  │  └── <sha256-blobs>   │  │  │
│  └─────────────────┘      │  └───────────────────────┘  │  │
│                           └─────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### なぜ Azure Files を使うのか？

| 特徴 | メリット |
|------|----------|
| **永続性** | VM を再作成してもデータが保持される |
| **スケーラビリティ** | 最大 100 TiB まで拡張可能 |
| **冗長性** | LRS/ZRS/GRS から選択可能 |
| **バックアップ** | Azure Backup との統合が容易 |
| **共有アクセス** | 複数 VM からの同時アクセス可能（将来の拡張性） |

---

## 2. 前提条件

- 有効な Azure サブスクリプション
- `az` CLI がインストール済みで `az login` 完了
- ローカルに SSH クライアントがインストール済み

```bash
# Azure CLI バージョン確認
az --version

# ログイン状態確認
az account show
```

---

## 3. Azure リソースのプロビジョニング

### 3.1 リソースグループの作成

```bash
# 変数設定
RESOURCE_GROUP="blossom-rg"
LOCATION="japaneast"

# リソースグループ作成
az group create \
  --name $RESOURCE_GROUP \
  --location $LOCATION
```

### 3.2 ストレージアカウントの作成

```bash
# ストレージアカウント名（グローバルで一意である必要がある）
STORAGE_ACCOUNT="blossomdata$(date +%s | tail -c 6)"

# ストレージアカウント作成
az storage account create \
  --name $STORAGE_ACCOUNT \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --sku Standard_LRS \
  --kind StorageV2 \
  --https-only true \
  --min-tls-version TLS1_2

# アカウントキーを取得
STORAGE_KEY=$(az storage account keys list \
  --account-name $STORAGE_ACCOUNT \
  --resource-group $RESOURCE_GROUP \
  --query "[0].value" -o tsv)

echo "Storage Account: $STORAGE_ACCOUNT"
echo "Storage Key: $STORAGE_KEY"
```

### 3.3 Azure Files 共有の作成

```bash
FILE_SHARE="blossom-data"

# ファイル共有作成（100 GiB クォータ）
az storage share create \
  --name $FILE_SHARE \
  --account-name $STORAGE_ACCOUNT \
  --account-key $STORAGE_KEY \
  --quota 100
```

### 3.4 VM の作成

```bash
VM_NAME="blossom-vm"
ADMIN_USER="azureuser"

# VM 作成
az vm create \
  --resource-group $RESOURCE_GROUP \
  --name $VM_NAME \
  --image Ubuntu2204 \
  --size Standard_B2s \
  --admin-username $ADMIN_USER \
  --generate-ssh-keys \
  --public-ip-sku Standard

# 必要なポートを開放
az vm open-port --resource-group $RESOURCE_GROUP --name $VM_NAME --port 22 --priority 1001
az vm open-port --resource-group $RESOURCE_GROUP --name $VM_NAME --port 8082 --priority 1002

# パブリック IP を取得
PUBLIC_IP=$(az vm show -d -g $RESOURCE_GROUP -n $VM_NAME -o tsv --query publicIps)
echo "VM Public IP: $PUBLIC_IP"
```

---

## 4. Azure Files の設定

### 4.1 接続情報の確認

Azure Portal または CLI で接続情報を取得します。

```bash
# 接続文字列の表示
echo "=== Azure Files 接続情報 ==="
echo "ストレージアカウント: $STORAGE_ACCOUNT"
echo "ファイル共有名: $FILE_SHARE"
echo "SMB パス: //$STORAGE_ACCOUNT.file.core.windows.net/$FILE_SHARE"
echo "ユーザー名: $STORAGE_ACCOUNT"
echo "パスワード: $STORAGE_KEY"
```

---

## 5. VM への Azure Files マウント

SSH で VM に接続します。

```bash
ssh $ADMIN_USER@$PUBLIC_IP
```

### 5.1 必要パッケージのインストール

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y cifs-utils
```

### 5.2 資格情報ファイルの作成

```bash
# 資格情報ディレクトリ作成
sudo mkdir -p /etc/smbcredentials

# 資格情報ファイル作成（以下の値は実際の値に置き換える）
sudo bash -c 'cat > /etc/smbcredentials/blossomdata.cred << EOF
username=<ストレージアカウント名>
password=<ストレージアカウントキー>
EOF'

# パーミッション設定（root のみ読み取り可能）
sudo chmod 600 /etc/smbcredentials/blossomdata.cred
```

### 5.3 マウントポイントの作成

```bash
sudo mkdir -p /mnt/blossom/data
sudo chown -R $USER:$USER /mnt/blossom
```

### 5.4 fstab への追加（永続マウント）

```bash
# fstab エントリを追加
# <ストレージアカウント名> と <ファイル共有名> は実際の値に置き換える
sudo bash -c 'cat >> /etc/fstab << EOF
//<ストレージアカウント名>.file.core.windows.net/<ファイル共有名> /mnt/blossom/data cifs _netdev,nofail,credentials=/etc/smbcredentials/blossomdata.cred,dir_mode=0755,file_mode=0644,serverino,nosharesock,actimeo=30,mfsymlinks 0 0
EOF'

# マウント実行
sudo mount -a

# マウント確認
df -h /mnt/blossom/data
```

### 5.5 マウントオプションの説明

| オプション | 説明 |
|-----------|------|
| `_netdev` | ネットワークが利用可能になってからマウント |
| `nofail` | マウント失敗時も起動を続行 |
| `credentials` | 資格情報ファイルのパス |
| `dir_mode=0755` | ディレクトリのパーミッション |
| `file_mode=0644` | ファイルのパーミッション |
| `serverino` | サーバー側の inode 番号を使用 |
| `nosharesock` | 各マウントで独立したソケットを使用 |
| `actimeo=30` | 属性キャッシュのタイムアウト（秒） |
| `mfsymlinks` | シンボリックリンクのサポート |

---

## 6. OCaml 環境セットアップ

### 6.1 ビルド依存パッケージのインストール

```bash
sudo apt install -y \
  git \
  build-essential \
  pkg-config \
  libgmp-dev \
  libev-dev \
  libssl-dev \
  m4 \
  opam
```

### 6.2 opam の初期化

```bash
# opam 初期化
opam init --disable-sandboxing -y

# OCaml 5.1.1 スイッチ作成
opam switch create 5.1.1 || opam switch set 5.1.1
eval "$(opam env)"

# ~/.bashrc に追加
echo 'eval "$(opam env)"' >> ~/.bashrc
```

### 6.3 プロジェクトのクローンとビルド

```bash
cd ~
git clone https://github.com/<your-repo>/ocaml-nostr-blossom.git
cd ocaml-nostr-blossom

# 依存パッケージインストール
opam install . --deps-only -y

# ビルド
dune build

# テスト実行（推奨）
dune runtest
```

---

## 7. Blossom サーバーの設定と起動

### 7.1 データディレクトリのシンボリックリンク作成

Blossom サーバーは `./data/` ディレクトリを使用するため、Azure Files マウントポイントへのシンボリックリンクを作成します。

```bash
cd ~/ocaml-nostr-blossom

# 既存の data ディレクトリがあれば退避
[ -d data ] && mv data data.backup

# Azure Files へのシンボリックリンク作成
ln -s /mnt/blossom/data data

# 確認
ls -la data/
```

### 7.2 TLS 証明書の準備

**開発/テスト用（自己署名証明書）**:
```bash
# 自己署名証明書生成
openssl req -x509 -newkey rsa:4096 \
  -keyout key.pem -out cert.pem \
  -days 365 -nodes \
  -subj "/CN=blossom.local"
```

**本番用（Let's Encrypt）**:
```bash
# certbot インストール
sudo apt install -y certbot

# 証明書取得（HTTP チャレンジ用にポート 80 を一時的に開放）
sudo certbot certonly --standalone -d your-domain.com

# 証明書パス
# /etc/letsencrypt/live/your-domain.com/fullchain.pem
# /etc/letsencrypt/live/your-domain.com/privkey.pem
```

### 7.3 手動起動テスト

```bash
cd ~/ocaml-nostr-blossom

opam exec -- dune exec bin/main.exe -- \
  --port 8082 \
  --cert cert.pem \
  --key key.pem
```

別ターミナルから確認:
```bash
curl -k https://localhost:8082/
```

---

## 8. systemd による常駐化

### 8.1 サービスファイルの作成

```bash
sudo bash -c 'cat > /etc/systemd/system/blossom.service << EOF
[Unit]
Description=OCaml Blossom Server - Nostr File Storage
Documentation=https://github.com/<your-repo>/ocaml-nostr-blossom
After=network-online.target mnt-blossom-data.mount
Wants=network-online.target
Requires=mnt-blossom-data.mount

[Service]
Type=simple
User=azureuser
Group=azureuser
WorkingDirectory=/home/azureuser/ocaml-nostr-blossom
Environment="HOME=/home/azureuser"
Environment="OPAMSWITCH=5.1.1"

# opam 環境を読み込んでサーバー起動
ExecStart=/bin/bash -lc "eval \$(opam env) && dune exec bin/main.exe -- --port 8082 --cert /home/azureuser/ocaml-nostr-blossom/cert.pem --key /home/azureuser/ocaml-nostr-blossom/key.pem"

# 再起動設定
Restart=on-failure
RestartSec=10

# リソース制限
LimitNOFILE=65536

# セキュリティ設定
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/mnt/blossom/data

[Install]
WantedBy=multi-user.target
EOF'
```

### 8.2 サービスの有効化と起動

```bash
# systemd リロード
sudo systemctl daemon-reload

# サービス有効化（起動時に自動開始）
sudo systemctl enable blossom.service

# サービス起動
sudo systemctl start blossom.service

# ステータス確認
sudo systemctl status blossom.service
```

### 8.3 ログ監視

```bash
# リアルタイムログ
journalctl -u blossom.service -f

# 最新 100 行
journalctl -u blossom.service -n 100

# エラーのみ
journalctl -u blossom.service -p err
```

---

## 9. 運用とメンテナンス

### 9.1 Azure Files の監視

```bash
# ディスク使用量確認
df -h /mnt/blossom/data

# ファイル数確認
find /mnt/blossom/data -type f | wc -l
```

Azure Portal でも監視可能:
- **Storage Account** → **Metrics** → File Capacity / Transactions

### 9.2 ストレージアカウントキーのローテーション

セキュリティのため、定期的にキーをローテーションします。

```bash
# 新しいキーを生成（key2 を再生成）
az storage account keys renew \
  --account-name $STORAGE_ACCOUNT \
  --resource-group $RESOURCE_GROUP \
  --key key2

# 新しいキーを取得
NEW_KEY=$(az storage account keys list \
  --account-name $STORAGE_ACCOUNT \
  --resource-group $RESOURCE_GROUP \
  --query "[1].value" -o tsv)

# 資格情報ファイル更新
sudo bash -c "cat > /etc/smbcredentials/blossomdata.cred << EOF
username=$STORAGE_ACCOUNT
password=$NEW_KEY
EOF"

# マウントを再実行
sudo umount /mnt/blossom/data
sudo mount -a
```

### 9.3 バックアップ

**Azure Backup を使用**:
```bash
# Recovery Services Vault 作成
az backup vault create \
  --resource-group $RESOURCE_GROUP \
  --name blossom-backup-vault \
  --location $LOCATION

# バックアップポリシー設定（Azure Portal で GUI 操作推奨）
```

**手動スナップショット**:
```bash
az storage share snapshot \
  --name $FILE_SHARE \
  --account-name $STORAGE_ACCOUNT \
  --account-key $STORAGE_KEY
```

### 9.4 パフォーマンスチューニング

大量のファイルを扱う場合の推奨設定:

| 設定項目 | 推奨値 | 説明 |
|---------|--------|------|
| VM サイズ | Standard_D2s_v3 以上 | 高負荷時 |
| Storage SKU | Premium_LRS | 低レイテンシ |
| actimeo | 30-60 | キャッシュ時間調整 |

---

## 10. トラブルシューティング

### 10.1 Azure Files がマウントできない

```bash
# ポート 445 の疎通確認
nc -zv <storage-account>.file.core.windows.net 445

# マウントを手動で試行
sudo mount -t cifs \
  //<storage-account>.file.core.windows.net/<share> \
  /mnt/blossom/data \
  -o credentials=/etc/smbcredentials/blossomdata.cred,vers=3.0

# dmesg でエラー確認
dmesg | tail -20
```

**よくある原因**:
- NSG でポート 445 がブロックされている
- 資格情報ファイルのパーミッションが間違っている
- ストレージアカウントキーが古い

### 10.2 Blossom サーバーが起動しない

```bash
# 詳細ログ確認
journalctl -u blossom.service -n 50 --no-pager

# 手動起動で確認
cd ~/ocaml-nostr-blossom
opam exec -- dune exec bin/main.exe -- --port 8082

# data ディレクトリの権限確認
ls -la /mnt/blossom/data
```

### 10.3 パフォーマンス問題

```bash
# I/O 統計
iostat -x 1 5

# ネットワーク統計
sar -n DEV 1 5

# Azure Files のレイテンシ確認（Azure Portal）
# Storage Account → Metrics → Success E2E Latency
```

---

## クイックスタートスクリプト

以下のスクリプトで一括セットアップが可能です（VM 内で実行）:

```bash
#!/bin/bash
set -e

# 変数（実際の値に置き換える）
STORAGE_ACCOUNT="your-storage-account"
STORAGE_KEY="your-storage-key"
FILE_SHARE="blossom-data"
GITHUB_REPO="https://github.com/<your-repo>/ocaml-nostr-blossom.git"

echo "=== 1. パッケージインストール ==="
sudo apt update && sudo apt upgrade -y
sudo apt install -y cifs-utils git build-essential pkg-config \
  libgmp-dev libev-dev libssl-dev m4 opam

echo "=== 2. Azure Files マウント ==="
sudo mkdir -p /etc/smbcredentials /mnt/blossom/data
echo "username=$STORAGE_ACCOUNT" | sudo tee /etc/smbcredentials/blossom.cred
echo "password=$STORAGE_KEY" | sudo tee -a /etc/smbcredentials/blossom.cred
sudo chmod 600 /etc/smbcredentials/blossom.cred

echo "//$STORAGE_ACCOUNT.file.core.windows.net/$FILE_SHARE /mnt/blossom/data cifs _netdev,nofail,credentials=/etc/smbcredentials/blossom.cred,dir_mode=0755,file_mode=0644,serverino,nosharesock,actimeo=30 0 0" | sudo tee -a /etc/fstab
sudo mount -a

echo "=== 3. OCaml セットアップ ==="
opam init --disable-sandboxing -y
opam switch create 5.1.1 || opam switch set 5.1.1
eval "$(opam env)"
echo 'eval "$(opam env)"' >> ~/.bashrc

echo "=== 4. プロジェクトビルド ==="
cd ~
git clone $GITHUB_REPO
cd ocaml-nostr-blossom
opam install . --deps-only -y
dune build

# data ディレクトリを Azure Files にリンク
[ -d data ] && mv data data.backup
ln -s /mnt/blossom/data data

echo "=== セットアップ完了 ==="
echo "次のコマンドでサーバーを起動:"
echo "  opam exec -- dune exec bin/main.exe -- --port 8082"
```

---

## 参考リンク

- [Mount SMB Azure File Share on Linux | Microsoft Learn](https://learn.microsoft.com/en-us/azure/storage/files/storage-how-to-use-files-linux)
- [Azure VM ベストプラクティス | Microsoft Learn](https://learn.microsoft.com/en-us/azure/well-architected/service-guides/virtual-machines)
- [systemd サービスの作成 | DigitalOcean](https://www.digitalocean.com/community/tutorials/how-to-configure-a-linux-service-to-start-automatically-after-a-crash-or-reboot-part-1-practical-examples)
- [Azure Storage セキュリティガイド](https://learn.microsoft.com/en-us/azure/storage/common/storage-security-guide)
