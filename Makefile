export ARCHS = arm64
export TARGET = iphone:clang:16.5:14.0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = TrollShot

TrollShot_FILES = main.m AppDelegate.m ScreenCapturer.mm HTTPScreenshotServer.mm
TrollShot_CFLAGS = -fobjc-arc -Iinclude-spi
TrollShot_FRAMEWORKS = UIKit CoreMedia CoreVideo CoreImage ImageIO IOSurface QuartzCore
TrollShot_PRIVATE_FRAMEWORKS =
TrollShot_CODESIGN_FLAGS = -STrollShot.entitlements

include $(THEOS_MAKE_PATH)/application.mk
