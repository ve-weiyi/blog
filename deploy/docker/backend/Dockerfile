FROM golang:alpine AS builder

LABEL stage=gobuilder

ENV CGO_ENABLED=0
ENV GOPROXY=https://goproxy.cn,direct

RUN apk update --no-cache && apk add --no-cache tzdata

# 要构建的服务目录，以仓库根为构建上下文：
#   blog-cloud/api/admin   blog-cloud/api/app   blog-cloud/rpc/blog
ARG SERVICE_DIR

# 以仓库根目录为上下文构建，go.work 与各子模块的 replace 自然生效
COPY . /build/
WORKDIR /build/${SERVICE_DIR}

RUN go mod tidy
RUN go build -ldflags="-s -w" -o /app/server .

FROM alpine

COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=builder /usr/share/zoneinfo/Asia/Shanghai /usr/share/zoneinfo/Asia/Shanghai
ENV TZ=Asia/Shanghai

WORKDIR /app
COPY --from=builder /app/server /app/server

CMD ["./server"]
