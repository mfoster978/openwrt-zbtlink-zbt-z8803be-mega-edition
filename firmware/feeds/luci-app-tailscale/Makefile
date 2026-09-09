include $(TOPDIR)/rules.mk
PKG_NAME:=luci-app-tailscale
PKG_VERSION:=1
PKG_RELEASE:=1
LUCI_TITLE:=Tailscale status and sign-in
LUCI_DEPENDS:=+luci-base +rpcd +tailscale +jq
include $(TOPDIR)/feeds/luci/luci.mk
define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/usr/libexec/rpcd $(1)/usr/share/luci/menu.d $(1)/usr/share/rpcd/acl.d $(1)/www/luci-static/resources/view/tailscale
	$(INSTALL_BIN) ./root/usr/libexec/rpcd/zbt.tailscale $(1)/usr/libexec/rpcd/zbt.tailscale
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/tailscale.json $(1)/usr/share/luci/menu.d/tailscale.json
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/tailscale.json $(1)/usr/share/rpcd/acl.d/tailscale.json
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/tailscale/status.js $(1)/www/luci-static/resources/view/tailscale/status.js
endef
$(eval $(call BuildPackage,$(PKG_NAME)))
