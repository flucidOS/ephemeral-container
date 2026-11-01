PREFIX ?= /usr
BINDIR ?= $(PREFIX)/bin
LIBEXECDIR ?= $(PREFIX)/libexec/ec
SHAREDIR ?= $(PREFIX)/share/ephemeral-container
SYSCONFDIR ?= /etc

.PHONY: all install check test clean

all:
	@echo "ephemeral-container (ec) ready. Run 'make check' or 'make install DESTDIR=...'"

install:
	install -d -m 0755 $(DESTDIR)$(BINDIR)
	install -d -m 0755 $(DESTDIR)$(LIBEXECDIR)
	install -d -m 0755 $(DESTDIR)$(SHAREDIR)
	install -d -m 0700 $(DESTDIR)$(SYSCONFDIR)/flucid/mok
	install -m 0755 bin/ec $(DESTDIR)$(BINDIR)/ec
	install -m 0755 libexec/ec-host-engine $(DESTDIR)$(LIBEXECDIR)/ec-host-engine
	install -m 0755 libexec/ec-container-finalize $(DESTDIR)$(LIBEXECDIR)/ec-container-finalize
	install -m 0644 share/ephemeral-container/Containerfile.seal $(DESTDIR)$(SHAREDIR)/Containerfile.seal
	install -m 0644 share/ephemeral-container/ec-profile.sh $(DESTDIR)$(SHAREDIR)/ec-profile.sh

check test:
	./tests/run-tests.sh

clean:
	@true
