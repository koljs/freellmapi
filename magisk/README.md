# FreeLLMAPI Magisk Module

把 FreeLLMAPI 打包成一个可刷入的 Magisk 模块，开机自启在 Android 手机上跑一个 OpenAI 兼容的 LLM 代理。无需 Termux，无需 root 命令行操作——所有依赖（Node.js 运行时、glibc 库、better-sqlite3 原生模块、React 仪表盘）都打包进模块 zip。

## 工作原理

Android 用的是 Bionic libc，而官方 Node.js linux-arm64 二进制是 glibc 链接的，不能直接跑。本模块的方案（参考 [koljs/aliyun-model-proxy](https://github.com/koljs/aliyun-model-proxy)）：

1. **捆绑 Node.js linux-arm64 二进制**（glibc 编译）
2. **从 Ubuntu arm64 rootfs 提取 glibc 运行时库**（`ld-linux-aarch64.so.1`、`libc.so.6`、`libstdc++.so.6` 等）
3. **用 glibc 动态链接器启动 Node**：`ld-linux-aarch64.so.1 --library-path ./lib node dist/index.js`，让 Node 进程树用捆绑的 glibc 而非系统的 Bionic
4. **better-sqlite3 原生模块**在 arm64 Ubuntu 容器里从源码编译，同样是 glibc 链接，与上面的运行时匹配
5. **服务端代码**用 esbuild 打包成单文件，`better-sqlite3` 作为 external 通过 `NODE_PATH` 在运行时加载

## 系统要求

- **已 root 且装了 Magisk** 的 Android 手机
- **arm64-v8a 架构**（2020 年后的手机基本都是；32 位 ARM 不支持）
- **Android 10+**（API 29+，Node.js 20 的内核要求）
- 至少 **150 MB 空闲存储**（模块本身约 80 MB，运行时数据另算）

## 构建

构建需要在 **x86_64 Linux**（或 macOS/WSL2）上进行，需要 Docker 用于跨架构编译 better-sqlite3。

### 前置依赖

- Node.js 20+
- npm
- Docker（带 qemu-user-static binfmt 支持，用于 arm64 模拟）
- curl、tar、zip

### 一键构建

```bash
npm run build:magisk
```

这会执行 `scripts/build-magisk.sh`，流程：

1. `esbuild` 打包服务端到 `build/magisk/files/dist/index.js`（`better-sqlite3` external）
2. `vite build` 构建仪表盘到 `build/magisk/files/client/`
3. 下载 Node.js v22.16.0 linux-arm64 二进制
4. 下载 Ubuntu 22.04 arm64 rootfs，提取 glibc 库
5. 在 arm64 Ubuntu 容器里 `npm install --build-from-source better-sqlite3`，提取编译产物
6. 组装模块目录，打包成 `freellmapi-magisk-v<version>.zip`

### Docker 跨架构编译提示

如果 Docker 没启用 arm64 模拟（`docker run --platform linux/arm64` 报错），执行一次：

```bash
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
```

Docker Desktop（macOS/Windows）默认已启用，无需此步。

## 安装

```bash
adb push freellmapi-magisk-v*.zip /sdcard/Download/
```

然后打开 **Magisk Manager** → **模块** → **从存储安装** → 选择 zip 文件 → 重启。

安装时 `customize.sh` 会：
- 校验架构（仅 arm64）
- 校验 Android 版本（API 29+）
- 在 `/data/local/freellmapi/.env` 生成 `ENCRYPTION_KEY`（首次安装）
- 创建数据目录 `/data/local/freellmapi/`

## 使用

重启后服务自动启动，监听 `0.0.0.0:3001`。

- **仪表盘**：手机浏览器打开 `http://127.0.0.1:3001`
- **代理端点**：`http://127.0.0.1:3001/v1`（局域网内其他设备用 `http://<手机IP>:3001/v1`）
- **首次配置**：在仪表盘注册管理员账号，添加上游 provider 的 API key，排序 fallback chain，从 Keys 页面拿 unified key

把任何 OpenAI 兼容客户端（ChatBox、OpenCat、Cursor 等）的 `base_url` 指向 `http://127.0.0.1:3001/v1`，`api_key` 填 unified key 即可。

## 文件布局

```
/data/adb/modules/freellmapi/          # 模块目录（Magisk 管理）
├── module.prop
├── customize.sh
├── service.sh                         # 开机自启入口
├── post-fs-data.sh
├── uninstall.sh
└── files/                             # 只读资源
    ├── node                           # Node.js linux-arm64 二进制
    ├── lib/                           # glibc 运行时库
    │   ├── ld-linux-aarch64.so.1
    │   ├── libc.so.6
    │   ├── libstdc++.so.6
    │   └── ...
    ├── dist/index.js                  # esbuild 打包的服务端
    ├── client/                        # 构建好的 React 仪表盘
    └── native/better-sqlite3/         # 编译好的原生模块

/data/local/freellmapi/                # 持久化数据（升级模块不丢）
├── .env                               # ENCRYPTION_KEY + 配置
├── data/freeapi.db                    # SQLite 数据库
├── node                               # 从模块目录复制的可执行副本
├── lib/                               # 从模块目录复制的库副本
├── native/better-sqlite3/             # 从模块目录复制的原生模块副本
├── service.log                        # 运行日志
└── freellmapi.pid                     # supervisor PID
```

**为什么有两份 node/lib/native？** 模块目录 `/data/adb/modules/` 在某些内核上挂载为 `noexec`，直接跑二进制会 `Permission denied`。`service.sh` 在首次启动时把可执行文件复制到 `/data/local/freellmapi/`（始终可执行），从那里运行。

## 运维

### 查看日志

```bash
adb shell cat /data/local/freellmapi/service.log
# 或实时跟踪
adb shell tail -f /data/local/freellmapi/service.log
```

### 手动重启服务

```bash
adb shell su -c 'kill $(cat /data/local/freellmapi/freellmapi.pid)'
# supervisor 会在 3 秒后自动拉起
```

### 停止服务

```bash
adb shell su -c 'kill $(cat /data/local/freellmapi/freellmapi.pid); pkill -f freellmapi/dist/index.mjs'
```

### 修改配置

编辑 `/data/local/freellmapi/.env`，然后重启服务。常用项：

```env
ENCRYPTION_KEY=<已生成，勿改>
PORT=3001
HOST=0.0.0.0
NODE_ENV=production
FREELLMAPI_CONTEXT_HANDOFF=on_model_switch   # 可选
REQUEST_ANALYTICS_RETENTION_DAYS=90
REQUEST_ANALYTICS_MAX_ROWS=100000
```

### 升级

重新构建 zip，在 Magisk Manager 里覆盖安装。`/data/local/freellmapi/` 下的 `.env`、数据库、日志都会保留——`customize.sh` 检测到已有 `.env` 就跳过生成 `ENCRYPTION_KEY`。

### 卸载

在 Magisk Manager 里移除模块，重启。`uninstall.sh` 会杀掉服务、清理可执行副本，但**保留** `/data/local/freellmapi/` 下的 `.env` 和数据库，方便日后重装。彻底清理：

```bash
adb shell su -c 'rm -rf /data/local/freellmapi'
```

## 已知限制

- **Doze / 省电策略**：屏幕熄灭后系统可能冻结后台进程。Magisk root 启动的 `service.sh` 同样受影响。如果发现服务间歇性无响应，可尝试：
  - 关闭电池优化对 Magisk Manager 的限制
  - 用 `dumpsys deviceidle whitelist +com.android.shell` 放行 shell 域
  - 保持屏幕常亮或接充电器
- **SELinux**：Magisk 上下文通常 OK，但跨域访问 `/data/data/` 需要额外 `magiskpolicy` 放行。本模块不访问其他 app 私有目录，无需额外配置。
- **仅 arm64**：32 位 ARM (armeabi-v7a) 不支持，Termux 已停发新版 Node。
- **首次启动慢**：`service.sh` 等待 `sys.boot_completed` + 10 秒网络就绪，加上 Node 冷启动，重启后约 15-20 秒服务才可用。
- **内存占用**：约 40-60 MB RSS，对现代手机无压力。

## 故障排查

| 现象 | 排查 |
|---|---|
| 重启后 `http://127.0.0.1:3001` 打不开 | `adb shell cat /data/local/freellmapi/service.log` 看报错 |
| `FATAL: node binary missing` | 模块 zip 构建不完整，重新 `npm run build:magisk` |
| `FATAL: glibc linker missing` | 同上，rootfs 下载失败 |
| `FATAL: better-sqlite3 native module missing` | Docker arm64 编译失败，检查 qemu binfmt |
| `ENCRYPTION_KEY` 相关报错 | `/data/local/freellmapi/.env` 缺失或为空，删除后重装模块重新生成 |
| 端口 3001 被占用 | 改 `.env` 里的 `PORT`，重启服务 |
| 局域网其他设备访问不了 | 确认 `.env` 里 `HOST=0.0.0.0`，检查手机防火墙/热点设置 |

## 构建自定义版本

改 `scripts/build-magisk.sh` 顶部的变量：

- `NODE_VERSION` — 换 Node 版本（必须 ≥ 20）
- `UBUNTU_ROOTFS_URL` — 换 glibc 来源（如换 Debian rootfs）
- `BETTER_SQLITE3_VERSION` — 自动从 `server/package.json` 读取，一般不用动

改完重新 `npm run build:magisk` 即可。
