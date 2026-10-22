# Docker Compose 容器部署指南

> **本文件是** Docker 形态的**依赖服务** —— 各中间件的启停方式与连接信息。

每个服务一个目录，目录内是它的 compose 文件（`kafka/` 例外 —— 单节点与三节点各一份）。

## 服务列表

| 目录 | 服务 | blog 是否在用 |
|---|---|---|
| `mysql/` | MySQL 数据库 | ✅ **必需** |
| `redis/` | Redis 缓存 | ✅ **必需** |
| `rabbitmq/` | RabbitMQ 消息队列 | ✅ **必需** |
| `nacos/` | Nacos 配置中心 | ✅ **必需** |
| `minio/` | MinIO 对象存储 | ✅ **必需** |
| `etcd/` | etcd 服务发现 | ⚠️ 已备好，**当前未启用**（服务间调用走直连） |
| `postgres/` | PostgreSQL（pgvector） | ➖ 备用，不部署也能跑 |
| `kafka/` | Kafka 单节点 / 三节点集群 | ➖ 备用，不部署也能跑 |
| `rancher/` | Rancher 容器管理平台 | ➖ 运维工具，与应用无关 |

> `deploy/docker/up.sh deps` 起的正是**前六个**（含当前未启用的 etcd）；
> PostgreSQL / Kafka / Rancher 按需单独起，它们不是 blog 的运行依赖。

## 使用方法

`-f` 指向某个服务的 compose 文件即可单独启停（多个服务就多写几个 `-f`）：

```bash
# 起单个
docker compose -f mysql/mysql.yaml up -d

# 起多个
docker compose -f mysql/mysql.yaml -f redis/redis.yaml up -d

# 停
docker compose -f mysql/mysql.yaml down
```

### 前置：外部网络 `blog-net`

六个依赖与 `deploy/docker/` 的应用**共用外部网络 `blog-net`**（各文件末尾的
`networks: default:` 声明）。这是应用能经短名 `mysql` / `redis` / `rabbitmq` / `minio`
访问中间件的前提 —— 否则每个 compose 各自一个网络，连依赖之间都互相看不见。

**上面的裸命令不会建它**，需先执行一次：

```bash
docker network create blog-net
```

`down` 不会删除该网络（它是 `external`，不归任何 compose 项目所有）。

### 起停全部六个

一条命令按序拉起这六个：`make image-deploy`（会先建好网络、再起应用）或
`deploy/docker/up.sh deps`（只要中间件）。停止用 `down.sh`。

## 服务连接信息

### MySQL
- Host: localhost
- Port: 3306
- Username: blog
- Password: blog-mysql-2026
- Database: blog

### PostgreSQL
- Host: localhost
- Port: 5432
- Username: postgres
- Password: postgres

### Redis
- Host: localhost
- Port: 6379
- Password: blog-redis-2026

### etcd
- Client: localhost:2379
- Peer: localhost:2380

### RabbitMQ
- AMQP Port: 5672
- Management UI: http://localhost:15672
- Username: blog
- Password: blog-rabbitmq-2026

### Nacos
- 控制台: http://localhost:8848/nacos
- Username: nacos
- Password: nacos

### Kafka 单节点
- Bootstrap: localhost:9092
- Kafka UI: http://localhost:9080

### Kafka 三节点集群
- Bootstrap: localhost:19094, localhost:29094, localhost:39094
- Schema Registry: http://localhost:8085
- Kafka UI: http://localhost:8099

### MinIO
- S3 API: http://localhost:9000
- 控制台: http://localhost:9001
- Username: blog
- Password: blog-minio-2026
- Bucket: blog（首次上传时由程序自动创建并设为公开读）

### Rancher
- 控制台: https://localhost:10443
- 初始密码: rancher
