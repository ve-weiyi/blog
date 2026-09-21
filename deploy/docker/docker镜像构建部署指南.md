# Docker 镜像构建部署指南

> **本文件是** Docker 形态的**应用侧** —— 两个 Dockerfile 的构建契约，以及本地编排怎么用它们。

## 内容

| 路径 | 作用 |
|---|---|
| `backend/` | 后端镜像的 Dockerfile —— **一个文件构建三个服务**（blog-rpc / app-api / admin-api） |
| `frontend/` | 前端镜像的 Dockerfile —— **一个文件构建两个站点**（app-web / admin-web） |
| `docker-compose.yml` | 五个应用的本地编排。**自带 `build:` 段**，所以它就是"从源码构建"那种形态 |
| `.env.example` | Nacos 连接参数**模板**。首次使用前复制为 `.env` |
| `.env` | 实际生效的那份，**已 gitignore、不入库**，由 compose 注入各容器 |

两者都是**多阶段构建**：后端 golang → alpine，前端 node → nginx。

## 构建契约

Dockerfile 靠 `ARG` 区分服务，所以**同一份文件能构建多个服务**，参数不能传错。

### 后端：`SERVICE_DIR`

| 取值 | 构建出的服务 |
|---|---|
| `blog-cloud/rpc/blog` | blog-rpc |
| `blog-cloud/api/app` | app-api |
| `blog-cloud/api/admin` | admin-api |

**构建上下文必须是仓库根**。Dockerfile 里是 `COPY . /build/` 再 `WORKDIR /build/${SERVICE_DIR}` ——
这样 `go.work` 与各子模块的 replace 才生效，否则依赖解析不出来。
产物是 `/app/server`，容器 `CMD ["./server"]`，运行时靠 `-nacos-*` 参数拉配置（见 compose 的 `command`）。

### 前端：`DIST_DIR` 与 `PROXY_PASS`

| 参数 | `app-web` | `admin-web` |
|---|---|---|
| `DIST_DIR` | `dist/blog` | `dist/admin` |
| `PROXY_PASS` | `app.veweiyi.cn` | `admin.veweiyi.cn` |

前端镜像内嵌了一份 nginx.conf（heredoc 生成），其中反代目标用占位符 `__PROXY_PASS__` 表示，
构建时由 `sed` 替换成 `PROXY_PASS` 的值。**两个站点的反代目标不同**，传错会导致接口 404。

## 怎么用

```bash
cp deploy/docker/.env.example deploy/docker/.env   # 首次：模板 → 实际配置
make image-build                                   # 只构建五个镜像，不启动
make image-deploy                                  # 起依赖 + 构建并启动五个应用
```

两个目标都在仓库根目录的 `Makefile` 里，`make help` 看全部命令。
`image-deploy` 先建外部网络 `blog-net`，再逐个拉起六个依赖，最后构建应用 ——
应用读的 Nacos `prod` 配置里主机名是短名（`mysql` / `redis` / `rabbitmq` / `minio`），
只有同处一个网络才解析得了。

需要只起中间件（本机跑后端）或只起应用时，用底层的
`deploy/docker/up.sh deps` / `up.sh app`；停止用 `down.sh`，**只停容器、不删卷**。

## 与 CI 共用同一组 Dockerfile

CI（`.github/workflows/docker-publish.yml`）用的是**这两个同样的 Dockerfile**，
只是参数来源不同：

| 形态 | 谁调用 Dockerfile | 参数来自 |
|---|---|---|
| Docker 单机 · 开发/自建 | `docker-compose.yml` 的 `build:` | compose 里写死的 `args` |
| Docker 单机 · 生产 | CI | CI 的 `matrix`（`service_dir` / `dist_dir` / `proxy_pass`） |

> **改构建参数时两处都要对齐** —— `docker-compose.yml` 与 `.github/workflows/docker-publish.yml`
> 的 `matrix`。只改一处会让"本地构建出来的"和"CI 构建出来的"镜像行为不一致。
