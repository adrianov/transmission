#pragma once

#include <libtransmission/quark.h>

struct tr_session;

void gtr_apply_session_pref(tr_session* session, tr_quark key);
