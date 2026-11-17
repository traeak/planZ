//! The runes of the keys that are not characters.
//! from /sys/include/keyboard.h (the constants; initkeyboard and the
//! rest are libdraw's and not here)

pub const KF = 0xF000; // Rune: beginning of private Unicode space
pub const Spec = 0xF800;
pub const PF = Spec | 0x20; // num pad function key
pub const Kview = Spec | 0x00; // view (shift window up)
// KF|1, KF|2, ..., KF|0xC is *respectively* F1, F2, ..., F12
pub const Khome = KF | 0x0D;
pub const Kup = KF | 0x0E;
pub const Kdown = Kview;
pub const Kpgup = KF | 0x0F;
pub const Kprint = KF | 0x10;
pub const Kleft = KF | 0x11;
pub const Kright = KF | 0x12;
pub const Kpgdown = KF | 0x13;
pub const Kins = KF | 0x14;

pub const Kalt = KF | 0x15;
pub const Kshift = KF | 0x16;
pub const Kctl = KF | 0x17;

pub const Kend = KF | 0x18;
pub const Kscroll = KF | 0x19;
pub const Kscrolloneup = KF | 0x20;
pub const Kscrollonedown = KF | 0x21;

// multimedia keys - no refunds
pub const Ksbwd = KF | 0x22; // skip backwards
pub const Ksfwd = KF | 0x23; // skip forward
pub const Kpause = KF | 0x24; // play/pause
pub const Kvoldn = KF | 0x25; // volume decrement
pub const Kvolup = KF | 0x26; // volume increment
pub const Kmute = KF | 0x27; // (un)mute
pub const Kbrtdn = KF | 0x28; // brightness decrement
pub const Kbrtup = KF | 0x29; // brightness increment

pub const Ksoh = 0x01;
pub const Kstx = 0x02;
pub const Ketx = 0x03;
pub const Keof = 0x04;
pub const Kenq = 0x05;
pub const Kack = 0x06;
pub const Kbs = 0x08;
pub const Knack = 0x15;
pub const Ketb = 0x17;
pub const Kdel = 0x7f;
pub const Kesc = 0x1b;

pub const Kbreak = Spec | 0x61;
pub const Kcaps = Spec | 0x64;
pub const Knum = Spec | 0x65;
pub const Kmiddle = Spec | 0x66;
pub const Kaltgr = Spec | 0x67;
pub const Kmod4 = Spec | 0x68;
pub const Kmouse = Spec | 0x100;
