# 前端约定

## 技术栈

| 技术 | 说明 |
|------|------|
| Vue 3 Composition API | `<script setup lang="ts">`，禁止 Options API |
| TypeScript | 严格模式 |
| Element Plus | UI 组件库 |
| Pinia | 状态管理 |
| Vue Router | 路由管理 |
| Vue I18n | 国际化 |
| Axios | HTTP 请求 |
| STOMP (stompjs) | WebSocket 实时通信 |
| Tauri | 桌面应用打包 |
| Vite | 构建工具 |
| pnpm | 包管理器 |
| Prettier | 代码格式化 |
| ESLint | 代码检查 |

## 项目结构

```
src/
├── api/            # API 接口定义，按模块分文件
├── views/          # 页面组件，按功能模块分目录
├── components/     # 公共组件
├── composables/    # 组合函数
├── stores/         # Pinia store
├── router/         # 路由配置
├── utils/          # 工具函数（request.ts、storage.ts 等）
├── types/          # TypeScript 类型定义
├── config/         # 前端配置
├── locales/        # 国际化文件
├── styles/         # 全局样式
├── App.vue         # 根组件
└── main.ts         # 入口
```

## 请求与响应

### 统一响应结构

```typescript
interface ApiResponse<T> {
  code: string;
  message: string;
  data: T;
  trace_id: string;
}
```

- `code` 为业务错误标识，客户端**只判断 `code`，不判断 `message` 文案**；取值见 [`docs/design/07-BLOG-错误码与中间件.md`](../../docs/design/07-BLOG-错误码与中间件.md) §1.4，与 `blog-*/src/enums/api.ts` 的 `ApiCodeEnum` 一一对应
- 分发**不依赖 HTTP 状态码**：HTTP 2xx 与非 2xx 的响应体都是信封，两个通道走同一条分发路径（见 §四）

### axios 拦截器

- 请求拦截：添加认证 token
- 响应拦截：统一错误处理（401、403、404、429、网络错误）
- 视图层不在 catch 块中重复 toast（拦截器已统一处理）

## 组件规范

- 使用 `<script setup lang="ts">` 语法
- Props 使用 `defineProps<T>()` 类型推导
- 页面组件按功能模块在 `src/views/` 下分目录组织
- 公共组件放 `src/components/`

## API 定义规范

- 按模块分文件：`src/api/<module>.ts`
- 方法命名清晰表达动作：`getXxx`、`createXxx`、`updateXxx`、`deleteXxx`

## Tauri 桌面应用

- 使用 `@tauri-apps/api` 调用原生能力（文件系统、Shell 等）
- 开发时通过 `pnpm tauri dev` 启动桌面应用
- 前端构建后通过 Tauri 打包为可执行文件

## WebSocket 实时通信

- 使用 STOMP 协议通过 `@stomp/stompjs` 连接
- 用于实时推送检测结果、设备状态等

## 开发命令

```bash
pnpm dev           # 开发模式
pnpm test          # 测试模式
pnpm build         # 生产构建
pnpm type-check    # TypeScript 类型检查
pnpm lint          # ESLint 检查
pnpm format        # Prettier 格式化
```