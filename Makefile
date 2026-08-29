SOURCES := $(shell find src/amqproxy -name '*.cr' 2> /dev/null)
ifeq ($(shell uname -s),Darwin)
LDFLAGS ?= -Wl,-dead_strip_dylibs
else
LDFLAGS ?= -Wl,-O1 -Wl,--as-needed -Wl,-z,relro -Wl,-z,now -pie
endif
CRYSTAL_FLAGS ?= --release
override CRYSTAL_FLAGS += --error-on-warnings --link-flags="$(LDFLAGS)" --stats

.PHONY: all
all: bin/amqproxy

bin/%: src/%.cr $(SOURCES) lib | bin
	crystal build $< -o $@ $(CRYSTAL_FLAGS)

lib: shard.yml shard.lock
	shards install --production

bin man1:
	mkdir -p $@

man1/amqproxy.1: bin/amqproxy | man1
	help2man -Nn "connection pool for AMQP connections" $< -o $@

.PHONY: deps
deps: lib

bin/ameba: lib/ameba | bin
	crystal build lib/ameba/bin/ameba.cr -o $@

lib/ameba: shard.yml shard.lock
	shards install

.PHONY: lint
lint: bin/ameba
	$< src/ spec/

.PHONY: test
test: lib
	crystal spec

.PHONY: format
format:
	crystal tool format --check

DESTDIR :=
PREFIX := /usr
BINDIR := $(PREFIX)/bin
DOCDIR := $(PREFIX)/share/doc
MANDIR := $(PREFIX)/share/man
SYSCONFDIR := /etc
UNITDIR := /lib/systemd/system

.PHONY: install
install: bin/amqproxy man1/amqproxy.1 config/example.ini extras/amqproxy.service README.md CHANGELOG.md
	install -D -m 0755 -t $(DESTDIR)$(BINDIR) bin/amqproxy
	install -D -m 0644 -t $(DESTDIR)$(MANDIR)/man1 man1/amqproxy.1
	install -D -m 0644 -t $(DESTDIR)$(UNITDIR) extras/amqproxy.service
	install -D -m 0644 -t $(DESTDIR)$(DOCDIR)/amqproxy README.md
	install -D -m 0644 config/example.ini $(DESTDIR)$(SYSCONFDIR)/amqproxy.ini
	install -D -m 0644 CHANGELOG.md $(DESTDIR)$(DOCDIR)/amqproxy/changelog

.PHONY: uninstall
uninstall:
	$(RM) $(DESTDIR)$(BINDIR)/amqproxy
	$(RM) $(DESTDIR)$(MANDIR)/man1/amqproxy.1
	$(RM) $(DESTDIR)$(SYSCONFDIR)/amqproxy/amqproxy.ini
	$(RM) $(DESTDIR)$(UNITDIR)/amqproxy.service
	$(RM) $(DESTDIR)$(DOCDIR)/amqproxy/{README.md,changelog}
	$(RM) -r $(DESTDIR)$(DOCDIR)/amqproxy

.PHONY: clean
clean:
	rm -rf bin
