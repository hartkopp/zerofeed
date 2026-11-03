# zerofeed JSON data and Web-UI display on OpenWrt

The script `zerofeedjson.sh` provides the current state of the power
control as JSON file `/var/run/zerofeed.json`. A second instance of the
OpenWrt web server `uhttpd` serves this file together with a web page
(`openwrt/solar/index.html`) that displays the data on a smartphone or
any other browser in the local network.

The web page has two views:

- a normal view with total solar power, grid power, house consumption,
  today's yield, the power and limits of every inverter, a 60 minutes
  history chart and the smart meter readings
- a large view (`#gross`) for a phone in landscape orientation that
  shows solar power, grid power and house consumption in big digits,
  readable from a distance of several meters

The instructions have been tested with OpenWrt 25.12, which uses `apk`
as package manager.

Commands marked with *PC* are executed in the cloned repository
directory, commands marked with *Router* are executed on the router
(`ssh root@<router-ip>`).

## Components

| Component | Path on the router | Source in this repository |
|---|---|---|
| Power control script (with JSON output) | `/usr/bin/zerofeed.sh` | `zerofeedjson.sh` |
| Start/stop script (autostart) | `/etc/init.d/zerofeed` | `openwrt/zerofeed` |
| Installation/check script | `/usr/bin/re_install_zerofeed.sh` | `openwrt/re_install_zerofeed.sh` |
| Web page | `/www/solar/index.html` | `openwrt/solar/index.html` |
| Symlink to the live data | `/www/solar/zerofeed.json` -> `/var/run/zerofeed.json` | created by the installation script |
| Web server instance `solar` | `/etc/config/uhttpd` | created by the installation script |
| uhttpd configuration before zerofeed | `/etc/uhttpd-pre-zerofeed` | created by the installation script |
| Default uhttpd configuration of the image | `/etc/uhttpd-default-zerofeed` | copy of `/rom/etc/config/uhttpd` |
| Packages | `bash`, `curl`, `jq` | installed by the installation script |

`/var/run/zerofeed.json` is located in RAM and is rewritten by the
script after every control step. Until the script has written the file
for the first time, the web page shows "Keine Daten".

The script reads the power of the currently controlled inverter in every
control loop. The power values of the other inverters are read round
robin (one inverter per control loop), which adds at most one OpenDTU
request per control loop, regardless of the number of inverters.

## The installation script

`re_install_zerofeed.sh` performs the initial installation and checks
(and repairs) the installation at any time, e.g. after an OpenWrt system
upgrade. It can be executed multiple times. Every step prints `OK`,
`FIXED`, `INFO` or `ERROR`:

1. stop a running zerofeed process (and wait until it is gone)
2. install the missing packages `bash`, `curl` and `jq` (`apk` or `opkg`)
3. install `/usr/bin/zerofeed.sh`, `/etc/init.d/zerofeed` and
   `/usr/bin/re_install_zerofeed.sh` from the uploaded files
4. create `/www/solar`, install `index.html` and the symlink to the JSON
   data
5. create the uhttpd instance `solar` (HTTP port 81 redirected to HTTPS
   port 8443 with the certificate of LuCI) and (re)start uhttpd when
   needed
6. save the uhttpd configuration before zerofeed and the default uhttpd
   configuration of the image, report a changed default of the image
7. add all files to `/etc/sysupgrade.conf` to keep them on a system
   upgrade
8. enable the autostart and start zerofeed

The uploaded files are taken from the directory of the script (e.g.
`/tmp`). The init script, the web page and the installation script are
updated when the uploaded file differs. Your configured
`/usr/bin/zerofeed.sh` and an existing uhttpd instance `solar` are not
changed - unless the option `-f` is given:

- `-f` overwrites `/usr/bin/zerofeed.sh` with the uploaded
  `zerofeedjson.sh` (upload a configured file, as your configuration in
  `/usr/bin/zerofeed.sh` gets lost) and recreates the uhttpd instance
  `solar` with the default values.
- `-u` accepts the current default uhttpd configuration of the image
  after a reported change (see *New default uhttpd configuration*).

The script uses `/bin/sh` as `bash` is not available after a system
upgrade.

## Initial installation

Adapt `SMIP`, `DTUIP`, `DTUUSER`, `DTUSN` and the array sizes in
`zerofeedjson.sh` to your environment (see section *Configuration* in the
top level [README](../README.md)). You can also do this after the
installation in `/usr/bin/zerofeed.sh` on the router.

Upload the files to `/tmp` on the router (*PC*). `scp -O` is needed as
OpenWrt does not provide an SFTP server by default:

```
scp -O zerofeedjson.sh openwrt/zerofeed openwrt/solar/index.html openwrt/re_install_zerofeed.sh root@<router-ip>:/tmp/
```

Run the installation (*Router*):

```
sh /tmp/re_install_zerofeed.sh
```

When `/usr/bin/zerofeed.sh` has been changed after the installation,
restart zerofeed with `/etc/init.d/zerofeed stop` and
`/etc/init.d/zerofeed start`.

## Update

Upload the new files to `/tmp` as for the initial installation and run
`sh /tmp/re_install_zerofeed.sh` (or `sh /tmp/re_install_zerofeed.sh -f`
to replace `/usr/bin/zerofeed.sh` as well).

## Usage

- Normal view: `https://<router-ip>:8443/`
- Large view: `https://<router-ip>:8443/#gross`

On the first access the browser warns about the self-signed certificate
(as with LuCI). Accept the warning to continue.

The page polls `zerofeed.json` every 5 seconds while it is visible. Data
older than 2 minutes is shown as outdated; the large view then shows the
solar power as "offline" with the time of the last data.

Buttons in the page header switch between the normal and the large view
and between light and dark mode. Without a selection the page follows
the light/dark setting of the device. The selection is stored in the
browser.

Hints for a phone used as permanent display:

- Open the large view and add it to the home screen ("Add to Home
  screen"). The large view can then be started directly.
- The large view requests a screen wake lock to keep the display on.
  This is only possible via HTTPS. The state is shown next to the
  buttons in the upper right corner ("Display bleibt an" when active).
  If the wake lock is not available, keep the display on with the phone
  settings (e.g. Android developer option "Stay awake" while charging).
- On Android the large view offers a fullscreen button. The buttons hide
  after 5 seconds and reappear when tapping the screen.
- The power history of the last 60 minutes is collected by the browser
  while the page is open.

## System upgrade (sysupgrade)

The installation script has added all files to `/etc/sysupgrade.conf`.
When the settings are kept on the upgrade ("Keep settings" in LuCI,
which is the default, or `sysupgrade` without `-n`), the files and the
uhttpd configuration are restored after the upgrade. Not restored are
the packages `bash`, `curl` and `jq` and the autostart link.

Before the upgrade you can check which files would be kept (*Router*):

```
sysupgrade -l | grep -E 'zerofeed|solar|uhttpd'
```

After the upgrade run (*Router*):

```
re_install_zerofeed.sh
```

The script installs the packages (an internet connection is needed),
enables the autostart and starts zerofeed.

### New default uhttpd configuration

A kept `/etc/config/uhttpd` is not replaced by a new default
configuration of the upgraded image. Therefore `re_install_zerofeed.sh`
saves the default of the image (`/rom/etc/config/uhttpd`) as
`/etc/uhttpd-default-zerofeed` on the installation. After a system
upgrade it compares the default of the new image with this copy and
reports the changed lines of the default as `INFO`, e.g.:

```
INFO   the default uhttpd configuration of the image has changed:
INFO     - defaults: option days '730'
INFO     + defaults: option days '397'
INFO     (- old default, + new default; format 'section: option value')
INFO     apply the changes to /etc/config/uhttpd if needed (e.g. with uci set)
INFO     then accept the new default: re_install_zerofeed.sh -u
```

The configuration is not changed by the script. Apply the changes you
want to take over, e.g. (*Router*):

```
uci set uhttpd.defaults.days='397'
uci commit uhttpd
```

Then accept the new default, so that the change is not reported again:

```
re_install_zerofeed.sh -u
```

The script compares the defaults of the images and not your
configuration with the default, as some options are added to the
configuration by packages on the first boot (e.g. `ucode_prefix` and
`ubus_prefix` of LuCI). Therefore copying `/rom/etc/config/uhttpd` to
`/etc/config/uhttpd` is no good idea: LuCI would not work anymore.

New default files from package upgrades (`/etc/config/uhttpd.apk-new`,
`/etc/config/uhttpd-opkg`) are reported as `INFO` as well.

The script shows the changed lines itself as the `diff` tool is not
installed by default. For a complete comparison of the files install the
package `diffutils`.

### Packages in the image

When building the image with the OpenWrt Firmware Selector or `owut`,
you can add `bash curl jq` to the package list. Then only the autostart
has to be enabled by `re_install_zerofeed.sh`.

## Removal

The configuration of uhttpd before the installation of zerofeed is
saved in `/etc/uhttpd-pre-zerofeed` (*Router*):

```
/etc/init.d/zerofeed stop
/etc/init.d/zerofeed disable
cp /etc/uhttpd-pre-zerofeed /etc/config/uhttpd
/etc/init.d/uhttpd restart
rm -rf /usr/bin/zerofeed.sh /etc/init.d/zerofeed /usr/bin/re_install_zerofeed.sh /www/solar /etc/uhttpd-pre-zerofeed /etc/uhttpd-default-zerofeed
```

Remove the zerofeed entries from `/etc/sysupgrade.conf` as well.
