# FANEL

自律進化型ローカル開発オーケストレーター。Claude Code・Hayabusa（ローカルLLM）・Codexを統合し、タスクの複雑度に応じてAIを自動選択。繰り返しタスクはスクリプト化してAI不使用で即実行。アイドル時はシステムが自律的に改善サイクルを回す。Mac / Apple Silicon専用。

## アーキテクチャ

```
タスク入力
  │
  ├─ Layer 0: ToolBox検索 → ヒット → スクリプト即実行（AI不使用・最速）
  │
  ├─ Council: Claude + Codex 並列分析 → 合意 / 逆質問
  │
  ├─ Layer 1: 小型モデル（2GB以下）  ── Hayabusa ── コ��ト0
  ├─ Layer 2: 中型モデル（2-8GB）    ── Hayabusa ── コスト0
  ├─ Layer 3: 大型モデル（8-40GB）   ── Hayabusa ── コスト0
  ├─ Layer 4: Claude Code            ── フォールバック
  │
  ├─ 完了後: パターン2回以上 → ToolBox自動登録
  │
  └─ アイドル時: 自律改善サイクル
       ├─ モデルベンチマーク
       ├─ スクリプト自動生成
       ├─ コード改善提案
       └─ Git自動push（安全ポリシー準拠）
```

## 必要環境

- macOS 13+ / Apple Silicon
- Swift 5.9+
- Claude Code（Anthropic Max プラン）
- Hayabusa（オプション・ローカルLLM推論エンジン）
- Tailscale（オプション・2拠点運用）
- Codex CLI（オプション・`npm install -g @openai/codex`）

## インストール

```bash
git clone https://github.com/karma-oss/fanel.git
cd fanel
swift build
```

## 起動

```bash
swift run FANEL
```

メニューバーに「FANEL」が表示され、Vaporサーバーがポート7384で自動起動します。

- 指令室: http://localhost:7384 または http://fanel.local:7384
- `/etc/hosts` に `127.0.0.1 fanel.local` を追加すると `fanel.local` でアク��ス可能

### 環境変数

| 変数 | 説明 | デフォルト |
|------|------|-----------|
| `FANEL_IDLE_SECONDS` | アイドル判定���数 | 300（5分） |

## Phase別機能

| Phase | 機能 | 概要 |
|-------|------|------|
| 0 | Claude Code制御 | Processクラスでサブプロセス起動・JSON抽出 |
| 1 | Vaporサーバー + 指令室 | メニューバーアプリ・ブラウザUI・mDNS |
| 2 | Claude Code統合 | 指令室チャット→Claude Code→結果表示 |
| 3 | Council（参謀会議） | Claude + Codex並列分析・2者合意・逆質問 |
| 4 | Hayabusa + Worker Pool | 4層モデル選択・ローカルLLM・自動フォールバック |
| 5 | ToolBox | スクリプト蓄積・ベクトル検索・AI不使用実行 |
| 6 | Tailscale 2拠点運用 | オーナー制・MagicDNS・ピア同期 |
| 7 | アイドル自律進化 | モデルベンチ・スクリプト生成・Git push |

## APIエンドポイント（28本）

<details>
<summary>一覧</summary>

| メソッド | パス | 概要 |
|----------|------|------|
| GET | / | 指令室HTML |
| GET | /api/status | サーバー状態 |
| GET | /api/projects | プロジェクト一覧 |
| POST | /api/tasks | タスク送信 |
| GET | /api/tasks | タスク履歴 |
| POST | /api/tasks/:id/answer | 逆質問への回答 |
| GET | /api/logs | ログ一覧 |
| GET | /api/models | モデル一覧 |
| POST | /api/models/:id/enable | モデル有効化 |
| POST | /api/models/:id/disable | モデル無効化 |
| POST | /api/models/:id/benchmark | ベンチマーク実行 |
| GET | /api/toolbox | ToolBoxエントリ一覧 |
| POST | /api/toolbox | 手動登録 |
| DELETE | /api/toolbox/:id | 削除 |
| POST | /api/toolbox/:id/execute | 手動実行 |
| GET | /api/progress | 進捗サマリー |
| GET | /api/idle/status | アイドル状態 |
| GET | /api/idle/history | アイドル履歴 |
| POST | /api/idle/suspend | アイドル停止 |
| POST | /api/idle/resume | アイドル再開 |
| GET | /api/ownership | オーナー状態 |
| POST | /api/ownership/acquire | オーナー取得 |
| POST | /api/ownership/release | オーナー解放 |
| GET | /api/peers | ピア一覧 |
| GET | /api/sync/status | 同期状態 |

</details>

## ファイル構成（26ファイル）

```
Sources/FANEL/
├── FANELApp.swift              # メニューバーアプリ (@main)
��── FANELError.swift            # エラー定義
├── VaporServerManager.swift    # Vaporサーバー管理
├── Routes.swift                # 全APIルート定義
├── ClaudeProcessManager.swift  # Claude Codeプロセス制御
├── LooseJSONParser.swift       # JSON抽出パーサー
├── TaskEnvelope.swift          # タスクデータ構造
├── TaskStore.swift             # タスク状態管理
├── TaskOrchestrator.swift      # Layer 0→Council→WorkerPoolフロー
├── LogStore.swift              # ログ保持
├── CouncilResult.swift         # Council型定義（進捗トラッキング含む）
��── CouncilManager.swift        # Claude+Codex並列分析・合意判定
├── HayabusaClient.swift        # Hayabusa通信クライアント
├── ModelRegistry.swift         # モデル管理・ベンチマーク
├── WorkerPool.swift            # 4層Worker選択・実行
├── ToolBoxEntry.swift          # ToolBoxエントリ型
├── ToolBoxStore.swift          # エントリ管理・永続化・実行
├── ToolBoxManager.swift        # ToolBox統合管理・自動登録
├── EmbeddingEngine.swift       # TF-IDFベクトル化・類似検索
├── TailscaleManager.swift      # Tailscale接続管理
├── OwnershipManager.swift      # オーナー制管理
├── PeerSyncManager.swift       # ピア同期・Git push
├── IdleDetector.swift          # アイドル検知
├��─ IdleTaskScheduler.swift     # アイドルタスクスケジューラ
├── IdleTaskRunner.swift        # アイドルタスク実���
├── CommandRoomHTML.swift        # HTML読み込み
└── Resources/CommandRoom.html  # 指令室フロントエンド
```

## ライセンス

MIT License
