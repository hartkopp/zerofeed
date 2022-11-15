#!/bin/sh

# Zero feed script to make sure the solar modules are reducing their output
# to (ideally) not push any energy into the public network.

# Inspired by https://github.com/tbnobody/OpenDTU/blob/master/docs/Web-API.md

# Needs OpenDTU and the Tasmota smart meter IoT devices in your WLAN and is
# intended to be executed on an OpenWrt router (install curl & jq packages).
# Use at your own risk! Especially I don't know if the inverter is fit for
# this purpose as all this functionality was reverse engineered by the
# fabulous OpenDTU developers. I simply rely on their work here.

# Author: Oliver Hartkopp
# License: MIT

# Exit if 'curl' is not installed
test -x /usr/bin/curl || exit 0

# Exit if 'jq' is not installed
test -x /usr/bin/jq || exit 0

# Current Smart Meter Power (signed value)
# -> should become a small positive value ;-)
SMPWR=0

# Current Solar Power (unsigned value)
SOLPWR=0

# Absolute Solar Limit (unsigned value) -> SMPWR + SOLPWR + ABSLIMITOFFSET
SOLABSLIMIT=0

# reduce safety margin from inverter by increasing this value
ABSLIMITOFFSET=50

# SmartMeter IP (Tasmota) (update for your local network setup)
SMIP=192.168.60.7

# DTU IP (OpenDTU) (update for your local network setup)
DTUIP=192.168.60.5

# DTU default admin user access (from OpenDTU installation)
DTUUSER="admin:openDTU42"

# DTU serial number (insert your inverter SN here)
DTUSN=116180400144

# DTU limiter (should be this at 100% after > 0W start)
DTUNOLIMRELVAL=100
DTULIMREL=0

# minimum solar power (Watt) bevor starting the power control
SOLMINPWR=100

# limit type absolute (non persistent)
LTABSNP=0
# limit type relative (non persistent)
LTRELNP=1

getSOLPWR()
{
    SOLPWR=`curl -s http://$DTUIP/api/livedata/status | jq '.total.Power.v'`
    if [ -n "$SOLPWR" ]; then
	# remove fraction to make it an integer
	SOLPWR=${SOLPWR%.*}
    fi
}

getDTUMAXPWR()
{
    DTUMAXPWR=`curl -s http://$DTUIP/api/limit/status | jq '."'$DTUSN'".max_power'`
    if [ -n "$DTUMAXPWR" ]; then
	# remove fraction to make it an integer
	DTUMAXPWR=${DTUMAXPWR%.*}
    fi
}

getDTULIMREL()
{
    DTULIMREL=`curl -s http://$DTUIP/api/limit/status | jq '."'$DTUSN'".limit_relative'`
    if [ -n "$DTULIMREL" ]; then
	# remove fraction to make it an integer
	DTULIMREL=${DTULIMREL%.*}
    fi
}

getSMPWR()
{
    SMPWR=`curl -s http://$SMIP/cm?cmnd=status%208 | jq '.StatusSNS.LK13BE.Power_curr'`
    if [ -n "$SMPWR" ]; then
	# remove fraction to make it an integer
	SMPWR=${SMPWR%.*}
    fi
}

waitLimitSetStatusOK()
{
    SETSTATUS="no_set_status"

    while [ "$SETSTATUS" != "\"Ok\"" ]; do
	sleep 1
	SETSTATUS=`curl -s http://$DTUIP/api/limit/status | jq '."'$DTUSN'".limit_set_status'`
	echo $SETSTATUS
    done
}

while [ true ];
do

    getSOLPWR;
    getDTUMAXPWR;
    getSMPWR;
    echo "initSOLPWR="$SOLPWR
    echo "initDTUMAXPWR="$DTUMAXPWR
    echo "initSMPWR="$SMPWR

    # wait until curl succeeds
    while [ -z "$SOLPWR" ] || [ -z "$DTUMAXPWR" ] || [ -z "$SMPWR" ]; do

	echo "Wait for devices"
	sleep 2
	getSOLPWR;
	getDTUMAXPWR;
	getSMPWR;

    done

    # check if we need to remove the limiter
    getDTULIMREL;
    echo "DTULIMREL="$DTULIMREL
    if [ -z "$DTULIMREL" ]; then
	# no data -> restart process
	continue
    fi
    if [ "$DTULIMREL" -ne "$DTUNOLIMRELVAL" ]; then
	# not 100% ? -> set to 100%
	curl -u "$DTUUSER" http://$DTUIP/api/limit/config -d 'data={"serial":"'$DTUSN'", "limit_type":'$LTRELNP', "limit_value":'$DTUNOLIMRELVAL'}'
	echo
	waitLimitSetStatusOK;
    fi

    # wait for at least some remarkable solar power (SOLMINPWR)
    while [ -n "$SMPWR" ] && [ -n "$SOLPWR" ] && [ "$SOLPWR" -lt "$SOLMINPWR" ]; do

	echo "Wait for "$SOLMINPWR"W solar power"
	echo "SOLPWR="$SOLPWR
	sleep 10;
	getSOLPWR;
	getSMPWR;

    done

    LASTLIMIT=0

    # main control loop
    while [ -n "$SMPWR" ] && [ -n "$SOLPWR" ] ; do

	echo
	echo "SOLPWR="$SOLPWR
	echo "SMPWR="$SMPWR
	echo "ABSLIMITOFFSET="$ABSLIMITOFFSET

	# calculate inverter limit
	SOLABSLIMIT=$(($SMPWR + $SOLPWR + $ABSLIMITOFFSET))
	echo "SOLABSLIMIT="$SOLABSLIMIT

	# do not set limits beyond the inverter capabilities
	if [ "$SOLABSLIMIT" -gt "$DTUMAXPWR" ]; then
	    SOLABSLIMIT=$DTUMAXPWR
	    echo Limit cropped to $DTUMAXPWR
	fi
	if [ "$SOLABSLIMIT" -ne "$LASTLIMIT" ]; then
	    curl -u "$DTUUSER" http://$DTUIP/api/limit/config -d 'data={"serial":"'$DTUSN'", "limit_type":'$LTABSNP', "limit_value":'$SOLABSLIMIT'}'
	    echo
	    waitLimitSetStatusOK;
	fi
	LASTLIMIT=$SOLABSLIMIT

	sleep 5;
	getSOLPWR;
	getSMPWR;

	# restart whole process
	if [ "$SOLPWR" -eq 0 ]; then
	    break
	fi

    done

    echo restart
done
