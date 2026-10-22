# STOMP 1.2 协议规范要点（含本实现对齐状态）

来源：[STOMP 1.2 Specification](https://stomp.github.io/stomp-specification-1.2.html)（CC-BY-3.0）。
本文取规范的**规范性表述原文**（英文引号内即为原文），并以中文标注含义；文末附 `stompws` 的对齐状态。
本文是「按规范重构 stompws」的判据 —— 有分歧时以规范原文为准，不以现状为准。

## 一、总则

- **帧格式**：`command EOL *(header EOL) EOL *OCTET NULL *EOL` —— 命令、头部、空行、正文、`NUL` 结尾。
- **编码**：默认 UTF-8；正文可用 `content-type` 指定其它编码与类型（`SEND`/`MESSAGE`）。
- **正文长度**：`content-length` 可选；缺失时正文以第一个 `NUL` 结束。
- **头部的值转义**（STOMP 1.2）：`\n`→LF、`\r`→CR、`\c`→`:`、`\\`→`\`。**例外**：
  > "STOMP 1.2 excludes CONNECT and CONNECTED frames from header escaping."
  → CONNECT / CONNECTED 的头**不做转义**（1.0/1.1 所有帧都转义）。这是 1.2 特有的行为。
- **重复头部**：
  > "If a client or a server receives repeated frame header entries, only the **first** header entry SHOULD be used as the value of header entry."
- **destination 的语义不由规范定义**：
  > "The STOMP protocol treats destinations as **opaque string** and their syntax is **server implementation specific**. Additionally STOMP does not define what the delivery semantics of destinations should be."
  → `/queue/`、`/topic/` **不是规范的一部分**，是 ActiveMQ / RabbitMQ / Artemis 等事实约定（参见 §七）。
- **大小限制（规范明确允许并建议）**：
  > "servers MAY place maximum limits on: the number of frame headers, the maximum length of header lines, the maximum size of a frame body. If these limits are exceeded the server SHOULD send the client an ERROR frame and then close the connection."

## 二、各帧的可选/必填头（规范原表）

**客户端帧**

| 帧 | REQUIRED | OPTIONAL |
|---|---|---|
| `CONNECT` / `STOMP` | `accept-version`, **`host`** | `login`, `passcode`, `heart-beat` |
| `SEND` | `dest` | `transaction` |
| `SUBSCRIBE` | `dest`, `id` | `ack` |
| `UNSUBSCRIBE` | `id` | — |
| `ACK` / `NACK` | **`id`**（1.2；1.0/1.1 用 `message-id` 或 `ack`） | `transaction` |
| `BEGIN` / `COMMIT` / `ABORT` | `transaction` | — |
| `DISCONNECT` | — | `receipt` |

**服务端帧**

| 帧 | REQUIRED | OPTIONAL |
|---|---|---|
| `CONNECTED` | `version` | `session`, `server`, `heart-beat` |
| `MESSAGE` | **`dest`, `message-id`, `subscription`** | `ack`（ack 模式非 auto 时**必须**有） |
| `RECEIPT` | `receipt-id` | — |
| `ERROR` | — | `message`（建议有） |

`host` 是**客户端义务**的原文：

> "STOMP 1.2 clients **MUST** set the following headers: `accept-version` …, `host` : The name of a virtual host that the client wishes to connect to. It is recommended clients set this to the host name that the socket was established against, or to any name of their choosing."

## 三、连接与协商

- 服务端可拒绝连接：
  > "The server can reject any connection attempt. The server **SHOULD** respond back with an ERROR frame explaining why the connection was rejected **and then close the connection**."
- 版本协商：`accept-version` 是逗号分隔的版本列表，服务端取兼容的**最高**版本；`CONNECT` 缺 `accept-version` 视为 1.0。帧表把 `accept-version` 列为 `CONNECT`/`STOMP` 的 REQUIRED，而协商一节只针对 `CONNECT` 说了缺失的含义 —— 本实现对两种命令一视同仁地按 1.0 处理（规范：「servers MUST handle a STOMP frame in the same manner as a CONNECT frame」）。
- 心跳协商（原文）：
  > "The first number represents what the sender of the frame **can do** (outgoing heart-beats): 0 means it cannot send heart-beats … The second number represents what the sender of the frame **would like to get** (incoming heart-beats): 0 means it does not want to receive heart-beats."
  > "The heart-beat header is OPTIONAL. A missing heart-beat header **MUST** be treated the same way as a `heart-beat:0,0` header."
  > "For heart-beats from the client to the server: if `<cx>` is 0 … or `<sy>` is 0 … then there will be none; otherwise, there will be heart-beats every **MAX(`<cx>`,`<sy>`)** milliseconds."
  → 即**某一方向要启用，必须双方都声明非零**；间隔取双方值的较大者。服务端抬高自己声明的值（如设下限）是允许的。

## 四、投递与确认语义

- `RECEIPT` 的含义是「**已经处理**」：
  > "Any client frame other than CONNECT MAY specify a `receipt` header … This will cause the server to acknowledge the **processing** of the client frame with a RECEIPT frame."
- `ERROR` 应关联出错的原始帧：
  > "if the frame included a receipt header, the ERROR frame SHOULD set the `receipt-id` header to match the value of the receipt header of the frame which the error is related to."
- `MESSAGE`：`message-id` 是**该消息的唯一标识**，`subscription` 必须匹配接收它的订阅 id；ack 模式非 auto 时**必须**带 `ack` 头（用于后续 ACK/NACK 关联）。
- `ack` 模式：`auto`（服务端视为已投递）、`client`（**累积确认**：确认某条即确认它之前的所有消息）、`client-individual`（只确认该条）。
- 未被确认的消息：服务端 "**will assume the message has not been processed and MAY redeliver** the message to another client"。
- 事务：`transaction` 头把 `SEND`/`ACK`/`NACK` 放进事务，**提交前不生效**。`BEGIN`/`COMMIT`/`ABORT` 用 `transaction` 头标识事务。

## 五、错误与关闭（**重构的关键判据**）

规范里关于「发 ERROR 之后是否关连接」的原文共 5 处，强度不同：

| 场合 | 原文 | 强度 |
|---|---|---|
| 帧无法解析 / 头不合法 | "the server **MUST** send the client an ERROR frame and then close the connection." | **MUST 关闭** |
| **SEND 处理失败** | "If the server cannot successfully process the SEND frame for any reason, the server **MUST** send the client an ERROR frame and then close the connection." | **MUST 关闭** |
| **订阅建立失败** | "If the server cannot successfully create the subscription, the server **MUST** send an ERROR frame and then close the connection." | **MUST 关闭** |
| 超过大小限制 | "the server **SHOULD** send the client an ERROR frame and then close the connection." | SHOULD 关闭 |
| 拒绝 CONNECT | "the server **SHOULD** respond back with an ERROR frame … and then close the connection." | SHOULD 关闭 |
| 其它错误 | "the server **MAY** respond with an ERROR frame and then close the connection." | 可选 |

即：**凡是「服务端无法处理这个帧」，就要 ERROR + 关连接**（不是只回 ERROR 然后继续用）。

`DISCONNECT` 的关闭方向与「延迟关闭」：

> "To do a graceful shutdown … the client SHOULD: send a DISCONNECT frame with a receipt … wait for the RECEIPT … close the socket."
> "Clients **MUST NOT** send any more frames after the DISCONNECT frame is sent."
> "STOMP servers **must** be able to support clients which rapidly connect and disconnect. This implies a server will likely only allow closed connections to linger for short time before the connection is reset. As a consequence, a client **may not receive the last frame** sent by the server (for instance an ERROR frame or the RECEIPT frame in reply to a DISCONNECT frame)."

→ 客户端收完 RECEIPT 负责关；服务端**可以**在回完 RECEIPT 后关闭，且**被允许**丢掉最后一帧（客户端必须容忍）。

## 六、规范**没有**规定的部分（不要按规范去猜）

- destination 的语法与投递语义（见 §一）；
- 任何鉴权/授权模型（`login`/`passcode` 是纯文本头，规范只说"Clients MAY … authenticate"）；
- 消息持久化、跨节点路由、限流、配额；
- 服务端的 vhost 行为（`host` 的用途由服务端自定）。

## 七、行业实践（参考实现，非规范）

- **destination 前缀**：`/queue/`（点对点）、`/topic/`（发布订阅）是事实约定，ActiveMQ / RabbitMQ / Artemis 都遵循；Artemis 允许配置前缀（[ARTEMIS-410](https://issues.apache.org/jira/si/jira.issueviews:issue-html/ARTEMIS-410/ARTEMIS-410.html)）。RabbitMQ 另有 `/exchange/<name>/<routing_key>`。
- **vhost 与 `host`**：RabbitMQ 把 `host` 当 vhost 用，且**故意容忍缺 `host`**（回退默认 vhost `/`），为此宁可"违反"1.1 规范的客户端义务（[讨论 1](http://lists.rabbitmq.com/pipermail/rabbitmq-discuss/2012-June/020883.html)、[讨论 2](http://lists.rabbitmq.com/pipermail/rabbitmq-discuss/2013-May/026847.html)）→ 说明服务端在这一点上「严格拒」与「宽容缺省」都有先例。
- **无法处理的 SEND**：真实 broker 会把连接关掉（RabbitMQ 投到不存在的 exchange 会让 channel/connection 出错）。

## 八、`stompws` 对齐状态

| 规范条目 | 现状 | 说明 |
|---|---|---|
| CONNECT/STOMP 的 REQUIRED 头 | ✅ | `host` 在 1.1/1.2 下强制（缺即 ERROR + 关闭）；**缺 `accept-version` 按规范回落 1.0**（原文："If the accept-version header is missing, it means that the client only supports version 1.0"，且 "servers MUST handle a STOMP frame in the same manner as a CONNECT frame"），那时不再要求 `host`（1.0 没有它） |
| 版本协商取最高版本 | ✅ | `stomp.V12 > V11 > V10` |
| 心跳协商（双方非零才启用、取 MAX、缺头等同 0,0） | ✅ | 另有服务端下限 30s（抬高自己声明的值，规范允许）；**cx=0（含缺头）时不做读超时判定**，并清掉 CONNECT 阶段设下的那条 |
| CONNECT/CONNECTED 头不转义（1.2） | ✅ | 依赖库按命令区分，且**不看协商版本**（`frame/writer.go`：`command != CONNECT && command != CONNECTED`）—— 即 1.0/1.1 下也不转义，与规范的版本区分不完全一致 |
| `RECEIPT` = 已处理（且累积确认此前所有帧） | ✅ | 回执一律在「校验/执行完成」之后；`COMMIT` 的回执也在提交成功之后（失败只回 ERROR，不再先谎报成功） |
| `ERROR` 带 `receipt-id` | ✅ | `SendError(msg, receiptID)` |
| `MESSAGE` 必带 `dest`/`message-id`/`subscription` | ✅ | 队列与 topic 两条投递路径都补 |
| ack 模式 `client` 为累积确认 | ✅ | `IsAckedBy` 用 `msgId >= sub.msgId` |
| 非 auto 订阅的 MESSAGE 必带 `ack` 头 | ⚠️ 仅 `/queue/` | `/topic/` 投递是 fire-and-forget：MESSAGE 不带 `ack` 头、也不进入待确认表，于是 `ack:client`/`client-individual` 静默退化成 auto，客户端发的 ACK 是 no-op（不报错）。上游同样如此，本实现不为此改动 |
| 未确认消息可重投 | ✅ | 断开/重入队按队列退回队首 |
| 事务提交前不生效 | ✅ | `txStore` 缓冲，`COMMIT` 时重放 |
| **无法处理即 ERROR + 关连接（MUST）** | ✅ | `Conn.sendErrorAndClose`：帧解析失败、必填头缺失、订阅建立失败、SEND 处理失败、ACK/NACK 无法定位消息，一律 ERROR 后关闭（回执时机不变：校验通过才回 RECEIPT） |
| **`DISCONNECT` 后服务端关闭** | ✅ | 清理订阅 + 回调之后刷出 RECEIPT，留 100ms 让写协程发完即关（规范允许丢掉最后一帧） |
| **帧体大小限制** | ✅ | 头段与正文各有上限（`wsFrameReader`：头段 8KB、正文 1MB，都是包内常量）；单条 WS 消息另有 `maxWSMessageSize`（1MB）。超限一律 ERROR + 关闭 |
| 头部与头名合法性 | ✅ | 头名缺冒号或为空 → 致命解析错误（ERROR + 关闭）；行尾 CRLF 按规范接受、重复头只取第一个。**但值里的裸 CR（未转义）不被拒**，不转义的 CONNECT/CONNECTED 帧里值含 NUL 也照收 —— 依赖库只按 LF 切行 |
| 规范未规定的部分（destination 语义、鉴权、vhost） | ✅ 明确自行定义 | 见 `docs/design/34-实时通信.md` |

## 九、已知偏离与风险

1. **正文无独立上限（2026-10-16 已修）**：`frame.Reader` 读完头就做 `make([]byte, contentLength)`，而 `content-length` 由客户端给出 —— 一条 40 字节的 `SEND`+`content-length:2000000000` 就能让服务端**立刻**分配 2GB（放大 5 千万倍）。
   顺带查明：**头段同样没有上限** —— 库注释写着 "A STOMP frame is rejected if its command and header section exceed the buffer size"（`bufferSize = 4096`），但 `readLine` 用 `bufio.ReadBytes` 会**无限累积**，那句注释声称的检查在代码里并不存在。
   修法：把「从 WS 消息读帧」这件事收进一层 `wsFrameReader`（`frame.NewReader` 的输入就是它）：按行读头段、**整段确认合法才放行**（放行前库不会去分配正文），正文只计数并逐块透传；原先的 `wsReader` 并入其中，链路上不再有第二层包装。见 `server/client/framereader.go`。这两处（正文放大、头段无上限）值得一并回报上游。
2. **hook 返回 `false` 时静默不回执**：应用级拒绝（`OnSend` 返回 `false`，如 blog-cloud 落库失败、事件类型不认识）既不回 RECEIPT 也不回 ERROR，客户端只能等超时。严格按规范「无法处理 SEND → MUST ERROR + 关闭」应关连接；但那会让一次落库失败/一条不认识的事件**断掉整个聊天连接**（且 `OnSend` 的 `bool` 语义会变成「是否致命」），影响面超出 stompws，未擅自改。
3. **超限只能靠 WebSocket 层关闭**：`SetReadLimit` 触发时 gorilla 的读循环会自己先发 `1009` 关闭帧，规范要求的 STOMP `ERROR` 帧只能尽力而为、会被它抢先 —— 客户端（含浏览器）看到的是 WS 关闭码而非 ERROR。
