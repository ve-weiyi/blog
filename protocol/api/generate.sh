#!/bin/bash

cd "$(dirname "$0")"                        # 切换到脚本所在目录

shopt -s nullglob                           # 当没有匹配的文件时，* 不再保留

# 支持传入服务目录参数：./generate.sh admin
# 不传参数则遍历当前目录下所有服务目录
if [ $# -gt 0 ]; then
  dirs=("$@")
else
  dirs=(*/)
fi

ROOT="$(cd ../.. && pwd)"                           # monorepo 根目录

for dir in "${dirs[@]}"; do
  [ -d "$dir" ] || continue

  SERVICE_NAME="${dir%/}"                           # 服务名，如 admin
  SERVICE_DIR="$ROOT/blog-cloud/api/$SERVICE_NAME"  # 生成代码归属的服务目录

  # 进入服务目录执行，使 goctl 记录的路径不含目录名
  (
    cd "$SERVICE_NAME"

    # 格式化 .api文件
    goctl api format -dir ./

    # 根据 api 文件生成 swagger 文档。
    goctl api swagger --api "$SERVICE_NAME.api" --dir "$SERVICE_DIR/docs"

    # 根据 api 文件生成 业务代码
    goctl api go -api "$SERVICE_NAME.api" -dir "$SERVICE_DIR" --style go_zero --home "$ROOT/.goctl/template" --type-group
  )
done
