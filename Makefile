ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = TMLightning

include $(THEOS)/makefiles/common.mk

# ============================================================
# 本 Makefile 默认构建【广告加速】插件 TMAiAccel。
#
# 会员插件 TMMemberPatch 已独立，需要时执行：
#     make package SCHEME=member
#
# 两个源文件互不依赖：
#   TMAiAccel.m        广告加速 + 拦截
#   TMMemberPatch.m    会员 / 免广告权益
#
# 注意: GitHub Actions 的 workflow 用纯 clang 逐个编译，
#       不依赖本 Makefile，所以这里只作本地 theos 构建用。
# ============================================================

ifeq ($(SCHEME),member)
  TWEAK_NAME = TMMemberPatch
  TMMemberPatch_FILES      = TMMemberPatch.m
  TMMemberPatch_FRAMEWORKS = UIKit Foundation CoreGraphics
  TMMemberPatch_CFLAGS     = -fobjc-arc -O2
else
  TWEAK_NAME = TMAiAccel
  TMAiAccel_FILES      = TMAiAccel.m
  TMAiAccel_FRAMEWORKS = UIKit Foundation CoreGraphics AVFoundation CoreMotion WebKit
  TMAiAccel_CFLAGS     = -fobjc-arc -O2
endif

include $(THEOS_MAKE_PATH)/tweak.mk
