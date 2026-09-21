.DEFAULT_GOAL := help

# ── 路径 ─────────────────────────────────────────────────

BACKEND := blog-cloud
LOG_DIR := logs

# ── 服务清单 ─────────────────────────────────────────────
# 后端：<服务名>:<端口>:<目录>:<配置文件（相对服务目录）>
# 目录与配置相对 blog-cloud/；启动顺序按列表排列，rpc 先于 api
SERVICES := blog-rpc:9120:rpc/blog:etc/blog-rpc.yaml \
            admin-api:9421:api/admin:etc/admin-api.yaml \
            blog-api:9420:api/app:etc/app-api.yaml

# stop 的端口由清单派生，避免漏项
PORTS := $(foreach s,$(SERVICES),$(word 2,$(subst :, ,$(s))))

# 前端：<目录>:<端口>
FRONTENDS := blog-admin:9521 blog-app:9520
FRONTEND_PORTS := $(foreach w,$(FRONTENDS),$(word 2,$(subst :, ,$(w))))

# go.work 下的全部模块，install 时逐个 tidy
WORK_MODULES := blog-cloud goctlx stompws vkit

# Darwin 无 stdbuf，行缓冲置空
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
	UNBUF :=
else
	UNBUF := stdbuf -oL
endif

.PHONY: help init fetch install dev test preview stop backend frontend image-build image-deploy clean

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
	@echo "    make test            后端 go run (Nacos 配置) + 前端 pnpm test"
	@echo "    make preview         前端 pnpm preview (构建产物 + mock)"
	@echo "    make stop            停止前后端运行端口"
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
	@trap 'kill 0; exit 0' INT TERM; \
	rm -rf $(LOG_DIR); \
	mkdir -p $(LOG_DIR); \
	echo "=== 全栈 - test (后端 Nacos 配置 + 前端 pnpm test, 后端日志→$(LOG_DIR)/, Ctrl+C 停止) ==="; \
	i=0; \
	for s in $(SERVICES); do \
		name=$$(echo $$s | cut -d: -f1); \
		dir=$$(echo $$s | cut -d: -f3); \
		if [ $$i -gt 0 ]; then echo "  等待 2s 启动下一个服务..."; sleep 2; fi; \
		( cd $(BACKEND)/$$dir && $(UNBUF) go run . ) >$(LOG_DIR)/$$name.log 2>&1 & \
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
stop:
	@for port in $(PORTS) $(FRONTEND_PORTS); do \
		lsof -ti :$$port 2>/dev/null | xargs kill -9 2>/dev/null || true; \
	done
	@echo "端口已释放：$(PORTS) $(FRONTEND_PORTS)"

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
