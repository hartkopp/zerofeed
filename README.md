# zerofeed

Zerofeed scripting for OpenDTU / Tasmota / OpenWrt

Zero feed script to make sure the solar modules are reducing their output
to (ideally) not push any energy into the public network.

Inspired by https://github.com/tbnobody/OpenDTU/blob/master/docs/Web-API.md

Needs OpenDTU and the Tasmota smart meter IoT devices in your WLAN and is
intended to be executed on an OpenWrt router (install curl & jq packages).

Use at your own risk! Especially I don't know if the inverter is fit for
this purpose as all this functionality was reverse engineered by the
fabulous OpenDTU developers. I simply rely on their work here.
