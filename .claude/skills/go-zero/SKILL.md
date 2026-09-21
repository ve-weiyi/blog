---
name: go-zero
description: "使用 go-zero 框架开发微服务时主动应用。当创建 REST API、构建 gRPC 服务、编写 .api/.proto 文件、使用 goctl 生成代码、实现 Handler/Logic/中间件、配置 RPC Client/拦截器/服务发现、设计流式传输、或排查 go-zero 错误时主动应用。"
license: MIT
compatibility: "go-zero v1.5+"
allowed-tools: Read Edit Write Glob Grep Bash(go:*) Bash(goctl:*)
---

# go-zero 开发指导

go-zero 微服务框架的开发约定与最佳实践，采用 ✅ vs ❌ 对照 + 规则表 + 反模式表的模式。按 REST API → RPC 服务 → 依赖注入 → 错误处理 → 命令速查组织。

## 核心原则

### ✅ 遵循

- **三层分离** — Handler/Server（解析/校验）→ Logic（业务）→ Svc（依赖注入），层间不越界
- **goctl 生成** — handler/routes/types/*.pb.go 由 goctl 从 .api/.proto 生成，禁止手动编辑生成文件
- **结构化错误** — REST 用 `httpx.ErrorCtx`/`httpx.OkJsonCtx` + 自定义 `SetErrorHandler`，RPC 用 `status.Error`
- **配置注入** — `conf.MustLoad` 加载 yaml → `ServiceContext` 聚合依赖 → Logic 通过 svcCtx 获取
- **Context 传播** — 所有层传递 `ctx`，不存 struct，不传 `context.Background()`
- **.api/.proto 是单一数据源** — 先改 spec → goctl 生成 → 再写 Logic

### ❌ 禁止

- Handler/Server 里写业务逻辑
- 手动编辑 `routes.go`、`types.go`、`*.pb.go`、`*_grpc.pb.go`
- 用 `w.Write()`、`fmt.Fprintf()`、`json.NewEncoder` 替代 httpx
- 硬编码配置值（端口、地址、密钥）
- 绕过 ServiceContext 直接创建全局客户端
- RPC 中用 `fmt.Errorf` 替代 `status.Error`
- 吞错误或返回无上下文的错误信息

---

## 一、.api 文件与 REST API

### .api 文件规范

```go
// user.api
syntax = "v1"

info(
    title: "User API"
    desc:  "用户管理 API"
)

type (
    CreateUserRequest {
        Name     string `json:"name" validate:"required,min=2,max=50"`
        Email    string `json:"email" validate:"required,email"`
        Password string `json:"password" validate:"required,min=8"`
    }
    CreateUserResponse {
        Id int64 `json:"id"`
    }
    GetUserRequest {
        Id int64 `path:"id" validate:"required,gt=0"`
    }
    GetUserResponse {
        Id    int64  `json:"id"`
        Name  string `json:"name"`
        Email string `json:"email"`
    }
    ListUsersRequest {
        Page     int    `form:"page,default=1" validate:"gte=1"`
        PageSize int    `form:"page_size,default=10" validate:"gte=1,lte=100"`
        Keyword  string `form:"keyword,optional"`
    }
    ListUsersResponse {
        Total int64       `json:"total"`
        Items []UserInfo  `json:"items"`
    }
    UserInfo {
        Id    int64  `json:"id"`
        Name  string `json:"name"`
        Email string `json:"email"`
    }
)

// 公开路由
@server (
    prefix: /api/v1
    group:  auth
)
service user-api {
    @handler Login
    post /login (LoginRequest) returns (LoginResponse)
}

// JWT 保护路由
@server (
    prefix:     /api/v1
    group:      user
    middleware: AuthMiddleware
    jwt:        Auth
)
service user-api {
    @doc "创建用户"
    @handler CreateUser
    post /users (CreateUserRequest) returns (CreateUserResponse)

    @doc "获取用户"
    @handler GetUser
    get /users/:id (GetUserRequest) returns (GetUserResponse)

    @doc "用户列表"
    @handler ListUsers
    get /users (ListUsersRequest) returns (ListUsersResponse)
}
```

### 请求标签参考

| 标签 | 用途 | 示例 |
|------|------|------|
| `json:"name"` | JSON 字段名 | `json:"user_name"` |
| `json:"name,optional"` | 可选字段 | 允许为零值 |
| `json:"name,omitempty"` | 空值时省略 | 序列化时跳过 |
| `path:"id"` | 路径参数 `/users/:id` | `path:"id"` |
| `form:"page"` | 查询参数 `?page=1` | `form:"page,default=1"` |
| `header:"Authorization"` | HTTP Header | `header:"Authorization"` |
| `validate:"required"` | 必填校验 | `validate:"required,min=1,max=100"` |

### 代码生成与生成后流水线

```bash
# 1. 生成代码
goctl api go -api user.api -dir . --style go_zero

# 2. 验证 .api 语法
goctl api validate -api user.api

# 3. 初始化模块（新项目）
[ ! -f go.mod ] && go mod init <module>

# 4. 整理依赖
go mod tidy

# 5. 验证 import 路径与 go.mod module 一致
grep -r "old/module/path" --include="*.go" -l

# 6. 编译验证
go build ./...
```

生成结构：
```
.
├── etc/user-api.yaml
├── internal/
│   ├── config/config.go       # 嵌入 rest.RestConf
│   ├── handler/               # goctl 生成，禁止手动编辑
│   │   └── routes.go          # 路由注册
│   ├── logic/                 # 业务代码在这里
│   ├── svc/servicecontext.go
│   ├── middleware/
│   └── types/types.go         # goctl 生成，禁止手动编辑
├── user-api.go                # 入口
└── user.api
```

### 规则

| # | 规则 |
|---|------|
| 1.1 | **先改 .api → goctl 生成 → 再写 logic**。禁止跳过生成直接写代码 |
| 1.2 | 请求/响应类型统一定义在 .api 中，不在 logic 层自定义新的 HTTP 类型 |
| 1.3 | middleware 在 .api 的 `@server` 块中声明；JWT 用 `jwt: Auth` |
| 1.4 | `goctl api go` 可安全重复运行，已存在的 logic 文件不会被覆盖 |
| 1.5 | 生成后必须 `go mod tidy` + `go build ./...` 确保无编译错误 |
| 1.6 | 命名风格（`--style`）必须与项目已有文件一致：`go_zero`（下划线）或 `goZero`（驼峰） |

### 反模式

| 反模式 | 问题 | 做法 |
|--------|------|------|
| 手动编辑 `routes.go` 添加路由 | 下次生成被覆盖 | 改 .api 重新生成 |
| 手动编辑 `types.go` 改字段 | 同上 | 改 .api 重新生成 |
| 逻辑写在 handler 里 | 违反三层分离 | 移到 logic 层 |
| 新项目跳过 `go mod tidy` | import 路径不匹配 | 生成后必执行 |

---

## 二、REST Handler、Logic 与中间件

### Handler（`internal/handler/`）

```go
// ✅ 正确：handler 只做三件事——解析、调用 logic、返回
func CreateUserHandler(svcCtx *svc.ServiceContext) http.HandlerFunc {
    return func(w http.ResponseWriter, r *http.Request) {
        var req types.CreateUserRequest
        if err := httpx.Parse(r, &req); err != nil {
            httpx.ErrorCtx(r.Context(), w, err)
            return
        }
        l := logic.NewCreateUserLogic(r.Context(), svcCtx)
        resp, err := l.CreateUser(&req)
        if err != nil {
            httpx.ErrorCtx(r.Context(), w, err)
        } else {
            httpx.OkJsonCtx(r.Context(), w, resp)
        }
    }
}

// ❌ 错误
func BadHandler(svcCtx *svc.ServiceContext) http.HandlerFunc {
    return func(w http.ResponseWriter, r *http.Request) {
        user, _ := svcCtx.UserModel.FindOne(r.Context(), id) // ❌ 数据库越层
        if user.Age < 18 { ... }                              // ❌ 业务逻辑
        json.NewEncoder(w).Encode(user)                       // ❌ 裸响应
    }
}
```

### Logic（`internal/logic/`）

```go
// ✅ 正确：logic 承载全部业务逻辑
type CreateUserLogic struct {
    logx.Logger
    ctx    context.Context
    svcCtx *svc.ServiceContext
}

func NewCreateUserLogic(ctx context.Context, svcCtx *svc.ServiceContext) *CreateUserLogic {
    return &CreateUserLogic{
        Logger: logx.WithContext(ctx),
        ctx:    ctx,
        svcCtx: svcCtx,
    }
}

func (l *CreateUserLogic) CreateUser(req *types.CreateUserRequest) (*types.CreateUserResponse, error) {
    // 业务校验
    if err := l.validate(req); err != nil {
        return nil, err
    }
    // 数据操作
    result, err := l.svcCtx.UserModel.Insert(l.ctx, &model.User{Name: req.Name})
    if err != nil {
        l.Logger.Errorf("insert user failed: %v", err)
        return nil, err
    }
    id, _ := result.LastInsertId()
    return &types.CreateUserResponse{Id: id}, nil
}
```

### 中间件（`internal/middleware/`）

```go
// ✅ 正确
type AuthMiddleware struct {
    secret string
}

func NewAuthMiddleware(secret string) *AuthMiddleware {
    return &AuthMiddleware{secret: secret}
}

func (m *AuthMiddleware) Handle(next http.HandlerFunc) http.HandlerFunc {
    return func(w http.ResponseWriter, r *http.Request) {
        token := r.Header.Get("Authorization")
        if token == "" {
            httpx.ErrorCtx(r.Context(), w, errors.New("missing authorization"))
            return
        }
        userId, err := m.verifyToken(token)
        if err != nil {
            httpx.ErrorCtx(r.Context(), w, err)
            return
        }
        ctx := context.WithValue(r.Context(), "userId", userId)
        next.ServeHTTP(w, r.WithContext(ctx))
    }
}
```

在 ServiceContext 中初始化并在路由注册时引用：

```go
// ServiceContext 中初始化 AuthMiddleware
// .api 中声明 middleware: AuthMiddleware，goctl 会自动生成引用代码
```

### 规则

| # | 规则 |
|---|------|
| 2.1 | Handler 不承载业务逻辑——不写 SQL、不做判断、不调多个服务 |
| 2.2 | Handler 用 `httpx.Parse` 解析，`httpx.ErrorCtx`/`httpx.OkJsonCtx` 返回 |
| 2.3 | Logic 禁止使用 HTTP 类型（`*http.Request`、`http.ResponseWriter`），只接 `ctx` + 类型 |
| 2.4 | 参数格式校验放 handler（必填/类型），业务规则校验放 logic |
| 2.5 | Logic 结构体命名 `XxxLogic`，构造函数 `NewXxxLogic(ctx, svcCtx)` |
| 2.6 | 中间件通过 `Handle(next http.HandlerFunc) http.HandlerFunc` 签名实现，在 .api `@server` 块声明 |

### 反模式

| 反模式 | 问题 | 做法 |
|--------|------|------|
| handler 里调 `svcCtx.XxxModel.FindOne()` | 数据库越层 | 移到 logic |
| `httpx.Error(w, err)` 不带 ctx | 丢失 trace | `httpx.ErrorCtx(r.Context(), w, err)` |
| `http.Error(w, "err", 500)` | 绕过统一格式 | `httpx.ErrorCtx` |
| logic 方法签名带 `*http.Request` | HTTP 侵入业务 | 只接 `ctx` + 类型 |

---

## 三、REST 错误处理

### 标准错误

```go
// ✅ 成功
httpx.OkJsonCtx(r.Context(), w, resp)

// ✅ 错误
httpx.ErrorCtx(r.Context(), w, err)
```

### 自定义错误处理器

每个 REST 服务应统一注册自定义错误处理器，映射业务错误 → HTTP 状态码：

```go
// internal/errorx/errorx.go
type CodeError struct {
    Code int    `json:"code"`
    Msg  string `json:"msg"`
}

func NewCodeError(code int, msg string) *CodeError {
    return &CodeError{Code: code, Msg: msg}
}

func (e *CodeError) Error() string {
    return e.Msg
}

// 定义业务错误
var (
    ErrUserNotFound   = errors.New("user not found")
    ErrDuplicateEmail = errors.New("email already exists")
    ErrUnauthorized   = errors.New("unauthorized")
)

// 在 main 中注册
func init() {
    httpx.SetErrorHandler(func(err error) (int, any) {
        switch {
        case errors.Is(err, ErrUserNotFound):
            return http.StatusNotFound, map[string]string{"error": err.Error()}
        case errors.Is(err, ErrDuplicateEmail):
            return http.StatusConflict, map[string]string{"error": err.Error()}
        case errors.Is(err, ErrUnauthorized):
            return http.StatusUnauthorized, map[string]string{"error": err.Error()}
        default:
            return http.StatusInternalServerError, map[string]string{"error": "internal server error"}
        }
    })
}
```

### 规则

| # | 规则 |
|---|------|
| 3.1 | REST 成功用 `httpx.OkJsonCtx(ctx, w, data)`，错误用 `httpx.ErrorCtx(ctx, w, err)` |
| 3.2 | 注册 `httpx.SetErrorHandler` 统一错误码映射，不要在 handler 中零散处理 |
| 3.3 | 业务错误定义为包级 `var`，logic 中 `return nil, ErrXxx`，handler 透传 |

---


## 四、Proto 文件与 RPC 服务

RPC 相关的完整内容（Proto 定义、代码生成、Server、Logic、RPC 错误处理、配置、RPC Client、拦截器、服务发现、流式传输、负载均衡、规则与反模式）见 **[`references/rpc.md`](references/rpc.md)**。

**读它当且仅当你正在做以下任一件事**：定义或修改 `.proto`、跑 `goctl rpc`、写 gRPC Server/Logic、配置 `zrpc.RpcServerConf`、配 RPC Client、写拦截器、配 etcd 服务发现、用流式传输。

---

## 五、REST vs RPC 选择

| 场景 | 选择 | 理由 |
|------|------|------|
| 公共 API / 浏览器 / 第三方对接 | REST | HTTP 标准，工具链成熟 |
| 内部微服务通信 | RPC | 强类型、高性能、流式支持 |
| 简单 CRUD | REST | 语义清晰 |
| 大数据集 / 实时推送 | RPC streaming | 分批流式传输 |
| BFF（Backend for Frontend） | REST | 前端友好 |
| 高性能要求 | RPC | Protobuf 序列化更小更快 |

---

## 六、Svc 依赖注入

```go
// ✅ 正确：所有依赖集中在 ServiceContext
type ServiceContext struct {
    Config        config.Config
    UserModel     model.UserModel
    UserRpc       user.UserServiceClient  // gRPC client
    AuthMiddleware rest.Middleware
}

func NewServiceContext(c config.Config) *ServiceContext {
    return &ServiceContext{
        Config:    c,
        UserModel: model.NewUserModel(sqlx.NewMysql(c.DataSource)),
        UserRpc:   user.NewUserServiceClient(zrpc.MustNewClient(c.UserRpc).Conn()),
    }
}
```

### 规则

| # | 规则 |
|---|------|
| 6.1 | 所有依赖集中在 ServiceContext，通过构造函数注入到 Logic |
| 6.2 | 配置用 `conf.MustLoad` 加载，启动时执行一次 |
| 6.3 | Database/Redis/RPC client 在 ServiceContext 中统一初始化，不在 logic 中各自创建 |
| 6.4 | 中间件在 ServiceContext 中初始化，由 goctl 生成的 handler 自动引用 |

### 反模式

| 反模式 | 问题 | 做法 |
|--------|------|------|
| `var DB *sql.DB` 包级全局 | 不可并行测试 | 注入 ServiceContext |
| logic 里各自 `sql.Open` / `zrpc.MustNewClient` | 连接池碎片化 | 统一在 ServiceContext 创建 |
| 每次请求 `conf.MustLoad` 读配置 | 磁盘 IO 浪费 | 启动时加载一次 |

---

## 七、常用命令

```bash
# 检查 goctl 是否安装
goctl --version

# === REST API ===
# 生成代码
goctl api go -api user.api -dir . --style go_zero
# 验证语法
goctl api validate -api user.api

# === RPC 服务 ===
# 生成代码
goctl rpc protoc user.proto --go_out=. --go-grpc_out=. --zrpc_out=. --style go_zero

# === 生成后必执行 ===
go mod tidy
go build ./...
```
