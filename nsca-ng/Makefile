#
# This is free software, licensed under the GNU General Public License v2.
# See /LICENSE for more information.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=nsca-ng
PKG_VERSION:=1.7
PKG_RELEASE:=1
PKG_MAINTAINER:=A. Valentin <avalentin@marcant.net>
PKG_LICENSE:=BSD-2-Clause
PKG_LICENSE_FILES:=COPYING

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/weiss/nsca-ng.git
# tag v1.7 (2026-02-09) — the release that works with OpenSSL 3
PKG_SOURCE_VERSION:=598ae4a1eb0ab5ccc53ff596aad88e2f92215bcd
PKG_SOURCE_SUBDIR:=$(PKG_NAME)-$(PKG_VERSION)
PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION)-$(PKG_SOURCE_VERSION).tar.gz
PKG_MIRROR_HASH:=040d0162cab4c7aa9df72be0302041970fc53d9de4c5201973cb4cbb9ae137fd

# a git checkout carries no generated configure
PKG_FIXUP:=autoreconf
PKG_BUILD_FLAGS:=lto
# lib/wrappers.c (the replacement printf family) does not compile against
# the musl toolchain's fortify headers: include/fortify/stdio.h then wraps a
# vsnprintf/snprintf that is not declared yet ("'vsnprintf' undeclared",
# snapshot SDK, gcc 14.4, 2026-10-03)
PKG_FORTIFY_SOURCE:=0

include $(INCLUDE_DIR)/package.mk

define Package/nsca-ng
  SECTION:=admin
  CATEGORY:=Administration
  TITLE:=NSCA-ng client (send_nsca)
  URL:=https://github.com/weiss/nsca-ng
  DEPENDS:=+libopenssl +libev +confuse
endef

define Package/nsca-ng/description
	The client half of NSCA-ng: send_nsca submits passive check results to a
	remote Nagios/Icinga over TLS with a per-client pre-shared key. Used by
	wwand-apntest to report its verdicts.
endef

define Package/nsca-ng/conffiles
/etc/send_nsca.cfg
endef

# Client only: the server is the monitor's side, and its POSIX AIO path does
# not build against musl.
CONFIGURE_ARGS += \
	--enable-client \
	--disable-server \
	--disable-posix-aio \
	--with-ev="$(STAGING_DIR)/usr" \
	--with-confuse="$(STAGING_DIR)/usr"

define Package/nsca-ng/install
	$(INSTALL_DIR) $(1)/usr/bin $(1)/etc
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/src/client/send_nsca $(1)/usr/bin/
	$(INSTALL_CONF) $(PKG_BUILD_DIR)/etc/send_nsca.cfg $(1)/etc/
endef

$(eval $(call BuildPackage,nsca-ng))
