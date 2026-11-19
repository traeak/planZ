//! USB keyboard/mouse constants
//! from nusb/kb/hid.h

pub const Stack = 32 * 1024;
pub const Nkey = 64;

// HID class subclass protocol ids
pub const PtrCSP = 0x020103; // mouse.boot.hid
pub const HidCSP = 0x000003; // could be a trackpoint
pub const PtrNonBootCSP = 0x020003;
pub const KbdCSP = 0x010103; // keyboard.boot.hid

// Requests
pub const Getreport = 0x01;
pub const Setreport = 0x09;
pub const Getproto = 0x03;
pub const Setidle = 0x0a;
pub const Setproto = 0x0b;

// protocols for SET_PROTO request
pub const Bootproto = 0;
pub const Reportproto = 1;

// protocols for SET_REPORT request
pub const Reportout = 0x0200;

// USB HID report descriptor item tags

// main items
pub const Input = 8;
pub const Output = 9;
pub const Collection = 10;
pub const Feature = 11;

pub const CollectionEnd = 12;

// global items
pub const UsagPg = 0;
pub const LogiMin = 1;
pub const LogiMax = 2;
pub const PhysMin = 3;
pub const PhysMax = 4;
pub const UnitExp = 5;
pub const UnitTyp = 6;
pub const RepSize = 7;
pub const RepId = 8;
pub const RepCnt = 9;

pub const Push = 10;
pub const Pop = 11;

// local items
pub const Usage = 0;
pub const UsagMin = 1;
pub const UsagMax = 2;
pub const DesgIdx = 3;
pub const DesgMin = 4;
pub const DesgMax = 5;
pub const StrgIdx = 6;
pub const StrgMin = 7;
pub const StrgMax = 8;

pub const Delim = 9;

// main item flags
pub const Fdata = 0 << 0;
pub const Fconst = 1 << 0;
pub const Farray = 0 << 1;
pub const Fvar = 1 << 1;
pub const Fabs = 0 << 2;
pub const Frel = 1 << 2;
pub const Fnowrap = 0 << 3;
pub const Fwrap = 1 << 3;
pub const Flinear = 0 << 4;
pub const Fnonlin = 1 << 4;
pub const Fpref = 0 << 5;
pub const Fnopref = 1 << 5;
pub const Fnonull = 0 << 6;
pub const Fnullst = 1 << 6;
