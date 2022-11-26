SOURCES := $(shell find src/amqproxy -name '*.cr' 2> /dev/null)
CRYSTAL_FLAGS := --release
override CRYSTAL_FLAGS += --debug --error-on-warnings --link-flags=-pie

.PHONY: all
all: bin/amqproxy

bin/%: src/%.cr $(SOURCES) lib | bin
	crystal build $< -o $(basename $@) $(CRYSTAL_FLAGS)

lib: shard.yml shard.lock
	shards install --production

bin man1:
	mkdir -p $@

man1/amqproxy.1: bin/amqproxy | man1
	help2man -Nn "connection pool for AMQP connections" $< -o $@

.PHONY: deps
deps: lib

.PHONY: lint
lint: lib
	lib/ameba/bin/ameba src/

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
	$(RM) $(DESTDIR)$(DOCDIR)/{README.md,changelog}

.PHONY: clean
clean:
	rm -rf bin
