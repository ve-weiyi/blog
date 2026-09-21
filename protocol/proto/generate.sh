#!/bin/bash

cd "$(dirname "$0")"                        # 切换到脚本所在目录

shopt -s nullglob                           # 当没有匹配的文件时，* 不再保留

# 支持传入服务目录参数：./generate.sh blog
# 不传参数则遍历当前目录下所有服务目录
if [ $# -gt 0 ]; then
  dirs=("$@")
else
  dirs=(*/)
fi

ROOT="$(cd ../.. && pwd)"                           # monorepo 根目录

for dir in "${dirs[@]}"; do
  [ -d "$dir" ] || continue

  SERVICE_NAME="${dir%/}"                           # 服务名，如 blog
  SERVICE_DIR="$ROOT/blog-cloud/rpc/$SERVICE_NAME"  # 生成代码归属的服务目录
  OUTPUT_DIR="$SERVICE_DIR/internal/pb"             # Proto 生成代码的输出目录 (设置在internal内部是为了防止api使用，api应该使用client下的pb)
  ZRPC_OUT="$SERVICE_DIR/"                          # zrpc_out 输出目录
  ETC_DIR="$SERVICE_DIR/etc"                        # YAML 配置文件目录

  # 进入服务目录执行，使 protoc 记录的 source 为纯文件名（如 config.proto），
  # 避免目录名渗入生成代码的标识符（file_config_proto → file_blog_config_proto）
  (
    cd "$SERVICE_NAME"

    for file in *.proto; do
      if [ -f "$file" ]; then
        # 生成代码
        goctl rpc protoc "$file" \
          --go_out="$OUTPUT_DIR" \
          --go-grpc_out="$OUTPUT_DIR" \
          --zrpc_out="$ZRPC_OUT" \
          --style go_zero \
          -m

        # goctl 以 proto 的 package 名命名入口文件与 YAML，而非 .proto 文件名：
        #   package blog.content.v1 → blog.content.v1.go、etc/blog.content.v1.yaml
        # 因此删除目标必须从 package 声明推导，不能由文件名拼 <name>rpc 得出
        pkg_name="$(sed -n 's/^[[:space:]]*package[[:space:]]\{1,\}\([^;]\{1,\}\);.*/\1/p' "$file" | head -n 1)"

        if [ -n "$pkg_name" ]; then
          # 删除 YAML 配置文件
          rm -f "$ETC_DIR/$pkg_name.yaml"

          # 删除生成的 Go 文件
          rm -f "${ZRPC_OUT}$pkg_name.go"
        fi
      fi
    done
  )
done
