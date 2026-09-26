# dir that contans the filesystem that must be checked
TESTDIR ?= "prime/"
CODENAME:="$(shell . /etc/os-release; echo "$$VERSION_CODENAME")"

.PHONY: all
all: check
	# nothing

.PHONY: install
install:
	set -ex; if [ -z "$(DESTDIR)" ]; then \
		echo "no DESTDIR set"; \
		exit 1; \
	fi
	rm -rf $(DESTDIR)
	cp -a $(CRAFT_STAGE)/base $(DESTDIR)

	# copy static files verbatim
	/bin/cp -a static/* $(DESTDIR)

	# since recently we're also missing some /dev files that might be
	# useful during build - make sure they're there
	mkdir -p $(DESTDIR)/dev
	[ -e $(DESTDIR)/dev/null ] || mknod -m 666 $(DESTDIR)/dev/null c 1 3
	[ -e $(DESTDIR)/dev/zero ] || mknod -m 666 $(DESTDIR)/dev/zero c 1 5
	[ -e $(DESTDIR)/dev/random ] || mknod -m 666 $(DESTDIR)/dev/random c 1 8
	[ -e $(DESTDIR)/dev/urandom ] || \
		mknod -m 666 $(DESTDIR)/dev/urandom c 1 9

	# create a symlink from /usr/bin to /bin, we need
	# this for the hooks to work properly
	if ! [ -e $(DESTDIR)/bin ]; then \
		ln -sf usr/bin $(DESTDIR)/bin; \
	fi

	# symlink bash to sh if not already present, otherwise we wont be able
	# to run the hooks, this has not been done for us by the chisel slices
	# as you may choose your own /bin/sh implementation
	if ! [ -e $(DESTDIR)/bin/sh ]; then \
		ln -sf bash $(DESTDIR)/bin/sh; \
	fi

	# chisel's libx11-data_xerrordb slice pulls in xkeyboard-config-2 as a
	# transitive dependency and creates this symlink at the wrong depth
	# (../share/xkeyboard-config-2, which doesn't resolve), instead of the
	# real xkb-data package's ../xkeyboard-config-2. The desktop-packages
	# part ships the rest of the real xkb-data package's content (it can't
	# ship this one file too - it would conflict with chisel-libs' copy
	# at snapcraft's stage step), so fix the symlink up here instead.
	ln -sf ../xkeyboard-config-2 $(DESTDIR)/usr/share/X11/xkb

	# generate dconf data for gnome-initial-setup (picked up by
	# hooks/002.4-configure-system-setup-tool.chroot)
	/usr/bin/dconf compile init-default.compiled $(CRAFT_PROJECT_DIR)/dconf-init-data
	/bin/mv init-default.compiled $(DESTDIR)/

	# create install-data for hooks
	mkdir -p $(DESTDIR)/install-data
	$(CRAFT_PROJECT_DIR)/generate-connections.py $(CRAFT_PROJECT_DIR)/snap-connections.txt $(DESTDIR)/usr/libexec/snap-connections.sh

	set -eux;						\
	export SNAP_BUILD_VARIANT="";				\
	. "$$CRAFT_STAGE"/build-env;			\
	for f in ./hooks/[0-9]*.chroot; do			\
		base="$$(basename "$${f}")";			\
		cp -a "$${f}" $(DESTDIR)/install-data/;		\
		chroot $(DESTDIR) "/install-data/$${base}";	\
		rm "$(DESTDIR)/install-data/$${base}";		\
	done
	rm -rf $(DESTDIR)/install-data

	set -eux;						\
	export SNAP_BUILD_VARIANT="";				\
	. "$$CRAFT_STAGE"/build-env;			\
	for f in ./hooks-build/[0-9]*.build; do			\
		"$$f" $(DESTDIR);				\
	done

	# remove the auth file again
	rm -f $(DESTDIR)/etc/apt/auth.conf.d/01-fips.conf

	# xdg-document-portal is now shipped confined as a snap dbus-activated
	# daemon (ubuntu-desktop-session's xdg-document-portal app), using a
	# privileged fuse-broker + fusermount3 shim (via the fuse-device
	# interface) to perform its FUSE mount, because fusermount3's setuid
	# mechanism cannot work on this nosuid rootfs. Remove the stock
	# unconfined unit/dbus-activation files so systemd doesn't refuse to
	# start due to two units claiming the same
	# BusName=org.freedesktop.portal.Documents, and so nothing races the
	# snap's own confined instance for the bus name.
	rm -f $(DESTDIR)/usr/lib/systemd/user/xdg-document-portal.service
	rm -f $(DESTDIR)/usr/share/dbus-1/services/org.freedesktop.portal.Documents.service

	# see https://github.com/systemd/systemd/blob/v247/src/shared/clock-util.c#L145
	touch $(DESTDIR)/usr/lib/clock-epoch

	# Hooks can remove files that were pulled in by chisel dependencies.
	# Reconcile manifest.wall so it reflects the final rootfs contents.
	python3 ./tools/refresh-manifest.py "$(DESTDIR)" --exclude-python

.PHONY: check
check:
	# exclude "useless cat" from checks, while useless they also make
	# some code more readable
	shellcheck -e SC2002 hooks/*

.PHONY: test
test:
	# run tests - each hook should have a matching ".test" file
	set -ex; if [ ! -d $(TESTDIR) ]; then \
		echo "no $(TESTDIR) found, please build the tree first "; \
		exit 1; \
	fi
	set -ex; for f in $$(pwd)/hook-tests/[0-9]*.test; do \
			if !(cd $(TESTDIR) && $$f); then \
				exit 1; \
			fi; \
	done

# Display a report of files that are (still) present in /etc
.PHONY: etc-report
etc-report:
	cd stage && find etc/
	echo "Amount of cruft in /etc left: `find stage/etc/ | wc -l`"

