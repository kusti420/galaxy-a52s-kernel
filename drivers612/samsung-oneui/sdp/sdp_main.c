// SPDX-License-Identifier: GPL-2.0-only
/*
 * Samsung Knox SDP ("Sensitive Data Protection") kernel side for GKI android16-6.12 as one module.
 * The parts are the 5.4 A52s kernel's security/sdp sources (built in there, four initcalls); here one
 * init/exit in the 5.4 link order. See SDP.md for what a module cannot provide (fs/crypto/sdp).
 */
#include <linux/module.h>
#include <sdp/dek_common.h>
#include "sdp_main.h"

static int __init sdp_mod_init(void)
{
	int ret;

	ret = sdp_crypto_init();
	if (ret)
		return ret;
	ret = dek_init();
	if (ret)
		goto e_crypto;
	ret = pub_crypto_mod_init();
	if (ret)
		goto e_dek;
	ret = sdp_fs_handler_mod_init();
	if (ret)
		goto e_pub;
	return 0;
e_pub:
	pub_crypto_mod_exit();
e_dek:
	dek_exit();
e_crypto:
	sdp_crypto_exit();
	return ret;
}

static void __exit sdp_mod_exit(void)
{
	sdp_fs_handler_mod_exit();
	pub_crypto_mod_exit();
	dek_exit();
	sdp_crypto_exit();
}

module_init(sdp_mod_init);
module_exit(sdp_mod_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Samsung Knox SDP DEK driver (dek_evt/dek_req/dek_log, netlink 28/29) for GKI 6.12");
