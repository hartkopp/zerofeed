#!/bin/sh

# (Re-)install and check the zerofeed components on an OpenWrt router.
#
# Initial installation:
#   Upload zerofeedjson.sh, zerofeed (init script), index.html and this
#   script to /tmp on the router and run 'sh /tmp/re_install_zerofeed.sh'
#
# After a system upgrade (or for a check at any time):
#   Run 're_install_zerofeed.sh' - it checks all components and repairs
#   what is missing (e.g. the packages bash, curl and jq).
#
# Options:
#   -f  also overwrite /usr/bin/zerofeed.sh with the uploaded
#       zerofeedjson.sh (your configuration in this file gets lost!)
#       and recreate the uhttpd instance 'solar' with default values
#   -u  accept the current default uhttpd configuration of the image
#       (after a reported change of the default has been checked)
#
# The script is written for /bin/sh as bash is not available after a
# system upgrade. It can be executed multiple times.
#
# Author: Oliver Hartkopp
# License: MIT

# installed components
ZF_BIN=/usr/bin/zerofeed.sh
ZF_INIT=/etc/init.d/zerofeed
ZF_SELF=/usr/bin/re_install_zerofeed.sh
ZF_PIDFILE=/var/run/zerofeed.pid
WWW_DIR=/www/solar
WWW_INDEX=$WWW_DIR/index.html
WWW_JSON=$WWW_DIR/zerofeed.json
ZF_JSON=/var/run/zerofeed.json
SYSUPGRADE_CONF=/etc/sysupgrade.conf
UHTTPD_CONF=/etc/config/uhttpd
UHTTPD_ROM=/rom/etc/config/uhttpd
# uhttpd configuration before the section 'solar' was added
UHTTPD_PRE=/etc/uhttpd-pre-zerofeed
# default uhttpd configuration of the image at the time of the installation
# (or of the last 'accept' with -u) to detect a changed default
UHTTPD_DEFAULT=/etc/uhttpd-default-zerofeed

# uploaded files (located next to this script)
SRC_BIN=zerofeedjson.sh
SRC_INIT=zerofeed
SRC_INDEX=index.html
SRC_SELF=re_install_zerofeed.sh

# needed packages
PACKAGES="bash curl jq"

# default ports of the uhttpd instance 'solar'
HTTP_PORT=81
HTTPS_PORT=8443

usage()
{
    echo "usage: $0 [-f] [-u]"
    echo "  -f  overwrite $ZF_BIN and recreate the uhttpd instance 'solar'"
    echo "  -u  accept the current default uhttpd configuration of the image"
}

FORCE=0
ACCEPT=0
for a in "$@"
do
    case "$a" in
	-f) FORCE=1 ;;
	-u) ACCEPT=1 ;;
	*) usage; exit 1 ;;
    esac
done

SRC_DIR=$(cd "$(dirname "$0")" && pwd)
ERRORS=0

ok()    { echo "OK     $*"; }
fixed() { echo "FIXED  $*"; }
info()  { echo "INFO   $*"; }
err()   { echo "ERROR  $*"; ERRORS=$((ERRORS + 1)); }

# process ids of running zerofeed.sh instances (executed by bash/sh - an
# editor with the file open is not matched)
zf_pids()
{
    ps w | grep -E "(bash|sh) $ZF_BIN( |\$)" | grep -v grep | awk '{ print $1 }'
}

# main process id from the pid file of the init script (bash forks short
# living subshells with the same command line, e.g. for `curl ... | jq ...`)
zf_main_pid()
{
    pid=$(cat "$ZF_PIDFILE" 2>/dev/null)
    if [ -n "$pid" ] && zf_pids | grep -qx "$pid"
    then
	echo "$pid"
    fi
}

md5()
{
    md5sum "$1" 2>/dev/null | awk '{ print $1 }'
}

# install_file <uploaded file> <destination> <mode> <overwrite if different>
install_file()
{
    src="$SRC_DIR/$1"
    dst="$2"

    if [ -f "$src" ] && [ "$src" != "$dst" ]
    then
	if [ ! -f "$dst" ]
	then
	    cp "$src" "$dst" && chmod "$3" "$dst" && fixed "$dst installed" || err "$dst could not be installed"
	    return
	fi
	if [ "$(md5 "$src")" = "$(md5 "$dst")" ]
	then
	    ok "$dst up to date"
	elif [ "$4" = "1" ]
	then
	    cp "$src" "$dst" && fixed "$dst updated from $src" || err "$dst could not be updated"
	else
	    info "$dst differs from $src - not overwritten (use -f)"
	fi
    elif [ -f "$dst" ]
    then
	ok "$dst present"
    else
	err "$dst missing - upload $1 to /tmp and run 'sh /tmp/$SRC_SELF'"
	return
    fi

    if [ "$3" = "755" ] && [ ! -x "$dst" ]
    then
	chmod "$3" "$dst" && fixed "$dst made executable"
    fi
}

echo "zerofeed (re-)installation check"
echo

# --- 1. stop a running zerofeed process ------------------------------------

if [ -n "$(zf_pids)" ]
then
    [ -x "$ZF_INIT" ] && "$ZF_INIT" stop
    # kill remaining processes (e.g. started without the init script)
    i=0
    while [ -n "$(zf_pids)" ] && [ "$i" -lt "10" ]
    do
	sleep 1
	i=$((i + 1))
    done
    if [ -n "$(zf_pids)" ]
    then
	kill -KILL $(zf_pids) 2>/dev/null
	sleep 1
    fi
    if [ -n "$(zf_pids)" ]
    then
	err "zerofeed could not be stopped (pid $(echo $(zf_pids)))"
	exit 1
    fi
    info "zerofeed stopped"
else
    ok "zerofeed not running"
fi

# --- 2. packages -------------------------------------------------------------

MISSING=""
for p in $PACKAGES
do
    command -v "$p" >/dev/null 2>&1 || MISSING="$MISSING $p"
done

if [ -z "$MISSING" ]
then
    ok "packages $PACKAGES installed"
else
    info "installing packages:$MISSING"
    if command -v apk >/dev/null 2>&1
    then
	apk update >/dev/null && apk add $MISSING >/dev/null
    elif command -v opkg >/dev/null 2>&1
    then
	opkg update >/dev/null && opkg install $MISSING >/dev/null
    fi
    STILLMISSING=""
    for p in $MISSING
    do
	command -v "$p" >/dev/null 2>&1 || STILLMISSING="$STILLMISSING $p"
    done
    if [ -z "$STILLMISSING" ]
    then
	fixed "packages$MISSING installed"
    else
	err "packages$STILLMISSING could not be installed (internet connection?)"
    fi
fi

# --- 3. files ----------------------------------------------------------------

NEW_BIN=0
[ -f "$ZF_BIN" ] || NEW_BIN=1
install_file "$SRC_BIN" "$ZF_BIN" 755 "$FORCE"
install_file "$SRC_INIT" "$ZF_INIT" 755 1
install_file "$SRC_SELF" "$ZF_SELF" 755 1

if [ "$NEW_BIN" = "1" ] && [ -f "$ZF_BIN" ]
then
    info "check the configuration (SMIP, DTUIP, DTUUSER, DTUSN, ...) in $ZF_BIN"
fi

# --- 4. web server directory, web page and symlink ---------------------------

if [ -d "$WWW_DIR" ]
then
    ok "$WWW_DIR present"
else
    mkdir -p "$WWW_DIR" && fixed "$WWW_DIR created" || err "$WWW_DIR could not be created"
fi

install_file "$SRC_INDEX" "$WWW_INDEX" 644 1

if [ -L "$WWW_JSON" ] && [ "$(readlink "$WWW_JSON")" = "$ZF_JSON" ]
then
    ok "$WWW_JSON -> $ZF_JSON"
else
    rm -f "$WWW_JSON"
    ln -s "$ZF_JSON" "$WWW_JSON" && fixed "$WWW_JSON -> $ZF_JSON created" || err "symlink $WWW_JSON could not be created"
fi

# --- 5. uhttpd instance 'solar' ----------------------------------------------

UHTTPD_RESTART=0

# normalized uhttpd configuration file (uci export) without the section
# 'solar', one line per option with the section name as prefix
uhttpd_lines()
{
    tmpd=/tmp/re_install_zerofeed.$$
    mkdir -p "$tmpd" && cp "$1" "$tmpd/uhttpd" || return
    uci -q -c "$tmpd" export uhttpd | awk -v q="'" '
	/^config / { sec = $3; gsub(q, "", sec); next }
	sec == "solar" || !NF || $1 == "package" { next }
	{ $1 = $1; print sec ": " $0 }'
    rm -rf "$tmpd"
}

# backup of the uhttpd configuration without the section 'solar'
if [ -f "$UHTTPD_PRE" ]
then
    ok "$UHTTPD_PRE present"
elif uci -q get uhttpd.solar >/dev/null
then
    # 'solar' already exists (installation with an older script version)
    uci -q export uhttpd | awk '
	/^config / { skip = ($0 ~ /^config uhttpd .solar.$/) }
	!skip { print }' > "$UHTTPD_PRE" && fixed "$UHTTPD_PRE created (from $UHTTPD_CONF without section 'solar')"
else
    cp "$UHTTPD_CONF" "$UHTTPD_PRE" && fixed "$UHTTPD_PRE created (copy of $UHTTPD_CONF)"
fi

if [ "$FORCE" = "0" ] && uci -q get uhttpd.solar >/dev/null
then
    ok "uhttpd instance 'solar' configured"
else
    uci -q delete uhttpd.solar
    uci batch <<EOF
set uhttpd.solar=uhttpd
add_list uhttpd.solar.listen_http='0.0.0.0:$HTTP_PORT'
add_list uhttpd.solar.listen_http='[::]:$HTTP_PORT'
add_list uhttpd.solar.listen_https='0.0.0.0:$HTTPS_PORT'
add_list uhttpd.solar.listen_https='[::]:$HTTPS_PORT'
set uhttpd.solar.redirect_https='1'
set uhttpd.solar.cert='/etc/uhttpd.crt'
set uhttpd.solar.key='/etc/uhttpd.key'
set uhttpd.solar.home='$WWW_DIR'
set uhttpd.solar.rfc1918_filter='1'
set uhttpd.solar.max_requests='3'
commit uhttpd
EOF
    fixed "uhttpd instance 'solar' created (http $HTTP_PORT -> https $HTTPS_PORT)"
    UHTTPD_RESTART=1
fi

if ! ls /lib/libustream-*.so >/dev/null 2>&1 && [ -n "$(uci -q get uhttpd.solar.listen_https)" ]
then
    err "no TLS library for uhttpd (libustream-*) - HTTPS will not work"
fi

# ports of the instance 'solar' from the uci configuration
SOLAR_PORTS=""
for l in $(uci -q get uhttpd.solar.listen_http) $(uci -q get uhttpd.solar.listen_https)
do
    p=${l##*:}
    case " $SOLAR_PORTS " in
	*" $p "*) ;;
	*) SOLAR_PORTS="$SOLAR_PORTS $p" ;;
    esac
done

ports_listening()
{
    for p in $SOLAR_PORTS
    do
	netstat -tln 2>/dev/null | grep -q ":$p " || return 1
    done
    return 0
}

if [ -z "$SOLAR_PORTS" ]
then
    err "no listen ports configured in uhttpd instance 'solar'"
fi

if [ "$UHTTPD_RESTART" = "0" ] && ! ports_listening
then
    UHTTPD_RESTART=1
fi

if [ "$UHTTPD_RESTART" = "1" ]
then
    /etc/init.d/uhttpd restart
    sleep 2
fi

if [ -z "$SOLAR_PORTS" ]
then
    :
elif ports_listening
then
    if [ "$UHTTPD_RESTART" = "1" ]
    then
	fixed "uhttpd restarted, listening on port$SOLAR_PORTS"
    else
	ok "uhttpd listening on port$SOLAR_PORTS"
    fi
else
    err "uhttpd not listening on all ports of instance 'solar' ($SOLAR_PORTS) - check 'logread -e uhttpd'"
fi

# --- 5b. changed default uhttpd configuration of the image ------------------
# A kept /etc/config/uhttpd is not replaced by a new default on a system
# upgrade. Compare the default of the image with the default at the time of
# the installation and report the changes - the configuration is not changed.

for f in "$UHTTPD_CONF.apk-new" "$UHTTPD_CONF-opkg"
do
    if [ -f "$f" ]
    then
	info "new uhttpd default configuration from a package upgrade: $f"
    fi
done

if [ -f "$UHTTPD_ROM" ]
then
    if [ ! -f "$UHTTPD_DEFAULT" ]
    then
	cp "$UHTTPD_ROM" "$UHTTPD_DEFAULT" && fixed "$UHTTPD_DEFAULT created (copy of $UHTTPD_ROM)"
    elif [ "$ACCEPT" = "1" ]
    then
	cp "$UHTTPD_ROM" "$UHTTPD_DEFAULT" && fixed "$UHTTPD_DEFAULT updated - current default accepted"
    else
	OLD_LINES=/tmp/re_install_zerofeed.old.$$
	NEW_LINES=/tmp/re_install_zerofeed.new.$$
	uhttpd_lines "$UHTTPD_DEFAULT" > "$OLD_LINES"
	uhttpd_lines "$UHTTPD_ROM" > "$NEW_LINES"
	if [ "$(cat "$OLD_LINES")" = "$(cat "$NEW_LINES")" ]
	then
	    ok "default uhttpd configuration of the image unchanged"
	else
	    info "the default uhttpd configuration of the image has changed:"
	    grep -vxF -f "$NEW_LINES" "$OLD_LINES" | sed 's/^/INFO     - /'
	    grep -vxF -f "$OLD_LINES" "$NEW_LINES" | sed 's/^/INFO     + /'
	    info "  (- old default, + new default; format 'section: option value')"
	    info "  apply the changes to $UHTTPD_CONF if needed (e.g. with uci set)"
	    info "  then accept the new default: $(basename "$ZF_SELF") -u"
	fi
	rm -f "$OLD_LINES" "$NEW_LINES"
    fi
fi

# --- 6. keep the files on a system upgrade -----------------------------------

touch "$SYSUPGRADE_CONF"
for f in "$ZF_BIN" "$ZF_INIT" "$ZF_SELF" "$WWW_DIR/" "$UHTTPD_PRE" "$UHTTPD_DEFAULT"
do
    if grep -qxF "$f" "$SYSUPGRADE_CONF"
    then
	ok "$f in $SYSUPGRADE_CONF"
    else
	echo "$f" >> "$SYSUPGRADE_CONF" && fixed "$f added to $SYSUPGRADE_CONF"
    fi
done

# --- 7. autostart and start of zerofeed --------------------------------------

if [ -x "$ZF_INIT" ]
then
    if "$ZF_INIT" enabled
    then
	ok "zerofeed autostart enabled"
    else
	"$ZF_INIT" enable && fixed "zerofeed autostart enabled"
    fi

    # detach from stdin/stdout/stderr - otherwise the background process
    # keeps e.g. a 'ssh root@router re_install_zerofeed.sh' session open
    "$ZF_INIT" start </dev/null >/dev/null 2>&1
    sleep 2
    if [ -n "$(zf_main_pid)" ]
    then
	ok "zerofeed running (pid $(zf_main_pid))"
    elif [ -n "$(zf_pids)" ]
    then
	ok "zerofeed running (pid $(echo $(zf_pids)))"
    else
	err "zerofeed not running - check $ZF_BIN"
    fi
else
    err "$ZF_INIT missing - zerofeed not started"
fi

if [ -f "$ZF_JSON" ]
then
    ok "$ZF_JSON present"
else
    info "$ZF_JSON not yet written by zerofeed (no solar power at night?)"
fi

echo
if [ "$ERRORS" = "0" ]
then
    echo "all checks passed"
else
    echo "$ERRORS error(s) - see above"
fi

if [ "$SRC_DIR" != "$(dirname "$ZF_SELF")" ]
then
    echo "after a system upgrade run: $(basename "$ZF_SELF")"
fi

exit "$ERRORS"
