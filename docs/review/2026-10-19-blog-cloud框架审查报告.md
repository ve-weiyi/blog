# blog-cloud 框架审查报告

日期：2026-10-19
审查范围：`blog-cloud` 的 `api/app`、`api/admin`、`rpc/blog`、`infra/*`、`cmd/*`
审查口径：Go 代码设计五维度（包与职责、接口与耦合、并发安全、错误与边界、一致性与简洁），不替代 `gofmt` / `go vet` / `golangci-lint`
审查方式：只读扫描，未修改任何代码。审查经过两轮全量复查，以下为合并去重后的最终结论。
路径约定：除特别注明外，路径均相对 `blog-cloud/`。
标记说明：✅ 表示该项已在 2026-10-19 的修复批次中处理；❌ 表示该项已明确决定不处理（含保留生成代码、暂不扩大范围）。部分条目只有已处理的子项带 ✅。

## 一、审查范围与方法

| 项 | 结果 |
|---|---|
| 规模 | 824 个 `.go` 文件 / 约 93k 行（含约 3 万行 pb 生成代码与 routes） |
| `gofmt -l` | 干净 |
| `go vet ./...` | 干净 |
| `go build ./...` | 通过 |
| `GOWORK=off go build ./...` | 通过（standalone 也 OK） |
| `go test ./...` | 全部通过 |
| `go test -race ./infra/... ./api/...` | 通过 |
| `golangci-lint` | 环境未安装，未执行 |

除逐文件通读全部业务 logic 外，另做了四项交叉核对：

1. Swagger 路径与 `routes.go` 的逐条比对（发现 `{id}` / `:id` 两套参数语法）；
2. 回读 GORM v1.31.2 源码，确认 `default` 标签对零值的写入/回填行为；
3. 追完整条「客户端输入 → query builder → `db.Order` / `db.Where`」链路；
4. 逐值核对示例配置与 `deploy/` 下 45 份配置中的凭据。

不覆盖：运行期行为、K8s 部署、`internal/pb/**` 与 `routes.go` 生成代码内部、前端实现；`vkit` / `stompws` 仅在与本仓调用相关处提及。

## 二、总体评价

分层与生成代码边界是清晰的：

- `api/*/internal`：`handler → logic → svc`，handler 基本 27 行，只做解析、调用 logic、封装响应；未发现 handler 承载业务逻辑。
- `rpc/blog/internal`：`server` 全为生成代码，`logic` 承担业务，`model` 由 goctlx 生成，接口命名统一。
- `infra` 的职责划分是本仓最亮的部分：`responsex`、`bizerr/bizcode`、`storex`、`tokenx`、`limitx`、`presencex`、`sse` 都是围绕契约设计而非围绕框架包装，可测试性好。
- `vkit` 只放通用能力，框架封装（gorm 日志等）留在 `infra`，符合 `architecture.md`。

风险集中在五处：

1. **认证/授权边界**：验证码校验结果被丢弃、RBAC 对带参路由默认放行，二者都可直接导致账号接管或提权；
2. **数据可见性与业务正确性**：私密/草稿/已删除内容可按 ID 读取，多个更新接口越权或清空字段，广播/聊天/邮件链路存在功能性错误；
3. **输入与注入**：用户可控 `sorts` 进入 `ORDER BY`；GET query 参数因缺少 `form` tag 全部不生效；分页无边界；
4. **凭据与日志**：示例配置携带生产凭据，gRPC 日志明文记录密码，GORM 日志记录 SQL 实参；
5. **工程整洁**：网关装配重复、MQ 全局状态、业务逻辑层零单测。

## 三、逐维度 findings

### 3.1 包与职责

- ❌ **[Should] 测试辅助代码编进生产二进制** — `api/admin/internal/svc/service_contexttest.go:1` 文件名不是 `_test.go`，且内部按相对路径 `../../etc/admin-api.yaml` 加载配置。应改为 `_test.go` 或移到 `cmd/`。（规则 1.1 / 4.11）（不处理）
- ✅ **[Should] MQ 使用包级全局客户端** — `rpc/blog/internal/mq/init.go:14-32` 有 15 个包级变量（连接、发布器、订阅器）。违反“禁止全局变量/全局客户端，显式注入”（`go.md`、规则 2.6），也难以测试。建议收敛为 `mq.Client` 注入 `ServiceContext`。（规则 1.5 / 2.6）（已收敛为泛型 `Channel[T]`，随 `ServiceContext` 注入）
- ❌ **[Should] 重复实现 × 4 组**（不处理）
  - `ConnectRedis`：`api/app/internal/svc/service_context.go:152`、`api/admin/internal/svc/service_context.go:203`、`rpc/blog/internal/svc/service_context.go:217` 三份几乎一致；
  - Nacos 引导：`api/app/app.go:20-62`、`api/admin/admin.go:21-63`、`rpc/blog/blog.go:47-91` 三份逐字复制；
  - 鉴权中间件：`api/app/internal/middleware/userauth_middleware.go` 与 `api/admin/internal/middleware/adminauth_middleware.go` 仅取 token 的头名不同；
  - `api/app/internal/common/apiutils/batch.go` 与 admin 侧完全一致。
  应抽到 `infra/`。（规则 5.1）
- **[Should] 死代码与未接线组件**
  - ❌ `api/app/internal/middleware/ratelimit_middleware.go:12-18`、`api/admin/internal/middleware/ratelimit_middleware.go:12-18` 是 goctl 模板空实现（实际限流走 `infra/middlewarex`）；不处理：模板生成文件，保留；
  - ❌ `infra/interceptorx/grpc_server_auth_interceptor.go:10` 与 `grpc_server_meta_interceptor.go:11` 完全相同且未注册；`infra/interceptorx/grpc_client_log_interceptor.go` 未接线；不处理：保留；
  - ✅ `infra/storex/captchax/captcha.go:65` 的 `GetCodeCaptcha` 全仓无调用；
  - ✅ `api/app/internal/svc/service_context.go:47` 的 `AgentLog` 从未赋值；❌ `permissionx.NewNoopEnforcer` 未接线（保留：本地调试用）；
  - ✅ `rpc/blog/internal/config/config.go:43-49` 的 `KafkaConf`。
  （规则 1.5 / 5.6）
- **[Should] logic 层引入 `net/http`** — ✅ `api/app/internal/logic/common/upload/upload_file_logic.go:5,34`（接收 `*http.Request`、直接 `FormFile`）、✅ `api/admin/internal/logic/common/upload/upload_file_logic.go`（同型问题）；❌ `api/app/internal/logic/common/websocket/websocket_logic.go:5`、`api/admin/internal/logic/common/websocket/websocket_logic.go:5`（保留：连接升级必须使用 HTTP 类型）；✅ `api/admin/internal/logic/access/api/sync_api_logic.go:6`（改为 `infra/swaggerx` 展开操作）。上传现已由 handler 解析出 `io.Reader` 再交给 logic。（规则 1.6）
- ❌ **[Should] 业务逻辑层没有测试覆盖** — 29 个测试文件、4.8k 行，全部在 `infra/`、admin 中间件、`mqlogic`；`api/*/internal/logic` 与 `rpc/blog/internal/logic` 为 0 测试。（不处理：测试只覆盖工具组件，不要求每个 logic 都有测试）
- **[Should] 生成的 protobuf 描述符与 etcd 的 `auth.proto` 同名，引用 zrpc client 的包无法写测试** — `protocol/proto/generate.sh` 先 `cd "$SERVICE_NAME"` 再生成，使 descriptor 路径记录为纯文件名 `auth.proto`；测试二进制同时链接 `go.etcd.io/etcd/api/v3/authpb` 时，`protoregistry` 在 init 阶段 panic（`file "auth.proto" is already registered`）。这也是业务 logic 层长期无法补测试的硬阻塞。修复：生成时保留目录前缀（如 `blog/auth.proto`），或为 proto 文件取全局唯一名。（规则 1.1 / 4.11）
- **[Praise]** handler 层极薄且一致；`model` 的接口 + `WithTx` 模式统一；`infra` 包命名全部自描述，没有 `util/common` 类垃圾抽屉。

### 3.2 接口与耦合

- ✅ **[Should] 每个网关对同一个 RPC 目标创建了 11/12 个独立 zrpc 客户端** — `api/app/internal/svc/service_context.go:101-111`、`api/admin/internal/svc/service_context.go:147-158`。每次 `zrpc.MustNewClient(c.AppRpcConf, ...)` 都会建一套连接池、Resolver 与拦截器链；生成的构造函数接收 `zrpc.Client`（如 `rpc/blog/client/contentservice/content_service.go:118`），共享一个 client 即可。（规则 2.6 / 5.6）
- ✅ **[Should] JWT HS256 的签名密钥来自服务名** — `api/app/internal/svc/service_context.go:79`、`api/admin/internal/svc/service_context.go:98`：`NewJWTSigner([]byte(c.Name), c.Name)`，密钥实际是 `blog-api` / `admin-api`。目前校验以 Redis 中存储的完整 token 相等为准（`infra/storex/tokenx/manager.go:129-138`），不能直接伪造登录；但签名已失去意义。建议密钥来自配置/环境变量，或改用已有的 `NewHMACSigner`。（规则 4.9 / 5.6）
- ✅ **[Should] 模型更新语义与调用方契约不匹配** — `model.Update` 使用 `db.Updates(&struct)`（如 `t_role_model.go:130`、`t_api_model.go:131`、`t_menu_model.go:141`、`t_notify_template_model.go:131`），GORM 会跳过零值字段：`update_role_logic.go:30-41` 无法把状态改回 0，`update_api_logic.go:29-38` 无法重新启用接口，`update_notify_template_logic.go:33-40` 无法禁用模板。另一面，部分接口又用整行 `Save` 覆盖未提交字段（`api/app/internal/logic/account/me/update_me_logic.go:30-33` 总是传 `&req.Avatar`）。应统一为字段级更新（显式 map），由调用方决定写哪些字段。（规则 4.6 / 5.2）
- ✅ **[Should] 更新接口的响应类型与 `.api` 声明不一致** — `.api` 声明返回 VO，logic 实际返回 `EmptyResp`（响应体 `{}`）：`update_category_logic.go:28`（content.api:153）、`update_tag_logic.go:28`、`update_album_logic.go:28`（media.api:72）、`update_photo_logic.go:28`、`update_page_logic.go:28`（site.api:134）、`update_friend_logic.go:28`。前端按 VO 取字段会全空。
- ✅ **[Should] `BizError.Violations` 跨 gRPC 边界丢失** — `infra/biz/bizerr/error.go:132-136` 的 `FromStatus` 只解析 `ErrorInfo`，从不解析 `WithBizError` 写入的 `errdetails.BadRequest`（`:105-108`）。一旦 RPC 侧使用字段级明细，HTTP 端 `data.field_violations` 恒为空。当前无生产者，属契约实现了一半。
- **[Praise]** `tokenx.Manager` 接口定义在消费方、由 `storex.KVStore/MemberStore` 组合而成；`StorageProvider`、`SmsProvider` 等外部适配都通过接口注入。
- **[Praise]** `permissionx.Enforcer` / `tracelogx.Enforcer` 都有编译期接口满足检查（`var _ Enforcer = ...`）。

### 3.3 并发安全

- ✅ **[Should] app 网关的关闭逻辑实际不会执行，STOMP hub 也未接线**（已改为关闭监听，两个网关均接入 `hub.Shutdown`） — `api/app/app.go:61/68/79` 使用 `defer nacosCloser.Close()`、`defer server.Stop()`、`defer job.Stop()`，但没有注册 `proc.AddShutdownListener`。go-zero 收到信号后会先跑关闭监听再 `syscall.Kill` 自己，main 不返回、defer 不执行（这一点由 `api/admin/admin.go:77-80` 的注释确认）。admin 的 `Shutdown`（`api/admin/internal/svc/service_context.go:190-201`）只停通知订阅与 Broker，两个网关都没有接 `StompHubServer.Shutdown`。长连接与后台任务收尾依赖进程退出。（规则 3.1）
- ✅ **[Should] MQ 初始化失败后没有自愈** — 已在 `vkit/adapter/mqx/rabbitmqx` 增加 `LazyConnect`：首次连接在后台按 `ReconnectConfig` 重试；发布器未连接时返回 `ErrNotConnected`（业务侧映射为 `ErrUnavailable`），订阅器等待首次连接后自动开始消费。业务侧只配置开关。
- ✅ **[Should] 角色缓存失效存在回填竞态**（已加代际号：撤权递增，读写两侧校验，旧结果无法回填） — `api/admin/internal/middleware/permissionx/rbac_enforcer.go:243-260` 先删内存/Redis，而正在执行的 `getUserRoles`（`:299-328`）可能已从 RPC 拿到旧角色并在删除之后回填，撤权在最长 5 分钟内继续生效。需要版本号或“失效后禁止回填”机制。
- ✅ **[Should] 点赞/浏览量的读改写与双写不一致**（已改为字段级原子增减；点赞状态读取失败直接报错；浏览量缓存失败不再触发重试；回种改用 `ZAddNX`。说说点赞同型修复） — `like_article_logic.go:45-67`、`like_comment_logic.go`：先读 `LikeCount` 再 `++/--` 并 `Save` 整行，并发点赞互相覆盖；Redis 失败只记日志并按“未点赞”分支继续，Redis 与 DB 无补偿。`increment_article_view_logic.go:30-48` 同样先读后写（应改为 `view_count = view_count + 1`），DB 成功、Redis 失败时重试会重复计数；`helper.go:235-250` 的缓存回种在 Redis 重启后可能把历史浏览量重置为 1，并发回种会翻倍。
- ✅ **[Should] `RedisMemberStore.Add` 用整键 TTL 覆盖“每成员独立 TTL”**（已移除 `Expire`，过期只由 score 与读路径惰性清理表达，并补独立 TTL 测试） — `infra/storex/redis_member_store.go:24-32` 每次 `Add` 都执行 `Expire(key, ttl)`；只要有一次用更短 TTL 写入，整个 ZSET（含长 TTL 成员）会被提前删除，与接口注释矛盾。现成受害者：`cmd/presencecheck/main.go:168-172` 先写入 60s 成员、再以 30ms TTL 加入成员，整键 30ms 后消失，自检断言 `NumUsers == 1` 必然失败。
- ✅ **[Should] `captchax` 的 `*rand.Rand` 共享且非并发安全** — `infra/storex/captchax/captcha.go:20,47,69`。`GetCodeCaptcha` 当前无调用，但一旦被并发请求使用就是数据竞争；验证码属于安全随机场景，`math/rand` 也不合适。（规则 3.9 / 4.9）
- ✅ **[Should] 撤回与投递存在竞态**（投递改为事务内 `SELECT ... FOR UPDATE` 锁消息行，与撤回串行化；幂等查询与插入同事务） — `revoke_notify_message_logic.go:44-58` 只回收撤回时已存在的 unread 记录；消费者 `consume_inbox_message_logic.go:45-48` 读到 `published` 后、插入前若撤回提交，新插入的记录不会被回收，列表仍可见并会广播发布事件。应把“消息仍 published”作为插入条件。
- **[Nit] STOMP / 消费者回调里大量 `context.Background()`** — `api/app/internal/common/stomphook/chatroom.go:47,106,195,236`、`infra/stompwsx/online.go:27,57,91`、`rpc/blog/internal/mq/subscriber.go:19-67`。回调没有请求 ctx 可以理解，但应至少套一个带超时的 context。（规则 3.2）
- ✅ **[Nit] 后台 RPC 没有超时/取消**（chatroom 回调、stompwsx 在线人数、RBAC 与操作日志策略加载均加 3–10 秒超时；长连接订阅保持无超时） — `rbac_enforcer.go:94,299`、`trace_enforcer.go:88`、`accessservice/sync_menus_logic.go:37`、`sync_apis_logic.go:37` 使用 `context.Background()` 调 RPC，单次悬挂无法取消。
- **[Praise]** `sse.Broker` 的关闭语义扎实：注销持写锁、Publish 持读锁、关闭幂等、慢消费者丢帧且不阻塞广播方（`api/admin/internal/common/sse/broker.go:36-98`）；`Bridge` 把发送纳入 `ctx.Done()` 选择（`bridge.go:55-62`）。
- **[Praise]** `presencex` 用 ZSET score 表示独立 TTL、读路径惰性清理，不需要清扫协程（`infra/storex/redis_member_store.go:44-65`）。
- **[Praise]** 通知发布/撤回的并发守卫是正面样板：状态判断与更新用 `WHERE id = ? AND status = ?` + 影响行数裁决（`publish_notify_message_logic.go:49-61`），撤回在事务内同时更新消息与投递记录（`revoke_notify_message_logic.go:44-65`）。

### 3.4 错误与边界

#### 3.4.1 认证、验证码与账号状态

- ✅ **[Must] 验证码校验结果被网关丢弃：任意验证码即可登录、注册、重置密码、恢复账号**（`Verify*` 失败直接返回业务错误；校验成功删除验证码，失败累计次数，5 次后作废）
  - RPC 在校验失败时返回正常响应 + `Success:false`，而不是 error：`rpc/blog/internal/logic/notificationservice/verify_email_code_logic.go:47-60`、`verify_mobile_code_logic.go:47-60`；`infra/storex/otpx/otpx.go:118-131`。
  - 网关侧全部写成 `_, err = ...`，只判断 `err != nil`，从不读取 `Success`：app 的 `account/auth/email_login_logic.go:31-39`、`mobile_login_logic.go:31-39`、`register_logic.go:32-40`、`reset_password_logic.go:30-40`、`account/me/reactivate_account_logic.go:33-51`；admin 同名文件同样写法。
  - 后果：知道任意用户邮箱/手机号，提交任意 code 即可登录；公开的 `POST /admin-api/v1/auth/password-resets`（只挂 `RateLimit`）可重置任意邮箱账号的密码（包括种子管理员，`protocol/sql/blog-data.sql:9`）；手机验证码登录与 OAuth 登录会自动注册；修好前验证码接口实际只有“发信”功能。
  - 修复：`Verify*` 失败直接返回 `bizerr.NewBizError(CodeVerifyCodeError, ...)`，不要用 `bool success` 表达安全校验结果；网关即使保留响应读取也必须检查 `Success`。补“错误验证码必须返回错误”的表驱动测试。
- ✅ **[Must] 用户状态模型：注册落库为“禁用”，注销账号仍可登录**
  - GORM v1.31.2 对带 `default` 标签且值为零的字段，会在 INSERT 时用默认值覆盖并回填结构体（`gorm/callbacks/create.go:340-343`）。`rpc/blog/model/t_user_model.go:53` 是 `default:1`，而 `enums.UserStatusNormal = 0`、`UserStatusDisabled = 1`（`infra/constants/enums/model.go:125-126`）。因此 `register_logic.go:71`、`login_by_mobile_logic.go:55`、`login_by_o_auth_logic.go:84` 传入的 `Status: 0` 实际落库为 1，注册事务提交后 `onLogin`（`login_by_password_logic.go:67`）返回 `ACCOUNT_DISABLED`——邮箱注册、手机自动注册、OAuth 首登必然失败。登录日志的 `status default:1`（`t_login_log_model.go:44`）有同样问题。
  - `onLogin` 只拦 `Disabled(1)`，不拦 `Logoff(2)` 与 `Deleted(-1)`；`deactivate_account_logic.go:49-50` 设置的正是 `Logoff + DeletedAt`，而 `DeletedAt` 是 `*time.Time` 而非 `gorm.DeletedAt`（`t_user_model.go:59`），GORM 不会自动过滤，所有 `FindOneByEmail/Mobile/UserId` 仍能查到注销用户——注销后仍可用任意登录方式重新登录。
  - `tokenx.Manager.Validate` 不查用户状态，禁用/注销后旧 token 仍有效（access 2h、refresh 7d）。
  - 状态语义有三处互相矛盾：模型/DDL 注释写“0-禁用 1-正常 2-冻结”（`t_user_model.go:53`、`protocol/sql/blog.sql:499`），枚举是“0-正常 1-禁用 2-注销”，admin 类型注释又写“2-冻结”（`api/admin/internal/types/account_user.go:44`）。
  - 修复：统一枚举与 DDL/模型注释，去掉或改正 `t_user.status` 的 `default`；`onLogin` 显式拒绝 `Disabled/Logoff/Deleted`；软删除改用 `gorm.DeletedAt` 或显式过滤；改密/禁用/注销后 `RevokeAll`。
  - （注册/登录状态路径已修复；`RevokeAll` 见“不吊销 token”条目，全量软删除过滤未改。）
- ✅ **[Must] 管理员重置用户密码时丢弃 `new_password`，实际把密码重置为空**（网关已透传，RPC 校验后 bcrypt 并吊销该用户全部令牌） — `api/admin/internal/logic/account/user/reset_user_password_logic.go:30-32` 只传 `UserId`，请求类型里的 `NewPassword`（`api/admin/internal/types/account_user.go:26-29`，带 `validate:"required,min=6"`）从未使用；RPC `rpc/blog/internal/logic/userservice/reset_user_password_logic.go:28-38` 对空串做 bcrypt 并写库。重置后该账号可用空密码通过 `login-by-password` 登录。
- ✅ **[Must] 绑定邮箱/手机号完全不校验验证码**（RPC 内校验 `bind` 场景验证码，唯一冲突映射为业务错误） — `api/app/internal/logic/account/me/bind_me_email_logic.go:29-35`、`bind_me_mobile_logic.go:29-35`（admin 同）只转发 `Email/Mobile`，请求里的 `VerifyCode` 从未读取；RPC 注释写着“验证码验证已在 API 层完成”（`rpc/blog/internal/logic/userservice/bind_me_email_logic.go:27`），实际两只手都没做。任意登录用户可绑定不属于自己的邮箱/手机号，唯一索引冲突会把原始 DB 错误透给客户端。
- **[Should] OTP 无失败计数与发送冷却** — ✅ 校验失败已计数，5 次后作废验证码；❌ 发送冷却未做（仍只有 IP 维度限流）。 — `infra/storex/otpx/otpx.go:118-131` 校验失败不计数、不删除；发送端 `send_email_code_logic.go` / `send_mobile_code_logic.go` 无按目标地址的冷却。6 位码 + 15 分钟有效期，在分布式 IP 下可被暴力枚举；也可对任意地址无节制发信。
  - 注意：路由上挂的是 `serverCtx.RateLimit`（`api/app/internal/svc/service_context.go:131`、`api/admin/internal/svc/service_context.go:163`），即真实的 Redis 滑动窗口限流（app 5 次/分、admin 10 次/分，按 IP+路径），并非空实现；空实现只是 `api/*/internal/middleware/ratelimit_middleware.go` 的死代码（❌ 不处理：模板生成文件，保留）。限流存在，但不按账号/验证码维度计数。
- ✅ **[Should] 验证码发送把 MQ 不可用当成功** — 已改为任何投递失败（含 `mq.ErrUnavailable`）都记录日志并返回 `SERVICE_UNAVAILABLE`，客户端可重试。 — `rpc/blog/internal/logic/notificationservice/send_email_code_logic.go:73-76`（`send_mobile_code_logic.go` 同）对 `mq.ErrUnavailable` 直接忽略并返回成功；验证码已写 Redis，但用户永远收不到。应显式失败或同步降级发送。
- ✅ **[Should] 改密/重置/禁用/注销后不吊销 token**（重置密码、管理员重置、修改密码、禁用用户、注销账号均调用 `RevokeAll`） — 全仓除 logout 外没有 `Revoke`/`RevokeAll` 调用（`api/app/internal/logic/account/auth/logout_logic.go:39` 是唯一一处）；`reset_password_logic.go`、`update_me_password_logic.go`、`reset_user_password_logic.go`、`deactivate_account_logic.go` 均未吊销。被盗 token 在改密后仍可用 2h，refresh 仍可续 7d。
- ✅ **[Should] 停用/恢复账号的校验缺失**（停用校验密码与原因并写入 30 天冷静期；恢复校验冷静期是否过期） — `deactivate_account_logic.go` 完全忽略 proto 里的 `password`/`reason`（`protocol/proto/blog/user.proto:179-182`）；`reactivate_account_logic.go:51-57` 不校验 30 天冷静期是否过期，`CanReactivateUntil` 形同虚设。
- ✅ **[Should] OAuth `state` 从未校验**（授权地址由服务端签发一次性 state，Redis 保存 10 分钟，登录/绑定时消费并校验平台；前端改用 sessionStorage 保存跳转意图） — app/admin 的 `OauthLogin` 不把 `state` 传给 RPC（`api/app/internal/logic/account/auth/oauth_login_logic.go:29-34`）；绑定侧虽然传了 `State`，RPC `bind_me_third_party_logic.go:30-70` 从不使用。存在登录/绑定 CSRF。
- ✅ **[Should] 绑定/解绑第三方账号的问题**（绑定插入错误已上抛；解绑前校验至少保留一种登录方式） — `bind_me_third_party_logic.go:59-70` 忽略 Insert 错误仍返回成功；`unbind_me_third_party_logic.go:35-43` 不检查“是否还有其它登录方式”，OAuth 注册用户解绑唯一平台后账号永久锁死。
- ✅ **[Should] 密码策略与校验缺失**（新增统一 `ValidatePassword`/`ValidatePasswordConfirm`，注册、重置、修改、管理员重置均使用；旧密码错误返回业务错误） — 注册/改密/重置均无长度或非空校验（`register_logic.go:58` 对空/1 位密码照样 bcrypt；`update_me_password_logic.go:49-52`）；旧密码错误返回 bcrypt 原始错误（500 而非业务错误）；`ConfirmPassword` 未使用（admin 侧还丢弃）。
- ✅ **[Should] 验证码 scene 收发不一致（修好校验后会暴露）** — 发送端直接把客户端 `type` 当 scene（`send_email_code_logic.go:31`、`send_mobile_code_logic.go:31`），文档约定值是 `login/register/reset_password/bind_email/bind_phone`；校验端用 `enums.CodeScene*`（`infra/constants/enums/model.go:175-179`，`mobile_login/email_login/register/reset_password/bind`）。`login` 与 `mobile_login` 对不上；`bind_email/bind_phone` 与 `bind` 也对不上。
- ✅ **[Should] 在线用户列表识别失败并被默认分页截断**（用户 ID 统一为 36 位小写 UUIDv7，游客保持 32 位小写 hex；按形态分流查询，历史 32 位用户 ID 查游客未命中时回查用户表；批量查询按 200 条分页取全） — `api/admin/internal/logic/account/user/get_online_users_logic.go:136-139` 用 36 位含 4 个横线判断 UUID，而 `randomx.GenerateRandomUUID` 生成时去掉了横线（32 位，`vkit/x/randomx/random.go:39-41`），所有真实用户都被当游客查询；同文件 58/71 行批量查询未传分页，默认 `size=10`，超过 10 人的明细被静默丢弃。
- ✅ **[Should] 游客身份由 `md5(ip+os+browser)` 生成**（改为服务端签发的 32 位随机 hex；Cookie + localStorage 两处持久化；IP/OS/浏览器降级为属性且仅在变化时更新；`/guest` 仅会话级调用，中间件以 Cookie 为权威、Cookie 只由 `/guest` 下发；游客档案长期保留、不设自动清理。清除站点数据视为新客户端，不做指纹找回） — `rpc/blog/internal/logic/guestservice/get_guest_logic.go:50-53`：同一 NAT 出口、同 OS/浏览器 的不同用户会合并为同一游客；换 IP 就新增一行，匿名接口可刷出大量记录；并发首次请求会撞唯一索引并把原始 DB 错误返回给匿名调用者。
- ✅ **[Should] 认证路径吞错、TOCTOU 与内部错误泄露** — 查询错误已区分 `ErrRecordNotFound`，并发注册的唯一键冲突映射为“邮箱已注册”；OAuth 登录的 `ErrRecordNotFound` 映射为“账号不存在”，其余错误只写服务端日志并按内部错误返回，不再透出原文。 — `login_by_mobile_logic.go:42`（查库失败走自动注册）、`login_by_o_auth_logic.go:54-56`、`bind_me_third_party_logic.go:53`、`get_guest_logic.go:53`、`reset_password_logic.go:49`；`register_logic.go:46-53` 先查后插不在事务内，并发注册返回原始唯一索引错误；`login_by_o_auth_logic.go:65-68` 把 DB 错误包装成 `RESOURCE_NOT_FOUND` 并透出 `err.Error()`。
- ✅ **[Should] 管理端网关不限制“管理员身份”，`/me/*` 组只挂 `AdminAuth`**（管理端登录改为要求至少一个启用角色，否则拒绝签发 admin 域 token） — `protocol/api/admin/account.api:110-156` 的登录接口是公开路由，`LoginByPassword` 对任意普通用户同样签发 admin 域 token（`Scope: admin-api`）；`api/admin/internal/handler/routes.go:335` 起的 `/me/*` 组只有 `AdminAuth`，没有 `Permission`。普通注册用户因此可以登录管理端并使用 `/me/profile`、`/me/bind-*` 等接口。
- ✅ **[Nit]** `register_logic.go` 的 optional 昵称已安全取值；客户端传入的用户名现在优先使用并校验唯一，未传才随机生成。

#### 3.4.2 授权与对象级访问控制

- ✅ **[Must] RBAC 对参数化路由、禁用接口、未分配接口全部默认放行：任意已登录用户可提权**
  - “已注册接口”判断是精确 map 查找：`api/admin/internal/middleware/permissionx/rbac_enforcer.go:220-223`，`allPerms[method+":"+r.URL.Path]` 找不到即放行。
  - 同步进 `allPerms` 的路径来自 Swagger，参数写成 `{id}`（`api/admin/docs/admin.json` 有 25 条含 `{...}` 的路径）；实际路由使用 `:id`，`r.URL.Path` 是具体的 `/roles/1/apis`。路径匹配函数又只认 `:` 前缀（`permissionx/matcher.go:65-87`），即使改用匹配判断也匹配不上 `{}`。
  - `rbac_enforcer.go:126-130` 在写入 `allPerms` 之前就跳过了 `APIStatusDisabled` 的接口——管理员“禁用接口”会让它从登记集合消失，从而对所有登录用户开放；而 `allPerms` 只由“角色-API 关联”推导（`:126-141`），新同步但尚未分配给任何角色的接口同样默认放行。
  - 后果：任何登录用户（含刚注册、无任何角色的账号）可直接调用 `PUT /roles/{role_id}/apis`（给自己授全量权限）、`PUT /users/{user_id}/roles`、`PATCH /users/{user_id}`、`POST /users/{user_id}/reset-password`、`DELETE /articles/{id}` 等全部带参路由。
  - 测试掩盖了问题：`rbac_enforcer_test.go` 的 `"param path"` 用例期望“允许”，但该路径未以具体值登记，实际走的是“未注册放行”分支。
  - 修复：登记判断改用路径匹配并统一 `{x}`/`:x`；未注册接口在 admin 侧 fail-closed；同步失败显式报警；补“参数化路径 + 无权限角色必须拒绝”的测试。
- ✅ **[Must] 接口同步遗漏 PATCH：新审核接口永远不被登记** — `sync_api_logic.go` 只展开 GET/POST/PUT/DELETE，admin Swagger 中已有的 PATCH（如 `/comments/{id}/review`、`/comments/batch-review`）不会进入 `t_api`。RBAC 改为 fail-closed 后，这些接口对所有角色永久拒绝，执行 `/apis/sync` 也无法恢复。修复：补齐 PATCH 与路径排序（同步结果稳定）、PATCH 标记为可追溯，并抽出 `infra/swaggerx` 加表驱动测试。
- ✅ **[Must] 聊天与评论更新越权**（关联字段清零已修；更新改为按操作者归属条件更新，评论仅允许正常/已编辑、聊天仅允许正常/已编辑/撤回，非本人返回无权限）
  - 聊天：`api/app/internal/common/stomphook/chatroom.go:236-241` 只传 `Id/Type/Content/Status`；`rpc/blog/internal/logic/chatservice/update_chat_logic.go:28-37` 不校验消息归属，✅ 并无条件写 `Nickname/Avatar`——调用方没传，导致每条被编辑的消息昵称和头像被清空。
  - 评论：`api/app/internal/logic/discussion/comment/update_comment_logic.go:28-33` 同样不传操作者身份；✅ `rpc/blog/internal/logic/discussionservice/update_comment_logic.go:28-40` 无条件把 `ParentId/ReplyId/Type` 覆盖为 0，并接受客户端传入的 `Status`——编辑一条回复会把父子关系与类型清空。
  - 任意登录用户可编辑任意聊天/评论记录（IDOR）。修复：更新契约加入操作者身份与归属校验。
- ✅ **[Must] `/me/login-logs` 越权读取全站登录日志**（网关强制以当前登录 uid 过滤） — `api/admin/internal/logic/account/me/query_me_login_log_list_logic.go:29-31` 只传分页，不传当前 uid；RPC `rpc/blog/internal/logic/syslogservice/list_login_logs_logic.go:36-38` 仅在 `UserId != nil` 时过滤。任意已登录管理员都能拉取全站所有用户的登录记录。修复：从 `metax` 取当前 uid 并强制作为过滤条件。
- ✅ **[Must] `SyncMenus` 空 `Meta` 解引用可崩溃 RPC 进程** — `rpc/blog/internal/logic/accessservice/sync_menus_logic.go:54` 直接读 `item.Meta.Perm`；`Meta` 在 protobuf 里是合法可省略的 message 字段。调用发生在 `go l.syncMenuList(in)` 里且没有 `recover`（`:29-34`），一次缺少 `meta` 的请求即可让整个 `blog-rpc` 进程 panic 退出；`sync_apis_logic.go` 对 `item` 为 nil 同样会 panic。结合上一条 RBAC 放行，普通账号也能触发。修复：入参校验 + goroutine 内 `recover`（panic 已修复；同步返回未改）。
- ✅ **[Should] RBAC 变更类接口无事务**（角色 API/菜单更新、批量删角色、清空接口/菜单均改为事务） — `update_role_api_logic.go:28-45`、`update_role_menu_logic.go:28-45` 先删后插，插入失败会让角色丢失全部权限；`batch_delete_roles_logic.go:28-45` 分四次删除多张表，中途失败留下部分删除；`clean_apis_logic.go`/`clean_menus_logic.go` 同理。
- ✅ **[Should] 接口/菜单同步是 fire-and-forget 且吞掉查询错误**（改为同步执行，返回真实数量与错误，panic 转 error） — `sync_apis_logic.go:29-34`、`sync_menus_logic.go:29-34` 起 goroutine 后立即返回 `SuccessCount: 0`，错误只写日志；`InsertApi/InsertMenu`（`:60` 附近）忽略 `FindOneBy...` 的错误，DB 故障会被当成“不存在”继续插入。
- **[Should] RPC 写接口普遍无归属校验（潜在越权）** — ✅ 创建文章改为优先使用 metadata 中的 uid，不信任请求字段；admin CMS 的其他写接口由 `AdminAuth+Permission` 授权，需以 gRPC 端口不对外暴露为前提。 — `update_article_logic.go:32-40`、`patch_article_logic.go:28-40`、`mediaservice/update_album_logic.go:28`、`update_photo_logic.go:28`、`batch_destroy_albums_logic.go:28` 等只按 id 改删；`create_article_logic.go:38` 直接信任请求里的 `UserId`。当前 HTTP 写路由由 `AdminAuth+Permission` 保护，但一旦 gRPC 端口可达或新增非管理员路由就会成为真实越权。
- ✅ **[Should] 已读标记未校验归属**（单条/批量均按 `recipient + channel=inbox` 限定） — `mark_record_read_logic.go:34-38` 只按 `id + status=unread`；`batch_mark_records_read_logic.go:45-47` 只按 `status=unread + id IN (...)`。请求里没有当前用户与 `recipient` 约束，结合 RBAC 放行可修改他人的已读状态。应传入调用者 userId 并加 `recipient = ? AND channel='inbox'`。
- ✅ **[Should] `role_key` 无唯一索引且 `ErrRoleExist` 被忽略**（DDL 增加唯一索引；创建/更新角色先查重并返回明确业务错误。上线前需清理历史重复 role_key） — `protocol/sql/blog.sql:402` 的 `role_key` 没有唯一约束；`rbac_enforcer.go:157-159` 忽略 `ErrRoleExist`。两个角色使用同一 `role_key` 时，第二个角色的权限被静默丢弃。
- ✅ **[Nit] `GetUserLikeArticle` 信任请求里的 `userId`**（改为从 metadata 取当前 uid） — `rpc/blog/internal/logic/contentservice/get_user_like_article_logic.go:30` 未与调用者身份比对（当前 app 路由传的是令牌 uid，但 RPC 层本身可被任意调用）。

#### 3.4.3 输入、注入与边界

- ✅ **[Must] 客户端可控的 `sorts` 原样进入 `ORDER BY`：公开接口 SQL 注入**（`queryx` 只保留「列名 [asc|desc]」，子查询、函数、分号与多级前缀均被丢弃，已补表驱动测试） — `infra/queryx/query_builder.go:32-47` 只做 `strings.Join`；各 model 的 `FindListAndTotal`/`FindOne` 直接 `db.Order(sorts)`，如 `t_article_model.go:249`、`t_category_model.go:239`、`t_tag_model.go:239`、`t_album_model.go:242`、`t_photo_model.go:242`、`t_page_model.go:241`、`t_friend_model.go:242`。入口是公开列表与 admin 各列表（`api/app/internal/logic/content/article/query_article_list_logic.go:36` 等）。触发：`GET /api/v1/articles` 携带 `Content-Type: application/json` 与 body `{"sorts":["id desc,(select ...)"]}`（go-zero 对 GET 也解析 JSON body；query 形式因下一条不生效）。可做布尔/时间盲注，或 `ORDER BY RAND()` 制造 CPU 消耗。修复：列名 allowlist + `asc/desc` 校验。
- ✅ **[Must] 所有 GET 列表接口的 query 参数不生效（分页、筛选、排序全部失效）**（查询类型补齐 `form` tag；同时移除 `ListQuery` 的 JSON 默认值，避免空 body 覆盖表单值；已补绑定测试） — `api/app/internal/types/types.go:123-127`、`api/admin/internal/types/types.go:95-99` 的 `ListQuery` 与各查询请求字段只有 `json` tag，没有 `form` tag。go-zero 的 `httpx.ParseForm` 使用 `form` 标签（`rest/httpx/requests.go:27-32`），字段没有 `form` tag 时回退为 Go 字段名（`core/mapping/utils.go:271-275`），因此 query 里的 `page` / `page_size` / `sorts` / `topic_id` / `article_title` 都匹配不上 `Page` / `PageSize` / `Sorts` / ...。前端恰恰用 axios `params` 发 GET query（如 `blog-app/src/api/content/article.ts:18-20`、`blog-admin/src/api/content/article.ts:21-24`）。后果：所有列表恒为默认分页（或零值），筛选全部被静默丢弃；只有带 JSON body 的请求才能生效。修复：补 `form` tag 或统一改为 JSON body 契约，并加端到端绑定测试。
- ✅ **[Must] 分页参数未做下限/上限校验，负数可绕过 LIMIT 全表返回**（`queryx.Build` 统一 clamp：页码最小 1，每页 1–1000） — `infra/queryx/query_builder.go:18-46` 只在 page/size 等于 0 时补默认值，负数原样保留；`rpc/blog/model/t_article_model.go:258`（其余 model 同型）仅在 `page>0 && size>0` 时才 `Limit/Offset`。触发：某公开列表携带 JSON body `{"page":-1,"page_size":-1}` → 不加 LIMIT 返回全表（含 longtext 正文），再叠加每条文章的浏览量查询，可放大为无认证 DoS。修复：统一 clamp。
- ✅ **[Must] 后台 STOMP 钩子用 `fmt.Sprintf` 拼接 JSON**（改为 `json.Marshal`，用户内容不再破坏 JSON） — `api/admin/internal/common/stomphook/chatroom.go:69,92,100,108` 把 `login` 与用户消息内容直接塞进 JSON 字符串，未做转义：消息里一个 `"` 就会产出非法 JSON，也可构造注入字段。app 侧已经用 `jsonv.AnyToJsonNE`（`api/app/internal/common/stomphook/chatroom.go:94`），后台侧应对齐。
- ✅ **[Should] 图形验证码尺寸无上限**（网关限制 80–400，`captchax` 入口再做 40–400 防御性 clamp） — `api/app/internal/logic/account/auth/get_captcha_logic.go:28`（admin 同）直接把客户端 `width/height` 传入；`infra/storex/captchax/captcha.go:81-88` 只在 0 时取默认，无上限/负值校验。匿名请求 `width=100000&height=100000` 即可触发巨量内存分配。
- **[Should] 上传凭证有效期无上限，文件名/目录未约束** — ✅ 有效期已限制在 60–3600 秒；文件名/目录约束不处理。 — `api/app/internal/logic/common/upload/create_upload_token_logic.go:30-35`（admin 同）对客户端 `ExpireSeconds` 不做上限，可申请超长期签名 PUT URL；`filepath.Join(req.FileBase, req.FileName)` 也未限制目录与文件名。
- ✅ **[Should] `QueryFileList` 负数分页触发切片 panic** — `api/admin/internal/logic/common/upload/query_file_list_logic.go:50-64`：`end` 在 `start` 被纠正为非负之前算出，`page_size < 0` 时得到 `filtered[0:负数]` → panic（go-zero recover 成 500）。
- ✅ **[Nit] 状态字段/照片归属值无校验**（新增 `IsValidIsDelete`/`IsValidArticleStatus`/`IsValidAlbumStatus`；创建/更新照片校验相册存在且未删除） — `BatchPatchAlbums/BatchPatchPhotos` 接受任意 `is_delete`（如 2），album/article 的 `status` 也接受任意整数；`create_photo_logic.go:29-36`、`update_photo_logic.go:33` 不校验 `album_id` 是否存在，可造出指向不存在相册的照片。
- ✅ **[Nit] `consume_inbox_message_logic.go:133-137`** — `target_ids` 用逗号 split，不 trim、不去重，`"u1, u2"` 会投递给 `" u2"`。

#### 3.4.4 数据正确性与可见性

- ✅ **[Must] 私密/草稿/已删除内容可按 ID 读取；私密相册出现在公开列表**（RPC 增加 `public_only` 参数，公开网关按公开条件查询；相册列表过滤 `status=1`，照片列表先校验相册可见；浏览量只统计公开文章）
  - 文章：`rpc/blog/internal/logic/contentservice/get_article_logic.go:30` 只按 id `FindById`，无 `status=1 and is_delete=0`；公开路由 `GET /api/v1/articles/{id}` 直接暴露正文，且先调用 `IncrementArticleView`（`api/app/internal/logic/content/article/get_article_logic.go:29-34`），草稿/删稿浏览量也会被刷。
  - 说说：`rpc/blog/internal/logic/discussionservice/get_talk_logic.go:24-27` 无 `status` 过滤。
  - 相册：`rpc/blog/internal/logic/mediaservice/get_album_logic.go:28-35` 无任何过滤；公开列表 `api/app/internal/logic/media/album/query_album_list_logic.go:29-38` 只传 `is_delete=0`，未过滤 `status=1`（`t_album.status` 1 公开 / 2 私密）；照片列表 `query_album_photo_list_logic.go:29-38` 也不校验所属相册是否私密/已删除。
  - 修复：RPC 层把“公开可见”作为显式参数（管理端复用同一 RPC，不能全局过滤），公开网关一律传公开条件。
- ✅ **[Must] 后台照片列表空指针** — `api/admin/internal/logic/media/photo/query_photo_list_logic.go:31` 直接解引用 `*req.AlbumId`；`AlbumId` 在 `protocol/api/admin/media.api:114` 是 optional（生成类型 `*int64`，`api/admin/internal/types/media_photo.go:34`）。`GET /admin-api/v1/photos` 不带 `album_id` → nil deref（500）。
- ✅ **[Must] 新建文章丢失作者**（admin 网关从认证上下文取 uid 写入请求） — `api/admin/internal/logic/content/article/create_article_logic.go:29-39` 的请求根本没有 `UserId`；RPC `rpc/blog/internal/logic/contentservice/create_article_logic.go:38` 落库 `user_id: in.UserId`（空串），文章详情作者恒为 null。修复：从已认证的 metadata 取 uid，不信任请求字段。
- ✅ **[Must] “发给全部用户”的通知只发给禁用账号** — `rpc/blog/internal/mq/mqlogic/consume_inbox_message_logic.go:123` 写死 `FindALL(ctx, "status = ?", 1)`；代码语义是 `UserStatusNormal = 0`、`UserStatusDisabled = 1`（`infra/constants/enums/model.go:124-127`）。修复：使用 `enums.UserStatusNormal` 并排除 `Logoff/Deleted`。注意与“用户状态模型”一条的耦合：当前注册用户因 GORM `default:1` 实际都落库为 1，公告“碰巧”能发给注册用户；修好状态模型后本问题会立刻暴露，两处必须一起改。
- ✅ **[Must] 聊天历史查询恒为空**（毫秒时间戳在 RPC 内转为 `time.Time`） — `rpc/blog/internal/logic/chatservice/list_chats_logic.go:29-34` 用 `created_at > ?` / `created_at < ?` 接收 `int64`，而 `t_chat.created_at` 是 `datetime`（`protocol/sql/blog.sql:118`）；调用方传毫秒时间戳（`api/app/internal/common/stomphook/chatroom.go:106-110`）。MySQL 对 `DATETIME` 与整数做隐式转换，`created_at < 1.79e12` 恒不成立，进入聊天室时历史列表为空。修复：传 `time.Time` 或格式化时间。
- ✅ **[Must] 邮件模板占位符未渲染，注册邮件正文是字面量** — `rpc/blog/internal/mq/mqlogic/consume_email_message_logic.go:42-45` 把 `tmpl.Content` 原样赋给 `event.Content`，`sendEmail`（`:101-108`）直接当正文发送；全链路没有占位符替换。种子模板 `EMAIL_REGISTER`（scene=register）正文是 `感谢您注册 {site_name}，请点击链接完成验证：{link}`（`protocol/sql/blog-data.sql:89-90`），用户收到的就是字面量。其它 scene（如 `email_login`）没有模板，走默认文案（`:50-52`，包含真实验证码），这条路径正常。修复：按 `event.Params` 渲染模板并补测试。
- ✅ **[Should] 文章创建/更新与标签写入不在同一事务，且标签逐条 upsert**（文章、分类、标签写入已收敛到同一事务；标签名去重并过滤空值。标签查询/插入仍是逐条，见 N+1 项） — `create_article_logic.go:49-75`：文章先落库，标签再单独开事务；标签失败时文章已存在，客户端重试会产生重复文章。`update_article_logic.go:51-78` 同理。`helper.go:203-233` 的 `findOrAddCategory/Tag` 在循环内逐条查询/插入（N+1），空标签名会写入 `tag_id=0`，重复标签名会撞 `uk_article_tag`。
- ✅ **[Should] N+1 查询/远程调用**（文章浏览量改 pipeline 批量取；评论回复新增批量 RPC 一次取回；回复数改 `GROUP BY`；RBAC 角色资源改批量 RPC；统计排行改 `IN` 批量查询） — 文章列表逐条查浏览量（`helper.go:107-124,151,238`，每条一次 Redis `ZScore`，缓存未命中再查 DB）；网关评论列表对每条评论单独调 `ListCommentReplies`（`api/app/internal/logic/discussion/comment/query_comment_list_logic.go:71-113`，每页 20 条即 20 次 RPC）；评论回复数按 `TopicIds` 逐个 `FindCount`（`get_comment_reply_count_logic.go:29-35`，且未排除已删除评论）；RBAC 策略加载对每个角色一次 `GetRoleResource`（`rbac_enforcer.go:119`）；统计接口 `ZRevRange` 后逐条 `FindById`（`get_article_stats_logic.go:141-158`）。建议批量 `IN` + map / pipeline / 批量 RPC。
- ✅ **[Should] 硬删除不清理关联数据**（删标签清 `t_article_tag`；删分类把文章归入未分类；销毁相册连同照片；删文章清标签关系与 Redis 计数缓存） — `batch_delete_tags_logic.go:28` 删标签但 `t_article_tag` 关系残留；`batch_delete_categories_logic.go:28` 删分类后文章 `category_id` 悬空；`batch_destroy_albums_logic.go:28` 硬删相册但照片保留且 `is_delete=0`（成为永不清理、仍可通过照片接口访问的孤儿）；`batch_delete_articles_logic.go:28` 不清标签关系与 Redis 点赞/浏览量 zset。
- ✅ **[Should] `BatchPatchAlbums` 二级更新失败被吞且无事务**（已改为事务；仅删除时级联照片，恢复相册不再复活单独删除的照片） — `batch_patch_albums_logic.go:28-40` 先改相册再改照片，照片失败只 `Errorf` 仍返回成功；恢复相册会把该相册下所有照片（含此前单独删除的）一并恢复。
- ✅ **[Should] 公开留言列表的状态常量错误**（改用 `MessageStatusNormal`） — `query_message_list_logic.go:28-40` 固定 `status=1`，而 `MessageStatusNormal = 0`（`infra/constants/enums/model.go`），公开列表实际只显示“已编辑”留言。评论列表的同类问题已随审核流修复。
- ✅ **[Should] 相关文章查询漏 `is_delete` 且吞错** — 四条查询已补 `is_delete=0`；查询失败已改为返回错误。
- ✅ **[Should] 按不存在的分类/标签筛选时条件被静默丢弃** — 查不到分类/标签时改为 `1 = 0`，返回空列表而不是全部文章。
- ✅ **[Should] 分类/标签文章数统计口径错误**（统计补 `is_delete=0 AND status=1`，标签统计按文章表关联过滤） — `helper.go:261-265,285-289` 统计未加 `is_delete=0/status=1`；`list_categories_logic.go:46`、`list_tags_logic.go:46` 用 `acm, _` 丢弃统计错误。
- ✅ **[Should] 相册照片数与分页问题**（公开列表过滤状态；照片列表接收分页参数并校验相册可见） — ✅ `get_album_logic.go:34` 传 `nil`，后台相册详情 `photo_count` 恒为 0；`list_albums_logic.go:78-85` 统计未过滤 `is_delete=0`；公开照片列表 `query_album_photo_list_logic.go:32-34` 硬编码 `Page:1, PageSize:100`，第 101 张起永远不可见。
- ✅ **[Should] `PatchArticle` 丢弃 `is_top`；导出接口是空实现**（`is_top` 已透传；导出实现为 Markdown，前端触发下载） — `api/admin/internal/logic/content/article/patch_article_logic.go:29-32` 只转发 `Id/IsDelete`，置顶操作永远不生效；`export_article_logic.go:27-29` 直接返回成功，未实现任何导出。
- ✅ **[Should] 删除通知消息不清理投递记录**（同事务删除 `t_notify_record`） — `batch_delete_notify_messages_logic.go:41-49` 只删 `t_notify_message`；`ListUserInboxRecords` 不校验消息是否存在，用户会看到标题/分类为空的未读项，未读数继续计入。
- ✅ **[Should] 公开首页展示定向通知**（首页只取 `target_type=all`） — `api/app/internal/logic/site/home/get_blog_home_info_logic.go:73-76` 只过滤 `status=published`；`list_notify_messages_logic.go:28-53` 没有 `target_type` 约束，`target_type=user_ids` 的定向公告会出现在所有访客的首页。
- ✅ **[Should] 站内信投递的去重不可靠**（投递已按消息行锁串行化，幂等查询与插入同事务，重复投递被挡在事务内；查询错误也已上抛） — `consume_inbox_message_logic.go:58-67` 查询已有记录失败时只记日志并继续插入；`t_notify_record` 没有 `(message_id, channel, recipient)` 唯一索引（`protocol/sql/blog.sql:303-322`）。RabbitMQ 至少一次投递、重投与发布并发时会产生重复未读。
- ✅ **[Should] 目标用户解析失败被当成“无目标用户”并 ack**（`resolveRecipients` 已改为返回 error，查询失败触发重投） — `consume_inbox_message_logic.go:120-127` 的 `resolveRecipients` 在 DB 出错时返回 nil；`Consume` 在 `:51-55` 把 nil 解释为“无目标用户”并 `return nil`，消息被确认、不再重试，整条公告静默丢失。
- ✅ **[Nit] 首页页面列表被默认分页截断为 10 条**（显式传 `PageSize=100`） — `get_blog_home_info_logic.go:42` 用空 `ListPagesRequest{}`，queryx 默认 `size=10`。
- ✅ **[Nit] 缺失 `website_config` 会让整个首页报错**（配置缺失返回空对象，首页按零值降级） — `get_blog_home_info_logic.go:59-64` 与 `get_config_logic.go:28`：新部署没有该行时返回 `ErrRecordNotFound`，首页整体 500，而不是空配置降级。
- ✅ **[Nit] 后台 `GetMe` 丢失已有数据** — `api/admin/internal/logic/account/me/get_me_logic.go:36-49` 固定返回空 `ThirdParties`、时间戳写 0，与 `.api` 契约不符。
- ✅ **[Nit] admin 更新文章只回填 `Id`**（更新后重新查询并返回完整 VO） — `api/admin/internal/logic/content/article/update_article_logic.go:44-47` 返回的 `ArticleVO` 其余字段全为空，与完整 VO 契约不符。
- ✅ **[Nit] 邮件/短信重试每次都新插一条投递记录**（发布端生成事件 ID；投递记录以 `(biz_id, channel)` 唯一索引去重，重投复用原记录并跳过已发送；旧格式消息无事件 ID 时退化为一次一记录） — `consume_email_message_logic.go:55-98`、`consume_sms_message_logic.go:51-94`；`biz_id` 被注释为幂等键却从未用于去重。
- ✅ **[Nit] 统计接口的其他口径问题**（地域统计按区域名排序；看板计数与收件箱查询错误已上抛） — `get_geo_stats_logic.go:80-86` 的 `ORDER BY` 被 map 遍历打乱；`get_dashboard_stats_logic.go:40-42` 计数错误被丢弃；✅ `batch_delete_notify_records_logic.go:28-34` 逐 id 删除；`list_user_inbox_records_logic.go:96-107,148-152` 查询失败只打日志仍返回成功。

#### 3.4.5 凭据、日志与外部依赖

- ✅ **[Must] gRPC 服务端日志明文记录密码**（请求/响应先递归脱敏再写日志，密码、令牌、授权码等字段统一替换为 `***`，已补测试） — `infra/interceptorx/grpc_server_log_interceptor.go:14-35` 对每个 unary 请求 `json.Marshal(req)` 后以 `Infow` 写日志，且已在 `rpc/blog/blog.go:142` 接线。`LoginByPasswordRequest.password`（`protocol/proto/blog/auth.proto:13-16`）、改密/重置密码请求都会以明文进入日志；生产日志配置为 `Mode: file`，会落盘。截断到 500 字节也挡不住。修复：按方法/字段脱敏，或对认证类方法完全不记录请求体。
- ✅ **[Must] 示例配置携带生产凭据**（三份示例配置已改为 `CHANGE_ME`；线上凭据仍需人工轮换并改为外部注入） — `api/app/etc/app-api.example.yaml:24,33`（MinIO SecretKey、Redis 口令）、`api/admin/etc/admin-api.example.yaml:24,33`、`rpc/blog/etc/blog-rpc.example.yaml:13,20,27`（MySQL/Redis/RabbitMQ 口令）。逐值比对确认：示例中的 7 类凭据值全部同时出现在 `deploy/` 的 45 份配置里。必须轮换并改为占位符/外部注入。
- ✅ **[Must] IP 归属地查询无超时，且在事务与公开热路径中同步调用**（`iplocx` 加 2s 超时与 24h 缓存、失败短期负缓存；注册/手机登录/OAuth 的查询移到事务外；公开路径仍同步但有界） — 根因在 `vkit/adapter/iplocx/ip_baidu.go:47`（`http.Get` 默认 client 无超时）。调用点：`register_logic.go:75`（GORM 事务内）、`login_by_mobile_logic.go:58`、`login_by_o_auth_logic.go:87`（同样在事务内）、`guestservice/get_guest_logic.go:46`（公开接口）、`api/app/internal/common/stomphook/chatroom.go:86,184`（每次连接/订阅/发言）。百度接口抖动会拖住数据库事务、登录、游客信息乃至 WebSocket 连接；公开端点还形成可放大的外部请求入口，并把客户端 IP 发给第三方。建议加超时与缓存、移出事务、公开路径改异步或本地库。
- **[Should] 审计身份可被伪造（uid 头与 XFF）** — ✅ 入口不再透传客户端 uid/token，鉴权通过后由认证中间件写入可信 metadata；✅ 远程 IP 统一用 `requestx.ClientIP`；❌ 访问日志仍按请求头 uid 记录（暂不校验，保留现状）。 — 全局 `CtxMetaMiddleware` 把客户端 `uid`/`x-device-id` 原样写入 metadata（`infra/middlewarex/meta_middleware.go:30-54`），而 `VisitLog` 是全局中间件，直接读取未验证的 uid/deviceId 写访问日志（`api/app/internal/middleware/visitlog_middleware.go:31-37`）；匿名请求伪造 `uid: root` 即可污染审计。另一方面 `meta_middleware.go:51-52` 用 `httpx.GetRemoteAddr(r)`（只认 XFF、返回整串）写入 `rpc-remote-ip`，伪造 `X-Forwarded-For` 可污染 guest/chat/login 审计的 IP 字段，guest 逻辑还用它参与 `device_id` 的 md5（`get_guest_logic.go:50`）。建议只在鉴权通过后传递身份头，入口处剥离客户端身份头；IP 统一用 `requestx.ClientIP` 的“最后一跳”口径。
- ✅ **[Should] 访问日志映射全部失效，`VisitLog` 实际从不写日志**（按当前路由重写，参数化路径用 `routex.Match`，含表驱动测试） — `api/app/internal/middleware/visitx/enforcer.go:12-23` 的 key 是旧路由（`/api/v1/blog`、`/api/v1/article/get_article`、`/api/v1/album/get_album`、`POST /api/v1/message/query_message_list` 等），当前路由已改为 `/api/v1/home`、`/api/v1/articles/:id`、`/api/v1/albums/:id`、`/api/v1/messages` 等；且 `IsVisitPage` 只做精确匹配。
- ✅ **[Should] 登录/登出日志不完整或错配**（`Status` 显式赋值；账号不存在、密码错误、禁用/注销均发布失败事件；登出按 `user_id + device_id + logout_at IS NULL` 更新） — 只有 `login_by_password_logic.go:73-78` 发布 `LoginEvent`，邮箱/手机/OAuth 登录都没有日志；`LoginEvent.Status` 未赋值（零值 0=失败），实际落库依赖 `t_login_log.status default:1` 被 GORM 覆盖成 1，属于偶然正确。登出消费者 `consume_logout_logic.go:31-45` 只按 `user_id = ?` 取最近一条，忽略 `DeviceId`，也没有 `logout_at IS NULL` 条件，多设备时会标记错记录。
- ✅ **[Should] 日志列表的日期过滤失败时被静默丢弃**（登录/访问/上传/操作日志均改为返回参数错误） — `list_login_logs_logic.go:42-51` 以及 operation/upload/visit 的同名逻辑：`time.Parse` 失败时直接不加条件，调用方拿到全量日志而不是空结果。
- ✅ **[Should] `OperationLog` 的请求体捕获实际失效，修复时必须脱敏** — `api/admin/internal/middleware/operationlog_middleware.go:67-73` 在 `next.ServeHTTP` 之后才 `io.ReadAll(r.Body)`，而 go-zero 的 `httpx.ParseJsonBody` 已把 body 读空（`rest/httpx/requests.go:117-124`），`request_data` 基本恒为空。若要修成真正记录请求体，必须同时按字段脱敏——`PUT /me/password` 等路由默认可追溯（`sync_api_logic.go:102-105` 把所有 PUT/DELETE 标为 traceable），否则会把明文密码写进 `t_operation_log`。
- ✅ **[Should] GORM 日志记录 SQL 参数值**（`ParameterizedQueries` 开启；非控制台模式只记 `Warn` 及以上） — `rpc/blog/internal/svc/service_context.go:174-189` 两处都设置 `ParameterizedQueries: false`、`LogLevel: logger.Info`，所有查询实参（邮箱、手机号、密码哈希等）会写入日志文件。建议生产改为 `true` 或只记录慢查询/错误。
- ✅ **[Should] 部分可追溯接口漏挂 `OperationLog`**（`/auth/session` 与 `/me/*` 组已补挂） — `api/admin/internal/handler/routes.go:293-299`（`DELETE /auth/session`）与 `:335-341`（`/me/avatar` 等只挂 `AdminAuth`），但 `sync_api_logic.go:102-105` 把所有 PUT/DELETE 标记为 traceable。
- ✅ **[Should] 内部错误原文透给客户端**（HTTP 与 gRPC 出口统一返回通用文案，真实错误只写服务端日志） — `infra/responsex/response.go:248-252` 对非 `BizError` 直接返回 `err.Error()`；`grpc_server_errors_interceptor.go:18` 把任意 handler error 以 `codes.Internal` + 原文回传。DB/MinIO/RPC 连接失败时，客户端能看到表名、连接地址等内部信息；`permission_middleware.go:38-41` 还把权限服务故障写成 `PERMISSION_DENIED`。
- ✅ **[Should] 防重放可绕过**（写操作强制 timestamp，窗口改为双向 3600 秒。device-token 仍是无密钥的客户端标识，不作为安全边界） — `infra/middlewarex/antireply_middleware.go:27-34`：timestamp 缺失直接放行；`now-ts > 3600` 只拦过去，未来时间戳任意通过。配合 `terminaltoken_middleware.go:51` 的 `sha256(deviceId+timestamp)`（无密钥、可自算），device-token 不构成完整性/重放边界。
- ✅ **[Should] 后台 Swagger/knife4j 与音乐代理公网暴露 + CORS 通配**（knife4j 生产环境不注册；音乐代理加限流；CORS 通配按部署需要保留） — `api/admin/internal/plugins/plugins.go:18` 的 knife4j 路由不挂鉴权；`api/app/internal/plugins/plugins.go:22-25` 的 `/api/v1/music/*` 是无鉴权、无限流的外部站点代理，每次请求触发一次 outbound HTTP；两个网关都用 `rest.WithCors("*")`（`api/app/app.go:65-67`、`api/admin/admin.go:66-68`）。
- ✅ **[Should] 每次 PV 都做全量 SUM**（改为读取前一天最后一行的累计值，并处理 `Scan` 错误） — `create_visit_log_logic.go:52-58,103` 每次访问执行一次 `SELECT SUM(...) FROM t_daily_stats WHERE date < ?`（UV 还多一次），随天数与访问量线性放大；建议缓存或在日切时计算。
- ❌ **[Should] 聊天广播泄露参与者的 IP 与 device_id**（不处理：前端用 `ip_address` 判定游客自己的消息，直接移除会破坏界面；彻底方案需引入不可逆的 sender_id 并同步改前端） — `api/app/internal/common/stomphook/chatroom.go:106-143` 的历史帧与 `:210-228` 的新消息帧都包含 `IpAddress/IpSource/DeviceId`；任何进入聊天频道的人都能收集全部参与者的 IP 与设备号，而 device_token 又可由 `sha256(deviceId+timestamp)` 自行计算。
- ✅ **[Should] WebSocket handler 在连接劫持后仍写 HTTP 信封**（handler 升级后不再写响应，失败信息由升级逻辑自行写回） — `api/app/internal/handler/common/websocket/websocket_handler.go:16-18`（admin 同）无条件调用 `responsex.Response`；`HandleWebSocket` 升级成功后立即返回（连接交给后台协程），随后对已 hijack 的 writer 写 JSON，产生 `ErrHijacked` / `WriteHeader on hijacked connection` 噪声；升级失败时又会在已写 503 后再写 200 信封。应只在升级失败时写响应。
- ✅ **[Nit] AMQP URL 未转义** — 重构前用 `fmt.Sprintf` 拼接，用户名/口令含 `@`、`:`、`/` 时解析失败；应用 `url.URL{User: url.UserPassword(...)}`。
- ✅ **[Nit] `OperationLog` 的 Swagger 查找对参数化路由永远失败** — `operationlog_middleware.go:129-153` 用 `k == path` 精确匹配 Swagger 的 `{id}` 模板，`/articles/123` 等记录 `module/description` 为空。
- ✅ **[Nit] `create_visit_log_logic.go:53-58`**（`Scan` 错误已检查） — `row.Scan` 返回值被忽略。

#### 3.4.6 错误处理（横切）

- ✅ **[Should] 吞错清单** — 已逐项改为区分 `gorm.ErrRecordNotFound` 与真实错误：登录/注册/重置密码/绑定第三方/游客、文章筛选与分类标签统计、关联文章、日志日期解析、接口与菜单同步、在线用户与看板统计均不再把故障当成“不存在/空结果”。文章筛选命中不存在的分类/标签时返回空结果，而不是丢掉筛选条件。（规则 4.4）
- ✅ **[Nit] `api/app/internal/logic/common/upload/upload_file_logic.go:52`** — `_, _ = CreateUploadLog(...)` 吞错无注释说明理由。
- ✅ **[Nit] 浏览器自增失败会让文章详情整体失败** — 已改为记录日志后继续返回正文，浏览量失败不再影响详情。
- ✅ **[Nit] `siteservice/convert.go:19`** — `jsonv.JsonToAny` 失败现在记录日志，脏数据不再完全静默。

### 3.5 一致性与简洁

- ✅ **[Should] 邮件 `is_ssl` 配置被静默丢弃** — `rpc/blog/internal/config/config.go:59` 定义了 `IsSsl`，但 `rpc/blog/internal/svc/service_context.go:233-241` 构造 `emailx.EmailConfig` 时没有映射 `SSL` 字段；`emailx` 只在 `SSL=true` 时设置 `TLSConfig`。按示例配置的 465 端口，邮件发送行为与配置不符。（规则 4.4 / 5.2）
- ✅ **[Should] `OperationLog` 的结构性问题** — `getApiSpec`（`operationlog_middleware.go:129-153`）每个请求线性遍历全部 Swagger path；`:67-73` 重新读已消费的 body、`:158-160` 把完整响应体缓冲到内存后再截断，对上传/大响应没有上限；`responseRecorder` 未实现 `http.Flusher`/`Hijacker`（当前 SSE/WS 路由未挂该中间件，暂不可触发，但全局启用会破坏流式响应）。建议建 path 索引、`io.LimitReader` 限额，并在 handler 前缓存请求体。
- ✅ **[Should] 构建与 CI 可复现性** — `.github/workflows/ci.yml:68-69` 使用 `GOWORK=off GOFLAGS=-mod=mod`，而 `*.sum` 被 `.gitignore` 忽略；`:82-84` 只给 stompws 开 `-race`，blog-cloud 的并发代码不会被检出。`lint.sh:10-19` 会改写所有 import 分组空行，包括 `internal/pb/**` 生成文件。
- ✅ **[Should] 文档测试没有断言** — `api/admin/docs/docs_test.go:19-41`：解析失败只打印并 `return`，成功路径仅 `t.Log`，`getRoutes` 结果循环体为空。违反 `go.md`“要断言，不要只打印”。
- ✅ **[Nit] 状态注释三处互相矛盾** — `rpc/blog/model/t_user_model.go:53`、`protocol/sql/blog.sql:499`、`api/admin/internal/types/account_user.go:44`（0/1/2 含义与枚举相反）。
- ✅ **[Nit] `next(w, r)` 与 `next.ServeHTTP(w, r)` 混用** — 如 `api/app/internal/middleware/userauth_middleware.go:59`、`api/admin/internal/middleware/adminauth_middleware.go:59`、`infra/middlewarex/ratelimit_middleware.go:36`。（模板中间件按要求保留，未改。）
- ✅ **[Nit] 注释与实现不一致** — `infra/middlewarex/terminaltoken_middleware.go:50` 实际是 `Sha256v`，而 `infra/biz/bizheader/header.go:72` 注释写的是 md5；`api/app/internal/svc/service_context.go:157` 的 `// no password set` 注释已过时。
- ❌ **[Nit] 日志出口不统一** — STOMP 钩子与 `infra/stompwsx/online.go` 使用标准库 `log.Printf`（带 emoji），其余系统统一用 `logx`。（不处理：STOMP 日志需要输出到控制台）
- ✅ **[Nit] 示例配置 `Mode: dev` 会打开 gRPC reflection** — `rpc/blog/etc/blog-rpc.example.yaml:3` 与 `rpc/blog/blog.go:134-136`；`make init-config` 会把示例直接复制成运行配置。
- ✅ **[Nit] 短信模板 key 与场景值不一致** — `rpc/blog/etc/blog-rpc.example.yaml:49-53` 的 `login`/`bind_mobile` 与接口场景 `login / reset_password / bind_phone` 对不上，切到 aliyun/tencent 时 `bind_phone` 取不到模板。
- ✅ **[Nit] 评论审核枚举未实现** — `infra/constants/enums/model.go:65-67` 的 `CommentIsReviewNo/Yes` 未被任何查询使用。
- ✅ **[Nit] 测试只打印不断言** — `infra/constants/mailtemplate/captcha_code_test.go:25-26` 仅 `t.Log(err)`，模板渲染失败测试仍会通过。
- **[Praise]** `responsex` 是全仓最好的设计之一：业务错误标识只在出口一处映射 HTTP 状态（`infra/responsex/response.go:61-95`），`statusAllowlist` 防止后门，`bizcode.All` + 测试保证枚举完整性。
- **[Praise]** `bizerr.WithBizError/FromStatus` 把业务标识编码进 gRPC `ErrorInfo` 并保留 canonical code 兜底，跨层错误语义完整。
- **[Praise]** `limitx` 的滑动窗口 Lua 脚本、`gormlogx` 的 `classify`/`emission` 表驱动，都是“规则与不变量写在代码里”的好例子。

## 四、汇总

| 级别 | 数量 | 主要条目 |
|---|---|---|
| **Must Fix** | **22** | 验证码结果被丢弃导致任意账号接管；RBAC 参数化路由/禁用接口/未分配接口 fail-open 导致提权；ORDER BY 注入；注册落库为禁用 + 注销仍可登录；管理员重置密码为空；绑定邮箱/手机无验证；聊天/评论更新越权与字段覆盖；私密/草稿/已删除内容可按 ID 读取；`/me/login-logs` 越权；后台照片列表空指针；新建文章丢作者；分页负数绕过 LIMIT；广播通知只发给禁用账号；聊天历史恒为空；邮件模板占位符未渲染；`SyncMenus` 空指针可崩溃 RPC；所有 GET 列表 query 参数不生效；gRPC 日志明文记录密码；示例配置中的生产凭据；IP 归属地无超时且在事务内；后台 STOMP JSON 拼接；接口同步遗漏 PATCH |
| **Should Fix** | **70** | OTP 暴力破解/发送轰炸；改密后不吊销 token；OAuth state 未校验；资料更新清空字段；验证码 scene 收发不一致；在线用户 UUID 识别错误；图形验证码尺寸无上限；文章事务边界；点赞/浏览量并发丢更新；硬删除孤儿数据；零值更新失效；通知删除/投递去重/撤回竞态；定向通知上首页；登出日志错配；RBAC 变更无事务与缓存回填竞态；同步接口异步丢弃结果；公开列表状态过滤错误；审计身份/XFF 可伪造；访问日志映射失效；上传凭证有效期无上限；后台文档/音乐代理公网暴露；OperationLog/GORM/gRPC 日志问题；Redis 成员 TTL 被整键覆盖；WebSocket 信封；内部错误泄露；更新接口响应类型不一致；每网关 11/12 个 zrpc 客户端；N+1；关闭逻辑不生效；MQ 全局变量；重复实现；业务层零单测；CI 可复现性等 |
| **Nit** | **26** | 状态注释矛盾、`next` 风格、md5/sha256 注释、未用类型、过时注释、标准库 log、吞错无注释、首页默认分页截断、配置缺失导致首页 500、`target_ids` 未 trim、重试产生重复投递记录、统计排序被 map 打乱、示例 `Mode: dev` 开 reflection、短信模板 key 不一致、`QueryFileList` 负数分页 panic、测试只打印不断言等 |
| **Praise** | **9** | handler/model 分层、tokenx、permissionx 编译期检查、sse.Broker、presencex、通知发布/撤回的并发守卫、responsex、bizerr gRPC 桥接、limitx/gormlogx |

> 数量为审查时口径；✅ 表示已处理，❌ 表示已明确不处理。

## 五、建议的修复顺序

1. **认证与授权（P0，先于一切）**
   - 验证码校验失败改为返回业务错误（或网关检查 `Success`），补回归测试——这是当前任意账号接管的入口；
   - RBAC：登记判断改用路径匹配并统一 `{id}` / `:id`，未注册接口在 admin 侧 fail-closed；
   - `sorts` 改为列名 allowlist，禁止原样进 `ORDER BY`；
   - 管理员重置密码透传 `new_password`；绑定邮箱/手机号补验证码校验；
   - 修复聊天/评论更新的归属校验与部分更新语义。
2. **数据可见性、状态模型与功能性缺陷**
   - 给查询请求补 `form` tag，恢复所有 GET 列表的分页/筛选/排序；
   - 详情接口（文章/说说/相册）统一加 `status/is_delete` 可见性约束；
   - 统一 `UserStatus` 枚举、DDL 注释/default 与 GORM `default` 标签；同步修正广播收件人筛选；注册流补测试；
   - 分页参数 clamp（下限 1、上限配置化）；
   - 修复聊天历史的 `DATETIME`/毫秒时间戳比较、邮件模板占位符渲染、`SyncMenus` 入参校验与 goroutine `recover`。
3. **安全与可靠性**
   - 轮换并替换示例配置中的生产口令/密钥（已确认与 `deploy/` 一致）；
   - 给 `iplocx` 加超时与缓存，移出事务、从公开热路径改异步；
   - 修复后台 STOMP 的 JSON 转义；`/me/login-logs` 按当前 uid 过滤；
   - 给 gRPC 日志拦截器加敏感字段脱敏，GORM 日志改为参数化输出；
   - 改密/禁用/注销后调用 `RevokeAll`；防重放校验时间窗口两端。
4. **架构装配**
   - 共享一个 `zrpc.Client`；把 `ConnectRedis`、Nacos 引导、鉴权中间件、`apiutils` 去重；
   - app 注册关闭监听，两个网关接上 `hub.Shutdown`；
   - MQ 全局状态注入 `ServiceContext`。
5. **性能与整洁**
   - 批量化 N+1；事务边界与硬删除清理；
   - 删除模板中间件/未注册拦截器/未使用的 captcha 方法；
   - 补认证、RBAC、通知链路的逻辑层单测；
   - 修正邮件 `SSL` 映射、响应类型与文档测试断言。

## 六、覆盖与限制

- 已逐文件通读：`authservice`、`userservice`、`guestservice`、`contentservice`、`mediaservice`、`siteservice`、`notificationservice`、`accessservice`、`discussionservice`、`chatservice`、`syslogservice`、`statsservice`，两个网关的 `logic`/`middleware`/`svc`/`plugins`/`common`，以及 `infra/**`、`cmd/presencecheck`。
- 已核对：Swagger 与路由、GORM 默认值与零值更新行为、客户端输入到 SQL 的完整链路、示例配置与部署配置的凭据一致性、go-zero 表单/JSON 绑定行为。
- 未覆盖：运行期行为与性能实测、K8s 部署与网络边界、前端实现、`internal/pb/**` 与 `routes.go` 生成代码内部。
- `golangci-lint` 未安装，未执行；`gofmt`、`go vet`、`go build`、`go test`、`go test -race`（infra + api）均通过。
