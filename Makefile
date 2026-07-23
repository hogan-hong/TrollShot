export ARCHS = arm64 arm64e
export TARGET = iphone:clang:16.5:14.0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = TrollShot
TOOL_NAME = trollshotd

TrollShot_FILES = main.m AppDelegate.m TSLogger.m TrollShotManager.m ScreenCapturer.mm HTTPScreenshotServer.mm
TrollShot_CFLAGS = -fobjc-arc -Iinclude-spi
TrollShot_FRAMEWORKS = UIKit CoreMedia CoreVideo CoreImage ImageIO IOSurface QuartzCore
TrollShot_PRIVATE_FRAMEWORKS =
TrollShot_CODESIGN_FLAGS = -STrollShot.entitlements

trollshotd_FILES = trollshotd.mm ScreenCapturer.mm HTTPScreenshotServer.mm
trollshotd_CFLAGS = -fobjc-arc -Iinclude-spi
trollshotd_FRAMEWORKS = UIKit CoreMedia CoreVideo CoreImage ImageIO IOSurface QuartzCore Foundation
trollshotd_CODESIGN_FLAGS = -STrollShot.entitlements

include $(THEOS_MAKE_PATH)/application.mk
include $(THEOS_MAKE_PATH)/tool.mk

export THEOS_STAGING_DIR
before-package::
	@mkdir -p "$(THEOS_STAGING_DIR)/Applications/TrollShot.app"
	@cp -p "$(THEOS_STAGING_DIR)/usr/bin/trollshotd" "$(THEOS_STAGING_DIR)/Applications/TrollShot.app/trollshotd"
	@cp -p "$(THEOS_STAGING_DIR)/Library/LaunchDaemons/com.hogan.trollshot.plist" "$(THEOS_STAGING_DIR)/Applications/TrollShot.app/com.hogan.trollshot.plist"
	@ldid -STrollShot.entitlements "$(THEOS_STAGING_DIR)/Applications/TrollShot.app"
