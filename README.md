# TrollShot

一个极简的 TrollStore 安装应用，只提供一个 HTTP 接口：

```
GET http://<设备IP>:8080/screenshot
```

访问后返回当前设备屏幕的 JPEG 截图。

TrollShot 源于 [TrollVNC](https://github.com/OwnGoalStudio/TrollVNC)，因此使用 GNU General Public License v2 许可证。

## 工作原理

1. 通过私有 API `CARenderServerRenderDisplay` 将屏幕内容渲染到 `IOSurface`。
2. 通过 `IOSurfaceAccelerator` 转换 surface 格式。
3. 将 surface 零拷贝包装成 `CVPixelBuffer`，再用 `CoreImage` / `ImageIO` 编码为 JPEG。
4. 通过应用内的迷你 HTTP 服务器返回 JPEG。

没有 VNC 协议，没有 HID 事件注入，没有远程控制。

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

输出为 `packages/` 目录下的 `.deb`。可以从中提取 `.app` 并重新打包成 `.ipa`，或通过越狱工具安装。

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
2. 记住黑屏上显示的 URL。
3. 在同一局域网内的另一台设备上访问 `http://<设备IP>:8080/screenshot`。

## 局限

- 应用必须保持前台（或允许后台运行），HTTP 服务器才能持续响应。iOS 会在短时间后挂起后台应用。
- 如需持久后台服务，需要像 TrollVNC 那样把截图服务拆到一个 root daemon 中（`trollvncserver` + `trollvncmanager`）。
- 需要私有 entitlement；普通非越狱/非 TrollStore 设备无法运行。

## 文件说明

- `ScreenCapturer.{h,mm}` — 通过私有 API 截屏
- `HTTPScreenshotServer.{h,mm}` — 迷你 HTTP 服务器
- `AppDelegate.{h,m}` / `main.m` — iOS 应用启动入口
- `include-spi/` — 私有框架的最小声明
- `TrollShot.entitlements` — 必需的 entitlement
- `Makefile` — Theos 构建配置
