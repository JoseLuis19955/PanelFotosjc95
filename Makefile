TARGET := iphone:clang:latest:15.0
ARCHS = arm64
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = jc95

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = jc95
jc95_FILES = main.m
jc95_FRAMEWORKS = UIKit PhotosUI Photos AVFoundation CoreImage CoreMedia CoreVideo QuartzCore
jc95_CFLAGS = -fobjc-arc
jc95_CODESIGN_FLAGS = -SEntitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
