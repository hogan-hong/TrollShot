export ARCHS = arm64
export TARGET = iphone:clang:14.5:14.0

# 构建类型（FLAVOR），按设备越狱状态选择安装包：
#   deb - 越狱设备专用：framebuffer 直读 GPU（单线程），含 daemon + launchd 开机自启
#   ipa - 非越狱 TrollStore 设备专用：CARenderServer（4 线程），仅 App（内含 trollshotd）
# 用法：make package FLAVOR=deb  或  make package FLAVOR=ipa
FLAVOR ?= deb
ifeq ($(FLAVOR),ipa)
TROLLSHOT_DEFS = -DTROLLSHOT_CA_ONLY
else
TROLLSHOT_DEFS = -DTROLLSHOT_FB_ONLY
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

include $(THEOS_MAKE_PATH)/application.mk
include $(THEOS_MAKE_PATH)/tool.mk

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
	@cp -p layout/Library/LaunchDaemons/com.hogan.trollshot.plist "$(THEOS_STAGING_DIR)/Applications/TrollShot.app/com.hogan.trollshot.plist"
	@mkdir -p "$(THEOS_STAGING_DIR)/Library/LaunchDaemons"
	@cp -p layout/Library/LaunchDaemons/com.hogan.trollshot.plist "$(THEOS_STAGING_DIR)/Library/LaunchDaemons/com.hogan.trollshot.plist"
	@mkdir -p "$(THEOS_STAGING_DIR)/DEBIAN"
	@if [ -f "layout/DEBIAN/postinst" ]; then \
		cp -p "layout/DEBIAN/postinst" "$(THEOS_STAGING_DIR)/DEBIAN/postinst"; \
		chmod 755 "$(THEOS_STAGING_DIR)/DEBIAN/postinst"; \
	fi
	@if [ -f "layout/DEBIAN/prerm" ]; then \
		cp -p "layout/DEBIAN/prerm" "$(THEOS_STAGING_DIR)/DEBIAN/prerm"; \
		chmod 755 "$(THEOS_STAGING_DIR)/DEBIAN/prerm"; \
	fi
	@mkdir -p "$(THEOS_STAGING_DIR)/usr/bin"
	@cp -p "layout/usr/bin/trollshotd_wrapper.sh" "$(THEOS_STAGING_DIR)/usr/bin/trollshotd_wrapper.sh"
	@chmod 755 "$(THEOS_STAGING_DIR)/usr/bin/trollshotd_wrapper.sh"
endif
