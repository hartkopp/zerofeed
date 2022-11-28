# zerofeed

Zerofeed solar power control shell script for OpenDTU / Tasmota / OpenWrt

## About

Zero feed script to make sure the solar modules are reducing their output
to (ideally) not push any energy into the public network.

Inspired by https://github.com/tbnobody/OpenDTU/blob/master/docs/Web-API.md

Needs OpenDTU and the Tasmota smart meter IoT devices in your WLAN and is
intended to be executed on an OpenWrt router (install curl & jq packages).

USE AT YOUR OWN RISK! Especially I don't know if the inverter is fit for
this purpose as all this functionality was reverse engineered by the
fabulous OpenDTU developers. I simply rely on their amazing work here.

## Code

The script `zerofeed-dbg.sh` contains extensive debug output which was used
during the development. The script `zerofeed.sh` should be completely silent
to not bloat any logfiles. `zerofeed-dbg.sh` is the main source code.

Create the 'release' script file without debug output with:
`grep -v echo zerofeed-dbg.h > zerofeed.sh`

## Configuration

The script has several options to be adapted to your environment:

- SmartMeter IP (Tasmota) (update for your local network setup)<br />
`SMIP=192.168.60.7`

- DTU IP (OpenDTU) (update for your local network setup)<br />
`DTUIP=192.168.60.5`

- DTU default admin user access (from OpenDTU installation)<br />
`DTUUSER="admin:openDTU42"`

- DTU serial number (insert your inverter SN here)<br />
`DTUSN=116180400144`

## Adaption

Additionally there are some values to tweak the power control process:

- reduce safety margin from inverter by increasing this value<br />
`ABSLIMITOFFSET=0`

- threshold to trigger the SOLABSLIMIT decrease<br />
`SMPWRTHRESMIN=10`

- threshold to trigger the SOLABSLIMIT increase<br />
`SMPWRTHRESMAX=50`

- minimum solar power (Watt) before starting the power control<br />
`SOLMINPWR=100`

These values are estimations and work fine in my environment.

## Power control functionality

The following pictures were rendered (with LibreOffice Calc) from debug
values during the development phase for understanding the general concept
of the zerofeed script. The adapted values and the algorithm have been
improved after getting the raw values for these figures.

* `SOLPWR` = blue (solar power yield)
* `SMPWR` = red (smart meter power consumption from house/flat)
* `SOLLASTLIMIT` = yellow (solar limit)

### Power control example (more solar power than consumption)

This picture shows a day with good solar power (SOLPWR) yield which has to be
limited to the house/flat power consumption (SMPWR). E.g. from 13:00 - 15:00
the solar panels are limited. At 15:30 a relevant power consumer is attached
with sets the SOLLASTLIMT value to DTUMAXPWR (disabled limit).

<img src="https://github.com/hartkopp/zerofeed/blob/main/img/high-solar-yield.png" width="800">

### Power control example (low solar power mostly unlimited)

This picture shows a day with low solar power (SOLPWR) yield where the
house/flat power consumption (SMPWR) is mostly higher than the solar yield
and therefore the SOLLASTLIMT value is set to DTUMAXPWR (disabled limit) for
most of the time. From 15:00 to 15:30 the solar power exceeds the SMPWR value
and the limiter gets enabled to not feed the public network.

<img src="https://github.com/hartkopp/zerofeed/blob/main/img/low-solar-yield.png" width="800">

## Power control algorithm

### Inverter startup phase

The script first waits for `SOLMINPWR` Watts before it starts to control
the solar panel power output. This makes sure that the inverter is working
and can process requests to the power limiter. The OpenDTU always answers
requests to get the current solar power - but in the case the solar power is
zero the inverter is completely shut down and not accessible!<br />
When the inverter switches off and the `SOLPWR` value becomes zero (e.g. over
night) the script gets back to this startup phase.

### Initializing/disabling the solar power limiter

When the inverter is up and running the limit is disabled (set to 100%).
Usually the persistent power limit value is always 100% at power on time until
someone modified this value (with persistence). This script only applies
non-persistent power limitations to the inverter.

### The power control loop

The 'system power' is measured by the Tasmota smart meter interface and
provides the value of the power flow from the public network to your
house/flat (where the solar modules are connected too). This value `SMPWR`
is usually a positive value which indicates the current power consumption
of your house/flat. When the solar modules produce more energy than your
house/flat consumes the `SMPWR` can become a negative value as the power
meter measures your feeding into the public network - which we want to
avoid with this script.

We mainly have two triggers to start a power limit control action to maintain
a low power consumption between `SMPWRTHRESMIN` and `SMPWRTHRESMAX`:<br />

1. `SMPWR` is less than `SMPWRTHRESMIN`:<br />
Concept: Set the power limit for the solar panels to `SMPWR` + `SOLPWR`.
As `SMPWR` was assumed to be negative the calculated limit is less than the
current solar power output `SOLPWR` and should lead to a `SMPWR` value greater
then zero. This action is now triggered when `SMPWR` is less than
`SMPWRTHRESMIN`, therefore the calulated limit results from:
`SMPWR + SOLPWR - SMPWRTHRESMIN`. As the inverter might be conservative and
too cautious with the limit the `ABSLIMITOFFSET` value was introduced to
increase the calculated limit. The `ABSLIMITOFFSET` probably needs to be
adjusted in your setup.

2. `SMPWR` is greater than `SMPWRTHRESMAX`:<br />
The `SMPWRTHRES*` threshold values are used to reduce the power limit control
commands to the OpenDTU and the inverter. In the best case the `SMPWR` value
remains between `SMPWRTHRESMIN` and `SMPWRTHRESMAX`. When `SMPWR` gets
greater than `SMPWRTHRESMAX` the solar power limit can be safely increased by
`SMPWRTHRESMAX`. Depending on `SMPWR` we can increase the solar power limit
faster to finally remove the solar power limit. When the solar power limit
has been increased up to 100% it remains there until `SMPWR` becomes less than
`SMPWRTHRESMIN` again to restart the power limit control process.
