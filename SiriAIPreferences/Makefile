include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = SiriAIPreferences

SiriAIPreferences_FILES = PrefsBundle.c
SiriAIPreferences_INSTALL_PATH = /Library/PreferenceBundles
# Plain C source, so the ObjC runtime has to be linked explicitly.
SiriAIPreferences_LDFLAGS = -lobjc
SiriAIPreferences_FRAMEWORKS = Foundation CoreFoundation

include $(THEOS_MAKE_PATH)/bundle.mk
