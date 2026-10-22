# stompws 与上游 stomp 服务端对齐对照表

> 用途：同步上游 `github.com/go-stomp/stomp/v3` 的改动时按此表定位本仓对应文件，并区分「有意差异」与「漏同步」。
> 基线：**v3.2.0**。上游的服务端 = `server/`（编排与中继）+ `server/client/`（一条连接）+ `server/{topic,queue}/`（目的地实现）。
> 自 2026-10-16 的分层改造后，两边**目录同形、依赖方向一致**，`queue.go` 与 `topic/` 已可逐字套用。

## 一、目录对照

| 上游 | 本仓 | 说明 |
|---|---|---|
| `stomp/server/` | `stompws/server/` | 同形：**目录本身就是 `package server`** |
| `stomp/server/client/` | `stompws/server/client/` | 同形 |
| `stomp/server/queue/` | `stompws/server/queue/` | `queue.go` 与上游逐字一致（仅 import 路径不同） |
| `stomp/server/topic/` | `stompws/server/topic/` | 逐字一致 |

依赖方向（两边现已相同）：`server → {client, topic, queue}`、`queue → client`、`client → 不依赖本仓任何包`。

## 二、逐文件对照

### `server/`（编排与中继）

| 上游 | 本仓 | 差异 |
|---|---|---|
| `server/server.go`（`Server`、`ListenAndServe`、`QueuePrefix`、`Authenticator` 接口） | `server/server.go`（`StompHubServer`、`With*` 选项、构造、`HandleWebSocket`、`Shutdown`、`RouteMessage`）＋ `server/hub.go`（`Hub` 实现与订阅入口） | 传输换成 WebSocket；类型名 `Server` → `StompHubServer`；配置改为选项式；多了连接数上限、单条 WS 消息上限、心跳与优雅关停 |
| `server/processor.go`（`requestProcessor`、`Listen`、`isQueueDestination`） | `server/processor.go` ＋ `server/request.go` ＋ `server/destination.go` | 职责相同；目的地判定独立成一文件（连接层与服务端共用）；多了目的地数量上限与「关停时已受理的请求必须处理完」 |
| `server/queue_storage.go`（`QueueStorage` 接口，与 `queue.Storage` 方法集相同） | 无 | 去掉了这份重复接口，直接用 `queue.Storage` |

### `server/client/`（一条连接）

| 上游 | 本仓 | 差异 |
|---|---|---|
| `client/conn.go`（`Conn` + 13 个 handler + 清理 + 读写两条循环） | `client/conn.go`（`Conn`、传输、`Serve`）＋ `client/handlers.go`（`processLoop`、调度、handler、清理）＋ `client/reply.go`（RECEIPT/ERROR）＋ `client/hub.go`（`Hub` 接口） | 单文件按职责拆开；**三条协程**（上游把写出与处理放在同一协程）；投递非阻塞、满则断开慢消费者；跨层调用走 `Hub` 接口而非 `chan Request` |
| `client/client.go`（7 行，仅包注释） | 无 | — |
| `client/config.go`（`Config` 接口：Authenticate/HeartBeat/Logger） | `client/config.go`（`Authenticator` 接口 ＋ `Config` **值结构**：Log/Authenticator/ConnectTimeout/MinHeartBeat）＋ `server` 的 `With*` 选项 | **同文件同名**；上游用接口方法取三样东西，我们用值结构承载同样的参数，由服务端在 `NewConn` 时注入。值结构可以被零值构造，所以 `NewConn` 会给没填的字段兜底（日志用默认、超时 10s、心跳下限 30s、认证器放行所有）—— 上游的接口形态没有这个问题 |
| `client/frame.go`（`determineVersion`/`getHeartBeat`，从**帧**取头） | `client/frame.go`（`frameToBytes` ＋ `negotiateVersion`/`parseHeartBeat`/`formatHeartBeat`，从 **header 值**取） | 多了帧编解码（WebSocket 要 `[]byte`）；接口收窄到 header 值（便于单测，且与命令分派解耦） |
| `client/validator.go`（`stomp.NewValidator` 是**空实现**） | `client/validator.go`（真实现） | 必填头、目的地字符集、`ack` 取值（`auto`/`client`/`client-individual`，非法值必须在订阅时就拦 —— 否则 `IsAckedBy` 永不匹配、队列订阅静默卡死）、1.2 的 `id`、CONNECT 的 receipt 禁令 |
| `client/errors.go` | `client/errors.go` ＋ `server/errors.go` | 两边各自持有文案：连接层不该依赖服务端内部常量 |
| `client/request.go`（5 个 op，含 `ConnectedOp`/`DisconnectedOp`） | `server/request.go`（4 个 op） | 去掉上游 processor 自己都不处理的两个 op；opcode 降为 server 包内部细节 |
| `client/subscription.go` | `client/subscription.go` | 多 `active` 原子位，并以 `IsActive()`/`Client()` 暴露给中继 |
| `client/subscription_list.go` | `client/subscription_list.go` | **`Ack`/`Nack` 各多一行清 `sub.subList` 回指针**（见 §三-1） |
| `client/tx_store.go` | `client/tx_store.go` | 容器 `container/list` → slice；API 同名同义 |
| `client/util.go`（`asMilliseconds`） | 无 | 心跳下限改为 hub 字段 |
| — | `client/hub.go`（`Hub` 接口：11 方法，逐条协程契约） | 本仓独有：连接层向上调用的唯一出口 |
| — | `client/config.go` 的 `Authenticator` 接口（由 `client` 调、`server` 注入）＋ `server/auth.go` 的默认实现 | 本仓独有（上游用 `Config.Authenticate`）。接口留在 `client` 是硬约束：`handleConnect` 要调它，而 `client` 不能 import `server` |
| — | `server/presence.go`（`PresenceManager` 端口 ＋ `PresenceMember`/`PresenceStats`）＋ `server/memory_presence.go`（内存实现） | 本仓独有：上游没有在线状态这回事。粒度是**连接**（`login` + `ref`），一个端口同时服务 hub 的上报与业务侧的查询；**通知不在端口里** —— 谁上线谁下线由 `EventHook` 播（端口拿不到 hub，签名即约束） |

### 本仓独有 / 上游独有

| | 项 |
|---|---|
| 本仓独有 | `client/hub.go`（跨界接口）、`client/config.go` 的 `Authenticator` 接口 ＋ `server/auth.go`、`server/hook.go`（事件钩子）、`server/presence.go` ＋ `server/memory_presence.go`（在线状态的端口与内存实现）、`server/destination.go`、`web/`（演示页） |
| 上游独有 | `channel_test.go`/`util_test.go` 等内部管道测试（那套通道已被替换，不适用）、`Config` 接口、`Server.HeartBeat` 等服务器字段、`queue_storage.go` 的重复接口 |

## 三、同步上游改动时的套用规则

1. **可逐字套用**：`queue/queue.go`、`queue/{manager,storage,memory_queue}.go`、`topic/*` —— 只把 import 里的 `go-stomp/stomp/v3/server/client` 换成本仓路径 `ve-weiyi/stompws/server/client`。
2. **类型名替换**：上游 `Server` → 本仓 `StompHubServer`；`client.Conn`、`client.Subscription`、`client.SubscriptionList` 同名。
3. **三处必须保留的本仓差异**（照抄上游会在本仓出错）：
   1. `subscription_list.go` 的 `Ack`/`Nack` 清回指针 —— 上游漏清，会让「确认后重新订阅」撞上 `Add` 的 panic（队列的等待消费者表与本表同类型，正是共用这份实现）；
   2. 投递是**非阻塞**的（满则断开慢消费者），因此有 `Hub.RequeueDirect` 这条「仅限中继协程内调用」的契约 —— 上游是阻塞投递，没有这回事；
   3. 钩子只在**连接层协程**执行（`Hub.Publish` 的契约）—— 不可挪进中继协程，否则慢钩子会卡死整个中继。
4. 上游新增的字段/常量，先判断它属于「一条连接」还是「服务端编排」，再分别落进 `client/` 或 `server/`。

## 四、修订记录

| 日期 | 变更 |
|---|---|
| 2026-10-16 | 初版。基线 v3.2.0；同日完成分层改造（hub + 中继提为 `server` 包、`client` 退回一条连接、`queue.go` 恢复与上游逐字一致），本表按改造后的布局编写。 |
