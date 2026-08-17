export TARGET = iphone:clang:14.5:14.0

# 构建类型（FLAVOR），按设备越狱状态选择安装包：
#   deb - 越狱设备专用：framebuffer 直读 GPU（单线程），含 daemon + launchd 开机自启
#         + airplay-autolink tweak（AirPlay 镜像自动连接，注入 SpringBoard）
#   ipa - 非越狱 TrollStore 设备专用：CARenderServer（4 线程），仅 App（内含 trollshotd）
# 用法：make package FLAVOR=deb  或 make package FLAVOR=ipa
FLAVOR ?= deb

ifeq ($(FLAVOR),ipa)
TROLLSHOT_DEFS = -DTROLLSHOT_CA_ONLY
export ARCHS = arm64
else
TROLLSHOT_DEFS = -DTROLLSHOT_FB_ONLY
# deb：双架构。SpringBoard 在 A12+ 是 arm64e 进程，tweak 只有 arm64 切片会被
# 静默拒绝注入（实测 2026-08-17）；App/daemon 双切片无副作用。
export ARCHS = arm64 arm64e
endif

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = TrollShot
TOOL_NAME = trollshotd

TrollShot_FILES = main.m AppDelegate.m TSLogger.m TrollShotManager.m ScreenCapturer.mm HTTPScreenshotServer.mm
TrollShot_CFLAGS = -fobjc-arc -Iinclude-spi $(TROLLSHOT_DEFS)
TrollShot_FRAMEWORKS = UIKit CoreMedia CoreVideo CoreImage ImageIO IOSurface QuartzCore IOKit
TrollShot_PRIVATE_FRAMEWORKS = FrontBoardServices IOMobileFramebuffer
TrollShot_RESOURCE_DIRS = Resources
TrollShot_CODESIGN_FLAGS = -STrollShot.entitlements

trollshotd_FILES = trollshotd.mm TSLogger.m ScreenCapturer.mm HTTPScreenshotServer.mm
trollshotd_CFLAGS = -fobjc-arc -Iinclude-spi $(TROLLSHOT_DEFS)
trollshotd_FRAMEWORKS = CoreMedia CoreVideo CoreImage ImageIO IOSurface QuartzCore Foundation IOKit
trollshotd_PRIVATE_FRAMEWORKS = FrontBoardServices IOMobileFramebuffer
trollshotd_LIBRARIES = pthread
trollshotd_CODESIGN_FLAGS = -STrollShot.entitlements

# AirPlay 自动连接 tweak（仅 deb 越狱包包含）
# 关键构建参数（实测 2026-08-17，见 airplay-autolink/ 内注释）：
#   - arm64+arm64e 双切片：SB 是 arm64e 进程，纯 arm64 被静默拒载
#   - -Wl,-no_fixup_chains：Substitute 2.3.1 不支持 Xcode15 chained fixups
ifeq ($(FLAVOR),deb)
TWEAK_NAME = airplay-autolink
airplay-autolink_FILES = airplay-autolink/Tweak.xm
airplay-autolink_CFLAGS = -fobjc-arc
airplay-autolink_LDFLAGS = -Wl,-no_fixup_chains
airplay-autolink_FRAMEWORKS = Foundation UIKit
airplay-autolink_PRIVATE_FRAMEWORKS = MediaRemote
endif

include $(THEOS_MAKE_PATH)/application.mk
include $(THEOS_MAKE_PATH)/tool.mk
ifeq ($(FLAVOR),deb)
include $(THEOS_MAKE_PATH)/tweak.mk
endif

# 布局目录命名为 layout-deb 而非 layout：Theos 对名为 layout 的目录有内建行为，
# 会无条件将其内容自动 stage 进所有包（包括 ipa 构建），导致 prerm 以 644 权限
# 混入而打包失败。改名后完全由下方 Makefile 逻辑控制，仅 deb 构建复制。
# 打包前把 daemon 二进制和 launchd plist 复制进 .app bundle，
# 这样 TrollShotManager 才能从 [NSBundle mainBundle] 里找到它们。
# 同时确保 Info.plist 被复制进 .app bundle（Theos 有时不会自动处理）。
before-package::
	@mkdir -p "$(THEOS_STAGING_DIR)/Applications/TrollShot.app"
	@cp -p Info.plist "$(THEOS_STAGING_DIR)/Applications/TrollShot.app/Info.plist"
	@if [ -f "$(THEOS_OBJ_DIR)/trollshotd" ]; then \
		cp -p "$(THEOS_OBJ_DIR)/trollshotd" "$(THEOS_STAGING_DIR)/Applications/TrollShot.app/trollshotd"; \
	elif [ -f "$(THEOS_OBJ_DIR)/debug/trollshotd" ]; then \
		cp -p "$(THEOS_OBJ_DIR)/debug/trollshotd" "$(THEOS_STAGING_DIR)/Applications/TrollShot.app/trollshotd"; \
	elif [ -f ".theos/obj/trollshotd" ]; then \
		cp -p ".theos/obj/trollshotd" "$(THEOS_STAGING_DIR)/Applications/TrollShot.app/trollshotd"; \
	fi
	@chmod +x "$(THEOS_STAGING_DIR)/Applications/TrollShot.app/trollshotd"
ifneq ($(FLAVOR),ipa)
	@cp -p layout-deb/Library/LaunchDaemons/com.hogan.trollshot.plist "$(THEOS_STAGING_DIR)/Applications/TrollShot.app/com.hogan.trollshot.plist"
	@mkdir -p "$(THEOS_STAGING_DIR)/Library/LaunchDaemons"
	@cp -p layout-deb/Library/LaunchDaemons/com.hogan.trollshot.plist "$(THEOS_STAGING_DIR)/Library/LaunchDaemons/com.hogan.trollshot.plist"
	@mkdir -p "$(THEOS_STAGING_DIR)/DEBIAN"
	@if [ -f "layout-deb/DEBIAN/postinst" ]; then \
		cp -p "layout-deb/DEBIAN/postinst" "$(THEOS_STAGING_DIR)/DEBIAN/postinst"; \
		chmod 755 "$(THEOS_STAGING_DIR)/DEBIAN/postinst"; \
	fi
	@if [ -f "layout-deb/DEBIAN/prerm" ]; then \
		cp -p "layout-deb/DEBIAN/prerm" "$(THEOS_STAGING_DIR)/DEBIAN/prerm"; \
		chmod 755 "$(THEOS_STAGING_DIR)/DEBIAN/prerm"; \
	fi
	@mkdir -p "$(THEOS_STAGING_DIR)/usr/bin"
	@cp -p layout-deb/usr/bin/trollshotd_wrapper.sh "$(THEOS_STAGING_DIR)/usr/bin/trollshotd_wrapper.sh"
	@chmod 755 "$(THEOS_STAGING_DIR)/usr/bin/trollshotd_wrapper.sh"
endif

ifeq ($(FLAVOR),deb)
# tweak dylib 装载需要重启 SpringBoard（daemon 重启不需要，由 postinst/launchd 处理）
after-install::
	install.exec "killall -9 SpringBoard || true"
endif
