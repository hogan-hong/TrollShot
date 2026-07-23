# TrollShot

一个 TrollStore 可安装的极简 iOS 应用，只提供一个 HTTP 接口：

```
GET http://<设备IP>:8080/screenshot
```

访问后返回当前设备屏幕的 JPEG 截图。

TrollShot 源于 [TrollVNC](https://github.com/OwnGoalStudio/TrollVNC)，因此使用 GNU General Public License v2 许可证。

## 工作原理

1. 通过私有 API `CARenderServerRenderDisplay` 将屏幕内容渲染到 `IOSurface`。
2. 通过 `IOSurfaceAccelerator` 转换 surface 格式。
3. 将 surface 零拷贝包装成 `CVPixelBuffer`，再用 `CoreImage` / `ImageIO` 编码为 JPEG。
4. 通过后台 daemon `trollshotd` 运行的迷你 HTTP 服务器返回 JPEG。

没有 VNC 协议，没有 HID 事件注入，没有远程控制。

## 架构说明

TrollShot 采用类似 TrollVNC 的后台 daemon 架构：

- `TrollShot.app` — 用户界面，负责"启动/停止" daemon
- `trollshotd` — 后台守护进程，真正跑 HTTP 截图服务

构建时，`Makefile` 的 `before-package` 钩子会把 `trollshotd` 和 `com.hogan.trollshot.plist` 一起复制进 `TrollShot.app` bundle。GitHub Actions 再把 `.app` 打包成标准 IPA（`Payload/TrollShot.app`）。

安装 IPA 后，点击"启动服务"时，`TrollShotManager` 会把 `trollshotd` 从 app bundle 复制到用户可写目录 `/var/mobile/trollshot/`，然后直接 `posix_spawn` 启动 daemon。

`layout/Library/LaunchDaemons/com.hogan.trollshot.plist` 仍保留在仓库中，供需要开机自启的高级用户手动放置到 `/Library/LaunchDaemons/`（需要 root 权限）。

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

1. 通过 TrollStore 安装 `TrollShot.ipa`。
2. 在设备上打开 TrollShot 应用。
3. 点击"启动服务"。
4. 等待界面显示"服务状态：运行中"。
5. 在同一局域网内的另一台设备上访问 `http://<设备IP>:8080/screenshot`。

## 停止与卸载

- 点击"停止服务"：向 `trollshotd` 进程发送 SIGTERM，1 秒内未退出则发送 SIGKILL。
- 卸载 IPA：系统会自动删除 app bundle，已复制到 `/var/mobile/trollshot/` 的 daemon 和日志不会自动清理，可手动删除。

## 日志

daemon 运行日志位于：

```
/var/mobile/trollshot/trollshotd.log
```

可以通过 SSH 或文件管理工具导出该日志进行排查。

## 局限

- 需要 TrollStore 或越狱环境；普通签名设备无法运行。
- daemon 需要 root 权限才能调用私有截屏 API。
- 需要私有 entitlement。
- 不手动放置 launchd plist 时，设备重启后服务不会自动启动，需要重新打开应用点击"启动服务"。

## 文件说明

- `ScreenCapturer.{h,mm}` — 通过私有 API 截屏
- `HTTPScreenshotServer.{h,mm}` — 迷你 HTTP 服务器
- `trollshotd.mm` — 后台 daemon 入口
- `TrollShotManager.{h,m}` — 启动/停止 daemon 的管理逻辑
- `AppDelegate.{h,m}` / `main.m` — iOS 应用启动入口
- `include-spi/` — 私有框架的最小声明
- `layout/Library/LaunchDaemons/com.hogan.trollshot.plist` — 可选的 launchd 配置
- `TrollShot.entitlements` — 必需的 entitlement
- `Makefile` — Theos 构建配置
