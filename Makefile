.DEFAULT_GOAL := help

# ── 路径 ─────────────────────────────────────────────────

BACKEND := blog-cloud
LOG_DIR := logs

# ── 服务清单 ─────────────────────────────────────────────
# 后端：<服务名>:<端口>:<目录>:<配置文件（相对服务目录）>
# 目录与配置相对 blog-cloud/；启动顺序按列表排列，rpc 先于 api
SERVICES := blog-rpc:9120:cmd/rpc/blog:etc/blog-rpc.yaml \
            admin-api:9421:cmd/api/admin:etc/admin-api.yaml \
            blog-api:9420:cmd/api/app:etc/app-api.yaml

# stop 的端口由清单派生，避免漏项
PORTS := $(foreach s,$(SERVICES),$(word 2,$(subst :, ,$(s))))

# 前端：<目录>:<端口>
FRONTENDS := blog-admin:9521 blog-app:9520
FRONTEND_PORTS := $(foreach w,$(FRONTENDS),$(word 2,$(subst :, ,$(w))))

# go.work 下的全部模块，install 时逐个 tidy
WORK_MODULES := blog-cloud blog-gin goctlx stompws vkit

# test 模式连接集群：Nacos 与 Hermes 通过 port-forward 暴露到本机
KUBECONFIG_FILE ?= deploy/k8s/k8s-config.yaml
NACOS_HOST ?= 127.0.0.1
NACOS_PORT ?= 8848
NACOS_NAMESPACE ?= test
NACOS_GROUP ?= veweiyi.cn
# 本地 test 的 admin 令牌签名密钥；可在仓库根目录 .env 覆盖
ADMIN_TOKEN_SECRET ?= local-dev-admin-token-secret-0123456789abcdef
export ADMIN_TOKEN_SECRET

# Darwin 无 stdbuf，行缓冲置空
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
	UNBUF :=
else
	UNBUF := stdbuf -oL
endif

.PHONY: help init fetch install dev test preview stop forward stop-forward backend frontend image-build image-deploy clean

# ═══════════════════════════════════════════════════════════
#  帮助
# ═══════════════════════════════════════════════════════════

help:
	@echo "可用命令："
	@echo ""
	@echo "  准备"
	@echo "    make init            首次初始化全部子模块"
	@echo "    make fetch           更新主仓库 + 全部子模块到最新"
	@echo "    make install         后端 go mod tidy + 前端 pnpm install"
	@echo ""
	@echo "  开发"
	@echo "    make dev             前端 pnpm dev (mock模式)"
	@echo "    make test            后端 go run (Nacos 配置) + 前端 pnpm test（自动转发 Nacos/Hermes）"
	@echo "    make preview         前端 pnpm preview (构建产物 + mock)"
	@echo "    make stop            停止前后端运行端口与端口转发"
	@echo "    make forward         仅转发 Nacos(8848/9848) 与 Hermes(18642)"
	@echo "    make stop-forward    停止端口转发"
	@echo ""
	@echo "  单独运行"
	@echo "    make backend         后端 go run（本地 yaml 配置）"
	@echo "    make frontend        前端 pnpm dev (mock模式)"
	@echo ""
	@echo "  部署（本地 Docker）"
	@echo "    make image-build     构建五个应用镜像（本地标签）"
	@echo "    make image-deploy    部署到本地 Docker（依赖 + 应用）"

# ═══════════════════════════════════════════════════════════
#  准备
# ═══════════════════════════════════════════════════════════

# 首次初始化全部子模块
init:
	git submodule update --init --recursive

# 更新主仓库 + 全部子模块到最新
fetch:
	git pull --rebase --autostash
	git submodule update --init --remote --rebase

# 后端 go mod tidy + 前端 pnpm install
install:
	@echo "=== 安装后端依赖 (go mod tidy) ==="
	@for m in $(WORK_MODULES); do \
		echo "  → $$m"; \
		( cd $$m && go mod tidy ) || exit 1; \
	done
	@echo ""
	@echo "=== 安装前端依赖 (pnpm install) ==="
	@for w in $(FRONTENDS); do \
		name=$$(echo $$w | cut -d: -f1); \
		echo "  → $$name"; \
		( cd $$name && pnpm install ) || exit 1; \
	done
	@echo ""
	@echo "依赖安装完成"

# ═══════════════════════════════════════════════════════════
#  开发
# ═══════════════════════════════════════════════════════════

# 全栈：仅前端，mock 模式（不起后端）
dev: stop frontend

# 全栈：后端 go run（Nacos 配置）+ 前端 pnpm test
test:
	@$(MAKE) --no-print-directory stop
	@$(MAKE) --no-print-directory forward
	@if [ -f .env ]; then \
		AI_API_KEY=$$(grep -E '^AI_API_KEY=' .env | tail -1 | cut -d= -f2-); \
		ADMIN_TOKEN_SECRET=$$(grep -E '^ADMIN_TOKEN_SECRET=' .env | tail -1 | cut -d= -f2-); \
		export AI_API_KEY ADMIN_TOKEN_SECRET; \
	fi; \
	trap 'kill 0; for f in /tmp/blog-forward-*.pid; do [ -f "$$f" ] && kill -9 $$(cat "$$f") 2>/dev/null; rm -f "$$f"; done; exit 0' INT TERM; \
	rm -rf $(LOG_DIR); \
	mkdir -p $(LOG_DIR); \
	echo "=== 全栈 - test (后端 Nacos 配置 + 前端 pnpm test, 后端日志→$(LOG_DIR)/, Ctrl+C 停止) ==="; \
	i=0; \
	for s in $(SERVICES); do \
		name=$$(echo $$s | cut -d: -f1); \
		dir=$$(echo $$s | cut -d: -f3); \
		if [ $$i -gt 0 ]; then echo "  等待 2s 启动下一个服务..."; sleep 2; fi; \
		( cd $(BACKEND)/$$dir && $(UNBUF) go run . \
			-nacos-host=$(NACOS_HOST) -nacos-port=$(NACOS_PORT) \
			-nacos-namespace=$(NACOS_NAMESPACE) -nacos-group=$(NACOS_GROUP) \
		) >$(LOG_DIR)/$$name.log 2>&1 & \
		i=$$((i+1)); \
	done; \
	echo "  等待 2s 启动前端..."; sleep 2; \
	for w in $(FRONTENDS); do \
		name=$$(echo $$w | cut -d: -f1); \
		( cd $$name && { [ -d node_modules ] || pnpm install; } && pnpm test ) & \
	done; \
	wait

# 前端构建产物 + mock（不起后端）
preview:
	@$(MAKE) --no-print-directory stop
	@trap 'kill 0; exit 0' INT TERM; \
	echo "=== 前端 - preview (构建产物 + mock, Ctrl+C 停止) ==="; \
	for w in $(FRONTENDS); do \
		name=$$(echo $$w | cut -d: -f1); \
		( cd $$name && { [ -d node_modules ] || pnpm install; } && pnpm build:preview && pnpm preview ) & \
	done; \
	wait

# 停止前后端运行端口
stop: stop-forward
	@for port in $(PORTS) $(FRONTEND_PORTS); do \
		lsof -ti :$$port 2>/dev/null | xargs kill -9 2>/dev/null || true; \
	done
	@echo "端口已释放：$(PORTS) $(FRONTEND_PORTS)"

# 把集群里的 Nacos（8848 登录 / 9848 gRPC）与 Hermes（18642）转发到本机
forward:
	@mkdir -p /tmp
	@if ! nc -z 127.0.0.1 8848 >/dev/null 2>&1; then \
		echo "  → Nacos 8848/9848"; \
		( trap '' TERM INT; exec kubectl --kubeconfig=$(KUBECONFIG_FILE) -n blog port-forward svc/nacos 8848:8848 9848:9848 ) >/tmp/blog-forward-nacos.log 2>&1 & \
		echo $$! >/tmp/blog-forward-nacos.pid; \
	fi
	@if ! nc -z 127.0.0.1 18642 >/dev/null 2>&1; then \
		echo "  → Hermes 18642"; \
		( trap '' TERM INT; exec kubectl --kubeconfig=$(KUBECONFIG_FILE) -n blog port-forward svc/hermes 18642:8080 ) >/tmp/blog-forward-hermes.log 2>&1 & \
		echo $$! >/tmp/blog-forward-hermes.pid; \
	fi
	@sleep 1

stop-forward:
	@for f in /tmp/blog-forward-nacos.pid /tmp/blog-forward-hermes.pid; do \
		if [ -f "$$f" ]; then kill -9 $$(cat "$$f") 2>/dev/null || true; rm -f "$$f"; fi; \
	done

# ═══════════════════════════════════════════════════════════
#  单独运行
# ═══════════════════════════════════════════════════════════

# 后端 go run（本地 yaml 配置）
backend:
	@$(MAKE) --no-print-directory stop
	@trap 'kill 0; exit 0' INT TERM; \
	rm -rf $(LOG_DIR); \
	mkdir -p $(LOG_DIR); \
	echo "=== 后端 - go run (本地 yaml, 日志→$(LOG_DIR)/, Ctrl+C 停止) ==="; \
	i=0; \
	for s in $(SERVICES); do \
		name=$$(echo $$s | cut -d: -f1); \
		dir=$$(echo $$s | cut -d: -f3); \
		conf=$$(echo $$s | cut -d: -f4); \
		if [ ! -f "$(BACKEND)/$$dir/$$conf" ]; then \
			echo "  缺少配置 $(BACKEND)/$$dir/$${conf}，可从同名 .example.yaml 复制"; \
			exit 1; \
		fi; \
		if [ $$i -gt 0 ]; then echo "  等待 2s 启动下一个服务..."; sleep 2; fi; \
		( cd $(BACKEND)/$$dir && $(UNBUF) go run . -f $$conf ) >$(LOG_DIR)/$$name.log 2>&1 & \
		i=$$((i+1)); \
	done; \
	wait

# 前端 pnpm dev (mock 模式)
frontend:
	@trap 'kill 0; exit 0' INT TERM; \
	echo "=== 前端 - dev (mock 模式, Ctrl+C 停止) ==="; \
	for w in $(FRONTENDS); do \
		name=$$(echo $$w | cut -d: -f1); \
		( cd $$name && { [ -d node_modules ] || pnpm install; } && pnpm dev ) & \
	done; \
	wait

# ═══════════════════════════════════════════════════════════
#  部署（本地 Docker）
# ═══════════════════════════════════════════════════════════

# 构建五个应用镜像（本地标签，不推送）
image-build:
	@bash deploy/docker/up.sh build

# 部署到本地 Docker：依赖与应用容器一起起来
image-deploy:
	@bash deploy/docker/up.sh

# ═══════════════════════════════════════════════════════════
#  清理
# ═══════════════════════════════════════════════════════════

clean:
	rm -rf $(LOG_DIR)
	@echo "已清理 $(LOG_DIR)/"
