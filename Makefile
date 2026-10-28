ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = TMLightning

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TMMemberPatch
TMMemberPatch_FILES = TMMemberPatch.m
TMMemberPatch_FRAMEWORKS = UIKit Foundation
TMMemberPatch_CFLAGS = -fobjc-arc -O2

include $(THEOS_MAKE_PATH)/tweak.mk
