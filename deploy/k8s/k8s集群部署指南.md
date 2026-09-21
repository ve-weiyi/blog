# K8s 集群部署指南

> **本文件是** Kubernetes 形态的**全流程手册** —— 只写怎么把服务跑起来，
> 从一台干净的云服务器到可通过域名访问的服务，按序执行即可复现。
> 设计权衡（为什么是单节点、为什么用 local-path 等）见
> [`docs/design/05-BLOG-部署与运维.md`](../../docs/design/05-BLOG-部署与运维.md)。

## 目录

- [一、前置条件](#一前置条件)
- [二、集群准备](#二集群准备)
- [三、安装集群组件](#三安装集群组件不在本仓库内)
- [四、准备凭据与数据](#四准备凭据与数据)
- [五、部署](#五部署)
- [六、验证](#六验证)
- [七、更新与回滚](#七更新与回滚)
- [八、附录](#八附录)

## 一、前置条件

| 条件 | 说明 |
|---|---|
| 云服务器 | **2 vCPU / 4 GB 内存 / 系统盘 ≥ 60 GB**。实测节点 2C/3.6G，中间件 PVC 合计 45Gi；全量部署后内存占用 77%，**内存是首个瓶颈**，低于 4 GB 不建议 |
| 操作系统 | Linux，本文在 **k3s v1.36.4+k3s1** 上验证 |
| 公网 IP | API server 与 Ingress 都经公网访问 |
| 域名 | **5 条 A 记录**指向节点 IP：`veweiyi.cn`、`app.veweiyi.cn`、`admin.veweiyi.cn`、`nacos.veweiyi.cn`、`minio.veweiyi.cn` |
| 安全组 | 放行 `22`、`80`、`443`、`6443` —— **仅这四个**，理由见下 |
| GitHub PAT | `read:packages` 权限，用于拉取 `ghcr.io/ve-weiyi/*` 私有镜像 |
| 本地工具 | `kubectl`、`ssh` |

### 为什么只要这四个端口

`80` 与 `443` 给 Ingress；`6443` 给 kubeconfig 直连 API；`22` 给 SSH。

**其余端口一律不放行。** MySQL / Redis / RabbitMQ / MinIO 四个清单里带 `hostPort`（3306 / 6379 /
5672 / 15672 / 9000 / 9001），一旦安全组放行，这些服务就直接暴露在公网上，只靠密码保护。
Nacos 与 etcd **不带** `hostPort` —— 前者只经 Ingress 暴露控制台、应用走集群内短名访问，
后者纯内部服务发现，都不需要对外。

> `80` 不只是给访客用的：证书走 ACME **HTTP-01** 验证，Let's Encrypt 需要从公网访问
> `http://<域名>/.well-known/acme-challenge/`。80 不通，证书就签不下来。

## 二、集群准备

首次接手节点时执行；完成后日常只需「连接集群」一步。

### 1. 远程授权

以 root 免密登录节点。公钥未上传时先授权一次（会提示输入服务器密码）：

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@<公网IP>
ssh root@<公网IP> hostname      # 验证免密生效
```

### 2. 集群创建

单节点 k3s，server 与 agent 合一。

```bash
ssh root@<公网IP>

# 主机名必须唯一 —— 它同时是证书 SAN 与 kubeconfig 里 tls-server-name 的取值
hostnamectl set-hostname k3s-master

# 显式指定版本，不要依赖默认的 stable 渠道（重跑安装脚本会静默换版本）
curl -sfL https://rancher-mirror.rancher.cn/k3s/k3s-install.sh | \
  INSTALL_K3S_MIRROR=cn INSTALL_K3S_VERSION=v1.36.4+k3s1 sh -

k3s kubectl get nodes           # 验证：k3s-master 应为 Ready
```

本集群**没有** `/etc/rancher/k3s/config.yaml` —— 启动参数就是 systemd 单元里的 `/usr/local/bin/k3s server`。
日后需追加参数时写进 `config.yaml` 而非 `INSTALL_K3S_EXEC`，这样重启与重跑脚本都不会丢。

### 3. 连接集群

API server 证书的 SAN 只含 `k3s-master` / `localhost` / 内网 IP / `127.0.0.1` / `10.43.0.1`，
**不含公网 IP**。`server` 直接指向公网 IP 会报
`x509: certificate is valid for ..., not <公网IP>`。用 `tls-server-name` 按证书里已有的名字校验：

```yaml
clusters:
  - cluster:
      server: https://<公网IP>:6443
      tls-server-name: k3s-master
```

这样可直连公网 IP 且通过完整 TLS 校验，**不需要** `insecure-skip-tls-verify`，也不需要 SSH 隧道。
这份 kubeconfig 存为 `deploy/k8s/k8s-config.yaml`（含 `system:masters` 私钥，**已 gitignore**）。

```bash
KUBECONFIG=deploy/k8s/k8s-config.yaml kubectl get nodes
```

### 4. 镜像加速

实测：节点直连 `registry-1.docker.io:443` 与 `registry.k8s.io` 均超时（DNS 可解析、TCP 不通），
而 `ghcr.io` 与 `quay.io` 直连可用。不配镜像源时所有 Pod 会卡在 `ContainerCreating`
——连 `rancher/mirrored-pause` 都拉不下来，pod sandbox 建不起来。

```yaml
# /etc/rancher/k3s/registries.yaml
mirrors:
  docker.io:
    endpoint:
      - "https://mirror.ccs.tencentyun.com"
      - "https://docker.m.daocloud.io"
```

```bash
systemctl restart k3s
k3s crictl pull rancher/mirrored-pause:3.10.2   # 验证
```

### 5. 确认 Traefik（Ingress 控制器）

k3s **默认启用 Traefik**，新装节点无需操作：

```bash
kubectl get ingressclass        # 验证：应出现 traefik (default)
```

仅当安装时带了 `--disable traefik` 才需处理 —— 该参数会使 IngressClass 为空、Ingress 无处挂载。
移除后重启：

```bash
# /etc/systemd/system/k3s.service，ExecStart 由
#   /usr/local/bin/k3s server '--disable' 'traefik'
# 改为
ExecStart=/usr/local/bin/k3s server

systemctl daemon-reload && systemctl restart k3s
```

> **排查位置的坑**：禁用既可能在 `config.yaml` 的 `disable: [traefik]`，也可能在 systemd 单元的
> `--disable traefik`。只查前者会误判为「未禁用」。旁证：
> `ls /var/lib/rancher/k3s/server/manifests/` 有 `traefik.yaml` 即未禁用（k3s 启动时写入，被禁用则随即删除）。

## 三、安装集群组件（不在本仓库内）

### cert-manager

TLS 证书由 cert-manager 向 Let's Encrypt 申请，**必须先装** —— 否则后面 apply `certs/` 时
ClusterIssuer 找不到 CRD，`kubectl apply` 直接报错。

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.yaml

kubectl -n cert-manager wait --for=condition=Available deploy --all --timeout=180s
kubectl -n cert-manager get pod      # 验证：三个 Pod 均 Running
```

版本与本集群一致（实测 `cert-manager-controller:v1.16.2`）。官方清单自带 `cert-manager` 命名空间与 CRD。

## 四、准备凭据与数据

### 1. 命名空间与共用 Secret

以下命令的工作目录是 `deploy/k8s`，请先切进去并把 `KUBECONFIG` 指到该目录下的 kubeconfig：

```bash
cd deploy/k8s
export KUBECONFIG="$PWD/k8s-config.yaml"

kubectl apply -f namespace.yaml     # 命名空间 blog
kubectl apply -f env.yaml           # Secret blog-env
```

`env.yaml` 是 Secret `blog-env`，**中间件与应用的凭据全部集中在这里**，不再有各自的 `*-secret`。
内容是明文（`stringData`），**未 gitignore** —— 提交前需先决定处置方式。

### 2. 私有镜像凭据

`kubectl apply -f app/` 时五个 Deployment 都引用 `ghcr-secret`，缺了会停在 `ImagePullBackOff`。

`env.ghcr.yaml` **已 gitignore、不入库**，新克隆的仓库里没有，需手动创建：

```bash
cat > env.ghcr.yaml <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: ghcr-secret
  namespace: blog
type: kubernetes.io/dockerconfigjson
stringData:
  .dockerconfigjson: |
    {"auths":{"ghcr.io":{"username":"<GHCR_USER>","password":"<GHCR_TOKEN>"}}}
EOF

# 把 <GHCR_USER>（GitHub 用户名）与 <GHCR_TOKEN>（read:packages 权限的 PAT）换成实际值
$EDITOR env.ghcr.yaml

kubectl apply -f env.ghcr.yaml
```

> `type` 与数据键名都是硬约定，不能改：必须是 `kubernetes.io/dockerconfigjson` +
> `.dockerconfigjson`（kubelet 按此键名读取）。

## 五、部署

工作目录承接上一节的 `deploy/k8s`。新开终端需重跑：`cd deploy/k8s && export KUBECONFIG="$PWD/k8s-config.yaml"`

```bash
# 1. MySQL 先起 —— 后面的 Nacos 与业务库都依赖它
kubectl apply -f mysql/
kubectl rollout status statefulset/mysql -n blog --timeout=180s

# 2. 初始化两个数据库（须在 Nacos 启动前完成，见下方说明）
kubectl exec -i mysql-0 -n blog -- \
  sh -c 'mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "CREATE DATABASE IF NOT EXISTS blog DEFAULT CHARSET utf8mb4 COLLATE utf8mb4_0900_ai_ci;"'

kubectl exec -i mysql-0 -n blog -- \
  sh -c 'mysql -u root -p"$MYSQL_ROOT_PASSWORD" blog' < ../../protocol/sql/blog.sql

kubectl exec -i mysql-0 -n blog -- \
  sh -c 'mysql -u root -p"$MYSQL_ROOT_PASSWORD" blog' < ../../protocol/sql/blog-data.sql

# Nacos 的配置库
kubectl exec -i mysql-0 -n blog -- \
  sh -c 'mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "CREATE DATABASE IF NOT EXISTS nacos DEFAULT CHARSET utf8mb4 COLLATE utf8mb4_0900_ai_ci;"'

kubectl exec -i mysql-0 -n blog -- \
  sh -c 'mysql -u root -p"$MYSQL_ROOT_PASSWORD" nacos' < nacos/mysql-schema.sql

# 3. 其余中间件
kubectl apply -f redis/
kubectl apply -f rabbitmq/
kubectl apply -f minio/
kubectl apply -f etcd/
kubectl apply -f nacos/

# 4. 应用（blog-rpc / app-api / admin-api / app-web / admin-web）
kubectl apply -f app/

# 5. 签发 TLS 证书（cert-manager；签发需 30~60 秒，先于 Ingress 可免去自签证书的过渡期）
kubectl apply -f certs/

# 6. Ingress（域名接入）
kubectl apply -f ingress/
```

**为什么两个数据库缺一不可：**

| 库 | 用途 | 不建的后果 |
|---|---|---|
| `blog` | 业务数据（30 张表） | 应用能启动，但每次查库报 `Table 'blog.t_user' doesn't exist` |
| `nacos` | Nacos 的配置存储 | Nacos 起不来 —— 它的 MySQL 后端需要这些表，缺表则启动失败 |

代码里的 `AutoMigrate` 是**注释掉的**（`svc/service_context.go`，理由：生产环境自动迁移有丢数据风险），
所以表结构必须由 `protocol/sql/blog.sql` 显式导入。`blog-data.sql` 提供可登录的种子账号。

`nacos/mysql-schema.sql` 取自镜像 `nacos/nacos-server:v3.1.1` 内的
`/home/nacos/conf/mysql-schema.sql`，与所部署版本严格对应，已随本目录入库。

### Ingress 与证书

`ingress/` 下每个 Ingress 声明 `ingressClassName: traefik`，由 k3s 内置 Traefik 的
**原生 provider**（`kubernetesingress`）接管，无需任何集群外配置。

HTTP → HTTPS 重定向由 [`ingress/middleware.yaml`](ingress/middleware.yaml) 的 Traefik Middleware 承担，
各 Ingress 通过注解引用（格式 `<namespace>-<name>@kubernetescrd`）：

```
traefik.ingress.kubernetes.io/router.middlewares: blog-redirect-https@kubernetescrd
```

证书由 [`certs/issuer.yaml`](certs/issuer.yaml) 与 [`certs/certificates.yaml`](certs/certificates.yaml)
声明，cert-manager 自动签发并在 90 天到期前续期：

| Secret | 域名 | 被哪个 Ingress 引用 |
|---|---|---|
| `blog-app-tls` | `app.veweiyi.cn` | `ingress/app.yaml` |
| `blog-admin-tls` | `admin.veweiyi.cn` | `ingress/admin.yaml` |
| `blog-nacos-tls` | `nacos.veweiyi.cn` | `ingress/nacos.yaml` |
| `blog-minio-tls` | `minio.veweiyi.cn` | `ingress/minio.yaml` |

一域名一证书，续期互不牵连。证书是 cert-manager 管理的 Secret，**无需手工维护证书文件**。

```bash
kubectl get certificate -n blog      # 验证：READY 应为 True（签发需 30~60 秒）
```

> **首次部署建议先用 staging 验证链路**：把 `certificates.yaml` 里的 issuerRef 临时改为
> `letsencrypt-staging`，签出的证书浏览器不信任，仅用于确认 HTTP-01 能跑通；确认后改回
> `letsencrypt-prod` 重新 apply。
> **不要拿生产环境试错** —— Let's Encrypt 对同一组域名每周只允许重签 5 次。

`ingress/` 下所有 Ingress 都在 `blog` 命名空间，因此每个 Secret 只需一份。
**TLS Secret 不能跨命名空间引用**，若将来有 Ingress 落到别的命名空间，需为它另建一份。

## 六、验证

```bash
kubectl get pod,pvc,svc,ingress -n blog
kubectl get certificate -n blog
kubectl get pv
```

期望：6 个中间件 Pod 与 5 个应用 Pod 均 `Running`；6 个 PVC 均 `Bound`；4 张证书 `READY=True`。

端到端验证（从本机发起真实 HTTPS 请求，证书应通过校验）：

```bash
for h in app.veweiyi.cn admin.veweiyi.cn nacos.veweiyi.cn minio.veweiyi.cn; do
  printf "%-18s " "$h"
  curl -s -o /dev/null -m 10 -w "HTTPS %{http_code}  证书校验:%{ssl_verify_result}\n" "https://$h/"
done
```

`证书校验:0` 表示信任链验证通过。期望响应：`nacos` 为 200（控制台）、`minio` 为 403
（匿名列桶被拒，正常）、`app` 与 `admin` 为 200 或 404（取决于前端是否已构建）。

验证 HTTP → HTTPS 重定向：

```bash
curl -s -o /dev/null -w "HTTP %{http_code} -> %{redirect_url}\n" http://nacos.veweiyi.cn/
# 期望：HTTP 301 -> https://nacos.veweiyi.cn/
```

> **后端 Service 缺失时 Ingress 不重定向**：Traefik 对后端 Service 不存在的 Ingress 建不出 router，
> 会直接返回 404 —— 没有 router 就没有地方挂 Middleware。应用尚未部署时 `app` / `admin` 会表现为此，
> 部署后自愈。

## 七、更新与回滚

```bash
kubectl rollout restart deployment/blog-rpc -n blog
kubectl rollout status  deployment/blog-rpc -n blog --timeout=120s
```

`app/` 下共五个 Deployment：`blog-rpc`、`app-api`、`admin-api`、`app-web`、`admin-web`。

镜像更新走 CI：推 `v*` tag 触发 [`.github/workflows/docker-publish.yml`](../../.github/workflows/docker-publish.yml)
构建并推送至 `ghcr.io`，节点侧用上面的 `rollout restart` 拉取新镜像（清单里均为 `:latest`）。

### 停止与销毁

**停对外服务** —— 只删应用与 Ingress，中间件、数据与证书全部保留：

```bash
kubectl delete -f app/ -f ingress/ --ignore-not-found
```

> 证书刻意不删：删掉后重新部署会重新签发，白耗 Let's Encrypt 每周 5 次的配额。
> 重新拉起用 `kubectl apply -f app/ -f ingress/`。

**销毁全部资源** —— 连中间件与 PVC 一起删，**数据不可恢复**：

```bash
kubectl delete -f ingress/ -f app/ --ignore-not-found
kubectl delete -f mysql/ -f redis/ -f rabbitmq/ --ignore-not-found
kubectl delete -f minio/ -f etcd/ -f nacos/ --ignore-not-found
kubectl delete -f certs/ --ignore-not-found
```

> `local-path` 的 PVC 回收策略是 `Delete`，删 PVC 即删数据，没有回收站。
> 中间件目录里 PVC 与 StatefulSet 同文件，删目录就是删数据 —— 这条命令没有确认提示。

## 八、附录

### 镜像清单

| 服务 | 镜像 | 来源 | 凭证 |
|---|---|---|---|
| blog-rpc | `ghcr.io/ve-weiyi/blog-rpc:latest` | 私有 | `ghcr-secret` |
| app-api | `ghcr.io/ve-weiyi/app-api:latest` | 私有 | `ghcr-secret` |
| admin-api | `ghcr.io/ve-weiyi/admin-api:latest` | 私有 | `ghcr-secret` |
| app-web | `ghcr.io/ve-weiyi/app-web:latest` | 私有 | `ghcr-secret` |
| admin-web | `ghcr.io/ve-weiyi/admin-web:latest` | 私有 | `ghcr-secret` |
| mysql | `mysql:8.0.34` | Docker Hub | — |
| redis | `redis:7.4-alpine` | Docker Hub | — |
| rabbitmq | `rabbitmq:4.3.2-management` | Docker Hub | — |
| nacos | `nacos/nacos-server:v3.1.1` | Docker Hub | — |
| minio | `minio/minio:RELEASE.2025-04-22T22-12-26Z` | Docker Hub | — |
| etcd | `quay.io/coreos/etcd:v3.5.17` | Quay | — |
| cert-manager | `quay.io/jetstack/cert-manager-controller:v1.16.2` | Quay | — |

镜像均已钉版本。**etcd 不要用 `registry.k8s.io`** —— 实测该域从本节点不可达（i/o timeout）。

### 本目录内容

| 路径 | 内容 |
|---|---|
| 根目录的 `*.yaml` | 命名空间、凭据 Secret、kubeconfig —— 逐个用途与 apply 顺序见第四节 |
| `mysql/` `redis/` `rabbitmq/` `nacos/` `minio/` `etcd/` | 中间件，各含 PVC + Service + StatefulSet |
| `app/` | 五个应用 + `nacos-config` ConfigMap |
| `ingress/` | 域名路由：Ingress + 重定向 Middleware |
| `certs/` | 证书签发：ClusterIssuer + Certificate |

### 已知缺口

- **没有备份**。六个中间件均单副本 + `local-path` 本地存储，PVC 回收策略为 `Delete`：
  节点故障或误删 PVC 即数据不可恢复。
- **默认口令未改**。`env.yaml` 中 MySQL / Redis / RabbitMQ / MinIO 的密码为初值；
  `protocol/sql/blog-data.sql` 的种子账号是 `root` / `root`；Nacos 控制台是默认的 `nacos` / `nacos`。
  配合「安全组只放行四个端口」可降低风险，但**首次部署后仍应改掉**。
- **SSE 长连接超时未调**。原 nginx 清单里的 `proxy-read-timeout: "600"` 随注解一并失效。
  Traefik 默认 `readTimeout=0`（不限）、`idleTimeout=180s`：SSE 若有短于 180s 的心跳则不受影响，
  若发现长连接被断，需在 kube-system 的 Traefik 配置里调 `idleTimeout`。

### 其他注意事项

- **存储供给器无需部署**。k3s 自带 local-path provisioner，`StorageClass/local-path`
  （provisioner `rancher.io/local-path`，已标记 default）随集群创建即存在，确认：`kubectl get sc`。
  **不要从上游引入 local-path 清单** —— 其 `StorageClass/local-path`、
  `ClusterRole/local-path-provisioner-role`、`ClusterRoleBinding/local-path-provisioner-bind`
  会与内置对象同名冲突。
- **全部对象显式声明 `namespace: blog`**。中间件与应用同命名空间，应用经服务短名
  （`mysql` / `redis` / `rabbitmq` / `minio` / `etcd` / `nacos`）直接访问。
- **应用的运行配置由 Nacos 下发**（见 `app/nacos-config.yaml` 的 `NACOS_HOST`），
  数据源、存储、OAuth 等不在本目录清单内 —— 改配置要去 Nacos 控制台改，改清单无效。
- **`etcd/` 当前没有使用者**。它作为 go-zero 的服务注册中心部署，但 `api/*/etc/*.example.yaml`
  里的 `AppRpcConf` 走的是**直连模式**（`Endpoints: blog-rpc:9120`），etcd 那段是注释状态。
  它按计划保留以备切换到注册中心模式，未启用时不影响运行。
- **K8s 部署全程是裸 `kubectl`，没有任何封装** —— 首次部署按第四、五节的顺序执行，
  日常启停与销毁见第七节。仓库里另有两个 Makefile，都与集群无关：根目录那份的
  `image-build` / `image-deploy` 管**本地 Docker 形态**，`blog-cloud/` 那份只管
  后端程序的编译与本地启动（`build` / `run-*`）。
