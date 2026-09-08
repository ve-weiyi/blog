# 架构总览

## 后端分层

```
┌──────────────────────────────────────────────────────┐
│  HTTP 网关层 (api)                              │
│  handler → logic → svc                                │
│  handler: 路由注册 + 参数校验 + 响应封装                  │
│  logic:   业务编排（通过 RPC client 调用下游 gRPC 服务）   │
├──────────────────────────────────────────────────────┤
│  RPC 服务层 (rpc)                               │
│  handler → logic → svc / core                         │
│  handler: gRPC server 方法实现                         │
│  logic:   业务逻辑                                     │
├──────────────────────────────────────────────────────┤
│  kit 公共库                                            │
│  adapter/: 外部服务适配器（RAGFlow, Seafile,            │
│            RabbitMQ, Nacos, K8s, Mail, Hermes 等）     │
│  infra/:   基础设施（中间件、拦截器、限流、响应封装等）     │
│  x/:       标准库扩展（JWT, 加密, JSON 转换, 随机值等）   │
└──────────────────────────────────────────────────────┘
```

### api 目录结构

```
api/
├── scan3d.go           # 入口
├── etc/                # 配置文件
├── docs/               # Swagger 文档
└── internal/
    ├── config/         # 配置结构
    ├── core/           # 核心引擎（line 产线调度、store 仓库层、ws、mes）
    ├── handler/        # 路由注册，按模块分目录
    ├── logic/          # 业务编排，按模块分目录
    ├── middleware/     # 中间件（认证、License 等）
    ├── model/          # GORM 数据模型
    ├── svc/            # 依赖注入（RPC client、配置）
    ├── task/           # 后台任务
    └── types/          # 请求/响应类型定义
```

### rpc 目录结构

```
rpc/
├── scan3d.go           # 入口
├── etc/                # 配置文件
├── cgo/                 # CGO 代码（海康相机 SDK 封装等）
├── client/              # gRPC 客户端（供其他服务调用）
├── pb/                  # protobuf 生成代码
└── internal/
    ├── config/          # 配置结构
    ├── handler/         # gRPC handler，按模块分目录
    ├── logic/           # 业务逻辑，按模块分目录
    ├── server/          # gRPC server 注册
    ├── svc/             # 依赖注入
    └── types/           # 类型定义
```

## 部署架构

```
docker-compose 管理第三方依赖（Hermes Agent）
各 Go 服务独立编译部署（bin/ 目录存放可执行文件）
前端通过 Tauri 打包为桌面应用
```