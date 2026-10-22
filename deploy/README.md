# 部署形态

本目录是**部署入口**：先在这里选形态，再去对应文档看步骤。

Kubernetes 与 Docker 单机（生产）**共用同一套镜像命名**（`ghcr.io/ve-weiyi/<service>`）——
在这两者之间切换不需要改镜像名。Docker 单机（开发/自建）是就地构建，用本地标签
（`blog-rpc:latest` 等），不涉及 ghcr。

## 选哪种

分类的两个维度是**镜像来源**与**运行环境**：

| | Kubernetes | Docker 单机（生产） | Docker 单机（开发/自建） |
|---|---|---|---|
| **镜像来源** | ghcr 预构建 | ghcr 预构建（CI 部署） | **本地从源码构建** |
| **运行环境** | 集群内 | 宿主机 | 宿主机 |
| **部署入口** | `kubectl`（裸命令） | CI 的 `workflow_dispatch` | `make image-deploy` |
| 适用 | 要自愈 / 滚动更新 / 资源隔离 | 单机小规模，发版走 CI | 改了代码要立刻验证、不想推镜像 |
| 编排 | `k8s/` 下的清单 | CI 直接 `docker run` | `docker/docker-compose.yml` |
| 依赖服务 | 集群内的 `k8s/<组件>/` | `docker-compose/` 起在宿主机 | 同左 |
| TLS 证书 | cert-manager 自动签发续期 | 手工获取，挂宿主机 Nginx | 同左 |
| 运维成本 | 中 | 低 | 低 |
| CI 自动部署 | ✅ | ✅ 默认路径 | ✗（本地操作） |

**判断依据**

- 需要自愈、滚动更新、证书自动续期 → **Kubernetes**
- 一台机器、手工运维、发版走 CI → **Docker 单机（生产）**
- 在本地改代码要立刻跑起来 → **Docker 单机（开发/自建）**

**两张 Docker 形态的差别只在镜像从哪来**：生产那份由 CI 构建推送 ghcr、服务器侧 `docker pull`；
开发/自建那份用同一份 `deploy/docker/docker-compose.yml`，而该文件自带 `build:` 段，
`make image-deploy` 会就地为五个服务执行 `docker build`。

> **Kubernetes 形态不支持本地构建镜像** —— 清单引用的是 `ghcr.io/ve-weiyi/<service>`。
> 要换镜像只能重新构建并推送，或改清单指向集群可达的 registry。

## 目录与文档

| 路径 | 文档 | 角色 |
|---|---|---|
| `k8s/` | [`k8s集群部署指南.md`](k8s/k8s集群部署指南.md) | **Kubernetes 全流程手册** —— 从一台干净的云服务器到可通过域名访问的服务 |
| `docker/` | [`docker镜像构建部署指南.md`](docker/docker镜像构建部署指南.md) | **Docker 形态的应用侧** —— 两个 Dockerfile 的构建契约，以及本地起停脚本 `up.sh` / `down.sh` |
| `docker-compose/` | [`docker-compose容器部署指南.md`](docker-compose/docker-compose容器部署指南.md) | **Docker 形态的依赖服务** —— 各中间件的启停方式与连接信息 |
| `nacos-config/` | [`配置说明.md`](nacos-config/配置说明.md) | **Nacos 配置的源头与发布方式** —— 三种形态共用同一份配置 |
| `nginx/` | — | 宿主机 Nginx 反代配置（Docker 形态用） |

> **两个 Docker 目录别混**：`docker/` 是**应用**（五个服务的 Dockerfile 与编排），
> `docker-compose/` 是**依赖服务**（中间件）。名字里都有 compose，内容完全不同。

## Docker 日常操作

入口在仓库根目录的 `Makefile`（`make help` 列全部命令）：

| 命令 | 作用 |
|---|---|
| `make image-build` | 只构建五个应用镜像，**不推送** |
| `make image-deploy` | 起依赖 + 构建并启动应用 |

首次需先 `cp deploy/docker/.env.example deploy/docker/.env`。
停止用 `bash deploy/docker/down.sh`，**只停容器、不删卷**。

> 只起中间件（本机跑后端时用）或只起应用，用 `deploy/docker/up.sh deps` / `up.sh app` ——
> 上面两个 make 目标就是它的封装。

## Kubernetes 日常操作

部署是裸 `kubectl`，没有封装。kubeconfig 必须显式指定 —— 本项目有两套 k3s 集群，
靠环境变量会静默串台：

```bash
export KUBECONFIG=$PWD/deploy/k8s/k8s-config.yaml
```

| 操作 | 命令 |
|---|---|
| 停对外服务，**保留中间件、数据与证书** | `kubectl delete -f deploy/k8s/app/ -f deploy/k8s/ingress/` |
| 重新拉起 | `kubectl apply -f deploy/k8s/app/ -f deploy/k8s/ingress/` |
| 重启单个服务 | `kubectl rollout restart deployment/blog-rpc -n blog` |

**首次部署**的完整顺序（含建库，且 MySQL 必须先于 Nacos）见
[`k8s/k8s集群部署指南.md`](k8s/k8s集群部署指南.md) 第五节；
**销毁全部资源**（含 PVC，数据不可恢复）见该指南第七节。

## CI 部署

`.github/workflows/docker-publish.yml`：

- **push `v*` tag** —— 构建全部 5 个镜像并推送，**不部署**
- **workflow_dispatch** —— 按服务构建，可选顺带部署

手动触发时两个关键输入：

| 输入 | 取值 | 说明 |
|---|---|---|
| `deploy_services` | `skip` / `all` / 单个服务 | `skip` 则只构建不部署 |
| `deploy_target` | `docker` / `k8s` | 部署目标形态；`deploy_services=skip` 时忽略 |

两条路径都经 SSH 到服务器执行（k8s 路径在节点上跑 `kubectl set image`），
**不把 kubeconfig 存进 GitHub Secret** —— 它含 `system:masters` 私钥，等同于集群最高权限。
