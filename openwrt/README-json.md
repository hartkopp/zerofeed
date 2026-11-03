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
| Web page | `/www/solar/index.html` | `openwrt/solar/index.html` |
| Symlink to the live data | `/www/solar/zerofeed.json` -> `/var/run/zerofeed.json` | created during installation |
| Web server instance `solar` | `/etc/config/uhttpd` | created with `uci` |
| Packages | `bash`, `curl`, `jq` | installed with `apk` |

`/var/run/zerofeed.json` is located in RAM and is rewritten by the
script after every control step. Until the script has written the file
for the first time, the web page shows "Keine Daten".

The script reads the power of the currently controlled inverter in every
control loop. The power values of the other inverters are read round
robin (one inverter per control loop), which adds at most one OpenDTU
request per control loop, regardless of the number of inverters.

## Initial installation

### Packages (Router)

```
apk update && apk add bash curl jq
```

### Copy the files (PC)

`scp -O` is needed as OpenWrt does not provide an SFTP server by default.

```
scp -O zerofeedjson.sh root@<router-ip>:/usr/bin/zerofeed.sh
scp -O openwrt/zerofeed root@<router-ip>:/etc/init.d/zerofeed
ssh root@<router-ip> mkdir -p /www/solar
scp -O openwrt/solar/index.html root@<router-ip>:/www/solar/index.html
```

### Permissions and configuration (Router)

```
chmod 755 /usr/bin/zerofeed.sh /etc/init.d/zerofeed
```

Adapt `SMIP`, `DTUIP`, `DTUUSER`, `DTUSN` and the array sizes in
`/usr/bin/zerofeed.sh` to your environment (see section *Configuration*
in the top level [README](../README.md)).

### Symlink for the web page (Router)

```
ln -sf /var/run/zerofeed.json /www/solar/zerofeed.json
```

### Web server instance `solar` (Router)

The instance serves `/www/solar` via HTTPS on port 8443 with the
certificate of the LuCI web interface. Requests to HTTP port 81 are
redirected to HTTPS.

```
uci batch <<'EOF'
set uhttpd.solar=uhttpd
add_list uhttpd.solar.listen_http='0.0.0.0:81'
add_list uhttpd.solar.listen_http='[::]:81'
add_list uhttpd.solar.listen_https='0.0.0.0:8443'
add_list uhttpd.solar.listen_https='[::]:8443'
set uhttpd.solar.redirect_https='1'
set uhttpd.solar.cert='/etc/uhttpd.crt'
set uhttpd.solar.key='/etc/uhttpd.key'
set uhttpd.solar.home='/www/solar'
set uhttpd.solar.rfc1918_filter='1'
set uhttpd.solar.max_requests='3'
commit uhttpd
EOF
/etc/init.d/uhttpd restart
```

These commands are intended for a new installation. When the section
`solar` already exists, `add_list` would add the ports twice. In this
case edit `/etc/config/uhttpd` directly. The resulting section looks
like this:

```
config uhttpd 'solar'
	list listen_http '0.0.0.0:81'
	list listen_http '[::]:81'
	list listen_https '0.0.0.0:8443'
	list listen_https '[::]:8443'
	option redirect_https '1'
	option cert '/etc/uhttpd.crt'
	option key '/etc/uhttpd.key'
	option home '/www/solar'
	option rfc1918_filter '1'
	option max_requests '3'
```

If you do not want HTTP at all, remove the `listen_http` lines and
`redirect_https`.

HTTPS needs the TLS library of uhttpd, which is installed when LuCI is
already reachable via HTTPS. Check with `ls /lib/libustream-ssl.so`.

No firewall changes are needed for access from the LAN, as the LAN zone
accepts connections to the router by default.

### Start zerofeed and enable the autostart (Router)

```
/etc/init.d/zerofeed enable
/etc/init.d/zerofeed start
```

### Check the installation (Router)

```
netstat -tln | grep -E ':(81|8443) '
ps | grep [z]erofeed
ls -l /www/solar /var/run/zerofeed.json
curl -sI http://127.0.0.1:81/ | grep -i location
```

The last command shows the redirect from HTTP port 81 to HTTPS.

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

### What is kept?

| Component | Kept on sysupgrade? |
|---|---|
| `/etc/config/uhttpd` (instance `solar`) | yes (all files in `/etc/config`) |
| `/etc/uhttpd.crt`, `/etc/uhttpd.key` | yes (uhttpd configuration files) |
| `/usr/bin/zerofeed.sh` (with your IPs and serial numbers) | **no**, unless listed in `/etc/sysupgrade.conf` |
| `/etc/init.d/zerofeed` | **no**, unless listed in `/etc/sysupgrade.conf` |
| Autostart link `/etc/rc.d/S95zerofeed` | **no**, unless listed in `/etc/sysupgrade.conf` |
| `/www/solar/` (web page and symlink) | **no**, unless listed in `/etc/sysupgrade.conf` |
| Packages `bash`, `curl`, `jq` | **no**, have to be installed again |
| `/var/run/zerofeed.json` | located in RAM, rewritten by the script |

### Preventive (once after the initial installation)

Add the files to the list of files to be kept (Router):

```
cat >> /etc/sysupgrade.conf <<'EOF'
/usr/bin/zerofeed.sh
/etc/init.d/zerofeed
/etc/rc.d/S95zerofeed
/www/solar/
EOF
```

Check which files would be kept on an upgrade:

```
sysupgrade -l | grep -E 'zerofeed|solar|uhttpd'
```

Keeping `/etc/rc.d/S95zerofeed` is optional. It saves the `enable` step
after the upgrade. Without the packages the script does not run anyway.

### On the upgrade

- Keep the settings ("Keep settings" in LuCI, which is the default, or
  `sysupgrade` without `-n` on the command line).
- Optional: create a backup and copy it to the PC:
  `sysupgrade -b /tmp/backup.tar.gz` (Router), then
  `scp -O root@<router-ip>:/tmp/backup.tar.gz .` (PC).
- Alternative for the packages: when building the image with the
  OpenWrt Firmware Selector or `owut`, add `bash curl jq` to the package
  list. Then the packages do not have to be installed after the upgrade.

### After the upgrade (Router)

Install the packages again (unless they are part of the image):

```
apk update && apk add bash curl jq
```

Enable the autostart (if `/etc/rc.d/S95zerofeed` was not kept) and start
zerofeed:

```
/etc/init.d/zerofeed enable
/etc/init.d/zerofeed start
```

Then run the checks from the initial installation.
