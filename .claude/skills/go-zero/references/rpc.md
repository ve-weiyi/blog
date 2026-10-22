# go-zero RPC 服务参考

> 本文件由 SKILL.md 的「四、Proto 文件与 RPC 服务」拆出，按需读取。

## Proto 定义

```protobuf
syntax = "proto3";
package user;
option go_package = "./user";

message CreateUserRequest {
  string name = 1;
  string email = 2;
}

message CreateUserResponse {
  int64 id = 1;
}

message GetUserRequest {
  int64 id = 1;
}

message GetUserResponse {
  int64 id = 1;
  string name = 2;
  string email = 3;
}

service UserService {
  rpc CreateUser(CreateUserRequest) returns(CreateUserResponse);
  rpc GetUser(GetUserRequest) returns(GetUserResponse);
}
```

## 代码生成

```bash
goctl rpc protoc user.proto --go_out=. --go-grpc_out=. --zrpc_out=. --style go_zero
```

生成结构：
```
.
├── etc/user.yaml
├── internal/
│   ├── config/config.go          # 嵌入 zrpc.RpcServerConf
│   ├── logic/                    # 业务代码在这里
│   ├── server/                   # gRPC server 实现（goctl 生成）
│   └── svc/servicecontext.go
├── user/
│   ├── user.pb.go
│   ├── user_grpc.pb.go
│   └── userservice.go            # Client 接口
├── user.go                       # 入口
└── user.proto
```

## Server（`internal/server/`）

```go
// ✅ 正确：server 层只做参数校验 + 调用 logic
func (s *UserServiceServer) CreateUser(ctx context.Context, in *user.CreateUserRequest) (*user.CreateUserResponse, error) {
    if in.Name == "" {
        return nil, status.Error(codes.InvalidArgument, "name is required")
    }
    l := logic.NewCreateUserLogic(ctx, s.svcCtx)
    return l.CreateUser(in)
}
```

## Logic（`internal/logic/`）

```go
func (l *CreateUserLogic) CreateUser(in *user.CreateUserRequest) (*user.CreateUserResponse, error) {
    result, err := l.svcCtx.UserModel.Insert(l.ctx, &model.User{Name: in.Name})
    if err != nil {
        l.Logger.Errorf("insert user failed: %v", err)
        return nil, status.Error(codes.Internal, "create user failed")
    }
    id, _ := result.LastInsertId()
    return &user.CreateUserResponse{Id: id}, nil
}
```

## RPC 错误处理

```go
// ✅ gRPC 标准状态码
import "google.golang.org/grpc/status"
import "google.golang.org/grpc/codes"

// 常用状态码映射
var (
    ErrInvalidArgument  = status.Error(codes.InvalidArgument, "invalid argument")   // 400
    ErrUnauthenticated  = status.Error(codes.Unauthenticated, "unauthenticated")    // 401
    ErrPermissionDenied = status.Error(codes.PermissionDenied, "permission denied") // 403
    ErrNotFound         = status.Error(codes.NotFound, "not found")                 // 404
    ErrAlreadyExists    = status.Error(codes.AlreadyExists, "already exists")       // 409
    ErrInternal         = status.Error(codes.Internal, "internal error")            // 500
    ErrUnavailable      = status.Error(codes.Unavailable, "service unavailable")    // 503
)

// Logic 中使用
func (l *GetUserLogic) GetUser(in *user.GetUserRequest) (*user.GetUserResponse, error) {
    if in.Id <= 0 {
        return nil, status.Error(codes.InvalidArgument, "invalid user id")
    }
    u, err := l.svcCtx.UserModel.FindOne(l.ctx, in.Id)
    if err != nil {
        if errors.Is(err, model.ErrNotFound) {
            return nil, status.Error(codes.NotFound, "user not found")
        }
        return nil, status.Errorf(codes.Internal, "find user failed: %v", err)
    }
    return &user.GetUserResponse{Id: u.Id, Name: u.Name, Email: u.Email}, nil
}

// 客户端解包错误
st, ok := status.FromError(err)
if ok {
    switch st.Code() {
    case codes.NotFound:
        // ...
    case codes.Unavailable:
        // ...
    }
}
```

## 配置

```go
// internal/config/config.go
type Config struct {
    zrpc.RpcServerConf           // ✅ 必须嵌入
    DataSource string
}
```

```yaml
# etc/user.yaml
Name: user.rpc
ListenOn: 0.0.0.0:8080
Timeout: 5000
Etcd:
  Hosts:
    - 127.0.0.1:2379
  Key: user.rpc
Log:
  Mode: console
  Level: info
DataSource: "user:pass@tcp(localhost:3306)/db?parseTime=true"
```

## RPC Client（调用方）

```go
// 在调用方服务的 ServiceContext 中初始化
type ServiceContext struct {
    Config  config.Config
    UserRpc user.UserServiceClient  // proto 生成的 client 接口
}

func NewServiceContext(c config.Config) *ServiceContext {
    return &ServiceContext{
        Config:  c,
        UserRpc: user.NewUserServiceClient(zrpc.MustNewClient(c.UserRpc).Conn()),
    }
}

// 配置（调用方 etc/*.yaml）
// UserRpc:
//   Etcd:
//     Hosts:
//       - 127.0.0.1:2379
//     Key: user.rpc

// 在 Logic 中调用 RPC
func (l *CreateOrderLogic) CreateOrder(req *types.CreateOrderRequest) (*types.CreateOrderResponse, error) {
    userResp, err := l.svcCtx.UserRpc.GetUser(l.ctx, &user.GetUserRequest{Id: req.UserId})
    if err != nil {
        return nil, err
    }
    // 使用 userResp 继续业务...
}
```

## 拦截器

```go
// ✅ Server 端鉴权拦截器
func UnaryAuthInterceptor(ctx context.Context, req interface{}, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (interface{}, error) {
    md, ok := metadata.FromIncomingContext(ctx)
    if !ok {
        return nil, status.Error(codes.Unauthenticated, "missing metadata")
    }
    tokens := md.Get("authorization")
    if len(tokens) == 0 {
        return nil, status.Error(codes.Unauthenticated, "missing token")
    }
    userId, err := validateToken(tokens[0])
    if err != nil {
        return nil, status.Error(codes.Unauthenticated, "invalid token")
    }
    ctx = context.WithValue(ctx, "userId", userId)
    return handler(ctx, req)
}

// 注册拦截器
server := zrpc.MustNewServer(c.RpcServerConf, func(grpcServer *grpc.Server) {
    user.RegisterUserServiceServer(grpcServer, srv)
})
server.AddUnaryInterceptors(UnaryAuthInterceptor)
server.Start()

// ✅ Client 端（注入 metadata）
func UnaryClientInterceptor(ctx context.Context, method string, req, reply interface{}, cc *grpc.ClientConn, invoker grpc.UnaryInvoker, opts ...grpc.CallOption) error {
    ctx = metadata.NewOutgoingContext(ctx, metadata.Pairs(
        "authorization", "Bearer token",
        "request-id", generateRequestId(),
    ))
    return invoker(ctx, method, req, reply, cc, opts...)
}

conn := zrpc.MustNewClient(c.UserRpc, zrpc.WithUnaryClientInterceptor(UnaryClientInterceptor))
```

## 服务发现

```yaml
# etcd 服务发现（Server 端注册 + Client 端发现）
Etcd:
  Hosts:
    - 127.0.0.1:2379
  Key: user.rpc

# 直连（无服务发现，开发/测试用）
Endpoints:
  - 127.0.0.1:8080
  - 127.0.0.1:8081

# DNS / K8s
Target: dns:///user-service.default.svc.cluster.local:8080
```

## 流式传输

```go
// Server streaming：服务端分批推送
func (l *ListUsersLogic) ListUsers(in *user.ListUsersRequest, stream user.UserService_ListUsersServer) error {
    for offset := 0; ; offset += pageSize {
        users, err := l.svcCtx.UserModel.FindMany(l.ctx, offset, pageSize)
        if err != nil {
            return status.Error(codes.Internal, "fetch failed")
        }
        if len(users) == 0 {
            break
        }
        for _, u := range users {
            if err := stream.Send(&user.UserInfo{Id: u.Id, Name: u.Name}); err != nil {
                return err
            }
        }
    }
    return nil
}

// Client streaming：客户端分批上传
func (l *BatchCreateLogic) BatchCreate(stream user.UserService_BatchCreateServer) error {
    var ids []int64
    for {
        req, err := stream.Recv()
        if err == io.EOF {
            return stream.SendAndClose(&user.BatchCreateResponse{Ids: ids})
        }
        if err != nil {
            return err
        }
        result, _ := l.svcCtx.UserModel.Insert(l.ctx, &model.User{Name: req.Name})
        id, _ := result.LastInsertId()
        ids = append(ids, id)
    }
}
```

## 负载均衡

go-zero 默认使用 **p2c_ewma**（Power of 2 Choices + EWMA）策略，自动选择延迟最低的节点，无需额外配置。可选策略：`round_robin`、`pick_first`。

## 规则

| # | 规则 |
|---|------|
| 4.1 | 先改 .proto → `goctl rpc protoc` 生成 → 再写 logic |
| 4.2 | gRPC server 方法在 `internal/server/` 中实现，只做参数校验和调用 logic |
| 4.3 | RPC 错误用 `status.Error(codes.XXX, "msg")`，不用 `fmt.Errorf` |
| 4.4 | Config 必须嵌入 `zrpc.RpcServerConf` |
| 4.5 | RPC Client 通过 ServiceContext 注入，不在 logic 中各自创建连接 |
| 4.6 | 跨服务鉴权用拦截器（Server 端验证 + Client 端注入 metadata） |
| 4.7 | 大数据集用流式传输，分批推送/接收 |
| 4.8 | 生产环境用 etcd 服务发现，不用直连 |

## 反模式

| 反模式 | 问题 | 做法 |
|--------|------|------|
| gRPC server 里写业务逻辑 | server 膨胀 | 移到 logic |
| `return nil, fmt.Errorf("err")` | 客户端收到 code=Unknown | `status.Errorf(codes.XXX, ...)` |
| Config 不嵌入 `zrpc.RpcServerConf` | 服务注册/发现失败 | 必须嵌入 |
| 每个 logic 各自 new RPC client | 连接池碎片化 | ServiceContext 统一注入 |
| 生产环境用直连 endpoints | 实例扩缩容失效 | etcd 服务发现 |

