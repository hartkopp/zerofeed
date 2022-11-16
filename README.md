# zerofeed

Zerofeed scripting for OpenDTU / Tasmota / OpenWrt

Zero feed script to make sure the solar modules are reducing their output
to (ideally) not push any energy into the public network.

Inspired by https://github.com/tbnobody/OpenDTU/blob/master/docs/Web-API.md

Needs OpenDTU and the Tasmota smart meter IoT devices in your WLAN and is
intended to be executed on an OpenWrt router (install curl & jq packages).

Use at your own risk! Especially I don't know if the inverter is fit for
this purpose as all this functionality was reverse engineered by the
fabulous OpenDTU developers. I simply rely on their amazing work here.

The script `zerofeed-dbg.sh` contains extensive debug output which was used
during the development. The script `zerofeed.sh` should be completely silent
to not bloat any logfiles. `zerofeed-dbg.sh` is the main source code.

Create the 'release' script file without debug output with:
`grep -v echo zerofeed-dbg.h > zerofeed.sh`

The script has several options to be adapted to your environment:

SmartMeter IP (Tasmota) (update for your local network setup)
SMIP=192.168.60.7

DTU IP (OpenDTU) (update for your local network setup)
DTUIP=192.168.60.5

DTU default admin user access (from OpenDTU installation)
DTUUSER="admin:openDTU42"

DTU serial number (insert your inverter SN here)
DTUSN=116180400144

Additionally there are some values to tweak the power control process:

reduce safety margin from inverter by increasing this value
ABSLIMITOFFSET=50

threshold to trigger the LASTLIMIT increase
SMPWRTHRES=80

minimum solar power (Watt) before starting the power control
SOLMINPWR=100

These values are estimations the work fine in my environment.
