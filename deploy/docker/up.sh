#!/usr/bin/env bash
#
# Docker 单机形态的启动入口：中间件 + 应用。
#
#   bash deploy/docker/up.sh          # 依赖与应用都起
#   bash deploy/docker/up.sh build    # 只构建应用镜像（不启动）
#   bash deploy/docker/up.sh deps     # 只起依赖（本机跑后端时用）
#   bash deploy/docker/up.sh app      # 只起应用
#
# 依赖逐个 docker compose 调用，不合并成一条 —— 合并会把项目名从
# mysql / redis / ... 变成单一项目，卷名随之改变，已有数据读不到。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEPS="$ROOT/deploy/docker-compose"
APP="$ROOT/deploy/docker"

# 依赖与应用必须同处这个网络，应用才能经短名 mysql / redis / rabbitmq / minio
# 访问中间件（Nacos 的 prod 配置里写的就是这些短名）。
# 幂等：已存在时 create 返回非零。
ensure_network() {
  docker network create blog-net 2>/dev/null || true
}

require_env() {
  if [ ! -f "$APP/.env" ]; then
    echo "缺少 $APP/.env —— 先执行：cp $APP/.env.example $APP/.env" >&2
    exit 1
  fi
}

build_images() {
  require_env
  echo "构建应用镜像 ..."
  docker compose -f "$APP/docker-compose.yml" build
}

start_deps() {
  ensure_network
  for s in mysql/mysql redis/redis rabbitmq/rabbitmq etcd/etcd nacos/nacos minio/minio; do
    echo "启动 $s ..."
    docker compose -f "$DEPS/$s.yaml" up -d
  done
}

start_app() {
  ensure_network
  require_env
  echo "构建并启动应用 ..."
  docker compose -f "$APP/docker-compose.yml" up -d
}

case "${1:-all}" in
  build) build_images ;;
  deps)  start_deps ;;
  app)   start_app ;;
  all)   start_deps; start_app ;;
  *)     echo "用法: $0 [build|deps|app]" >&2; exit 2 ;;
esac

echo "完成。"
