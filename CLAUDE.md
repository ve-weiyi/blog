# 项目上下文

monorepo + git submodule：主仓库负责协议定义、部署编排与文档，各服务是独立 git 仓库，各有独立的依赖管理与发布节奏。

## 规则地图

动手前先看这里。**「加载时机」是实际行为，不是建议** —— 带 `paths:` 的规则只在你读到匹配文件时才进上下文，别指望它一直在。

| 想要什么 | 看哪 | 加载时机 |
|---|---|---|
| 工作流程（改动流程、`cd`/大小写陷阱、`cmd/` 诊断、凭据约束、文档归属、CI 校验） | [`.claude/rules/workflow.md`](.claude/rules/workflow.md) | 每次会话 |
| 后端分层、vkit 三层判据 | [`.claude/rules/architecture.md`](.claude/rules/architecture.md) | `**/*.go` |
| Go 设计规范（包命名、测试） | [`.claude/rules/go.md`](.claude/rules/go.md) | `**/*.go` |
| 后端约定（分层职责、统一响应格式、API 修改流程、GORM、错误处理） | [`.claude/rules/backend.md`](.claude/rules/backend.md) | `**/*.go`、`**/*.api`、`**/*.proto` |
| 前端约定 | [`.claude/rules/frontend.md`](.claude/rules/frontend.md) | `**/*.vue`、`**/*.ts` |
| **出问题了怎么查、已知故障模式、集群与凭据事实** | [`.claude/rules/k8s-ops.md`](.claude/rules/k8s-ops.md) | `deploy/**` |
| Go 通用设计规则（五维度：包与职责、接口与耦合、并发安全、错误与边界、一致性与简洁） | `golang-design` skill | 写 Go 时触发 |
| go-zero 框架用法（`.api`/`.proto`、goctl、Handler/Logic、RPC Client、拦截器、服务发现） | `go-zero` skill | 用 go-zero 时触发 |
| Go 代码设计审查（五维度检查 + 分级输出） | `golang-design-review` skill | 审查时触发 |

## 仓库构成

| 目录 | 角色 |
|---|---|
| `blog-cloud/` | 后端：HTTP 网关 + RPC 服务 |
| `blog-app/` | 前端：博客站点（Vue 3 + Naive UI） |
| `blog-admin/` | 前端：管理后台（Vue 3 + Element Plus） |
| `stompws/` | STOMP over WebSocket 聊天室服务（独立模块，含自己的 `web/`） |
| `vkit/` | 公共库：被后端与 stompws 引用 |
| `goctlx/` | 代码生成工具：从 API 定义与数据库生成前后端代码 |
| `protocol/` | 接口定义：`api/`（HTTP `.api`）、`proto/`（gRPC `.proto`）、`sql/`（建表） |
| `deploy/` | 部署清单与指南 |
| `docs/` | 文档：设计、功能方案、审查、手册、规范 |

**各模块内部目录结构以代码为准**，不在此复制 —— 概览见 [`README.md`](README.md) 的「仓库结构」，分层职责见 [`.claude/rules/architecture.md`](.claude/rules/architecture.md)。

## 部署

| 想要什么 | 看哪 |
|---|---|
| 部署步骤、服务清单 | [`deploy/k8s/k8s集群部署指南.md`](deploy/k8s/k8s集群部署指南.md)（**唯一真相源**） |
| **出问题了怎么查、集群事实、凭据散落处** | [`.claude/rules/k8s-ops.md`](.claude/rules/k8s-ops.md) |
| 选哪种部署形态（k8s / docker / 源码构建） | [`deploy/README.md`](deploy/README.md) |
| Nacos 配置（test / prod 两环境） | [`deploy/nacos-config/配置说明.md`](deploy/nacos-config/配置说明.md) |

集群现状一条命令自查（**不要凭记忆断言状态**）：

```bash
kubectl --kubeconfig=deploy/k8s/k8s-config.yaml get pod,pvc,certificate -n blog
```

**两套 k3s 集群（腾讯云 / 本地）内容完全不同，勿混用**；且每条 `kubectl` 都要显式带 `--kubeconfig` —— 它不跨 Bash 调用保持，漏了会静默回落到另一套集群或 `localhost:8080`，**查出错误结果且不报错**。两套集群的地址、节点与 kubeconfig 对照、以及 `tls-server-name` 必填的原因，见 [`.claude/rules/k8s-ops.md`](.claude/rules/k8s-ops.md) §二。

## 凭据

凭据（口令、授权码、AK、私钥）**不准写进文档、注释、提交信息**。`k8s-config.yaml` 含 `system:masters` 私钥（已 gitignore），读取时用脚本处理，避免私钥进入对话上下文。

凭据来源、四处同步要求，以及 `deploy/k8s/env.yaml` 明文密码**未** gitignore 的风险，见 [`.claude/rules/k8s-ops.md`](.claude/rules/k8s-ops.md) §八。
