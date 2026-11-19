/*
 * The stock half of planZ's test of the USB programs' library
 * (nusb/lib): built in the guest with the library's own files,
 *	cp /sys/src/cmd/nusb/lib/^(usb.h dev.c dump.c parse.c) .
 *	6c -FTVw usbtest.c dev.c dump.c parse.c && 6l -o usbtest.stock usbtest.6 dev.6 dump.6 parse.6
 * and run on the devices of usbfake (tools/usbzig.rc).  usbtest.zig
 * is the other half and prints the same.
 *
 * usage: usbtest [ devid ... ]
 * With no device it prints the names of the classes.
 */
#include <u.h>
#include <libc.h>
#include <thread.h>
#include "usb.h"

void
main(int argc, char **argv)
{
	Dev *d, *epd, *epd2;
	Usbdev *ud;
	Ep *ep;
	Desc *dd;
	Conf *c;
	Iface *ifc;
	uchar buf[8];
	char *s;
	int i, mode;

	fmtinstall('U', Ufmt);
	fmtinstall('H', encodefmt);
	quotefmtinstall();
	ARGBEGIN{
	case 'd':
		usbdebug++;
		break;
	}ARGEND
	if(argc == 0){
		for(i = 0; i < 256; i++)
			print("%d %s\n", i, classname(i));
		exits(nil);
	}
	for(; argc > 0; argc--, argv++){
		d = getdev(*argv);
		if(d == nil){
			print("%s: getdev: %r\n", *argv);
			continue;
		}
		ud = d->usb;
		print("%s: dir %s id %d hname %s usb3 %d maxpkt %d depth %d\n",
			*argv, d->dir, d->id, d->hname, d->isusb3, d->maxpkt, d->depth);
		print("ver %x csp %lux vid %x did %x dno %x class %d nconf %d sid %d %d %d\n",
			ud->ver, ud->csp, ud->vid, ud->did, ud->dno, ud->class, ud->nconf,
			ud->vsid, ud->psid, ud->ssid);
		print("%U", d);
		for(i = 0; i < nelem(ud->ep); i++)
			for(ep = ud->ep[i]; ep != nil; ep = ep->next)
				print("ep[%d] id %d dir %d type %d attrib %x pollival %d maxpkt %d ntds %d conf %d iface %d alt %d\n",
					i, ep->id, ep->dir, ep->type, ep->attrib, ep->pollival,
					ep->maxpkt, ep->ntds,
					ep->conf != nil? ep->conf->cval: -1,
					ep->iface != nil? ep->iface->id: -1,
					ep->iface != nil? ep->iface->alt: -1);
		for(i = 0; i < nelem(ud->ddesc) && (dd = ud->ddesc[i]) != nil; i++)
			print("ddesc %d conf %d iface %d ep %d: %.*H\n", i, dd->conf->cval,
				dd->iface != nil? dd->iface->id: -1,
				dd->ep != nil? dd->ep->id: -1,
				dd->data.bLength, &dd->data);

		s = loaddevstr(d, 2);
		print("string 2: %s\n", s);
		free(s);
		s = loaddevstr(d, 0);
		print("string 0: %s\n", s);
		free(s);
		s = loaddevstr(d, 99);
		print("string 99: %s\n", s);
		free(s);

		for(i = 1; i < nelem(ud->ep); i++){
			ep = ud->ep[i];
			if(ep == nil)
				continue;
			epd = openep(d, ep);
			if(epd == nil){
				print("openep %d: %r\n", ep->id);
				continue;
			}
			print("openep %d: dir %s id %d maxpkt %d\n", ep->id, epd->dir, epd->id, epd->maxpkt);
			mode = ORDWR;
			if(ep->dir == Ein)
				mode = OREAD;
			if(ep->dir == Eout)
				mode = OWRITE;
			print("opendevdata %d\n", opendevdata(epd, mode) >= 0);
			print("unstall %d\n", unstall(d, epd, ep->dir));
			print("%U", epd);
			/* it is there now, and is opened */
			epd2 = openep(d, ep);
			print("again %d\n", epd2 != nil);
			closedev(epd2);
			closedev(epd);
		}
		c = ud->conf[0];
		if(c != nil){
			print("setconf %d\n", setconf(d, c));
			for(i = 0; i < nelem(c->iface); i++)
				for(ifc = c->iface[i]; ifc != nil; ifc = ifc->next)
					print("setalt %d %d: %d\n", ifc->id, ifc->alt, setalt(d, ifc));
		}
		print("devctl %d\n", devctl(d, "name %s%d", "x", 7));
		werrstr("none");
		i = usbcmd(d, Rd2h|Rvendor|Rdev, 0x55, 1, 2, buf, 4);
		print("usbcmd %d: %r\n", i);
		closedev(d);
	}
	exits(nil);
}
