# K8s 集群运维手册

腾讯云单节点 k3s 上的 blog 集群。**部署步骤见 `../../deploy/k8s/k8s集群部署指南.md`（唯一真相源）** ——
本手册只解决"出问题了怎么查"，以及那些报错会把人带偏的地方。

## 一、集群构成

节点 `k3s-master`（2C / 3.6G / 系统盘 70Gi，k3s v1.36.4+k3s1），**全部对象在 `blog` 命名空间**。

| 服务 | Service 端口 | hostPort | 容器内工具 |
|---|---|---|---|
| `mysql` | 3306 | 3306 | sh ✓ curl ✓ |
| `redis` | 6379 | 6379 | sh ✓ |
| `rabbitmq` | 5672 / 15672 | 5672 / 15672 | sh ✓ |
| `minio` | 9000 / 9001 | 9000 / 9001 | sh ✓ curl ✓ |
| `nacos` | 8848 / 8080 / 9848 / 9849 | **无** | sh ✓ curl ✓ |
| `etcd` | 2379 / 2380 | **无** | **无 sh、无 curl** |

全部 Service 为 **headless**。存储 `local-path`，PVC 合计 45Gi，回收策略 `Delete`。
Ingress 由 k3s 内置 **Traefik 原生 provider** 接管；证书由 **cert-manager + Let's Encrypt** 自动签发续期。

## 二、访问方式

```bash
# 每条 kubectl 都显式带 --kubeconfig，避免环境变量串台
kubectl --kubeconfig=deploy/k8s/k8s-config.yaml <cmd>
```

- 集群内：服务短名 `mysql` / `redis` / `rabbitmq` / `minio` / `etcd` / `nacos`
- 集群外：`159.75.154.50` + hostPort（**nacos 与 etcd 不适用** —— 它们没有 hostPort）
- Nacos 控制台：`https://nacos.veweiyi.cn/`（经 Ingress → 8080）

## 三、诊断通道（按性价比排序）

### 1. 直查 MySQL —— 最有效的一条

**Nacos 的全部状态都在 MySQL 里**，比翻 API 快得多，且不受认证问题影响：

```bash
kubectl exec mysql-0 -n blog -- sh -c 'mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "<SQL>"'
```

| 想查什么 | SQL |
|---|---|
| 有哪些配置 | `SELECT tenant_id, group_id, data_id, LENGTH(content) FROM nacos.config_info;` |
| 有哪些命名空间 | `SELECT tenant_id, tenant_name FROM nacos.tenant_info;` |
| 有哪些用户 | `SELECT username, enabled FROM nacos.users;` |
| 业务数据 | `SELECT COUNT(*) FROM blog.t_user;` |

### 2. 容器内探测

有 `sh` 的容器可直接 `kubectl exec`；**etcd 没有 sh**，要探测它得另起一个 Pod
（`quay.io/coreos/etcd:v3.5.17` 自带 `etcdctl`）。需要 curl 而容器里没有时，
用 `curlimages/curl` 起临时 Pod，经服务短名访问。

### 3. 日志

- 应用（k8s 内）：`kubectl logs <pod> -n blog`
- 应用（本地运行）：`blog-cloud/runtime/`
- **Nacos SDK 日志**：`blog-cloud/runtime/<服务>/nacos/logs/nacos-sdk.log` ——
  它比应用侧的报错信息量更大，**应用抛的错常常不指向真因**（见下一节）

## 四、已知故障模式（症状 → 真因）

| 症状 | 真因 | 处置 |
|---|---|---|
| `panic: failed to get Nacos config ... read config from both server and cache fail` | 本地运行且**只转发了 8848**；SDK 拉配置走 gRPC **9848** | 两个端口都转发：`kubectl -n blog port-forward svc/nacos 8848:8848 9848:9848` |
| 同上，但 9848 已通 | Nacos **命名空间未注册** —— 配置发布成功却读不到 | `POST /nacos/v3/admin/core/namespace` 建命名空间 |
| 应用启动即 panic，日志有 `proto: file "auth.proto" is already registered` | etcd 客户端库与项目自身都有 `auth.proto` | Deployment 必须带 `GOLANG_PROTOBUF_REGISTRATION_CONFLICT=warn`（绕过，非根治） |
| 应用正常启动但查库报 `Table 'blog.*' doesn't exist` | 未导入 `protocol/sql/blog.sql`（代码里 `AutoMigrate` 是**注释掉的**） | 按 `../../deploy/k8s/k8s集群部署指南.md` 第五节导入 |
| Pod `ImagePullBackOff` | `ghcr-secret` 缺失，或 PAT 过期 | 建 `env.ghcr.yaml`（已 gitignore，模板见 README）并 apply |
| Ingress 返回 404 **且不重定向** | 后端 Service 不存在 → Traefik 建不出 router → Middleware 无处挂载 | 不是 Ingress 的问题，先部署应用 |
| 证书 `READY=False` | 域名未解析到节点，或 80 端口不通（HTTP-01 需公网可达） | 查 DNS 与安全组 |
| 应用连不上中间件 | 该形态的 Nacos 配置写的是另一种地址（`test` 用公网 IP、`prod` 用短名） | 确认服务读的是哪个命名空间的配置 |
| `kubectl` 查到"陌生"的资源 | `KUBECONFIG` 回落到了本地集群 | 显式指定 kubeconfig |

## 五、Nacos 的特殊性（踩坑最集中处）

部署的是 **Nacos 3.1.1**，与 2.x 差异较大，且报错普遍不指向真因：

1. **建表脚本只建表不插数据** → 首次启动后 `users` 表为空，**没有任何管理员账号**
2. **命名空间必须显式创建** → 否则配置能发布成功、但客户端读不到
3. **控制台登录与管理 API 是两条通道**
4. **v1 与 v3 API 并存**：
   - **客户端**（SDK v2）用 v1：`POST /nacos/v1/auth/login` 换 token，配置查询走 **gRPC 9848**
   - **管理操作**用 v3：`/nacos/v3/admin/...`
5. **管理操作走 server-identity 头**，不经用户体系：
   `-H "serverIdentity: security"`（值对应 `env.yaml` 的 `NACOS_AUTH_IDENTITY_KEY/VALUE`）

**发布配置**：`bash deploy/nacos-config/publish.sh [env] [service]`（幂等）

已知问题：**控制台 UI 登不进去**（返回 `User not found`），但库里 `nacos` 用户与哈希都正常，
且**客户端通道实测可用** —— 不影响应用，需要 UI 时可再调一次 `POST /v3/auth/user/admin` 换新密码。

## 六、危险操作

| 操作 | 后果 |
|---|---|
| `kubectl delete -f <中间件目录>` | 删 PVC，**数据不可恢复** —— PVC 与 StatefulSet 在同一文件里 |
| 删除 `certs/` 下的 Certificate | Secret 被删，重签要重新占用 Let's Encrypt 配额 |
| 反复重签证书 | Let's Encrypt 对同一组域名**每周限 5 次** |

**`kubectl delete -f app/ -f ingress/` 是安全的**：只停应用与 Ingress，保留中间件、数据与证书。

## 七、改动清单前的自检

改 `deploy/` 下任何东西之前，先想三件事：

1. **两套集群**：这个 kubeconfig 指的是腾讯云还是本地？对象名可能相同而内容完全不同。
2. **三种部署形态**：Kubernetes（`deploy/k8s/`）、Docker 单机·生产（CI 拉 ghcr 预构建镜像）、
   Docker 单机·开发自建（`deploy/docker/` 就地构建）—— 改镜像名要三处对齐
   （CI 的 `matrix.service`、k8s 清单、compose）。
3. **凭据散落处**：`deploy/k8s/env.yaml`（`blog-env`）、`deploy/nacos-config/*` 里的明文密码、
   `deploy/docker/.env` —— **两边手工保持一致，没有自动同步**。
