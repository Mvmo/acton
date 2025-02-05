include common.mk
CHANGELOG_VERSION=$(shell grep '^\#\# \[[0-9]' CHANGELOG.md | sed 's/\#\# \[\([^]]\{1,\}\)].*/\1/' | head -n1)

ACTONC=dist/bin/actonc

# This is the version we will stamp into actonc
BUILD_TIME=$(shell date "+%Y%m%d.%-H.%-M.%-S")
ifdef BUILD_RELEASE
export VERSION_INFO?=$(VERSION)
else
export VERSION_INFO?=$(VERSION).$(BUILD_TIME)
endif

CFLAGS+=-g -I. -Wno-int-to-pointer-cast -Wno-pointer-to-int-cast
LDFLAGS+=-Llib
LDLIBS+=-lprotobuf-c -luuid -lm -lpthread

# look for jemalloc
JEM_LIB?=$(wildcard /usr/lib/x86_64-linux-gnu/libjemalloc.a)
ifneq ($(JEM_LIB),)
$(info Using jemalloc: $(JEM_LIB))
CFLAGS+=-DUSE_JEMALLOC
LDFLAGS+=-L$(dir $(JEM_LIB))
LDLIBS+=-ljemalloc
endif

ifeq ($(shell uname -s),Darwin)
LDFLAGS+=-L/usr/local/opt/util-linux/lib
LDLIBS+=-largp
endif

ifeq ($(shell uname -s),Linux)
CFLAGS += -Werror
endif

.PHONY: all
all: version-check distribution

.PHONY: help
help:
	@echo "Available make targets"
	@echo "  all     - build everything"
	@echo "  dist    - build complete distribution"
	@echo "  actonc  - build the Acton compiler"
	@echo "  backend - build the database backend"
	@echo "  rts     - build the Run Time System"
	@echo ""
	@echo "  test    - run the test suite"


.PHONY: version-check
version-check:
ifneq ($(VERSION), $(CHANGELOG_VERSION))
	$(error Version in common.mk ($(VERSION)) differs from last version in CHANGELOG.md ($(CHANGELOG_VERSION)))
endif


# /backend ----------------------------------------------
backend/actondb: backend/actondb.c lib/libActonDB.a
	$(CC) -o$@ $< $(CFLAGS) \
		$(LDFLAGS) \
		-lActonDB \
		$(LDLIBS)

backend/%.o: backend/%.c
	$(CC) -o$@ $< -c $(CFLAGS)

backend/failure_detector/%.o: backend/failure_detector/%.c
	$(CC) -o$@ $< -c $(CFLAGS)

backend/failure_detector/db_messages.pb-c.c: backend/failure_detector/db_messages.proto
	protoc-c --c_out=$@ $<

# backend tests
BACKEND_TESTS=backend/failure_detector/db_messages_test \
	backend/test/actor_ring_tests_local \
	backend/test/actor_ring_tests_remote \
	backend/test/db_unit_tests \
	backend/test/queue_unit_tests \
	backend/test/skiplist_test \
	backend/test/test_client

.PHONY: test-backend
test-backend: $(BACKEND_TESTS)
	@echo DISABLED TEST: backend/failure_detector/db_messages_test
	./backend/test/actor_ring_tests_local
	./backend/test/actor_ring_tests_remote
	./backend/test/db_unit_tests
	@echo DISABLED test: ./backend/test/queue_unit_tests
	./backend/test/skiplist_test

backend/failure_detector/db_messages_test: backend/failure_detector/db_messages_test.c lib/libActonDB.a
	$(CC) -o$@ $< $(CFLAGS) \
		$(LDFLAGS) \
		-lActonDB $(LDLIBS)

backend/test/%: backend/test/%.c lib/libActonDB.a
	$(CC) -o$@ $< $(CFLAGS) -Ibackend \
		$(LDFLAGS) -lActonDB $(LDLIBS)

backend/test/skiplist_test: backend/test/skiplist_test.c backend/skiplist.c
	$(CC) -o$@ $^ $(CFLAGS) -Ibackend \
		$(LDLIBS)

# /builtin ----------------------------------------------
ENV_FILES=$(wildcard builtin/minienv.*)
BUILTIN_HFILES=$(filter-out $(ENV_FILES),$(wildcard builtin/*.h))
BUILTIN_CFILES=$(filter-out $(ENV_FILES),$(wildcard builtin/*.c))
builtin/builtin.o: builtin/builtin.c $(BUILTIN_HFILES) $(BUILTIN_CFILES)
	$(CC) $(CFLAGS) -Wno-unused-result -c -O3 $< -o$@

builtin/minienv.o: builtin/minienv.c builtin/minienv.h builtin/builtin.o
	$(CC) $(CFLAGS) -c -O3 $< -o$@


# /compiler ----------------------------------------------
ACTONC_ALL_HS=$(wildcard compiler/*.hs compiler/**/*.hs)
ACTONC_TEST_HS=$(wildcard compiler/tests/*.hs)
ACTONC_HS=$(filter-out $(ACTONC_TEST_HS),$(ACTONC_ALL_HS))
compiler/actonc: compiler/package.yaml.in compiler/stack.yaml $(ACTONC_HS)
	cd compiler && stack build --dry-run 2>&1 | grep "Nothing to build" || \
		(sed 's,^version:.*,version:      "$(VERSION_INFO)",' < package.yaml.in > package.yaml \
		&& stack build --ghc-options -j4 \
		&& stack --local-bin-path=. install 2>/dev/null)

.PHONY: clean-compiler
clean-compiler:
	cd compiler && stack clean >/dev/null 2>&1 || true
	rm -f compiler/actonc compiler/package.yaml compiler/acton.cabal

# Building the builtin, rts and stdlib is a little tricky as we have to be
# careful about order. First comes the __builtin__.act file,
STDLIB_ACTFILES=$(wildcard stdlib/src/*.act stdlib/src/**/*.act)
STDLIB_CFILES=$(wildcard stdlib/src/*.c stdlib/src/**/*.c)
STDLIB_TYFILES=$(subst src,out/types,$(STDLIB_CFILES:.c=.ty))
STDLIB_HFILES=$(subst src,out/types,$(STDLIB_CFILES:.c=.h))
STDLIB_OFILES=$(subst src,out/release,$(STDLIB_CFILES:.c=.o))
STDLIB_ACTS=$(not-in $(STDLIB_ACTFILES),$(STDLIB_CFILES))

# __builtin__.ty is special, it even has special handling in actonc. Essentially
# all other modules depend on it, so it must be compiled first. While we use
# wildcard patterns for all other files, we have explicit targets for
# __builtin__.ty to make things work. Other .ty file targets etc depend on this,
# so we get the order right.
dist/types/__builtin__.ty: stdlib/out/types/__builtin__.ty
	@mkdir -p $(dir $@)
	cp $< $@

stdlib/out/types/__builtin__.ty: stdlib/src/__builtin__.act $(ACTONC)
	@mkdir -p $(dir $@)
	$(ACTONC) $< --stub

stdlib/out/types/%.ty: stdlib/src/%.act dist/types/__builtin__.ty $(ACTONC)
	@mkdir -p $(dir $@)
	$(ACTONC) $< --stub

stdlib/out/types/%.h: stdlib/src/%.h
	@mkdir -p $(dir $@)
	cp $< $@

stdlib/out/release/%.o: stdlib/src/%.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -Istdlib/ -Istdlib/out/ -c $< -o$@

NUMPY_CFILES=$(wildcard stdlib/c_src/numpy/*.h)
ifeq ($(shell uname -s),Linux)
NUMPY_CFLAGS+=-lbsd -ldl -lmd
endif
stdlib/out/release/numpy.o: stdlib/src/numpy.c stdlib/src/numpy.h stdlib/out/types/math.h $(NUMPY_CFILES) stdlib/out/release/math.o
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -Wno-unused-result -r -Istdlib/out/ $< -o$@ $(NUMPY_CFLAGS) stdlib/out/release/math.o

# /lib --------------------------------------------------
ARCHIVES=lib/libActon.a lib/libActonRTSdebug.a lib/libActonDB.a

# If we later let actonc build things, it would produce a libActonProject.a file
# in the stdlib directory, which we would need to join together with rts.o etc
# to form the final libActon (or maybe produce a libActonStdlib and link with?)
OFILES += builtin/builtin.o builtin/minienv.o $(STDLIB_OFILES) stdlib/out/release/numpy.o rts/empty.o rts/rts.o
lib/libActon.a: builtin/builtin.o builtin/minienv.o $(STDLIB_OFILES) stdlib/out/release/numpy.o rts/empty.o rts/rts.o
	ar rcs $@ $^

OFILES += rts/rts-debug.o
lib/libActonRTSdebug.a: rts/rts-debug.o
	ar rcs $@ $^

COMM_OFILES += backend/comm.o rts/empty.o
DB_OFILES += backend/db.o backend/queue.o backend/skiplist.o backend/txn_state.o backend/txns.o rts/empty.o
DBCLIENT_OFILES += backend/client_api.o rts/empty.o
REMOTE_OFILES += backend/failure_detector/db_messages.pb-c.o backend/failure_detector/cells.o backend/failure_detector/db_queries.o backend/failure_detector/fd.o
VC_OFILES += backend/failure_detector/vector_clock.o
BACKEND_OFILES=$(COMM_OFILES) $(DB_OFILES) $(DBCLIENT_OFILES) $(REMOTE_OFILES) $(VC_OFILES)
OFILES += $(BACKEND_OFILES)
lib/libActonDB.a: $(BACKEND_OFILES)
	ar rcs $@ $^


# /rts --------------------------------------------------
rts/rts.o: rts/rts.c rts/rts.h
	$(CC) $(CFLAGS) -Wno-int-to-void-pointer-cast \
		-Wno-unused-result \
		$(LDLIBS) \
		-c -O3 $< -o $@

rts/rts-debug.o: rts/rts.c rts/rts.h
	$(CC) $(CFLAGS) -DRTS_DEBUG -Wno-int-to-void-pointer-cast \
		-Wno-unused-result \
		$(LDLIBS) \
		-c -O3 $< -o $@

rts/empty.o: rts/empty.c
	$(CC) $(CFLAGS) -c $< -o $@

rts/pingpong: rts/pingpong.c rts/pingpong.h rts/rts.o
	$(CC) $(CFLAGS) -Wno-int-to-void-pointer-cast \
		-lutf8proc -lActonDB \
		$(LDLIBS)
		rts/rts.o \
		builtin/builtin.o \
		builtin/minienv.o \
		$< \
		-o $@


# top level targets

.PHONY: backend
backend:
	$(MAKE) -C backend

.PHONY: rts
rts: $(ARCHIVES)

.PHONY: test
test:
	$(MAKE) -C backend test
	$(MAKE) -C test

.PHONY: clean
clean: clean-compiler clean-distribution clean-backend clean-rts

.PHONY: clean-backend
clean-backend:
	rm -f $(BACKEND_OFILES) backend/actondb

.PHONY: clean-rts
clean-rts:
	rm -f $(ARCHIVES) $(OFILES) $(STDLIB_HFILES) $(STDLIB_OFILES) $(STDLIB_TYFILES)

# == DIST ==
#

$(ACTONC): compiler/actonc
	@mkdir -p $(dir $@)
	cp $< $@

# This does a little hack, first copying and then moving the file in place. This
# is to avoid an error if actondb is currently running. cp tries to open the
# file and modify it, which the Linux kernel (and perhaps others?) will prevent
# if the file to be modified is an executable program that is currently running.
# We work around it by moving / renaming the file in place instead!
dist/bin/actondb: backend/actondb
	@mkdir -p $(dir $@)
	cp $< $@.tmp
	mv $@.tmp $@

dist/builtin/%: builtin/%
	@mkdir -p $(dir $@)
	cp $< $@

dist/rts/%: rts/%
	@mkdir -p $(dir $@)
	cp $< $@

dist/types/%: stdlib/out/types/%
	@mkdir -p $(dir $@)
	cp $< $@

dist/lib/%: lib/%
	@mkdir -p $(dir $@)
	cp $< $@

dist/lib/libActon.a: lib/libActon.a
	@mkdir -p $(dir $@)
	cp $< $@

DIST_BINS=$(ACTONC) dist/bin/actondb
DIST_HFILES=dist/rts/rts.h \
	dist/builtin/minienv.h \
	$(addprefix dist/,$(BUILTIN_HFILES)) \
	$(subst stdlib/out/types,dist/types,$(STDLIB_HFILES))
DIST_TYFILES=$(subst stdlib/out/types,dist/types,$(STDLIB_TYFILES))
DIST_ARCHIVES=$(addprefix dist/,$(ARCHIVES))

.PHONY: distribution clean-distribution
distribution: $(DIST_BINS) $(DIST_HFILES) $(DIST_TYFILES) $(DIST_ARCHIVES)

clean-distribution:
	rm -rf dist

# == release ==
# This is where we take our distribution and turn it into a release tar ball
ARCH=$(shell uname -s -m | sed -e 's/ /-/' | tr '[A-Z]' '[a-z]')
GNU_TAR := $(shell ls --version 2>&1 | grep GNU >/dev/null 2>&1; echo $$?)
ifeq ($(GNU_TAR),0)
TAR_TRANSFORM_OPT=--transform 's,^dist,acton,'
else
TAR_TRANSFORM_OPT=-s ,^dist,acton,
endif

ACTONC_VERSION=$(shell $(ACTONC) --version 2>/dev/null | head -n1 | cut -d' ' -f2)
.PHONY: acton-$(ARCH)-$(ACTONC_VERSION).tar.bz2
acton-$(ARCH)-$(ACTONC_VERSION).tar.bz2:
	tar jcvf $@ $(TAR_TRANSFORM_OPT) --exclude .gitignore dist

.PHONY: release
release: distribution
	$(MAKE) acton-$(ARCH)-$(ACTONC_VERSION).tar.bz2

.PHONY: install
install:
	mkdir -p $(DESTDIR)/usr/bin $(DESTDIR)/usr/lib/acton
	cp -a dist/. $(DESTDIR)/usr/lib/acton/
	cd $(DESTDIR)/usr/bin && ln -s ../lib/acton/bin/actonc
	cd $(DESTDIR)/usr/bin && ln -s ../lib/acton/bin/actondb

.PHONY: debian/changelog
debian/changelog: debian/changelog.in CHANGELOG.md
	cat $< | sed 's/VERSION/$(VERSION_INFO)/' > $@

.PHONY: debs
debs: debian/changelog
	debuild --preserve-envvar VERSION_INFO -i -us -uc -b
