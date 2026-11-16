//! from libauth/auth_attr.c

const auth = @import("libauth.zig");

/// The attributes of the conversation rpc is in, from factotum.
pub fn auth_attr(rpc: *auth.AuthRpc) ?*auth.Attr {
    if (auth.auth_rpc(rpc, "attr", "") != .ARok)
        return null;
    return auth.parseattr(rpc.arg);
}
