#!/bin/bash

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

# Exit if 'bash' is not installed
test -x /bin/bash || exit 0

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
ABSLIMITOFFSET=0

# SMPWR threshold to trigger the SOLLASTLIMIT increase
SMPWRTHRESMAX=50
SMPWRTHRESMIN=10

# SmartMeter IP (Tasmota) (update for your local network setup)
SMIP=192.168.60.7

# DTU IP (OpenDTU) (update for your local network setup)
DTUIP=192.168.60.5

# DTU default admin user access (from OpenDTU installation)
DTUUSER="admin:openDTU42"

# DTU serial numbers (insert your inverter SNs here)
DTUSN=(116180400144 116190745467 116190745954)

# manual limits to override the detected  inverter limits (in Watt) (0 = disabled)
DTULIM=(0 1000 1000)

# initialize arrays for inverter specific values
DTUMAXP=(0 0 0)
DTUMINP=(0 0 0)

MAXDTUIDX=$((${#DTUSN[@]} - 1))
CURRDTU=0

# DTU limiter (should be this at 100% after > 0W start)
DTULIMREL=0

# limit type absolute (non persistent)
LTABSNP=0
# limit type relative (non persistent)
LTRELNP=1

# poll interval
POLLNORMAL=5
POLLFAST=5

getSOLPWR()
{
    # get power from the single selected inverter
    SOLPWR=`curl -s http://$DTUIP/api/livedata/status | jq '.inverters[] | select(.serial == "'${DTUSN[$CURRDTU]}'").AC."0".Power.v'`
    if [ -n "$SOLPWR" ]; then
	# remove fraction to make it an integer
	SOLPWR=${SOLPWR%.*}
    fi
}

getDTUMAXPWR()
{
    DTUMAXPWR=`curl -s http://$DTUIP/api/limit/status | jq '."'${DTUSN[$CURRDTU]}'".max_power'`
    if [ -n "$DTUMAXPWR" ]; then
	# remove fraction to make it an integer
	DTUMAXP[$CURRDTU]=${DTUMAXPWR%.*}
	echo "DTUMAXP["$CURRDTU"] = "${DTUMAXP[$CURRDTU]}
	# 2% is the minimum control boundary - so take 3% to be sure
	DTUMINP[$CURRDTU]=$(($DTUMAXPWR / 33))
	echo "DTUMINP["$CURRDTU"] = "${DTUMINP[$CURRDTU]}
    fi
}

getDTULIMREL()
{
    DTULIMREL=`curl -s http://$DTUIP/api/limit/status | jq '."'${DTUSN[$CURRDTU]}'".limit_relative'`
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

    while [ "$SETSTATUS" = "\"Pending\"" ]; do
	sleep 1
	SETSTATUS=`curl -s http://$DTUIP/api/limit/status | jq '."'${DTUSN[$CURRDTU]}'".limit_set_status'`
	# SETSTATUS can be "Ok" or "Pending" or "Failure"
	echo "SETSTATUS="$SETSTATUS
    done
}

# run initialization and solar power control forever
while [ true ]; do

    echo `date +#I\ %d.%m.%y\ %T`
    getSOLPWR
    getDTUMAXPWR
    getSMPWR
    getDTULIMREL
    echo "initSOLPWR="$SOLPWR
    echo "initDTUMAXPWR="$DTUMAXPWR
    echo "initSMPWR="$SMPWR
    echo "initDTULIMREL="$DTULIMREL

    # wait until curl succeeds
    while [ -z "$SOLPWR" ] || [ -z "$SMPWR" ]; do

	echo `date +#W\ %d.%m.%y\ %T`
	echo "Wait for devices"
	sleep 2
	getSOLPWR
	getSMPWR

    done

    # get maximum power of inverters and fill DTUMAXP[] &  DTUMINP[]
    RESTART=0
    CURRDTU=0
    while [ "$CURRDTU" -le "$MAXDTUIDX" ]
    do
	getDTULIMREL
	if [ -z "$DTULIMREL" ]; then
	    # no data -> restart process
	    RESTART=1
	    break
	fi
	echo "DTULIMREL["$CURRDTU"] = "$DTULIMREL"%"

	getDTUMAXPWR
	if [ -z "$DTUMAXPWR" ]; then
	    # no data -> restart process
	    RESTART=1
	    break
	fi

	# check for manual limit override
	if [ "${DTULIM[$CURRDTU]}" -ge "${DTUMINP[$CURRDTU]}" ] && [ "${DTULIM[$CURRDTU]}" -le "${DTUMAXP[$CURRDTU]}" ]
	then
	    DTUMAXP[$CURRDTU]=${DTULIM[$CURRDTU]}
	    echo setting manual limit DTUMAXP[$CURRDTU] to ${DTUMAXP[$CURRDTU]} W
	fi

	((CURRDTU+=1))
    done

    if [ "$RESTART" -eq "1" ]
    then
	echo restart at getDTUMAXPWR
	continue
    fi

    # start control process when having 10W more than the minimum control boundary
    SOLMINPWR=$((${DTUMINP[0]} + 10))
    echo "SOLMINPWR="$SOLMINPWR

    # at this point the inverters are properly powered up

    # set OK value if we do not need to set the relative limit
    SETSTATUS="\"Ok\""

    # set limiter of first inverter to its maximum and the rest to minimum
    RESTART=0
    CURRDTU=0
    while [ "$CURRDTU" -le "$MAXDTUIDX" ]
    do
	if [ "$CURRDTU" -eq "0" ]
	then
	    INITLIM=${DTUMAXP[$CURRDTU]}
	else
	    INITLIM=${DTUMINP[$CURRDTU]}
	fi
	echo setting non permanent limit for inverter $CURRDTU to $INITLIM W
	SETLIM=`curl -u "$DTUUSER" http://$DTUIP/api/limit/config -d 'data={"serial":"'${DTUSN[$CURRDTU]}'", "limit_type":'$LTABSNP', "limit_value":'$INITLIM'}' 2>/dev/null | jq '.type'`
	echo "SETLIM="$SETLIM
	getLimitSetStatus

	# SETSTATUS can be "Ok" or "Failure" here
	if [ "$SETSTATUS" != "\"Ok\"" ]; then
	    echo setting the absolute limit of first inverter failed
	    RESTART=1
	    break
	fi
	((CURRDTU+=1))
    done

    if [ "$RESTART" -eq "1" ]
    then
	echo restart at set init limits
	continue
    fi

    CURRDTU=0
    getSOLPWR
    getSMPWR
    # wait for at least some remarkable solar power (SOLMINPWR)
    while [ -n "$SMPWR" ] && [ -n "$SOLPWR" ] && [ "$SOLPWR" -lt "$SOLMINPWR" ]; do

	echo `date +#P\ %d.%m.%y\ %T`
	echo "Wait for "$SOLMINPWR"W solar power"
	echo "SOLPWR="$SOLPWR
	sleep 10
	getSOLPWR
	getSMPWR
	#cho `date +%d.%m.%y,%T`","$SOLPWR","$SMPWR","$SOLABSLIMIT","$SOLLASTLIMIT","$ABSLIMITOFFSET","$SMPWRTHRESMIN","$SMPWRTHRESMAX > /var/run/zerofeed.state

    done

    # start from the top
    SOLLASTLIMIT=${DTUMAXP[$CURRDTU]}

    # main control loop
    while [ -n "$SMPWR" ] && [ -n "$SOLPWR" ]; do

	MAINSLEEP=$POLLNORMAL

	echo `date +#C\ %d.%m.%y\ %T`
	echo "SOLPWR="$SOLPWR
	echo "SMPWR="$SMPWR
	echo "SOLLASTLIMIT="$SOLLASTLIMIT
	echo "SOLABSLIMIT="$SOLABSLIMIT
	echo "ABSLIMITOFFSET="$ABSLIMITOFFSET

	if [ "$SMPWR" -lt "$SMPWRTHRESMIN" ]; then
	    # calculate inverter limit to stop feeding into public network
	    SOLABSLIMIT=$(($SMPWR + $SOLPWR - $SMPWRTHRESMIN + $ABSLIMITOFFSET))
	    echo "set SOLABSLIMIT="$SOLABSLIMIT
	elif [ "$SMPWR" -gt "$SMPWRTHRESMAX" ]; then
	    # the system power consumption is higher than our defined threshold
	    # => we could safely increase the current SOLLASTLIMIT by SMPWR
	    #    until DTUMAXPWR is reached (see following if-statement).
	    #    SOLABSLIMIT=$(($SMPWR + $SOLLASTLIMIT - $SMPWRTHRESMIN))
	    #
	    # As there was a weird oscillation observed with real SMPWR values
	    # we make smaller steps with SMPWRTHRESMAX towards DTUMAXPWR instead.
	    # When SMPWR is 'really big' we jump half of the SMPWR value.
	    if [ "$SMPWR" -gt $((2 * $SMPWRTHRESMAX)) ]; then
		PWRINCR=$(($SMPWR / 2))
	    else
		PWRINCR=$SMPWRTHRESMAX
	    fi

	    SOLABSLIMIT=$(($PWRINCR + $SOLLASTLIMIT - $SMPWRTHRESMIN))
	    echo "update SOLABSLIMIT="$SOLABSLIMIT
	fi

	# do not set limits beyond the inverter capabilities
	if [ "$SOLABSLIMIT" -gt "${DTUMAXP[$CURRDTU]}" ]; then
	    echo Calculated limit $SOLABSLIMIT cropped to ${DTUMAXP[$CURRDTU]}
	    SOLABSLIMIT=${DTUMAXP[$CURRDTU]}
	fi

	# do not set limits beyond the inverter capabilities
	if [ "$SOLABSLIMIT" -lt "${DTUMINP[$CURRDTU]}" ]; then
	    echo Calculated limit $SOLABSLIMIT cropped to ${DTUMINP[$CURRDTU]}
	    SOLABSLIMIT=${DTUMINP[$CURRDTU]}
	fi

	# when we moved far away from SOLPOWER -> hop to the maximum
	if [ "$(($SOLABSLIMIT - $SOLPWR))" -gt "200" ] && [ "$(($SOLABSLIMIT - $SOLLASTLIMIT))" -lt "150" ]; then
	    echo Fast hop of inverter $CURRDTU to ${DTUMAXP[$CURRDTU]}
	    SOLABSLIMIT=${DTUMAXP[$CURRDTU]}
	fi

	# only set the limit when the value was changed
	if [ "$SOLABSLIMIT" -ne "$SOLLASTLIMIT" ]; then
	    SETLIM=`curl -u "$DTUUSER" http://$DTUIP/api/limit/config -d 'data={"serial":"'${DTUSN[$CURRDTU]}'", "limit_type":'$LTABSNP', "limit_value":'$SOLABSLIMIT'}' 2>/dev/null | jq '.type'`
	    echo "SETLIM="$SETLIM" on inverter "$CURRDTU
	    getLimitSetStatus
	    MAINSLEEP=$POLLFAST
	fi

	# SETSTATUS can be "Ok" or "Failure" here
	if [ "$SETSTATUS" != "\"Ok\"" ]; then
	    echo setting the abs limit failed
	    # setting the limit failed -> restart process
	    break
	fi

	# generate CSV capable status output
	echo `date +%d.%m.%y,%T`","$SOLPWR","$SMPWR","$SOLABSLIMIT","$SOLLASTLIMIT","$ABSLIMITOFFSET","$SMPWRTHRESMIN","$SMPWRTHRESMAX
	#cho `date +%d.%m.%y,%T`","$SOLPWR","$SMPWR","$SOLABSLIMIT","$SOLLASTLIMIT","$ABSLIMITOFFSET","$SMPWRTHRESMIN","$SMPWRTHRESMAX > /var/run/zerofeed.state

	SOLLASTLIMIT=$SOLABSLIMIT

	# check for inverter change
	if [ "$SOLABSLIMIT" -eq "${DTUMINP[$CURRDTU]}" ] && [ "$CURRDTU" -gt "0" ]
	then
	    echo -n "step down from inverter "$CURRDTU
	    ((CURRDTU-=1))
	    echo " to inverter "$CURRDTU
	    SOLLASTLIMIT=${DTUMAXP[$CURRDTU]}
	    # set a default value when SMPWRTHRESMIN < SOLPWR < SMPWRTHRESMAX
	    SOLABSLIMIT=${DTUMINP[$CURRDTU]}
	else if [ "$SOLABSLIMIT" -eq "${DTUMAXP[$CURRDTU]}" ] && [ "$CURRDTU" -lt "$MAXDTUIDX" ]
	     then
		 echo -n "step up from inverter "$CURRDTU" "
		 ((CURRDTU+=1))
		 echo " to inverter "$CURRDTU
		 SOLLASTLIMIT=${DTUMINP[$CURRDTU]}
		 # set a default value when SMPWRTHRESMIN < SOLPWR < SMPWRTHRESMAX
		 SOLABSLIMIT=${DTUMINP[$CURRDTU]}
	     fi
	fi

	sleep $MAINSLEEP
	getSOLPWR
	getSMPWR

	# restart whole process
	if [ "$SOLPWR" -eq 0 ] || [ "$DTUMAXPWR" -eq 0 ]; then
	    unset SOLPWR
	    unset DTUMAXPWR
	    break
	fi

    done

    echo restart
done
