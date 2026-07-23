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

- `TrollShot.app` — 用户界面，只负责"启动/停止" daemon
- `trollshotd` — 后台守护进程，真正跑 HTTP 截图服务

安装 `.deb` 包时，`layout/DEBIAN/postinst` 会以 root 权限执行，将 `trollshotd` 复制到 `/usr/bin/`，将 `com.hogan.trollshot.plist` 复制到 `/Library/LaunchDaemons/`，并执行 `launchctl load -w`。

`plist` 中设置了 `RunAtLoad` 和 `KeepAlive`，因此设备重启后会自动启动截图服务。只有点击"停止服务"，或卸载 `.deb` 包时，服务才会停止。

## 安装方式

**推荐通过 TrollStore 直接安装 `.deb` 包**（TrollStore 2.0+ 支持）。安装过程中会自动完成 daemon 和 launchd plist 的系统级部署，无需越狱即可实现开机自启。

不再推荐安装 IPA，因为 IPA 无法触发 postinst 脚本，导致不能写入 `/Library/LaunchDaemons/`，也就无法实现开机自启。

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

输出为 `packages/` 目录下的 `.deb`。

## 使用方法

1. 通过 TrollStore 安装 `.deb` 包。
2. 在设备上打开 TrollShot 应用。
3. 点击"启动服务"。
4. 等待界面显示"服务状态：运行中"和本机 IP。
5. 在同一局域网内的另一台设备上访问 `http://<设备IP>:8080/screenshot`。

## 停止与卸载

- 点击"停止服务"：立即 unload launchd plist，当前运行停止；重启后不再自启。
- 卸载 `.deb` 包：`layout/DEBIAN/prerm` 会自动清理 `/usr/bin/trollshotd`、`/Library/LaunchDaemons/com.hogan.trollshot.plist` 和 `/var/mobile/trollshot/`。

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
- 必须通过 `.deb` 安装才能实现开机自启；IPA 不支持此功能。

## 文件说明

- `ScreenCapturer.{h,mm}` — 通过私有 API 截屏
- `HTTPScreenshotServer.{h,mm}` — 迷你 HTTP 服务器
- `trollshotd.mm` — 后台 daemon 入口
- `TrollShotManager.{h,m}` — 启动/停止 daemon 的管理逻辑
- `AppDelegate.{h,m}` / `main.m` — iOS 应用启动入口
- `include-spi/` — 私有框架的最小声明
- `layout/Library/LaunchDaemons/com.hogan.trollshot.plist` — launchd 配置
- `layout/DEBIAN/postinst` — 安装 .deb 时以 root 部署 daemon 和 plist
- `layout/DEBIAN/prerm` — 卸载 .deb 时清理系统目录
- `TrollShot.entitlements` — 必需的 entitlement
- `Makefile` — Theos 构建配置
