//! libauth, the client's half: the name space of a user (newns,
//! addns), mounting with authentication (amount), and the
//! conversation with factotum that proves who one is to a server
//! (auth_proxy over auth_rpc).  auth.h, and the library's functions
//! under their C names.
//! from 9front 11952's /sys/src/libauth, one file per C file in this
//! directory
//!
//! Not ported: auth_challenge.c, auth_respond.c, auth_userpasswd.c,
//! auth_getuserpasswd.c and login.c (the server's side of a login, and
//! passwords out of factotum), which nothing ported needs yet.
//!
//! DIFF (all files):
//!   - Strings are slices and failures are errors, with the C's text
//!     in the error string.
//!   - An rpc's answer (rpc.arg) is a slice of the rpc's buffer.

const std = @import("std");
const libc = @import("libc");

const attr_ = @import("attr.zig");
const rpc_ = @import("auth_rpc.zig");
const proxy_ = @import("auth_proxy.zig");
const getkey_ = @import("auth_getkey.zig");
const amount_ = @import("amount.zig");
const newns_ = @import("newns.zig");
const procsetuser_ = @import("procsetuser.zig");
const chuid_ = @import("auth_chuid.zig");
const noworld_ = @import("noworld.zig");

pub const MAXCHLEN = 256; // max challenge length
pub const MAXNAMELEN = 256; // maximum name length
pub const MD5LEN = 16;
pub const AuthRpcMax = 4096;

/// What an rpc to factotum returned.
pub const Rpc = rpc_.Rpc;
pub const AuthRpc = rpc_.AuthRpc;
pub const auth_allocrpc = rpc_.auth_allocrpc;
pub const auth_freerpc = rpc_.auth_freerpc;
pub const auth_rpc = rpc_.auth_rpc;

pub const AuthInfo = proxy_.AuthInfo;
/// Asked for a key that factotum has not got (the text is what
/// factotum wants): false to give up.
pub const AuthGetkey = *const fn (params: []const u8) bool;
pub const fauth_proxy = proxy_.fauth_proxy;
pub const auth_proxy = proxy_.auth_proxy;
pub const auth_getinfo = proxy_.auth_getinfo;
pub const auth_freeAI = proxy_.auth_freeAI;
pub const auth_getkey = getkey_.auth_getkey;

pub const amount = amount_.amount;
/// What amount and newns ask for keys with: auth_getkey unless the
/// program sets another.
pub var amount_getkey: ?AuthGetkey = getkey_.auth_getkey;

pub const newns = newns_.newns;
pub const addns = newns_.addns;
pub const newnsdebug = &newns_.newnsdebug;
pub const noworld = noworld_.noworld;
pub const procsetuser = procsetuser_.procsetuser;
pub const auth_chuid = chuid_.auth_chuid;

pub const Attr = attr_.Attr;
pub const AttrType = attr_.AttrType;
pub const attrfmt = attr_.attrfmt;
pub const copyattr = attr_.copyattr;
pub const delattr = attr_.delattr;
pub const findattr = attr_.findattr;
pub const freeattr = attr_.freeattr;
pub const mkattr = attr_.mkattr;
pub const parseattr = attr_.parseattr;
pub const strfindattr = attr_.strfindattr;
pub const auth_attr = @import("auth_attr.zig").auth_attr;
