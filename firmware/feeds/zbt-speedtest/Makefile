include $(TOPDIR)/rules.mk

PKG_NAME:=zbt-speedtest
PKG_VERSION:=1.7.10
PKG_RELEASE:=1
PKG_SOURCE:=speedtest-go-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://codeload.github.com/showwin/speedtest-go/tar.gz/v$(PKG_VERSION)?
PKG_HASH:=70a2937d0759820fe7ee8f61b960d60c07b34c0d783ed11c0065b68fe2964aea
PKG_BUILD_DIR:=$(BUILD_DIR)/speedtest-go-$(PKG_VERSION)-zbt
# The source tarball's top-level name is also used by the stock CLI package.
# Unpack into our own directory so parallel package builds cannot overwrite it.
PKG_UNPACK=$(HOST_TAR) -xzf $(DL_DIR)/$(PKG_SOURCE) -C $(PKG_BUILD_DIR) --strip-components=1
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_BUILD_DEPENDS:=golang/host
PKG_BUILD_PARALLEL:=1
GO_PKG:=github.com/showwin/speedtest-go
GO_PKG_BUILD_PKG:=$(GO_PKG)/cmd/zbt-speedtest

include $(INCLUDE_DIR)/package.mk
include $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk

define Package/zbt-speedtest
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Live router speed tests using Speedtest.net servers
  URL:=https://github.com/showwin/speedtest-go
  DEPENDS:=$(GO_ARCH_DEPENDS) +ca-bundle
endef

define Build/Prepare
	$(call Build/Prepare/Default)
	$(INSTALL_DIR) $(PKG_BUILD_DIR)/cmd/zbt-speedtest
	$(CP) ./src/*.go $(PKG_BUILD_DIR)/cmd/zbt-speedtest/
endef

define Package/zbt-speedtest/install
	$(call GoPackage/Package/Install/Bin,$(1))
	$(INSTALL_DIR) $(1)/usr/share/licenses/zbt-speedtest
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/LICENSE $(1)/usr/share/licenses/zbt-speedtest/LICENSE
endef

$(eval $(call GoBinPackage,zbt-speedtest))
$(eval $(call BuildPackage,zbt-speedtest))
