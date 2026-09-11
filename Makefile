.DEFAULT_GOAL := help

# ═══════════════════════════════════════════════════════════
#  帮助
# ═══════════════════════════════════════════════════════════

.PHONY: help
help:
	@echo "可用命令："
	@echo ""
	@echo "  准备"
	@echo "    make init            首次初始化全部子模块"
	@echo "    make fetch           更新主仓库 + 全部子模块到最新"
	@echo "    make install         后端 go mod tidy + 前端 pnpm install"
	@echo ""
	@echo "  开发"
	@echo "    make dev             后端 go run + 前端 pnpm dev"
	@echo "    make test            编译后端到 bin/ 后运行 + 前端 pnpm dev"
	@echo "    make stop            停止前后端运行端口"
	@echo ""
	@echo "  单独运行"
	@echo "    make backend         后端 go run（本地 yaml 配置）"
	@echo "    make frontend        前端 pnpm dev"
	@echo ""
	@echo "  编译"
	@echo "    make build           编译全部后端到 bin/"
	@echo ""
	@echo "  CGO"
	@echo "    make cgo-build       编译全部海康 wrapper DLL"
	@echo "    make cgo-clean       清理全部构建产物"
