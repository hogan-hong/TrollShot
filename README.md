# TrollShot

一个 TrollStore 可安装的极简 iOS 应用，只提供一个 HTTP 接口：

```
GET http://<设备IP>:8080/screenshot
```

访问后返回当前设备屏幕的 JPEG 截图。

TrollShot 源于 [TrollVNC](https://github.com/OwnGoalStudio/TrollVNC)，因此使用 GNU General Public License v2 许可证。

## 工作原理

TrollShot 根据运行环境自动选择截图方式：

### 越狱模式（daemon 以 root 运行）

1. 通过 `IOMobileFramebufferGetMainDisplay` + `IOMobileFramebufferGetLayerDefaultSurface` 直接读取系统 framebuffer 的 IOSurface。
2. 使用 `IOSurfaceGetSeed` 进行脏帧检测：画面未变化时直接返回缓存结果，跳过重复编码。
3. 通过 `IOSurfaceAccelerator` 拷贝帧数据到目标 surface。
4. 将 surface 零拷贝包装成 `CVPixelBuffer`，再用复用的 `CIContext` / `ImageIO` 编码为 JPEG。
5. HTTP 并发降为串行（1），避免 framebuffer 读取冲突。

此方案参考 [screendump](https://github.com/cosmosgenius/screendump) 的 fix14 实现，直接读取 framebuffer，完全绕过 mach IPC 链路，避免越狱注入（Substitute）对 `CARenderServerRenderDisplay` 的 hook 开销导致设备卡死。

### 非越狱模式（TrollStore，以 mobile 用户运行）

1. 通过私有 API `CARenderServerRenderDisplay` 将屏幕内容渲染到 `IOSurface`。
2. 通过 `IOSurfaceAccelerator` 转换 surface 格式。
3. 将 surface 零拷贝包装成 `CVPixelBuffer`，再用 `CoreImage` / `ImageIO` 编码为 JPEG。
4. HTTP 最大并发 4（原值）。

### 共通优化

- `CIContext` 和 `FBSOrientationObserver` 在初始化时创建一次并复用，不再每次截图重新分配。
- 越狱模式下启用帧缓存：`IOSurfaceGetSeed` 未变化时直接返回上次的 JPEG，减少重复编码开销。

没有 VNC 协议，没有 HID 事件注入，没有远程控制。

## 架构说明

TrollShot 采用类似 TrollVNC 的后台 daemon 架构：

- `TrollShot.app` — 用户界面，负责"启动/停止" daemon
- `trollshotd` — 后台守护进程，真正跑 HTTP 截图服务

构建时，`Makefile` 的 `before-package` 钩子会把 `trollshotd` 和 `com.hogan.trollshot.plist` 一起复制进 `TrollShot.app` bundle。GitHub Actions 再把 `.app` 打包成标准 IPA（`Payload/TrollShot.app`）。

安装 IPA 后，点击"启动服务"时，`TrollShotManager` 会把 `trollshotd` 从 app bundle 复制到用户可写目录 `/var/mobile/trollshot/`，然后直接 `posix_spawn` 启动 daemon。

`layout/Library/LaunchDaemons/com.hogan.trollshot.plist` 仍保留在仓库中，供需要开机自启的高级用户手动放置到 `/Library/LaunchDaemons/`（需要 root 权限）。

### 越狱环境

在越狱设备上通过 `.deb` 安装时，launchd plist 会自动部署到 `/Library/LaunchDaemons/com.hogan.trollshot.plist`，daemon 以 root 身份运行且 `KeepAlive=true`（被杀后自动重启）。

App 会自动检测运行环境：
- **检测到系统级 plist（越狱）**：启动/停止通过 `launchctl bootstrap`/`bootout` 操作（兼容旧版 `load`/`unload`），不直接 `posix_spawn`
- **未检测到（TrollStore）**：手动复制 daemon 到 `/var/mobile/trollshot/` 并 `posix_spawn` 启动

> 注意：如果 App 以 mobile 用户运行且 `launchctl` 权限不足，停止服务可能失败。此时会弹出提示，请通过 SSH 以 root 执行：
> ```
> launchctl unload /Library/LaunchDaemons/com.hogan.trollshot.plist
> ```

## 安装方式

**通过 TrollStore 直接安装 IPA**。

构建产物为 `TrollShot.ipa`，下载后用 TrollStore 安装即可。

## 构建要求

- macOS 已安装 Xcode Command Line Tools
- 已安装 [Theos](https://theos.dev/) 并设置好 `$THEOS`
- iOS SDK（如 iPhoneOS16.5）
- `ldid` 用于 ad-hoc 签名

## 本地构建

```sh
cd TrollShot
make clean package
```

发布版构建：

```sh
make clean package FINALPACKAGE=1
```

本地输出为 `packages/` 目录下的 `.deb`。GitHub Actions 会自动从 staging 提取 `.app` 并打包成 IPA。

## 使用方法

### 基本使用

1. 通过 TrollStore 安装 `TrollShot.ipa`。
2. 在设备上打开 TrollShot 应用。
3. 点击"启动服务"。
4. 等待界面显示"服务状态：运行中"。
5. 在同一局域网内的另一台设备上访问 `http://<设备IP>:8080/screenshot`。

### API 接口

```
GET http://<设备IP>:8080/screenshot
```

支持以下查询参数，可单独使用或组合使用：

| 参数 | 格式 | 说明 |
|------|------|------|
| `rotate` | `rotate=1` | 强制顺时针旋转 90 度。不加此参数时自动检测设备方向（横屏自动旋转，竖屏不旋转）。 |
| `crop` | `crop=x1,y1,x2,y2` | 裁剪指定区域。x1,y1 为左上角坐标，x2,y2 为右下角坐标。坐标基于旋转后的最终图像。不加此参数时返回全屏截图。 |

#### 示例

```
# 全屏截图（自动检测横竖屏）
GET /screenshot

# 强制旋转
GET /screenshot?rotate=1

# 裁剪指定区域（左上角 0,0 到右下角 667,750）
GET /screenshot?crop=0,0,667,750

# 旋转 + 裁剪组合使用
GET /screenshot?rotate=1&crop=0,0,667,750

# 健康检查（返回 pong）
GET /ping

# 停止 daemon（越狱环境，daemon 自行卸载 launchd 并退出）
GET /shutdown
```

#### 自动横竖屏检测

TrollShot 通过 `FBSOrientationObserver`（FrontBoardServices 私有框架）自动检测设备方向，参考 TrollVNC 的方案。横屏（LandscapeLeft / LandscapeRight）时自动顺时针旋转 90 度输出，竖屏（Portrait）时保持原始方向。

iPhone 物理截屏像素固定为 750x1334（竖屏），横屏游戏时自动旋转输出为 1334x750。

#### 诊断响应头

每次截图响应包含以下 HTTP 头，可用于调试：

| 响应头 | 说明 |
|--------|------|
| `X-Orig-Size` | 原始截图尺寸（旋转前），如 `750x1334` |
| `X-Final-Size` | 最终输出尺寸（旋转/裁剪后），如 `1334x750` |
| `X-Rotated` | 是否进行了旋转，`YES` 或 `NO` |
| `X-Crop` | 裁剪区域坐标，如 `0,0,667,750`；未裁剪时为 `none` |

## 调试模式

App 界面提供「调试模式」开关按钮：

- **关闭调试模式（默认）**：daemon 的 stdout/stderr 重定向到 /dev/null 丢弃，TSLogger 不写文件，日志文件不会增长。
- **开启调试模式**：daemon 带 `--debug` 参数启动，stdout/stderr 重定向到 `/var/mobile/trollshot/trollshotd.log`，TSLogger 写入 `/var/mobile/Documents/TrollShot.log`。开启时可选择清空旧日志。

调试模式状态持久化在 `/var/mobile/trollshot/debug_mode` 标志文件中（内容为 `1` 或 `0`）。切换调试模式时，如果服务正在运行，会自动重启 daemon 使设置立即生效。

## 日志

调试模式开启时，会产生两个日志文件：

| 日志文件 | 路径 | 说明 |
|----------|------|------|
| daemon 标准输出 | `/var/mobile/trollshot/trollshotd.log` | daemon 进程的 stdout/stderr 重定向输出（posix_spawn dup2） |
| TSLogger 运行日志 | `/var/mobile/Documents/TrollShot.log` | ScreenCapturer 中 TSLog 宏写入的结构化日志（带时间戳） |

两个日志文件都只在调试模式开启时才会写入。关闭调试模式后不会产生新的日志内容。

可以通过 SSH 或文件管理工具导出日志进行排查。

## 停止与卸载

- **TrollStore 环境**：点击"停止服务"向 `trollshotd` 进程发送 SIGTERM，1 秒内未退出则发送 SIGKILL，最后 `killall -9` 兜底。
- **越狱环境**：点击"停止服务"先执行 `launchctl bootout`/`unload` 卸载系统级 plist，再 kill 进程。如果权限不足会弹出错误提示，需通过 SSH 以 root 手动执行 `launchctl unload`。
- 卸载 IPA/.deb：系统会自动删除 app bundle，已复制到 `/var/mobile/trollshot/` 的 daemon、日志和 `/var/mobile/Documents/TrollShot.log` 不会自动清理，可手动删除。越狱环境还需手动删除 `/Library/LaunchDaemons/com.hogan.trollshot.plist` 并执行 `launchctl unload`。

## 局限

- 需要 TrollStore 或越狱环境；普通签名设备无法运行。
- daemon 需要 root 权限才能调用私有截屏 API。
- 需要私有 entitlement。
- 不手动放置 launchd plist 时，设备重启后服务不会自动启动，需要重新打开应用点击"启动服务"。

## 文件说明

### 核心源码

- `ScreenCapturer.{h,mm}` - 通过私有 API 截屏，越狱模式用 IOMobileFramebuffer 直读 framebuffer，非越狱模式用 CARenderServerRenderDisplay；包含脏帧检测、帧缓存、旋转（FBSOrientationObserver）和裁剪逻辑
- `HTTPScreenshotServer.{h,mm}` - 迷你 HTTP 服务器，解析 `rotate` / `crop` 查询参数
- `trollshotd.mm` - 后台 daemon 入口，解析 `--debug` 参数
- `TrollShotManager.{h,m}` - 启动/停止 daemon 的管理逻辑，调试模式标志读写，stdout/stderr 重定向控制
- `TSLogger.{h,m}` - 日志管理器，懒加载写入 `/var/mobile/Documents/TrollShot.log`，受 `debugEnabled` 控制
- `AppDelegate.{h,m}` / `main.m` - iOS 应用启动入口，含调试模式开关按钮

### 私有框架声明

- `include-spi/FBSOrientationObserver.h` - FrontBoardServices 方向观察器（来自 TrollVNC）
- `include-spi/IOMobileFramebufferSPI.h` - IOMobileFramebuffer 私有接口声明（越狱模式 framebuffer 直读，参考 screendump fix14）
- `include-spi/IOKitSPI.h` - IOKit 私有接口声明
- `include-spi/IOSurfaceSPI.h` - IOSurface 私有接口声明（含 IOSurfaceGetSeed 脏帧检测）
- `include-spi/UIScreen+Private.h` - UIScreen 私有方法声明

### 构建与配置

- `Makefile` - Theos 构建配置（链接 FrontBoardServices 私有框架）
- `control` - Theos 包控制文件（包名、版本、依赖）
- `TrollShot.entitlements` - 必需的私有 entitlement（`com.apple.private.security.no-container` 等）
- `Info.plist` - 应用配置
- `layout/Library/LaunchDaemons/com.hogan.trollshot.plist` - 可选的 launchd 配置（开机自启）
- `Resources/` - 应用图标资源
