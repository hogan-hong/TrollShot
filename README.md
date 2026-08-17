# TrollShot

一个 TrollStore 可安装的极简 iOS 应用，只提供一个 HTTP 接口：

```
GET http://<设备IP>:6688/screenshot
```

访问后返回当前设备屏幕的 JPEG 截图。

TrollShot 源于 [TrollVNC](https://github.com/OwnGoalStudio/TrollVNC)，因此使用 GNU General Public License v2 许可证。

## 工作原理

TrollShot 按**安装包类型**固定截图路线（设备运行环境固定，越狱设备装 deb、非越狱设备装 ipa，见下方「安装方式」）：

### 越狱模式（daemon 以 root 运行）

1. 通过 `IOMobileFramebufferGetMainDisplay` + `IOMobileFramebufferGetLayerDefaultSurface` 直接读取系统 framebuffer 的 IOSurface。
2. 使用 `IOSurfaceGetSeed` 进行脏帧检测：画面未变化时直接返回缓存结果，跳过重复编码。
3. 通过 `IOSurfaceAccelerator` 拷贝帧数据到目标 surface。
4. 将 surface 零拷贝包装成 `CVPixelBuffer`，再用复用的 `CIContext` / `ImageIO` 编码为 JPEG。
5. HTTP 并发降为串行（1），避免 framebuffer 读取冲突。

此方案参考 [screendump](https://github.com/cosmosgenius/screendump) 的 fix14 实现，直接读取 framebuffer，完全绕过 mach IPC 链路，避免越狱注入（Substitute）对 `CARenderServerRenderDisplay` 的 hook 开销导致设备卡死。

**重要：越狱模式下需要设备开启 AirPlay 屏幕镜像。** framebuffer 直读绕过 SpringBoard，游戏防截屏保护会触发（画面变灰）。开启 AirPlay 屏幕镜像后，`UIScreen.isCaptured` 变为 `YES`，系统感知到屏幕正在被录制，游戏正常渲染彩色画面。AirPlay 接收端使用修改后的 UxPlay（`-vs 0` 丢弃视频流，不占服务器资源），设备端仅编码 16x16@1fps，开销极低。

截图时实时检查 `UIScreen.isCaptured` 状态，镜像未开启时返回 HTTP 503 错误。

### framebuffer 直读画面处理（与 screendump 完全对齐）

早期版本曾对 fb 直读画面做过 IOSurface 加锁防花屏和 CIColorMatrix 色彩补偿（逐通道常数减抬升），实测两轮均不理想（补偿后过深过饱和，且色偏随画面内容漂移、非常数）。

对照开源 screendump（alias20 一系，iOS13 VNC 取图方案，`IOMobileFramebufferGetMainDisplay` + `GetLayerDefaultSurface/CopyLayerDisplayedSurface` + `IOSurfaceAcceleratorTransferSurface`）逐行比对后确认：两者的取图调用链完全一致，色偏源自我们多做的后处理环节。

通过 RFB 协议同屏抓帧定量对比（screendump 5900 raw 帧 vs TrollShot API JPEG）：fb 层画面完全正常（screendump 与 TrollVNC/CARenderServer 残差 0.1，像素级一致），偏白全部来自我们独有的“缓冲→JPEG”段——三通道均匀 +33/255 加白、残差仅 2.4。据此彻底重写该段，与 screendump 推 VNC 字节完全同语义：

1. 去掉 IOSurface 加锁/解锁（AirPlay 镜像开启后 fb 更新节奏稳定，实测无花屏）；
2. 去掉 CIColorMatrix 色彩补偿；
3. 删除自建 surface 的 `kIOSurfaceColorSpace`（sRGB）标签——screendump 的目标 surface 无此标签，额外标签会让 blit/封装环节引入非预期色彩处理；
4. 废弃 `CVPixelBuffer` -> `CIImage` -> `CIContext createCGImage` 整条封装链（即使禁用 CIContext 色彩管理仍残留 +33 加白），改为直读 surface 字节（`IOSurfaceGetBaseAddress`）+ `CGDataProvider` + `CGImageCreate` 纯字节搬运，仅保留 ImageIO 的 JPEG 编码（对 8bit RGB 直通）。

**根因（format=raw 分段定位）**：transfer 后的 RGB 字节与 screendump 逐像素一致（残差 0.0），偏白全部发生在 `CGImageCreate` 之后--framebuffer surface 的 alpha 字节恒为 223（非 255），图像声明为 `kCGImageAlphaPremultipliedFirst` 时编码环节按 alpha 做 un-premultiply/白底合成，产生均匀 +32 加白。修复：声明 `kCGImageAlphaNoneSkipFirst`（alpha 存在但忽略，与 screendump 的 VNC 推流语义一致），RGB 字节原样直通。

### 非越狱模式（TrollStore，以 mobile 用户运行）

1. 通过私有 API `CARenderServerRenderDisplay` 将屏幕内容渲染到 `IOSurface`。
2. 通过 `IOSurfaceAccelerator` 转换 surface 格式。
3. 直读 surface 字节构建 `CGImage`，用 `ImageIO` 编码为 JPEG（与 fb 直读共用后段，见上节第 4 条）。
4. HTTP 最大并发 4（原值）。

此方案与 TrollVNC 截屏方式相同，`CARenderServerRenderDisplay` 走 SpringBoard 渲染管道，系统感知到截屏，游戏防截屏不会触发，无需 AirPlay 镜像。

### 共通优化

- `CIContext` 和 `FBSOrientationObserver` 在初始化时创建一次并复用，不再每次截图重新分配。
- 越狱模式下启用帧缓存：`IOSurfaceGetSeed` 未变化时直接返回上次的 JPEG，减少重复编码开销。

没有 VNC 协议，没有 HID 事件注入，没有远程控制。

## 架构说明

TrollShot 采用类似 TrollVNC 的后台 daemon 架构：

- `TrollShot.app` - 用户界面，负责"启动/停止" daemon
- `trollshotd` - 后台守护进程，真正跑 HTTP 截图服务

构建时，`Makefile` 的 `before-package` 钩子会把 `trollshotd` 和 `com.hogan.trollshot.plist` 一起复制进 `TrollShot.app` bundle。GitHub Actions 再把 `.app` 打包成标准 IPA（`Payload/TrollShot.app`）。

安装 IPA 后，点击"启动服务"时，`TrollShotManager` 会把 `trollshotd` 从 app bundle 复制到用户可写目录 `/var/mobile/trollshot/`，然后直接 `posix_spawn` 启动 daemon。

`layout-deb/Library/LaunchDaemons/com.hogan.trollshot.plist` 仍保留在仓库中，供需要开机自启的高级用户手动放置到 `/Library/LaunchDaemons/`（需要 root 权限）。

### 越狱环境

在越狱设备上通过 `.deb` 安装时，launchd plist 会自动部署到 `/Library/LaunchDaemons/com.hogan.trollshot.plist`，daemon 以 root 身份运行且 `KeepAlive=true`（被杀后自动重启）。

**开机自启动**：`.deb` 安装后，设备重启（或半绑定越狱重新越狱）时 launchd 会自动加载 plist 启动 wrapper 脚本，wrapper 脚本启动时会清除运行时停止标志（`stop.flag`），确保每次开机都自动启动 daemon，无需手动打开 App。

通过 App 停止服务时，daemon 写入 `stop.flag` 标志文件并退出，wrapper 脚本检测到标志后暂停重启（同时兜底 kill 残留进程）。通过 App 重新启动服务时，App 删除 `stop.flag`，wrapper 脚本自动恢复 daemon。`stop.flag` 仅作为运行时信号，不跨重启持久化。

**端口热切换**：wrapper 脚本持续监视 `api_port` 文件，App 修改端口后 1~2 秒内自动把 daemon 重启到新端口，无需手动停止/启动服务。服务处于停止状态时保持停止，下次启动服务时直接用新端口。

wrapper 脚本运行日志位于 `/var/mobile/trollshot/wrapper.log`，可用于排查开机自启动问题。
wrapper.log 有自动保护：wrapper 每次启动时若文件超过 128KB 会截断只保留尾部 32KB；
daemon 崩溃循环（反复秒退）时按 60 秒窗口汇总写入一行累计次数，不会逐次刷屏。

App 会自动检测运行环境：
- **检测到系统级 plist（越狱）**：启动/停止通过 `launchctl bootstrap`/`bootout` 操作（兼容旧版 `load`/`unload`），不直接 `posix_spawn`
- **未检测到（TrollStore）**：手动复制 daemon 到 `/var/mobile/trollshot/` 并 `posix_spawn` 启动

> 注意：如果 App 以 mobile 用户运行且 `launchctl` 权限不足，停止服务可能失败。此时会弹出提示，请通过 SSH 以 root 执行：
> ```
> launchctl unload /Library/LaunchDaemons/com.hogan.trollshot.plist
> ```

## 安装方式

按设备越狱状态选择安装包，两种包的截图路线在编译期固定、互不包含对方代码：

| 安装包 | 适用设备 | 截图方式 | 并发 | 获取途径 |
|--------|----------|----------|------|----------|
| `TrollShot-deb`（`com.hoganhong.trollshot`） | 越狱设备 | framebuffer 直读 GPU（需 AirPlay 镜像） | 1（串行） | GitHub Actions 产物 `TrollShot-deb`，Cydia/Sileo/SSH 安装，开机自启 |
| `TrollShot.ipa` | 非越狱设备（TrollStore） | CARenderServer（与 TrollVNC 相同） | 4 | GitHub Actions 产物 `TrollShot-ipa`，TrollStore 安装 |

越狱设备只装 deb、不装 ipa；非越狱设备只装 ipa、不装 deb。设备状态固定，无需运行时判断。

2026-08-17 起 deb 包内置 `airplay-autolink` tweak（AirPlay 镜像自动连接守护，v7.0 整合），
与早期独立发行的 `com.hoganhong.airplay-autolink` 包互斥（control 已声明 Conflicts/Replaces）。
旧设备升级命令：

```sh
dpkg -r com.hoganhong.airplay-autolink   # 先卸独立包（可跳过，dpkg 会提示冲突再处理）
dpkg -i com.hoganhong.trollshot_<版本>_iphoneos-arm.deb   # 安装即含 tweak，装完自动 respring
```

### 安装脚本（postinst）行为说明

安装/升级完成后 postinst 自动完成（顺序执行）：

1. 清除停止标志、修复二进制与 plist 权限；
2. 加载 launchd daemon 并按 `launchctl list` 实际状态校验；
3. **显式执行 `uicache` 重建图标缓存**：卸载重装或异常安装后，SpringBoard
   respring 的自动重扫并不总是刷新图标缓存（实测出现过桌面无图标、资源库
   搜不到），必须显式重建；
4. **respring 按安装途径自动区分**：
   - **GUI 包管理器（Zebra/Sileo）安装：脚本不自动 respring**。包内含
     MobileSubstrate tweak，GUI 安装完成页会自动出现"重启 SpringBoard"按钮
     （与其他插件一致），点击后 tweak 生效；避免脚本自行 respring 打断 GUI
     内的连续安装队列、或引发"幽灵安装"（dpkg 显示已装但文件全无，需
     `dpkg --purge` 后重装才能恢复）。
   - **SSH/命令行无人值守安装**（机队批量路径）：无人点按钮，脚本延迟 12 秒
     后台自动 respring 让 tweak dylib 加载生效；延迟是为了让 dpkg / cydia
     triggers 先收尾，防止安装流程被斩断。

升级注意：升级期间设备会短暂断开 AirPlay 镜像（respring），tweak 重载后自动重连。
GUI 安装完成后请点击完成页的"重启 SpringBoard"按钮；SSH 安装约 15 秒后自动
respring，期间保持设备供电即可。

## 版本号规则

GitHub Actions 每次构建把 `1.0.<构建号>` 注入 deb 的 `Version` 与 App 的
`CFBundleShortVersionString`（主界面标题实时显示），产物文件名同步带版本号，
不再固定 1.0.0。本地构建保持 `control` 里的默认版本。

## 构建要求

- macOS 已安装 Xcode Command Line Tools
- 已安装 [Theos](https://theos.dev/) 并设置好 `$THEOS`
- iOS SDK（如 iPhoneOS16.5）
- `ldid` 用于 ad-hoc 签名

## 本地构建

按构建类型（FLAVOR）出对应的包：

```sh
cd TrollShot
make clean package FLAVOR=deb   # 越狱版：framebuffer 直读，单线程，含 daemon + launchd 自启
make clean package FLAVOR=ipa   # 非越狱版：CARenderServer，4 线程，仅 App
```

发布版构建：

```sh
make clean package FINALPACKAGE=1 FLAVOR=deb
```

本地输出为 `packages/` 目录下的 `.deb`。GitHub Actions 会分别用两种 FLAVOR 构建一次：deb 产物为 `TrollShot-deb`，ipa 产物从 staging 提取 `.app` 打包成 `TrollShot-ipa`。

不传 FLAVOR 时默认构建 deb 版。如需旧的"运行时自动检测"行为（同一包同时含两条截图路径，仅供调试），可在 Makefile 中把 `TROLLSHOT_DEFS` 置空后构建。

## 使用方法

### 基本使用

1. 通过 TrollStore 安装 `TrollShot.ipa`。
2. 在设备上打开 TrollShot 应用。
3. 点击"启动服务"。
4. 等待界面显示"服务状态：运行中"。
5. 在同一局域网内的另一台设备上访问 `http://<设备IP>:6688/screenshot`。

### 越狱模式使用流程

越狱设备使用 framebuffer 直读模式时需要 AirPlay 屏幕镜像维持 `isCaptured` 状态。
deb 包内置的 `airplay-autolink` tweak 会在设备启动、镜像断开时**自动**发现并连接
UxPlay 服务器，正常情况零人工操作：

1. 在局域网内部署 UxPlay 服务器（Docker 方式，支持多设备同时连接，服务名默认 `TrollShot-AirPlay`）。
2. 安装 deb 包（自动 respring 生效）。确认 TrollShot App 主界面"AirPlay服务器"与
   服务器广播名一致（默认一致，包含匹配）。
3. 十几秒内镜像自动建立。访问 `http://<设备IP>:<API端口>/status` 确认镜像状态为 `ok`。
4. 访问 `http://<设备IP>:<API端口>/screenshot` 获取彩色截图。

> 未开启 AirPlay 镜像时，截图请求返回 HTTP 503，响应头包含 `X-Mirror-Status: inactive`。

### 主界面配置项

| 配置项 | 默认值 | 存储 | 生效方式 |
|--------|--------|------|----------|
| API 端口 | `6688` | `/var/mobile/trollshot/api_port` | 编辑结束保存，wrapper 监视端口文件，1~2 秒自动重启 daemon 到新端口；服务停止时下次启动生效 |
| AirPlay 服务器名 | `TrollShot` | `/var/mobile/Library/Preferences/com.hoganhong.airplay-autolink.plist` 的 `target` 键 | 编辑结束保存，tweak 在下次镜像断开转变时热加载，无需重启 SpringBoard |

## AirPlay 自动连接（airplay-autolink，v7.0 整合）

deb 包内置注入 SpringBoard 的守护 tweak（`/Library/MobileSubstrate/DynamicLibraries/airplay-autolink.dylib`），
基于 v6.8.1 定版（KVO 秒级断开感知 + 120 秒兜底轮询 + 单链不变量，见独立仓库历史文档），
整合后新增两项能力：

1. **断开清理上报**：检测到镜像断开（含设备重启后的首次判定）时，自动通过 Bonjour
   按配置的服务器名解析 `_airplay._tcp` 得到 UxPlay 地址，调用
   `GET /cleanup?name=<本机设备名>`（UxPlay-AirPlay-Docker 2026-08-17 新增接口），
   服务器立即清除本设备残留的半死会话（否则约 6 分钟超时期间重连会被干扰），
   随后走正常自动重连。失败不影响重连流程，30 秒限频。
2. **配置热加载**：每次断开转变时重读 plist，App 界面改"AirPlay服务器"即时生效。

设备识别使用**设备名**而非 MAC：同一设备 wifi/USB 转网卡切换后 MAC 会变，
设备名稳定唯一（服务器端 /cleanup 按名精确匹配 AirPlay 握手时设备自报名）。

日志：`/var/mobile/Library/Logs/airplay-autolink.log`（🧹 前缀为清理上报）。
详细参数（`interval`/`fallback` 等进阶键）见 plist 内注释与独立仓库 README。

### API 接口

```
GET http://<设备IP>:6688/screenshot
```

支持以下查询参数，可单独使用或组合使用：

| 参数 | 格式 | 说明 |
|------|------|------|
| `rotate` | `rotate=1` | 强制顺时针旋转 90 度。不加此参数时自动检测设备方向（横屏自动旋转，竖屏不旋转）。 |
| `crop` | `crop=x1,y1,x2,y2` | 裁剪指定区域。x1,y1 为左上角坐标，x2,y2 为右下角坐标。坐标基于旋转后的最终图像。不加此参数时返回全屏截图。 |
| `format` | `format=png\|raw` | 诊断用输出格式。`png` 无损编码；`raw` 直接返回 IOSurface transfer 后的原始 BGRA 字节（跳过 CGImage 封装与编码，忽略 rotate/crop），响应头带 `X-Image-Width`/`X-Image-Height`/`X-Row-Bytes`。默认 `jpeg`。 |

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

# 无损 PNG（诊断色彩偏移用）
GET /screenshot?format=png

# 原始 BGRA 字节（诊断：定位偏移发生在 transfer / CGImage / 编码哪一段）
GET /screenshot?format=raw

# 健康检查（返回 pong）
GET /ping

# 服务状态（返回 JSON，含镜像状态）
GET /status

# 停止 daemon（越狱环境，daemon 自行卸载 launchd 并退出）
GET /shutdown
```

#### /status 响应

返回 JSON 格式的服务状态：

```json
{
  "mode": "framebuffer",
  "jailbreak": true,
  "mirror": true,
  "needs_mirror": true,
  "status": "ok"
}
```

| 字段 | 说明 |
|------|------|
| `mode` | 截图模式：`framebuffer`（越狱直读）、`carender`（CARenderServer） |
| `jailbreak` | 是否越狱环境 |
| `mirror` | AirPlay 屏幕镜像是否活跃（`UIScreen.isCaptured`） |
| `needs_mirror` | 是否需要 AirPlay 镜像才能正常截图 |
| `status` | 综合状态：`ok`（正常）、`need_mirror`（需要开启AirPlay镜像） |

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

#### 并发与 503 行为

`/screenshot` 受并发限制（越狱 framebuffer 模式为 1，非越狱模式为 4）。`/ping`、`/status` 等轻量端点不受并发限制，截图处理期间也可正常响应（App 状态检测不受影响）。

截图请求返回 503 时，通过响应头区分两种原因：

| 响应头 | 含义 |
|--------|------|
| `X-Mirror-Status: inactive` | AirPlay 镜像未开启（越狱 framebuffer 模式），需先开启镜像 |
| `X-Busy: true` | 截图并发已满，前一个截图仍在处理，稍后重试即可 |

客户端遇到 `X-Busy` 时应短暂等待（如 100ms）后重试，不要立即放弃。

## 调试模式

App 界面提供「调试模式」开关按钮：

- **关闭调试模式（默认）**：daemon 的 stdout/stderr 重定向到 /dev/null 丢弃，TSLogger 不写文件，日志文件不会增长。
- **开启调试模式**：daemon 带 `--debug` 参数启动，stdout/stderr 重定向到 `/var/mobile/trollshot/trollshotd.log`，TSLogger 写入 `/var/mobile/trollshot/TrollShot.log`。开启时可选择清空旧日志。

调试模式状态持久化在 `/var/mobile/trollshot/debug_mode` 标志文件中（内容为 `1` 或 `0`）。切换调试模式时，如果服务正在运行，会自动重启 daemon 使设置立即生效。

## 日志

全部日志文件均受「调试模式」分级控制并带大小上限，长期运行不会把设备存储挤爆：

| 日志文件 | 路径 | 调试模式关闭时 | 调试模式开启时 | 大小上限 |
|----------|------|----------------|----------------|----------|
| daemon 标准输出 | `/var/mobile/trollshot/trollshotd.log` | 不写（重定向 /dev/null，每次调试启动先清空） | 写入 | 调试启动时清空 |
| TSLogger 运行日志 | `/var/mobile/trollshot/TrollShot.log` | 不写（不创建文件） | 写入 | 超 1MB 截断保留尾部 256KB |
| wrapper 脚本日志 | `/var/mobile/trollshot/wrapper.log` | 只记关键事件（启动/停止/端口切换/崩溃汇总） | 同左 | 启动时超 128KB 截断保留尾部 32KB |
| AirPlay 自动连接日志 | `/var/mobile/Library/Logs/airplay-autolink.log` | 只记关键事件（镜像建立/断开/错误/清理上报） | 全量（含逐秒 tick 轮询） | 超 1MB 截断保留尾部 256KB |

说明：

- 关键事件始终落盘：镜像建立成功/断开触发重连/看门狗卡死/清理上报等低频但排障必需的事件，调试模式关闭时也会记录。
- 逐秒轮询噪音（发现层扫描、等待协商、兜底心跳）只在调试模式开启时落盘。tweak 注入在 SpringBoard 内，每 60 秒重读一次 `debug_mode` 标志，App 里切换开关后 1 分钟内生效，无需重启设备。
- 历史教训：曾因旧版 daemon 崩溃循环（CoreImage 截图路径 bug）65 小时刷出 5.4MB 的 wrapper.log；新版已修复该 bug，且上述限频+截断双保险确保即使再出现崩溃循环，日志量也被压在数百 KB 以内。
- 系统的 `/var/mobile/Library/Logs/CrashReporter/`（崩溃报告）不受以上机制管辖，如积累过大可手动清理：`rm -f /var/mobile/Library/Logs/CrashReporter/trollshotd-*.ips`。

可以通过 SSH 或文件管理工具导出日志进行排查。

## 停止与卸载

- **TrollStore 环境**：点击"停止服务"向 `trollshotd` 进程发送 SIGTERM，1 秒内未退出则发送 SIGKILL，最后 `killall -9` 兜底。
- **越狱环境**：点击"停止服务"先执行 `launchctl bootout`/`unload` 卸载系统级 plist，再 kill 进程。如果权限不足会弹出错误提示，需通过 SSH 以 root 手动执行 `launchctl unload`。
- 卸载 IPA/.deb：系统会自动删除 app bundle，已复制到 `/var/mobile/trollshot/` 的 daemon 和日志不会自动清理，可手动删除。越狱 `.deb` 卸载时 `prerm` 脚本会自动停止 daemon 并卸载 launchd plist，无需手动清理 `/Library/LaunchDaemons/com.hogan.trollshot.plist`。

## 局限

- 需要 TrollStore 或越狱环境；普通签名设备无法运行。
- daemon 需要 root 权限才能调用私有截屏 API。
- 越狱模式 framebuffer 直读需要设备开启 AirPlay 屏幕镜像，否则游戏防截屏会触发灰屏。
- 需要私有 entitlement。
- 越狱 `.deb` 安装支持开机自启动（launchd plist + wrapper 脚本）。TrollStore IPA 安装不支持开机自启动，需手动打开 App 点击"启动服务"。

## 文件说明

### 核心源码

- `ScreenCapturer.{h,mm}` - 通过私有 API 截屏，越狱模式用 IOMobileFramebuffer 直读（需 AirPlay 镜像维持 isCaptured），非越狱模式用 CARenderServerRenderDisplay；包含脏帧检测、帧缓存、旋转（FBSOrientationObserver）和裁剪逻辑
- `HTTPScreenshotServer.{h,mm}` - 迷你 HTTP 服务器，解析 `rotate` / `crop` 查询参数，提供 `/status` 镜像状态检查
- `trollshotd.mm` - 后台 daemon 入口，解析 `--debug` 参数
- `TrollShotManager.{h,m}` - 启动/停止 daemon 的管理逻辑，调试模式标志读写，API 端口与 AirPlay 服务器名配置读写，stdout/stderr 重定向控制
- `airplay-autolink/Tweak.xm` - AirPlay 镜像自动连接 tweak（v7.0 整合）：KVO 秒级断开感知 + 兜底轮询 + 断开清理上报（Bonjour 解析 + `/cleanup` 接口）+ 配置热加载；仅 deb 构建
- `airplay-autolink.plist` - Substitute/Substrate 注入过滤器（仅 SpringBoard）
- `TSLogger.{h,m}` - 日志管理器，懒加载写入 `/var/mobile/Documents/TrollShot.log`，受 `debugEnabled` 控制
- `AppDelegate.{h,m}` / `main.m` - iOS 应用启动入口，含调试模式开关按钮

### 私有框架声明

- `include-spi/FBSOrientationObserver.h` - FrontBoardServices 方向观察器（来自 TrollVNC）
- `include-spi/IOMobileFramebufferSPI.h` - IOMobileFramebuffer 私有接口声明（越狱模式 framebuffer 直读，参考 screendump fix14）
- `include-spi/IOKitSPI.h` - IOKit 私有接口声明
- `include-spi/IOSurfaceSPI.h` - IOSurface 私有接口声明（含 IOSurfaceGetSeed 脏帧检测）
- `include-spi/UIScreen+Private.h` - UIScreen 私有方法声明
