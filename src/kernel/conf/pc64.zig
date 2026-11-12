//! Kernel configuration for the amd64 PC.
//! Stands in for 9/pc64/pc64 (the configuration file) and the tables
//! that 9/port/mkdevc generates from it.
//!
//! The order matters only for the first entry: channel type 0 must be
//! the root device, whose close does nothing, because a channel that
//! fails before it is given to a device is closed as type 0.

const devmod = @import("../port/dev.zig");

pub const devtab = [_]*const devmod.Dev{
    &@import("../port/devroot.zig").rootdevtab,
    &@import("../port/devcons.zig").consdevtab,
    &@import("../port/devenv.zig").envdevtab,
    &@import("../port/devpipe.zig").pipedevtab,
    &@import("../port/devsrv.zig").srvdevtab,
    &@import("../port/devdup.zig").dupdevtab,
    &@import("../port/devproc.zig").procdevtab,
    &@import("../port/devmnt.zig").mntdevtab,
    &@import("../port/devuart.zig").uartdevtab,
    &@import("../arch/amd64/devrtc.zig").rtcdevtab,
    &@import("../port/devswap.zig").swapdevtab,
    &@import("../port/devsd.zig").sddevtab,
    &@import("../port/devether.zig").etherdevtab,
    &@import("../ip/devip.zig").ipdevtab,
    &@import("../port/devcap.zig").capdevtab,
    &@import("../port/devtls.zig").tlsdevtab,
    &@import("../port/devusb.zig").usbdevtab,
    &@import("../port/devshr.zig").shrdevtab,
    &@import("../port/devdraw.zig").drawdevtab,
    &@import("../port/devmouse.zig").mousedevtab,
    &@import("../arch/amd64/devkbd.zig").kbddevtab,
    &@import("../port/devpnp.zig").pnpdevtab,
    &@import("../port/devaudio.zig").audiodevtab,
};

/// Let each driver announce itself to the device that will use it;
/// called once, before the devices are reset.  What mkdevc generates
/// as links() from the "link" section of the configuration.
pub fn links() void {
    devsd.sdifc = &sdifc_list;
    @import("../port/ethervirtio10.zig").ethervirtio10link();
    @import("../port/ether8125.zig").ether8125link();
    @import("../port/usbxhcipci.zig").usbxhcipcilink();
    @import("../port/audiohda.zig").audiohdalink();
    devip.ipprotoinit = &ipprotoinit;
    @import("../ip/ethermedium.zig").ethermediumlink();
    @import("../ip/loopbackmedium.zig").loopbackmediumlink();
    @import("../ip/netdevmedium.zig").netdevmediumlink();
}

const devip = @import("../ip/devip.zig");
const Fs = @import("../ip/ipdat.zig").Fs;

/// The protocols of the IP stack, in the order of 9/pc64/pc64.
const ipprotoinit = [_]*const fn (*Fs) void{
    @import("../ip/tcp.zig").tcpinit,
    @import("../ip/udp.zig").udpinit,
    @import("../ip/ipifc.zig").ipifcinit,
    @import("../ip/icmp.zig").icmpinit,
    @import("../ip/icmp6.zig").icmp6init,
};

const devsd = @import("../port/devsd.zig");

const sdifc_list = [_]*const devsd.SDifc{
    &@import("../port/sdvirtio10.zig").sdvirtio10ifc,
    &@import("../port/sdnvme.zig").sdnvmeifc,
    &@import("../port/sdiahci.zig").sdiahciifc,
};
