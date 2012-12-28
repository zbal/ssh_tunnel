#!/bin/bash
#####################################
# Created by: vincent.viallet@gmail.com
# Inspired by: adamlandas@gmail.com
#####################################
# Description: This script can do the following:
#   * create tunnel interfaces between localhost and SSH_HOST
#   ** point localhost default gw to SSH_HOST
#   ** point blacklisted ips out orginal default gw
#####################################
# Requirements:
#   * run and connect as root (routing + iptables operation)
#   * remote SSH server allow root login
#   * remote SSH server allow tunnel 
#       "PermitTunnel yes" in sshd_config
#####################################
VERSION="0.1"

# Mode of operations
CREATE_DEFAULT_GW="1"
CREATE_TUNNEL="1"

REMOTE_SSH_HOST="66.228.60.39"
GATEWAY="192.168.1.1"

LOCAL_TUN="0"   # will use and create tun0 locally
LOCAL_TUN_IP=10.6.0.2
REMOTE_TUN="1"  # will use and create tun1 remotely
REMOTE_TUN_IP=10.6.0.1

# Those subnets and blacklist text file will always go through
# the regular gateway - never through the tunnel
BLACKLIST="./CN_cidr.txt"
PROTECTED_SUBNETS="10.1.0.0/16" # space separated list of subnets

# Internal data
FREQUENCY="90"  # frequency for checks
RUN_PIDS_FOLDER="/var/run/ssh_tunnel"

# Perform base operations and check
init() {
    if [ $((UID)) != 0 ]; then
        echo "You need to run this script as root to create tunnels."
        exit 1
    fi
    
    if [ ! -d "$RUN_PIDS_FOLDER" ]; then
        mkdir -p "$RUN_PIDS_FOLDER"
    fi
}


# Blacklist manager - allow add / remove blacklist routing
blacklist_routing() {
    case "$1" in
        "add") action='replace';;
        "remove") action='del';;
        "*") echo 'Invalid argument. '; return 1;;
    esac
    
    echo -n "$1 protected subnets: "
    for SUBNET in $PROTECTED_SUBNET
    do
        ip route $action $SUBNET via $GATEWAY &> /dev/null
        echo -n '.'
    done
    echo " done."
    
    if [ ! -z "$BLACKLIST" -a -f "$BLACKLIST" ] ; then
        echo -n "$1 blacklist: ";
        for line in $(cat $BLACKLIST)
        do
            ip route $action $line via $GATEWAY &> /dev/null
            echo -n '.'
        done
        echo " done."
    fi
    return 0;
}


# Gateway manager - allow for fast change in case of networking issue
gateway_routing() {
    case "$1" in
        "default") 
            ip route replace default via $GATEWAY &> /dev/null
            ip route del $REMOTE_SSH_HOST via $GATEWAY &> /dev/null
            echo "Default gateway reset."
            ;;
        "tunnel") 
            ip route add $REMOTE_SSH_HOST via $GATEWAY &> /dev/null
            ip route replace default via $REMOTE_TUN_IP &> /dev/null
            echo "Default gateway using SSH tunnel."
            ;;
        "*") echo 'Invalid argument. '; return 1;;
    esac
}

# Helpers
blacklist_add() { blacklist_routing "add"; return }
blacklist_remove() { blacklist_routing "remove"; return }
gateway_default() { gateway_routing "default"; return }
gateway_tunnel() { gateway_routing "tunnel"; return }

# establish the SSH tunnel
tunnel_create() {
    echo -n "Creating SSH tunnel and related iptables: "
    ssh -NTCf -w $LOCAL_TUN:$REMOTE_TUN root@$REMOTE_SSH_HOST
    # run all commands at once to avoid connecting over and over
    # TODO: error catching + reporting
    commands="ip link set tun$REMOTE_TUN up"
    commands="$commands && ip addr add $REMOTE_TUN_IP/32 peer $LOCAL_TUN_IP dev tun$REMOTE_TUN"
    commands="$commands && iptables -t nat -A POSTROUTING -s $LOCAL_TUN_IP/32 -o eth0 -j MASQUERADE"
    commands="$commands && iptables -A FORWARD -s $LOCAL_TUN_IP/32 -j ACCEPT"
    
    ssh root@$REMOTE_SSH_HOST "( $commands )" &> /dev/null
    echo "done."
}
tunnel_remove() {
    echo -n "Tearing down SSH tunnel and related iptables: "
    commands="iptables -D FORWARD -s $LOCAL_TUN_IP/32 -j ACCEPT"
    commands="$commands && iptables -t nat -D POSTROUTING -s $LOCAL_TUN_IP/32 -o eth0 -j MASQUERADE"
    ssh root@$REMOTE_SSH_HOST "( $commands )" &> /dev/null
    
    PID=$(ps aux | grep "ssh -NTCf -w $LOCAL_TUN:$REMOTE_TUN root@$REMOTE_SSH_HOST" | grep -v grep | awk '{print $2}')
    [ ! -z "$PID" ] && kill -9 "$PID" &> /dev/null
    echo "done."
}

# tunnel_check:
# Returns
#   0 = good
#   1 = bad - missing tunnel
#   2 = bad - can not reach other end of tunnel
#   3 = bad - can not reach public IP - routing issue on the other end?
tunnel_check() {
    ip addr show $LOCAL_TUN &> /dev/null
    if [ "$?" -ne 1 ] ; then
        return 1
    fi

    ping -c3 $REMOTE_TUN_IP &> /dev/null
    if [ "$?" -eq 1 ] ; then
        return 2
    fi

    ping -c3 8.8.8.8 &> /dev/null
    if [ "$?" -eq 1 ] ; then
        return 3
    fi

    return 0
}

# Run methods

# Run frequent ping check - allow quick rollback of gateway to default
# if the tunnel becomes un-responsive
run_light() {
    while true
    do
        CURRENT_GW=$(ip route show | grep -E '^default')
        if [ "$CURRENT_GW" != "default via $GATEWAY dev eth0" ]; then
            tunnel_check
            if [ $? -ne 0 ]; then
                gateway_default
            fi
        else
            echo "Already using default gateway."
        fi
        sleep $FREQUENCY
    done
}

run_full() {
    while true
    do
        CURRENT_GW=$(ip route show | grep -E '^default')
        if [ "$CURRENT_GW" != "default via $GATEWAY dev eth0" ]; then
            tunnel_check
            if [ $? -ne 0 ]; then
                gateway_default
                blacklist_remove
                tunnel_remove
                tunnel_create
                tunnel_check
                if [ $? -ne 0 ]; then
                    tunnel_remove
                else
                    blacklist_add
                    gateway_tunnel
                fi
            fi
        else
            tunnel_create
            tunnel_check
            if [ $? -ne 0 ]; then
                tunnel_remove
            else
                blacklist_add
                gateway_tunnel
            fi
        fi
        sleep $FREQUENCY
    done
}

help() {
    print_version
    printf "Usage: %s: [-h] [-v] [-f freq] [-m mode] args" $(basename $0)
    printf "\n
    -h | --help       -- display help (this page)
    -v | --version    -- display version
    -f | --frequency  -- how often to run the check in seconds (default 90s)
    -m | --mode       -- run mode; either 'light' or 'full'\n\n"
}

# display version number
print_version() {
    printf "Version: %s\n" $VERSION
}

get_options() {
    # Note that we use `"$@"' to let each command-line parameter expand to a 
    # separate word. The quotes around `$@' are essential!
    # We need TEMP as the `eval set --' would nuke the return value of getopt.
    TEMP=`getopt --options hvf:m: \
                 --long help,version,frequency:,mode: \
                 -- "$@"`

    if [ $? != 0 ] ; then echo "Terminating..." >&2 ; exit 1 ; fi

    # Note the quotes around `$TEMP': they are essential!
    eval set -- "$TEMP"

    while true ; do
        case "$1" in
            -h|--help) help ; exit 0 ;;
            -v|--version) print_version ; exit 0 ;;
            -f|--frequency) FREQUENCY=$2 ; shift 2 ;;
            -m|--mode) MODE=$2 ; shift 2 ;;
            --) shift ; break ;;
            *) echo "Internal error!" ; exit 1 ;;
        esac
    done
}

get_options "$@"
init
case $MODE in 
    "light") run_light;;
    "full") run_full;;
    "*") echo "Invalid run mode."; exit 1;;
esac