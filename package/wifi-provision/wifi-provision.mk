################################################################################
#
# Copyright (c) OpenIPC  https://openipc.org  MIT License
#
# wifi-provision -- user-friendly Wi-Fi setup
#
################################################################################

WIFI_PROVISION_LICENSE = MIT
WIFI_PROVISION_LICENSE_FILES = LICENSE

# No download: the sources live in the package directory. site_method local
# copies them into the build directory so an out-of-tree build never writes
# back into the external tree. PKGDIR carries a trailing slash and Buildroot
# rejects one on SITE (package/pkg-generic.mk), hence the patsubst.
WIFI_PROVISION_SITE = $(patsubst %/,%,$(WIFI_PROVISION_PKGDIR))
WIFI_PROVISION_SITE_METHOD = local

WIFI_PROVISION_DEPENDENCIES = wpa_supplicant rtw-hostapd busybox

ifeq ($(BR2_PACKAGE_WIFI_PROVISION_CAPTIVE_DNS),y)
define WIFI_PROVISION_BUILD_CMDS
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) \
		-o $(@D)/wifi-dnsd $(@D)/src/wifi-dnsd.c
endef

define WIFI_PROVISION_INSTALL_DNSD
	$(INSTALL) -m 0755 -D $(@D)/wifi-dnsd $(TARGET_DIR)/usr/sbin/wifi-dnsd
endef
else
define WIFI_PROVISION_BUILD_CMDS
endef

define WIFI_PROVISION_INSTALL_DNSD
endef
endif

# Replace the stock wlan0 stanza. The shipped one starts its own
# wpa_supplicant from the U-Boot environment on every ifup; leaving it in
# place would mean two owners of the same interface racing each other, and
# whichever won, the credentials the user typed into the setup page would
# not be the ones used. "inet manual" keeps ifup bringing the link up while
# wifi-manager owns the supplicant, hostapd and DHCP.
#
# The original is kept alongside so an integrator can see what changed and
# a rollback is a single move.
define WIFI_PROVISION_INSTALL_NETWORK_STANZA
	if [ -f $(TARGET_DIR)/etc/network/interfaces.d/wlan0 ] && \
	   ! [ -f $(TARGET_DIR)/etc/network/interfaces.d/wlan0.stock ]; then \
		mv $(TARGET_DIR)/etc/network/interfaces.d/wlan0 \
		   $(TARGET_DIR)/etc/network/interfaces.d/wlan0.stock; \
	fi
	$(INSTALL) -m 0644 -D $(WIFI_PROVISION_PKGDIR)/files/etc/network/interfaces.d/wlan0 \
		$(TARGET_DIR)/etc/network/interfaces.d/wlan0
endef

define WIFI_PROVISION_INSTALL_TARGET_CMDS
	$(INSTALL) -m 0755 -d $(TARGET_DIR)/usr/libexec/wifi
	$(INSTALL) -m 0644 -t $(TARGET_DIR)/usr/libexec/wifi \
		$(WIFI_PROVISION_PKGDIR)/files/usr/libexec/wifi/wifi-lib.sh \
		$(WIFI_PROVISION_PKGDIR)/files/usr/libexec/wifi/wifi-sta.sh \
		$(WIFI_PROVISION_PKGDIR)/files/usr/libexec/wifi/wifi-ap.sh \
		$(WIFI_PROVISION_PKGDIR)/files/usr/libexec/wifi/wifi-scan.sh

	$(INSTALL) -m 0755 -D $(WIFI_PROVISION_PKGDIR)/files/usr/sbin/wifi-manager \
		$(TARGET_DIR)/usr/sbin/wifi-manager
	$(INSTALL) -m 0755 -D $(WIFI_PROVISION_PKGDIR)/files/usr/sbin/wifi-ctl \
		$(TARGET_DIR)/usr/sbin/wifi-ctl
	$(INSTALL) -m 0755 -D $(WIFI_PROVISION_PKGDIR)/files/usr/sbin/wifi-button-watch \
		$(TARGET_DIR)/usr/sbin/wifi-button-watch

	$(INSTALL) -m 0755 -D $(WIFI_PROVISION_PKGDIR)/files/etc/init.d/S41wifi \
		$(TARGET_DIR)/etc/init.d/S41wifi

	$(INSTALL) -m 0755 -d $(TARGET_DIR)/etc/wifi
	$(INSTALL) -m 0644 -D $(WIFI_PROVISION_PKGDIR)/files/etc/wifi/wifi.defaults \
		$(TARGET_DIR)/etc/wifi/wifi.defaults

	$(INSTALL) -m 0755 -d $(TARGET_DIR)/var/www-wifi/cgi-bin
	$(INSTALL) -m 0644 -D $(WIFI_PROVISION_PKGDIR)/files/var/www-wifi/index.html \
		$(TARGET_DIR)/var/www-wifi/index.html
	$(INSTALL) -m 0755 -D $(WIFI_PROVISION_PKGDIR)/files/var/www-wifi/cgi-bin/wifi \
		$(TARGET_DIR)/var/www-wifi/cgi-bin/wifi

	$(WIFI_PROVISION_INSTALL_DNSD)
	$(WIFI_PROVISION_INSTALL_NETWORK_STANZA)
endef

$(eval $(generic-package))
