// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

/* This file is designed specifically to be included by other source files to
   implement missing (or duplicate) functionality without exposing internal
   details in header files. */

#ifdef TR_CRYPTO_X509_FALLBACK

#include "libtransmission/crypto-utils.h"

tr_x509_store_t tr_ssl_get_x509_store(tr_ssl_ctx_t /*handle*/)
{
    return nullptr;
}

bool tr_x509_store_add(tr_x509_store_t /*handle*/, tr_x509_cert_t /*cert*/)
{
    return false;
}

tr_x509_cert_t tr_x509_cert_new(void const* /*der*/, size_t /*der_length*/)
{
    return nullptr;
}

void tr_x509_cert_free(tr_x509_cert_t /*handle*/)
{
}

#else

extern "C" __attribute__((used)) char const tr_crypto_fallback_empty_tu = 0;

#endif /* TR_CRYPTO_X509_FALLBACK */
