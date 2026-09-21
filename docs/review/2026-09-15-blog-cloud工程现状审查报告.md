# blog-cloud 工程现状审查报告

> 日期：2026-09-15
> 范围：`blog-cloud`（Go 服务端）+ `deploy/` 部署配置 + `docs/`
> 方式：两轮独立排查 —— 代码遗留项（TODO / 死代码 / 吞错）与测试覆盖现状，逐条人工复核后成文
> 性质：**日期快照**。结论对应上述日期的代码状态，落地后以代码为准。

---

## 〇、结论概览

项目整体是健康的：`go build ./...` 与 `go vet ./...` 全绿，没有 `panic("not implemented")`、空 `err != nil {}` 分支或空 switch 分支。问题集中在三类：

1. **工程保障缺失** —— 没有任何自动化检查，测试覆盖几乎为零且恰好漏掉最关键的层
2. **若干安全/数据正确性隐患** —— 均有界，但方向是越权或错误掩盖
3. **文档与配置漂移** —— 端口方案、存储方案、模块结构都改过，文档与模板没跟

按「修复价值 / 成本」排序的完整清单见下。

---

## 一、工程保障（最高价值）

### 1.1 没有任何自动化检查

| 位置 | 现状 |
|---|---|
| `.github/workflows/` 三个 workflow | 全是镜像构建与清理，**无 `go build` / `go vet` / `go test`** |
| `blog-cloud/lint.sh` | 不是检查器，是**格式化器** —— 用 awk 删 import 块空行 + `gofmt -w` 原地改写文件 |
| `blog-cloud/Makefile` | 无 test target |
| 根 `Makefile` 的 `test` | 是「跑起全栈联调」的启动目标，与 Go 测试同名但无关 |

**后果**：编译不过、格式不对、测试失败都能直接合进主干。

**建议**：新增 CI workflow —— 四个 Go 模块跑 `gofmt -l` + `go build ./...` + `go vet ./...` + `go test ./...`；两个前端跑 `vue-tsc --noEmit`。

> 前置条件已解除：`infra/biz/bizerr/error.go:47` 的非恒定格式串曾让 `go test ./...` 直接编译失败，已于本次修复（见 §七）。

### 1.2 测试覆盖几乎为零，且漏掉最关键的层

794 个 `.go` 文件，11 个测试文件。

| 层 | 文件数 | 测试 |
|---|---|---|
| `rpc/blog/internal/logic` | **166** | **0** |
| `api/{app,admin}` logic + handler | **397** | **0** |
| `rpc/blog/model` | 30 | 0 |
| `infra/tokenx` | — | 17 个用例（项目里最扎实的） |
| `infra/captchax` / `staticfile` / `mailtemplate` | — | 有 |
| `api/admin` 的 `permissionx` / `tracelogx` | — | 有 |

登录、注册、改密、文章、评论、权限数据加载**全在零测试的那一层**。基础设施工具有测试而业务逻辑裸奔，是当前最大的质量风险。

**建议**：不追求覆盖率。按 `docs/design/06-BLOG-测试方案.md` 的分层，优先补**登录/鉴权链路**与**内容写入**的单元 + 集成测试。

---

## 二、安全与数据正确性

### 2.1 权限缓存失效路径吞错（越权方向）

`api/admin/internal/middleware/permissionx/rbac_enforcer.go:212`

```go
_ = m.rds.Del(context.Background(), cachekey.UserRoleCacheKey(userId)).Err()
```

角色变更经 Redis pub/sub 通知 `InvalidateUser`（`:322`）。内存缓存会被清掉，但 Redis 那次 `Del` 失败被吞掉。而 `getUserRoles` 的读取顺序是**内存 → Redis → RPC**（`:216` 起）—— 内存空了会回落到 Redis 拿到**旧角色**并重新灌回内存。

`userRoleTTL = 5 * time.Minute`（`:57`），即被撤销权限的管理员**最多保留 5 分钟旧权限**。窗口有界，但方向是越权。建议：失败时记日志并降级为「不缓存」，或直接返回错误让上层重试。

### 2.2 `NoopEnforcer` 注释与行为相反

`api/admin/internal/middleware/permissionx/noop_enforcer.go:7,23`

注释写「允许所有操作」，`Enforce` 实现却是 `return false, nil`（**全部拒绝**）。目前零引用，但文件里有 `var _ Enforcer = &NoopEnforcer{}` 的接口断言，看起来像「随时可接入」。一旦接错会直接锁死后台。

### 2.3 配置查询吞错 → 真实错误被掩盖

`rpc/blog/internal/logic/siteservice/save_config_logic.go:34`

```go
result, _ := l.svcCtx.TConfigModel.FindOneByKey(l.ctx, in.ConfigKey)
if result != nil { entity.Id = result.Id }
```

`Save` 是 GORM 语义——主键为零则 INSERT、非零则 UPDATE。查询真出错（连接失败、超时）时 `result` 为 nil，`Id` 保持 0，于是走 INSERT，撞上 `t_config` 的 `UNIQUE KEY uk_key`，**真正的失败原因被替换成一个误导性的重复键错误**。

> 注：不是「写入重复行」—— `uk_key` 挡住了。严重度是**错误掩盖**而非数据损坏。

### 2.4 `SmsConf` 代码在用、yaml 里一条都没有

`rpc/blog/internal/svc/service_context.go:105` 调 `NewSmsProvider(c.SmsConf)`，但所有 `*.example.yaml` 里都没有 `SmsConf` 段，只能靠 tag 的 `provider,default=mock` 兜底走 mock。**线上短信配置无据可依**。

---

## 三、配置与开发路径脱节

### 3.1 本地 yaml 与 Makefile 对不上

`.gitignore:42-43` 忽略了 `app-api.yaml` / `admin-api.yaml` / `app-rpc.yaml`，而 `Makefile:102,106,110` 正是用它们启动。

实际情况：

| 文件 | 真实内容 |
|---|---|
| `api/app/etc/app-api.yaml` | 仅 3 行（Name/Host/Port），缺 `RedisConf` / `StorageConfig` / `AppRpcConf` |
| `api/admin/etc/admin-api.yaml` | 同上，且 **Port 与 app 都是 8888** |
| `rpc/blog/etc/app-rpc.yaml` | **不存在**，目录下只有 `.example.yaml` |

按 `make run-app-rpc` 走根本起不来，开发路径实际只能靠 nacos 模式兜底 —— 与 README 里 `make deps && make docker-deps` 的「5 分钟启动」承诺不符。

---

## 四、文档漂移

### 4.1 部署文档大面积过时

端口方案迁过两轮（API 9090/9091 → 9420/9421；Web 9420/9421 → 9520/9521），文档没跟：

| 文档 | 问题 |
|---|---|
| `docs/deploy/从零开始部署博客系统.md` | `cd blog-gozero`、`make run-rpc/run-blog/run-admin`（实际是 `run-app-rpc/run-app-api/run-admin-api`）、9090/9091、引用不存在的 `blog-gozero/项目启动说明.md` |
| `docs/deploy/生产部署（1）服务部署.md` | API 写 9090/9091；Web 写 `-p 9420:80`（**与 API 端口撞车**）；`deploy/docker-compose/data` 目录不存在；用 v1 的 `docker-compose` |
| `docs/deploy/生产部署（4）HTTPS配置.md` | 仍写 9420 |
| `docs/deploy/生产部署（2）Nginx配置.md` | 已于本次修正（拷贝路径、站点配置改为指向仓库文件） |

### 4.2 设计文档未记录本次的决策变更

`docs/design/` 的定位是「写改动它需要重新走设计评审的内容」。以下三项属该类，但文档未动：

| 文档 | 缺什么 |
|---|---|
| `03-BLOG-认证与授权.md §1.2` | 令牌身份从 **uid 变为 uid+deviceID**；登录模式选**单点**（新登录踢掉旧会话）—— 都是策略决策 |
| `05-BLOG-部署与运维.md §1.1` | 依赖服务列表是「MySQL / Redis / RabbitMQ / Nacos」，**无对象存储**；§1.3 说「前端容器内 Nginx 反代后端」，已不是当前形态（外层 nginx 直连后端） |
| `03` / `07` | 图形验证码只在 admin 密码登录强制校验，未记录 |

按文档规则，应在各文档「修订记录」一节补关键决策偏移，正文不必逐字追更。

### 4.3 `docs/feature/2026-09-11-api-admin整理方案.md` 状态行是错的

文件头写「状态：**已定案，未实施**」，但当前 `api/admin/internal/logic/` 的模块结构（`access` / `account` / `common` / `content` / `discussion` / `media` / `notification` / `site` / `stats` / `syslog`）与方案里「改动后模块对照」**完全一致** —— 早已落地。

---

## 五、契约质量（方案 §三，显式推迟项）

| 项 | 问题 | 影响 |
|---|---|---|
| `PageResult.List` 是 `interface{}` | 所有分页接口的列表元素类型在生成物中丢失，前端只能自行再声明一遍；而同文件集里 `QueryFileListResp` 已是 `List []*FileInfoVO`，两种写法并存 | **影响面最大** |
| `validate:` 全仓仅 2 处 | 其余 130+ 个请求类型无任何校验标签 | 需先定「后端兜底到什么程度」的策略 |
| Guest 三类型字段几乎完全重叠 | `GuestInfoVO` / `GuestItem` / `GetGuestResp` | 中 |
| `UpdateArticleDelete` 命名 | 实为切换软删除状态，读起来像「更新删除」 | 低 |

---

## 六、死代码与清理项

| 项 | 位置 | 说明 |
|---|---|---|
| goctl 占位限流中间件 | `api/{app,admin}/internal/middleware/ratelimit_middleware.go` | 函数体只有 `// TODO generate middleware implement function` + 直接透传；真限流在 `infra/middlewarex` |
| 与 Meta 重复的认证拦截器 | `infra/interceptorx/grpc_server_auth_interceptor.go` | 与已注册的 `ServerMetaInterceptor` **逐行相同**（只差一行被注释的日志），且未注册 |
| 从未注册的客户端日志拦截器 | `infra/interceptorx/grpc_client_log_interceptor.go` | 只注册了 `ClientErrorInterceptor` |
| 整个包 0 import | `infra/requestx/`、`infra/grpcerrors/`、`infra/constants/mailtemplate/` | — |
| 61 个枚举常量零引用 | `infra/constants/enums/model.go` | 如 `AlbumIsDeleteNo/Yes`、`ArticleTypeOriginal`、`MenuVisibleYes/No` 等；对照 `ArticleStatusPublic` 是在用的，说明是早期设计残留 |
| 未使用的导出类型 | `CommentRecent`、`IdReq`、`IdsReq`、`ResetUserPasswordResp`、`UpdateUserStatusResp` | 通用请求体被定义却没用，通常意味着对应 .api 定义与实现已脱节 |
| 未使用的 metax / cachekey 函数 | `GetApiTokenFromCtx`、`GetApiAppNameFromCtx`、`GetApiRemoteAgentFromCtx`、`GetAppNameFromCtx`、`GetCaptchaKey` | — |
| 被注释而非删除的代码块 | `operationlog_middleware.go:85-99`（15 行）、`metax/meta.go:90-106`（17 行） | — |
| AutoMigrate | `rpc/blog/internal/svc/service_context.go:93-95`（调用被注释）与 `:265`（函数体仍在） | 注释掉的理由正确，但函数应一并移除 |
| 被编进生产二进制的测试文件 | `api/admin/internal/svc/service_contexttest.go` | 文件名**不是** `_test.go`；内含硬编码的 `conf.MustLoad("../../etc/admin-api.yaml")`；函数零引用 |
| 遗留请求头常量 | `infra/biz/bizheader/header.go:61-62,68-69` | `HeaderClientId` / `HeaderClientToken` / `HeaderXAdminId` / `HeaderXAdminAuth`，且后者不在 `HeaderFields` 白名单内 |

---

## 七、本次已修项

| 项 | 位置 | 改动 |
|---|---|---|
| 非恒定格式串 | `infra/biz/bizerr/error.go:47` | `fmt.Errorf(st.Message())` → `errors.New(...)`。`st.Message()` 来自对端任意文本，含 `%` 会被当格式动词解析。**此项是 CI 的前置** |
| 配置查询吞错 | `rpc/blog/internal/logic/siteservice/save_config_logic.go:34` | 区分 `gorm.ErrRecordNotFound`（走新增）与真实错误（向上返回） |
| `SmsConf` 缺失 | `rpc/blog/etc/app-rpc.example.yaml` | 补齐 `SmsConf` 段，含各服务商所需字段与模板映射 |

---

## 八、权限匹配的测试（已补齐）

`api/admin/internal/middleware/permissionx` 是本次唯一新增测试的地方，选它有三条理由：**纯函数、不碰 DB、不在 logic 层**。而它决定的是「该请求放不放行」，匹配错了就是越权或全站锁死 —— 符合「只测关键代码」的判据。

**`rbac_enforcer_test.go` 的夹具缺陷（已修）**

`TestEnforce` 此前有 2 个用例失败，被 §七 第一项的 vet 错误掩盖。**初判「测试写错、断言该从 `err` 改成 `ok`」是错的** —— 错在读 `Enforce` 只读到一半就下了结论。实际尾部是：

```go
return false, fmt.Errorf("用户[%s]无权限访问资源[%s %s]", user, method, path)
```

拒绝时**确实返回 error**，断言一直是对的。真正的缺陷在夹具：`newTestEnforcer` 没有填充 `allPerms`，而 `Enforce` 对**未注册**的接口按设计放行（`rbac_enforcer.go:188`）。被拒绝的两个用例恰好是「已登记但未授予」的接口，夹具里却连登记都没有，于是全部走了放行分支 —— 连 `allowed` 用例也是**空过**。

修法：`newTestEnforcer` 增加 `registered` 参数填充 `allPerms`，并把待拒绝的两个接口显式登记进去。

**`matcher_test.go`（新增）**

覆盖权限匹配的纯函数：`normalizeMethod` / `normalizePath` / `splitPermID` / `pathMatch` / `matchPermission` / `apiPermission.Match`。其中几条语义值得固定下来：`:param` 只匹配单段且段数必须相等（`/users/:id` 不匹配 `/users/123/extra`）；`*` 吃掉剩余所有段但不作为零段匹配（`/api/*` 不匹配 `/api`）；`splitPermID` 只按第一个冒号切分。

---

## 九、测试范围的取舍（已定）

**判据**：只测「错了不会报错、只会静默给出错误结果」的代码。传话型代码错了会立刻抛 error 或肉眼可见，不值得测。

**位置约束**：不在 logic 层写测试。logic 是编排层，依赖 `svcCtx`（DB / Redis / RPC），在那写单测成本高且脆弱；单元测试应落在**不依赖外部依赖的纯逻辑**上。这与《06 测试方案》§一的定义一致（单元测试 = 纯逻辑：算法、解析、转换、校验）。

因此权限匹配（`permissionx/matcher.go`）是当前最合适的落点 —— 它是纯函数，却又是鉴权的核心判定。

**代价需知**：落在 logic 层的判断（如数据可见性过滤、登录分支）因此**不会被覆盖**。若将来要让它们可测，正确做法是把纯判断**抽成独立函数**（输入输出都是普通值），而不是在 logic 里搭测试。例如数据可见性的 `status` / `is_delete` 条件目前散落在多个 SQL 里，抽出来才能测。

**明确不测**：215 个传话型 logic（构造请求 → 调下游 → 查 err）、goctl 生成的 handler / types、VO 转换与分页包装。

---

## 修订记录

| 日期 | 内容 |
|---|---|
| 2026-09-15 | 初稿。合并「代码遗留项排查」与「测试覆盖现状」两轮结果；修正排查中对 `ServerAuthInterceptor`（实为重复而非缺失）与 HMAC Signer（`Verify` 返回 `(nil,nil)` 是接口契约语义，Store 比对仍会兜住）的两处误判 |
| 2026-09-15 | 补 §八、§九。**修正初稿中「`TestEnforce` 断言写错」的误判** —— 实为夹具缺 `allPerms`，断言本就正确；补充测试范围判据（只测静默失败的关键代码、不落 logic 层）与 `matcher_test.go` |
