#!/bin/sh

# Zero feed script to make sure the solar modules are reducing their output
# to (ideally) not push any energy into the public network.

# Inspired by https://github.com/tbnobody/OpenDTU/blob/master/docs/Web-API.md

# Needs OpenDTU and the Tasmota smart meter IoT devices in your WLAN and is
# intended to be executed on an OpenWrt router (install curl & jq packages).
# USE AT YOUR OWN RISK! Especially I don't know if the inverter is fit for
# this purpose as all this functionality was reverse engineered by the
# fabulous OpenDTU developers. I simply rely on their amazing work here.

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

# Absolute Solar Limit (unsigned value)
# -> SMPWR + SOLPWR + ABSLIMITOFFSET
SOLABSLIMIT=0

# reduce safety margin from inverter by increasing this value
ABSLIMITOFFSET=50

# SMPWR threshold to trigger the SOLLASTLIMIT increase
SMPWRTHRES=80

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

# minimum solar power (Watt) before starting the power control
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

# get current power via 'status 8' from Tasmota (for LK13BE smart meter)
getSMPWR()
{
    SMPWR=`curl -s http://$SMIP/cm?cmnd=status%208 | jq '.StatusSNS.LK13BE.Power_curr'`
    if [ -n "$SMPWR" ]; then
	# remove fraction to make it an integer
	SMPWR=${SMPWR%.*}
    fi
}

getLimitSetStatus()
{
    SETSTATUS="\"Pending\""

    while [ "$SETSTATUS" == "\"Pending\"" ]; do
	sleep 1
	SETSTATUS=`curl -s http://$DTUIP/api/limit/status | jq '."'$DTUSN'".limit_set_status'`
	# SETSTATUS can be "Ok" or "Pending" or "Failure"
	echo "SETSTATUS="$SETSTATUS
    done
}

# run initialization and solar power control forever
while [ true ]; do

    getSOLPWR
    getDTUMAXPWR
    getSMPWR
    getDTULIMREL
    echo "initSOLPWR="$SOLPWR
    echo "initDTUMAXPWR="$DTUMAXPWR
    echo "initSMPWR="$SMPWR
    echo "initDTULIMREL="$DTULIMREL

    # wait until curl succeeds
    while [ -z "$SOLPWR" ] || [ -z "$DTUMAXPWR" ] || [ -z "$SMPWR" ]; do

	echo `date +#\ %d.%m.%y\ %T`
	echo "Wait for devices"
	sleep 2
	getSOLPWR
	getDTUMAXPWR
	getSMPWR

    done

    # wait for at least some remarkable solar power (SOLMINPWR)
    while [ -n "$SMPWR" ] && [ -n "$SOLPWR" ] && [ "$SOLPWR" -lt "$SOLMINPWR" ]; do

	echo `date +#\ %d.%m.%y\ %T`
	echo "Wait for "$SOLMINPWR"W solar power"
	echo "SOLPWR="$SOLPWR
	sleep 10
	getSOLPWR
	getSMPWR

    done

    # set OK value if we do not need to set the relative limit
    SETSTATUS="\"Ok\""

    # check if we need to remove the limiter
    getDTULIMREL
    echo "DTULIMREL="$DTULIMREL
    if [ -z "$DTULIMREL" ]; then
	# no data -> restart process
	continue
    fi
    if [ "$DTULIMREL" -ne "$DTUNOLIMRELVAL" ]; then
	# not 100% ? -> set to 100%
	SETLIM=`curl -u "$DTUUSER" http://$DTUIP/api/limit/config -d 'data={"serial":"'$DTUSN'", "limit_type":'$LTRELNP', "limit_value":'$DTUNOLIMRELVAL'}' 2>/dev/null | jq '.type'`
	echo "SETLIM="$SETLIM
	getLimitSetStatus
    fi

    # SETSTATUS can be "Ok" or "Failure" here
    if [ "$SETSTATUS" != "\"Ok\"" ]; then
	echo setting the rel limit failed
	# setting the limit failed -> restart process (skip main control loop)
	SMPWR=""
    fi

    # start from the top
    SOLLASTLIMIT=$DTUMAXPWR

    # main control loop
    while [ -n "$SMPWR" ] && [ -n "$SOLPWR" ]; do

	echo `date +#\ %d.%m.%y\ %T`
	echo "SOLPWR="$SOLPWR
	echo "SMPWR="$SMPWR
	echo "ABSLIMITOFFSET="$ABSLIMITOFFSET

	if [ "$SMPWR" -lt 0 ]; then
	    # calculate inverter limit to stop feeding into public network
	    SOLABSLIMIT=$(($SMPWR + $SOLPWR + $ABSLIMITOFFSET))
	    echo "set SOLABSLIMIT="$SOLABSLIMIT
	elif [ "$SMPWR" -gt "$SMPWRTHRES" ]; then
	    # the system power consumption is higher than our defined threshold
	    # => safely increase the current SOLLASTLIMIT by SMPWR
	    #    until DTUMAXPWR is reached (see following if-statement)
	    SOLABSLIMIT=$(($SMPWR + $SOLLASTLIMIT))
	    echo "update SOLABSLIMIT="$SOLABSLIMIT
	fi

	# do not set limits beyond the inverter capabilities
	if [ "$SOLABSLIMIT" -gt "$DTUMAXPWR" ]; then
	    echo Calculated limit $SOLABSLIMIT cropped to $DTUMAXPWR
	    SOLABSLIMIT=$DTUMAXPWR
	fi

	# only set the limit when the value was changed
	if [ "$SOLABSLIMIT" -ne "$SOLLASTLIMIT" ]; then
	    SETLIM=`curl -u "$DTUUSER" http://$DTUIP/api/limit/config -d 'data={"serial":"'$DTUSN'", "limit_type":'$LTABSNP', "limit_value":'$SOLABSLIMIT'}' 2>/dev/null | jq '.type'`
	    echo "SETLIM="$SETLIM
	    getLimitSetStatus
	fi

	# SETSTATUS can be "Ok" or "Failure" here
	if [ "$SETSTATUS" != "\"Ok\"" ]; then
	    echo setting the abs limit failed
	    # setting the limit failed -> restart process
	    break
	fi

	SOLLASTLIMIT=$SOLABSLIMIT

	sleep 5
	getSOLPWR
	getSMPWR

	# restart whole process
	if [ "$SOLPWR" -eq 0 ]; then
	    break
	fi

    done

    echo restart
done
