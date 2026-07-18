# Builds the fair_dice NIF. Invoked automatically by :elixir_make during
# `mix compile`. Output goes to the app's priv/ dir so :code.priv_dir/1 finds it
# both in dev (_build/.../priv) and in a release.

PRIV_DIR = $(MIX_APP_PATH)/priv
NIF_SO   = $(PRIV_DIR)/fair_dice.so

# erl_nif.h ships inside the ERTS include dir; ask erl where that is.
ERTS_INCLUDE_DIR ?= $(shell erl -noshell -eval \
	'io:format("~ts/erts-~ts/include", [code:root_dir(), erlang:system_info(version)])' \
	-s init stop)

CFLAGS ?= -O3 -std=c11
CFLAGS += -Wall -Wextra -fPIC -I"$(ERTS_INCLUDE_DIR)"

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
	LDFLAGS += -dynamiclib -undefined dynamic_lookup
else
	LDFLAGS += -shared
endif

all: $(NIF_SO)

$(NIF_SO): c_src/fair_dice.c
	mkdir -p $(PRIV_DIR)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

clean:
	$(RM) $(NIF_SO)

.PHONY: all clean
