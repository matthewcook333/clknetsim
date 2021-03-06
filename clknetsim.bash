# Copyright (C) 2010, 2011  Miroslav Lichvar <mlichvar@redhat.com>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# Modified by: Michael Saffron & Nick Carter; HMC RedHat Clinic Team '14 - '15

client_pids=""

start_client() {
    local node=$1 client=$2 config=$3 suffix=$4 opts=$5
    local args=() line lastpid

    rm -f tmp/log.$node tmp/conf.$node

    [ $client = chrony ] && client=chronyd
    [ $client = ntp ] && client=ntpd

    if ! which $client$suffix &> /dev/null; then
	    echo "can't find $client$suffix in PATH"
	    return 1
    fi

    case $client in
	chronyd)
	    cat > tmp/conf.$node <<-EOF
		pidfile tmp/pidfile.$node
		allow
		cmdallow
		bindcmdaddress 0.0.0.0
		$config
		EOF
	    args=(-d -4 -f tmp/conf.$node $opts)
	    ;;
	ntpd) # the filegens here don't seem to actually do anything
	    cat > tmp/conf.$node <<-EOF
		pidfile tmp/pidfile.$node
		
		# statsdir /home/clinic/git/clknetsim/tmp/ntpstats-$node
		# statistics loopstats rawstats sysstats
		# filegen loopstats file loopstats type day enable
		# filegen rawstats file rawstats type day enable
		# filegen sysstats file sysstats type day enable

		restrict default
		# logconfig=syncstatus +allall
		$config
		EOF
	    args=(-n -c tmp/conf.$node $opts)
	    ;;
	ptp4l)
	    cat > tmp/conf.$node <<-EOF
		[global]
		$config
		EOF
	    args=(-f tmp/conf.$node $opts)
	    ;;
	ptpd2) # who knows if this will work, seems not to, asserts failing
	    cat > tmp/conf.$node <<-EOF
		$config
		
		EOF
	    args=(-DDD -c tmp/conf.$node $opts)
	    ;;
	chronyc)
	    args=($opts -m)
	    while read line; do args+=("$line"); done <<< "$config"
	    ;;
	pmc)
	    args=($opts)
	    while read line; do args+=("$line"); done <<< "$config"
	    ;;
	ntpq)
	    while read line; do args+=(-c "$line"); done <<< "$config"
	    args+=($opts)
	    ;;
	sntp)
	    args=(-K /dev/null $opts $config)
	    ;;
	ntpdate)
	    args=($opts $config)
	    ;;
	busybox)
	    args=(ntpd -ddd -n)
	    while read line; do args+=(-p "$line"); done <<< "$config"
	    args+=($opts)
	    ;;
	phc2sys)
	    args=(-s /dev/ptp0 -O 0 $opts $config)
	    ;;
	*)
	    echo "unknown client $client"
	    exit 1
	    ;;
    esac

    LD_PRELOAD=$CLKNETSIM_PATH/clknetsim.so \
    CLKNETSIM_NODE=$node CLKNETSIM_SOCKET=tmp/sock \
    $client_wrapper $client$suffix "${args[@]}" &> tmp/log.$node &
    lastpid=$!
    disown $lastpid

    client_pids="$client_pids $lastpid"
}

start_server() {
    local nodes=$1 ret=0
    shift
    $server_wrapper $CLKNETSIM_PATH/clknetsim "$@" -s tmp/sock tmp/conf $nodes > tmp/stats 2> tmp/log
    if [ $? -ne 0 ]; then
        echo clknetsim failed 1>&2
        ret=1
    fi
    kill $client_pids &> /dev/null
    client_pids=" "
    return $ret
}

generate_seq() {
    $CLKNETSIM_PATH/clknetsim -G "$@"
}

generate_config1() {
    local nodes=$1 offset=$2 freqexpr=$3 delayexprup=$4 delayexprdown=$5 refclockexpr=$6 i

    for i in `seq 2 $nodes`; do
	echo "node${i}_offset = $offset"
	echo "node${i}_freq = $freqexpr"
	echo "node${i}_delay1 = $delayexprup"
	if [ -n "$delayexprdown" ]; then
	    echo "node1_delay${i} = $delayexprdown"
	else
	    echo "node1_delay${i} = $delayexprup"
	fi
        [ -n "$refclockexpr" ] && echo "node${i}_refclock = $refclockexpr"
    done > tmp/conf
}

generate_config2() {
    local nodes=$1 offset=$2 freqexpr=$3 delayexpr=$4 i j

    for i in `seq 2 $nodes`; do
	echo "node${i}_offset = $offset"
	echo "node${i}_freq = $freqexpr"
	for j in `seq 1 $nodes`; do
	    [ $i -eq $j ] && continue
	    echo "node${i}_delay${j} = $delayexpr"
	    echo "node${j}_delay${i} = $delayexpr"
	done
    done > tmp/conf
}

generate_config3() {
    local topnodes=$1 nodes=$2 offset=$3 freqexpr=$4 delayexpr=$5 i j

    for i in `seq $[$topnodes + 1] $nodes`; do
	echo "node${i}_offset = $offset"
	echo "node${i}_freq = $freqexpr"
	for j in `seq 1 $topnodes`; do
	    [ $i -eq $j ] && continue
	    echo "node${i}_delay${j} = $delayexpr"
	    echo "node${j}_delay${i} = $delayexpr"
	done
    done > tmp/conf
}

generate_config4() {
    local stablenodes=$1 subnets=$2 offset=$3 freqexpr=$4 delayexpr=$5
    local subnet i j added

    echo "$subnets" | tr '|' '\n' | while read subnet; do
	for i in $subnet; do
	    if ! [[ " $stablenodes $added " =~ [^0-9]$i[^0-9] ]]; then
		echo "node${i}_offset = $offset"
		echo "node${i}_freq = $freqexpr"
	    fi
	    for j in $subnet; do
		[ $i -eq $j ] && continue
		echo "node${i}_delay${j} = $delayexpr"
	    done
	    added="$added $i"
	done
    done > tmp/conf
}

find_sync() {
    local offlog=$1 freqlog=$2 index=$3 offsync=$4 freqsync=$5 smooth=$6

    [ -z "$smooth" ] && smooth=0.05

    paste <(cut -f $index $1) <(cut -f $index $2) | awk '
    BEGIN {
	lastnonsync = -1
	time = 0
    }
    {
	off = $1 < 0 ? -$1 : $1
	freq = $2 < 0 ? -$2 : $2

	if (avgoff == 0.0 && avgfreq == 0.0) {
	    avgoff = off
	    avgfreq = freq
	} else {
	    avgoff += '$smooth' * (off - avgoff)
	    avgfreq += '$smooth' * (freq - avgfreq)
	}

	if (avgoff > '$offsync' || avgfreq > '$freqsync') {
	    lastnonsync = time
	}
	time++
    } END {
	if (lastnonsync < time) {
	    print lastnonsync + 1
	} else {
	    print -1
	}
    }'
}

get_stat() {
    local statname=$1 index=$2

    if [ -z "$index" ]; then
	echo $(cat tmp/stats | grep "^$statname:" | cut -f 2)
    else
	cat tmp/stats | grep "^$statname:" | cut -f 2 |
	head -n $index | tail -n 1
    fi
}

check_stat() {
    local value=$1 min=$2 max=$3 tolerance=$4
    [ -z "$tolerance" ] && tolerance=0.0
    awk "
    BEGIN {
	eq = (\"$value\" == \"inf\" ||
	      $value + $value / 1e6 + $tolerance >= $min) &&
	     (\"$max\" == \"inf\" ||
	      (\"$value\" != \"inf\" &&
	      $value - $value / 1e6 - $tolerance <= $max))
	exit !eq
    }"
}

if [ -z "$CLKNETSIM_PATH" ]; then
    echo CLKNETSIM_PATH not set 2>&1
    exit 1
fi

if [ ! -x "$CLKNETSIM_PATH/clknetsim" -o ! -e "$CLKNETSIM_PATH/clknetsim.so" ]; then
    echo "can't find clknetsim or clknetsim.so in $CLKNETSIM_PATH"
    exit 1
fi

[ -d tmp ] || mkdir tmp
