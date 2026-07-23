export ARCHS = arm64 arm64e
export TARGET = iphone:clang:16.5:14.0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = TrollShot
TOOL_NAME = trollshotd

TrollShot_FILES = main.m AppDelegate.m TSLogger.m TrollShotManager.m ScreenCapturer.mm HTTPScreenshotServer.mm
TrollShot_CFLAGS = -fobjc-arc -Iinclude-spi
TrollShot_FRAMEWORKS = UIKit CoreMedia CoreVideo CoreImage ImageIO IOSurface QuartzCore
TrollShot_PRIVATE_FRAMEWORKS =
TrollShot_RESOURCE_DIRS = Resources
TrollShot_CODESIGN_FLAGS = -STrollShot.entitlements

trollshotd_FILES = trollshotd.mm TSLogger.m ScreenCapturer.mm HTTPScreenshotServer.mm
trollshotd_CFLAGS = -fobjc-arc -Iinclude-spi
trollshotd_FRAMEWORKS = UIKit CoreMedia CoreVideo CoreImage ImageIO IOSurface QuartzCore Foundation
trollshotd_CODESIGN_FLAGS = -STrollShot.entitlements

include $(THEOS_MAKE_PATH)/application.mk
include $(THEOS_MAKE_PATH)/tool.mk

# 打包前把 daemon 二进制和 launchd plist 复制进 .app bundle，
# 这样 TrollShotManager 才能从 [NSBundle mainBundle] 里找到它们。
before-package::
	@mkdir -p "$(THEOS_STAGING_DIR)/Applications/TrollShot.app"
	@if [ -f "$(THEOS_OBJ_DIR)/trollshotd" ]; then \
		cp -p "$(THEOS_OBJ_DIR)/trollshotd" "$(THEOS_STAGING_DIR)/Applications/TrollShot.app/trollshotd"; \
	elif [ -f "$(THEOS_OBJ_DIR)/debug/trollshotd" ]; then \
		cp -p "$(THEOS_OBJ_DIR)/debug/trollshotd" "$(THEOS_STAGING_DIR)/Applications/TrollShot.app/trollshotd"; \
	elif [ -f ".theos/obj/trollshotd" ]; then \
		cp -p ".theos/obj/trollshotd" "$(THEOS_STAGING_DIR)/Applications/TrollShot.app/trollshotd"; \
	fi
	@chmod +x "$(THEOS_STAGING_DIR)/Applications/TrollShot.app/trollshotd"
	@cp -p "layout/Library/LaunchDaemons/com.hogan.trollshot.plist" "$(THEOS_STAGING_DIR)/Applications/TrollShot.app/com.hogan.trollshot.plist"
