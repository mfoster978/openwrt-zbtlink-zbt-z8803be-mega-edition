include $(TOPDIR)/rules.mk
PKG_NAME:=luci-app-speedtest-lite
PKG_VERSION:=1
PKG_RELEASE:=2
LUCI_TITLE:=LuCI speed test utility page
LUCI_DEPENDS:=+luci-base +rpcd +rpcd-mod-file +jq +curl
include $(TOPDIR)/feeds/luci/luci.mk
define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-speedtest-lite.json $(1)/usr/share/luci/menu.d/luci-app-speedtest-lite.json
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/speedtest-lite
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/speedtest-lite/config.js $(1)/www/luci-static/resources/view/speedtest-lite/config.js
endef
$(eval $(call BuildPackage,$(PKG_NAME)))
