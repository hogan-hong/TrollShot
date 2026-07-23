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

TrollShot 采用和 TrollVNC 类似的后台 daemon 架构：

- `TrollShot.app` — 用户界面，只负责"安装/启动/停止" daemon
- `trollshotd` — 后台守护进程，真正跑 HTTP 截图服务
- `com.hogan.trollshot.plist` — launchd 配置，开机自启动、崩溃自动重启

点击"启动服务"后，`trollshotd` 会被安装到 `/usr/local/bin/` 并以 `root`权限运行。即使 `TrollShot.app` 被杀掉或切到后台，HTTP 服务依然可用。

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

## 重新打包为 TrollStore 可用的 IPA

```sh
mkdir -p extracted Payload
dpkg-deb -R packages/com.example.trollshot_*.deb extracted
APP_PATH=$(find extracted -name "*.app" -type d | head -n1)
cp -R "$APP_PATH" Payload/
zip -r TrollShot.ipa Payload
```

然后用 TrollStore 安装 `TrollShot.ipa`。

## 使用方法

1. 在设备上打开 TrollShot 应用。
2. 点击"启动服务"。
3. 等待界面显示"服务状态：运行中"。
4. 在同一局域网内的另一台设备上访问 `http://<设备IP>:8080/screenshot`。

## 日志

daemon 运行日志位于：

```
/var/log/trollshot/trollshotd.log
```

可以通过 SSH 或文件管理工具导出该日志进行排查。

## 局限

- 需要 TrollStore 或越狱环境；普通签名设备无法运行。
- daemon 需要 root 权限才能调用私有截屏 API。
- 需要私有 entitlement。

## 文件说明

- `ScreenCapturer.{h,mm}` — 通过私有 API 截屏
- `HTTPScreenshotServer.{h,mm}` — 迷你 HTTP 服务器
- `trollshotd.mm` — 后台 daemon 入口
- `TrollShotManager.{h,m}` — 安装/启动/停止 daemon 的管理逻辑
- `AppDelegate.{h,m}` / `main.m` — iOS 应用启动入口
- `include-spi/` — 私有框架的最小声明
- `layout/Library/LaunchDaemons/com.hogan.trollshot.plist` — launchd 配置
- `TrollShot.entitlements` — 必需的 entitlement
- `Makefile` — Theos 构建配置
