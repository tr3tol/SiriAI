include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = SiriAIPreferences

SiriAIPreferences_FILES = PrefsBundle.c TestConnection.m
SiriAIPreferences_INSTALL_PATH = /Library/PreferenceBundles
TestConnection.m_CFLAGS = -fobjc-arc
# PrefsBundle.c is plain C, so the ObjC runtime has to be linked explicitly.
SiriAIPreferences_LDFLAGS = -lobjc
SiriAIPreferences_FRAMEWORKS = UIKit Foundation CoreFoundation

include $(THEOS_MAKE_PATH)/bundle.mk
