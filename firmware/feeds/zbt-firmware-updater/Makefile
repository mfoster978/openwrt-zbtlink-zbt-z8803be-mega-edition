include $(TOPDIR)/rules.mk

PKG_NAME:=zbt-firmware-updater
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_BUILD_DEPENDS:=golang/host
PKG_BUILD_PARALLEL:=1
GO_PKG:=github.com/mfoster978/zbt-firmware-updater
GO_PKG_BUILD_PKG:=$(GO_PKG)

include $(INCLUDE_DIR)/package.mk
include $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk

define Package/zbt-firmware-updater
  SECTION:=admin
  CATEGORY:=Administration
  TITLE:=Verified manual GitHub release updates for ZBT Mega
  DEPENDS:=$(GO_ARCH_DEPENDS) +ca-bundle +rpcd +ubus
endef

define Build/Prepare
	$(INSTALL_DIR) $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
	$(CP) ./LICENSE $(PKG_BUILD_DIR)/LICENSE
endef

define Package/zbt-firmware-updater/install
	$(call GoPackage/Package/Install/Bin,$(1))
	$(INSTALL_DIR) $(1)/usr/share/licenses/zbt-firmware-updater
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/LICENSE $(1)/usr/share/licenses/zbt-firmware-updater/LICENSE
endef

$(eval $(call GoBinPackage,zbt-firmware-updater))
$(eval $(call BuildPackage,zbt-firmware-updater))
