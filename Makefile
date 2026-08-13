ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME = rootless
SDKVERSION = 16.5
INSTALL_TARGET_PROCESSES = Siri

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SiriAI
SiriAI_FILES = Tweak.xm
SiriAI_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
SiriAI_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += SiriAIPreferences
include $(THEOS_MAKE_PATH)/aggregate.mk
