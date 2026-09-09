include $(TOPDIR)/rules.mk
PKG_NAME:=luci-app-speedtest-lite
PKG_VERSION:=1
PKG_RELEASE:=1
LUCI_TITLE:=LuCI speed test utility page
LUCI_DEPENDS:=+luci-base +rpcd +jq +curl +speedtest-netperf +speedtest-go
include $(TOPDIR)/feeds/luci/luci.mk
define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-speedtest-lite.json $(1)/usr/share/luci/menu.d/luci-app-speedtest-lite.json
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-speedtest-lite.json $(1)/usr/share/rpcd/acl.d/luci-app-speedtest-lite.json
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/speedtest-lite
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/speedtest-lite/config.js $(1)/www/luci-static/resources/view/speedtest-lite/config.js
	$(INSTALL_DIR) $(1)/www/cgi-bin
	$(INSTALL_BIN) ./root/www/cgi-bin/speedtest-lite-run $(1)/www/cgi-bin/speedtest-lite-run
endef
$(eval $(call BuildPackage,$(PKG_NAME)))
