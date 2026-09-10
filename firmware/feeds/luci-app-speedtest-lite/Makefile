include $(TOPDIR)/rules.mk
PKG_NAME:=luci-app-speedtest-lite
PKG_VERSION:=2
PKG_RELEASE:=1
LUCI_TITLE:=LuCI live speed test dashboard
LUCI_DEPENDS:=+luci-base +rpcd +zbt-speedtest
include $(TOPDIR)/feeds/luci/luci.mk
define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-speedtest-lite.json $(1)/usr/share/luci/menu.d/luci-app-speedtest-lite.json
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/speedtest-lite
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/speedtest-lite/config.js $(1)/www/luci-static/resources/view/speedtest-lite/config.js
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/speedtest-lite/style.css $(1)/www/luci-static/resources/view/speedtest-lite/style.css
endef
$(eval $(call BuildPackage,$(PKG_NAME)))
