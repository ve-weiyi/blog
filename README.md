<div align=center>

# blog

现代化的全栈博客系统 —— Go 微服务后端 + Vue 3 双前端

[![Go](https://img.shields.io/badge/Go-1.25-blue?logo=go)](https://go.dev/)
[![Go-Zero](https://img.shields.io/badge/Go--Zero-1.10-yellow?logo=go)](https://go-zero.dev/)
[![gRPC](https://img.shields.io/badge/gRPC-1.81-brightgreen)](https://grpc.io/)
[![GORM](https://img.shields.io/badge/GORM-1.31-red)](https://gorm.io/)
[![MySQL](https://img.shields.io/badge/MySQL-8.0-orange?logo=mysql)](https://www.mysql.com/)
[![Redis](https://img.shields.io/badge/Redis-9.19-purple?logo=redis)](https://redis.io/)
[![Vue](https://img.shields.io/badge/Vue-3.5-brightgreen?logo=vuedotjs)](https://vuejs.org/)
[![TypeScript](https://img.shields.io/badge/TypeScript-5.9-blue?logo=typescript)](https://www.typescriptlang.org/)
[![Docker](https://img.shields.io/badge/Docker-blue?logo=docker)](https://www.docker.com/)
[![License](https://img.shields.io/badge/License-MIT-green)](https://opensource.org/licenses/MIT)

[🖥️ 博客前台](https://blog.veweiyi.cn) ·
[🖥️ 管理后台](https://admin.veweiyi.cn) ·
[📑 前台接口文档](https://blog.veweiyi.cn/api/v1/swagger/index.html) ·
[📑 后台接口文档](https://admin.veweiyi.cn/admin-api/v1/swagger/index.html)

</div>

---

## 📚 项目简介

blog 是一个基于 Go 语言开发的现代化博客系统，采用微服务架构。后端基于 go-zero 框架，通过 gRPC 提供服务、HTTP 网关对外暴露接口；前端包含博客前台与管理后台两个独立的 Vue 3 单页应用。

项目采用 **monorepo + git submodule** 组织：主仓库负责协议定义、部署编排与文档，各服务是独立的 git 仓库，拥有各自独立的依赖管理与发布节奏。

### ✨ 核心特性

- **微服务架构** —— go-zero + gRPC，服务注册发现、负载均衡、高可用
- **双前端** —— 博客前台（Naive UI）与管理后台（Element Plus）独立开发部署
- **完整权限体系** —— 基于 RBAC 的动态权限、菜单与路由
- **多种登录方式** —— 账号密码、GitHub / QQ / 微信 / Google / 微博 OAuth
- **实时通信** —— STOMP over WebSocket 聊天室与消息推送
- **异步解耦** —— RabbitMQ 消息队列处理通知、日志等异步任务
- **一键部署** —— Docker Compose 本地编排 + Kubernetes 生产部署
- **代码生成** —— 内置 goctl 模板与 goctlx 工具，从 API 定义与数据库生成代码

---

## 🏗️ 系统架构

```
┌──────────────────────────────────────────────────────────────┐
│                        客户端层                                │
│     博客前台 (blog-app)          管理后台 (blog-admin)          │
└───────────────────────────┬──────────────────────────────────┘
                            │ HTTP
┌───────────────────────────▼──────────────────────────────────┐
│                      HTTP 网关层                               │
│     app-api (:9420)                admin-api (:9421)          │
│     handler → logic → svc                                     │
└───────────────────────────┬──────────────────────────────────┘
                            │ gRPC
┌───────────────────────────▼──────────────────────────────────┐
│                       RPC 服务层                               │
│                    app-rpc (:9120)                            │
│      用户 / 权限 / 文章 / 互动 / 通知 / 资源 / 配置 / 分析        │
└───────────────────────────┬──────────────────────────────────┘
                            │
┌───────────────────────────▼──────────────────────────────────┐
│                       基础设施                                 │
│   MySQL · Redis · RabbitMQ · Nacos 注册中心 · STOMP WebSocket  │
└──────────────────────────────────────────────────────────────┘
```

### 📁 仓库结构

```
blog/
├── blog-cloud/       # 后端服务：api/admin、api/app、rpc/blog
├── blog-admin/       # 管理后台前端（Vue 3 + Element Plus）
├── blog-app/         # 博客前台前端（Vue 3 + Naive UI）
├── vkit/             # 公共库：adapter（外部服务适配）、x（标准库扩展）
├── stompws/          # STOMP over WebSocket 服务
├── goctlx/           # 代码生成工具（API / 模型 / 前端）
├── protocol/         # 协议定义：api、rpc、sql
├── deploy/           # 部署编排：docker、docker-compose、k8s
├── docs/             # 文档：部署、设计、手册、规范
└── assets/           # 项目截图
```

---

## 📸 图片展示

### 博客前台

PC 端首页 —— 全屏大图轮播、诗词文案、音乐播放器：

![博客前台首页](./assets/img.jpg)

文章列表 —— 卡片式布局、分类标签、站点资讯侧栏：

![博客前台文章列表](./assets/img_1.jpg)

登录 —— 邮箱密码登录，支持多种社交账号：

![博客前台登录](./assets/img_2.jpg)

移动端 —— 响应式布局，抽屉式导航与本地搜索：

| 首页 | 导航菜单 | 搜索 |
|:---:|:---:|:---:|
| ![移动端首页](./assets/img_6.jpg) | ![移动端菜单](./assets/img_7.jpg) | ![移动端搜索](./assets/img_8.jpg) |

### 管理后台

仪表盘 —— 在线用户、UV / PV、文章量等实时统计与访问趋势：

![后台仪表盘](./assets/img_3.jpg)

数据统计 —— 文章贡献热力图与用户地域分布：

![后台数据统计](./assets/img_4.jpg)

菜单管理 —— 动态菜单配置，与 RBAC 权限体系联动：

![后台菜单管理](./assets/img_5.jpg)

---

## 🛠️ 技术栈

### 后端

| 技术 | 版本 | 说明 |
|------|------|------|
| Go | 1.25 | 编程语言 |
| go-zero | 1.10 | 微服务框架 |
| gRPC | 1.81 | RPC 通信框架 |
| GORM | 1.31 | ORM 框架 |
| MySQL | 8.0 | 关系型数据库 |
| Redis | 9.19 | 缓存数据库 |
| RabbitMQ | 3.12+ | 消息队列 |
| Nacos | 2.x | 注册中心与配置中心 |
| JWT | — | 身份认证 |
| Swagger | 2.0 | API 文档 |

### 前端

| 技术 | 博客前台 | 管理后台 |
|------|---------|---------|
| Vue | 3.5 | 3.5 |
| TypeScript | 5.9 | 5.9 |
| Vite | 6.4 | 8.0 |
| Pinia | 3.0 | 3.0 |
| UI 组件库 | Naive UI 2.43 | Element Plus 2.13 |
| UnoCSS | 66.5 | 66.6 |

### 部署

Docker · Docker Compose · Kubernetes · Nginx

---

## 📁 子项目导航

| 项目 | 说明 | 仓库 |
|------|------|------|
| [blog-cloud](./blog-cloud) | 后端服务（go-zero 微服务版） | [GitHub](https://github.com/ve-weiyi/blog-cloud) |
| [blog-admin](./blog-admin) | 管理后台前端 | [GitHub](https://github.com/ve-weiyi/blog-admin) |
| [blog-app](./blog-app) | 博客前台前端 | [GitHub](https://github.com/ve-weiyi/blog-app) |
| [vkit](./vkit) | 公共库（适配器与工具集） | [GitHub](https://github.com/ve-weiyi/vkit) |
| [stompws](./stompws) | STOMP over WebSocket 服务 | [GitHub](https://github.com/ve-weiyi/stompws) |
| [goctlx](./goctlx) | 代码生成工具 | [GitHub](https://github.com/ve-weiyi/goctlx) |

---

## 🚀 快速开始

### 环境要求

- Go 1.25+
- Node.js 20+ 与 pnpm
- Docker 与 Docker Compose
- MySQL 8.0+ · Redis 6.2+ · RabbitMQ 3.12+

### 1. 克隆项目

```bash
git clone --recursive git@github.com:ve-weiyi/blog.git
cd blog
```

已克隆但未拉取子模块时：

```bash
git submodule update --init --recursive
```

### 2. 启动依赖服务

```bash
docker compose -f deploy/docker-compose/mysql/mysql.yaml up -d
docker compose -f deploy/docker-compose/redis/redis.yaml up -d
docker compose -f deploy/docker-compose/rabbitmq/rabbitmq.yaml up -d
docker compose -f deploy/docker-compose/nacos/nacos.yaml up -d
```

### 3. 启动后端

```bash
cd blog-cloud

# 三个终端分别启动，先 RPC 后 API
go run rpc/blog/app.go -f rpc/blog/etc/app-rpc.yaml
go run api/app/app.go  -f api/app/etc/app-api.yaml
go run api/admin/admin.go -f api/admin/etc/admin-api.yaml
```

### 4. 启动前端

```bash
cd blog-admin && pnpm install && pnpm dev   # 管理后台
cd blog-app   && pnpm install && pnpm dev   # 博客前台
```

### 5. 一键容器化部署

```bash
docker compose -f deploy/docker/docker-compose.yml up -d
```

Kubernetes 部署见 [`deploy/k8s/`](./deploy/k8s)，完整部署文档见 [`docs/deploy/`](./docs/deploy)。

---

## 📈 后续计划

- [x] 使用 STOMP 协议 + WebSocket 实现聊天室
- [ ] 用户评论邮件提醒
- [ ] 集成 ElasticSearch 搜索引擎
- [ ] 添加 Prometheus 监控
- [ ] 集成 AI 聊天功能
- [ ] 增加更多社交功能

---

## 🤝 参与贡献

欢迎提交 Issue 与 Pull Request。分支管理与提交规范见 [`docs/standards/`](./docs/standards)。

## 📄 开源协议

本项目基于 [MIT](https://opensource.org/licenses/MIT) 协议开源。

## 🙏 致谢

感谢以下项目的启发：

- [风丶宇的博客](https://github.com/X1192176811/blog)
- [阿冬的个人博客](https://github.com/ttkican/Blog)
- [vue3-element-admin](https://github.com/youlaitech/vue3-element-admin)
