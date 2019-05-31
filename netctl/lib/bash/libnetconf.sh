#!/bin/bash

[ -z "$__included_libnetconf" ] || return 0
declare -r __included_libnetconf=1

# External tool dependencies, MUST always be defined,
# even if empty (e.g.: declare -a crt1_request_tools_list=())
declare -a crt1_request_tools_list=(
	'ip'			# ip(8)
	'tc'			# tc(8)
	'xargs'			# xargs(1)
	'sed'			# sed(1)
	'cat'			# cat(1)
	'ipset'			# ipset(8)
	'iptables-restore'	# iptables-restore(8)
	'ip6tables-restore'	# ip6tables-restore(8)
	'sysctl'		# sysctl(8)
	'ethtool'		# ethtool(8)
)

# Log all messages to standard output in addition to logfile
NCTL_LOG_STD=y

# Source startup code
. @target@/netctl/lib/bash/crt1.sh

# Source functions libraries
. @target@/netctl/lib/bash/libbool.sh
. @target@/netctl/lib/bash/librtti.sh
. @target@/netctl/lib/bash/libfile.sh
. @target@/netctl/lib/bash/liblog.sh
. @target@/netctl/lib/bash/libacct.sh
. @target@/netctl/lib/bash/libstring.sh

##
## Accounting
##

# Usage: netconf_account <object> [<content_of_object>]
netconf_account()
{
	local -i rc=$?

	# is accounting enabled?
	nctl_is_yes "$NCTL_ACCOUNT_ENABLE" || return $rc

	# user
	local user
	if [ -n "$SUDO_USER" ]; then
		user="$SUDO_USER"
	elif [ -n "$LOGNAME" ]; then
		user="$LOGNAME"
	fi

	# command
	local command
	command="${netconf_fn:-${FUNCNAME[1]:-$FUNCNAME}}"
	command="${command#netconf_}"

	# object
	local object="${1:-unknown}"
	shift

	# status
	local status
	[ $rc -eq 0 ] && status='success' || status='failure'

	# Always manually specify locations where we account!
	# Accounting is a MUST for this subsystem.

	nctl_account \
		'[user]: %s [command]: %s [object]: %s [content of object]: %s [status]: %s\n' \
		"$user" "$command" "$object" "$*" "$status"

	return $rc
}
declare -fr netconf_account

##
## Helper functions
##

# Usage: netconf_for_each_elem <action> <elem>...
netconf_for_each_elem()
{
	local action="${1:?missing 1st argument to \"$FUNCNAME\" (action)}"
	shift

	local elem item refs addrs
	local -i rc=0

	while [ $# -gt 0 ]; do
		elem="$1"
		shift
		[ -n "$elem" ] || continue

		# Skip elements managed by user config
		[ -n "${netconf_user_map##*|$elem|*}" ] || continue

		eval refs="\${!${elem}_ref*}"
		# for compatibility only
		eval addrs="\${!${elem}_a*}"

		nctl_action_for_each \
			"netconf_${elem%%_*}_${action}" \
			"$elem" $refs $addrs ||
		: $((rc += $?))
	done

	return $rc
}

# Path to /[s]ys/[c]lass/[n]et directory.
declare -r NCTL_SCN_DIR="$NCTL_SYS_DIR/class/net"

# Usage: netconf_ifup {<var_name>}
netconf_ifup()
{
	local var_name="$1"
	local val

	eval "val=\"\$$var_name\""
	[ -n "$val" ] || return 0

	# Account actions
	trap '
		local netconf_fn="${FUNCNAME[1]}"
		netconf_account "$var_name" "$val"
		trap - RETURN
	' RETURN

	set -- $val

	local u_if="$1"
	shift
	case "$u_if" in
		*:*)
			## Address

			u_if="${u_if%:*}"
			ip addr replace dev "$u_if" "$@" 2>&1 |nctl_log_pipe
			;;
		*@*)
			## Existing interface (e.g. physical)

			local -a a=()
			local -i i=0 once=0

			u_if="${u_if#*@}"
			while [ $# -gt 0 ]; do
				case "$1" in
					'name')
						if [ $once -gt 0 ]; then
							shift 2
							continue
						else
							once=1
						fi
						;;
					*)
						a[$((i++))]="$1"
						shift
						continue
						;;
				esac

				if [ ! -e "$NCTL_SCN_DIR/$2" -o \
				       -e "$NCTL_SCN_DIR/$u_if" ]; then
					a[$((i++))]="$1"
					a[$((i++))]="$2"
				else
					u_if="$2"
				fi

				shift 2
			done

			if [ ${#a[@]} -le 0 ]; then
				return
			fi

			ip link set dev "$u_if" "${a[@]}" 2>&1 |nctl_log_pipe
			;;
		*+*)
			## Traffic control

			local u_if_object="${u_if%+*}"
			u_if="${u_if#*+}"
			tc "$u_if_object" replace dev "$u_if" "$@" 2>&1 |nctl_log_pipe
			;;
		*-*)
			## Ethtool settings

			local u_if_object="${u_if%-*}"
			u_if="${u_if##*-}"
			ethtool "$u_if_object" "$u_if" "$@" 2>&1 |NCTL_LOG_STD=n nctl_log_pipe
			;;
		*=*)
			## Sysctl settings

			sysctl -q -w "$u_if" 2>&1 |nctl_log_pipe
			;;
		*)
			## Non-existing interface (e.g. veth, vlan, gre, ...)

			if [ -e "$NCTL_SCN_DIR/$u_if" ]; then
				ip link set dev "$u_if" up "$@" 2>&1 |nctl_log_pipe
			else
				ip link replace dev "$u_if" up "$@" 2>&1 |nctl_log_pipe
			fi
			;;
	esac
	nctl_get_rc
}
declare -fr netconf_ifup

# Usage: netconf_ifdown {<var_name>}
netconf_ifdown()
{
	local var_name="$1"
	local val

	eval "val=\"\$$var_name\""
	[ -n "$val" ] || return 0

	# Account actions
	trap '
		local netconf_fn="${FUNCNAME[1]}"
		netconf_account "$var_name" "$val"
		trap - RETURN
	' RETURN

	set -- $val

	local u_if="$1"
	shift
	case "$u_if" in
		*:*)
			## Address

			local u_ip="$1"

			if [ -n "$(ip addr show to "$u_ip" dev "$u_if" 2>/dev/null)" ]; then
				ip addr del dev "$u_if" "$u_ip" 2>&1 |nctl_log_pipe
			else
				:
			fi
			;;
		*+*)
			## Traffic control
			;;
		*-*)
			## Ethtool settings
			;;
		*=*)
			## Sysctl settings
			;;
		*)
			## Link

			local u_if_old_name="${u_if#*@}"
			local u_if_new_name="${u_if%@*}"
			u_if="${u_if_new_name:-$u_if_old_name}"

			local u_if_scn="$NCTL_SCN_DIR/$u_if"
			if [ -e "$u_if_scn" ]; then
				if [ -e "$u_if_scn/device" ]; then
					ip link set dev "$u_if" down 2>&1 |nctl_log_pipe
				else
					ip link del dev "$u_if" 2>&1 |nctl_log_pipe
				fi
			else
				:
			fi
			;;
	esac
	nctl_get_rc
}
declare -fr netconf_ifdown

# Usage: netconf_ifshow {<var_name>}
netconf_ifshow()
{
	local var_name="$1"
	local val

	eval "val=\"\$$var_name\""
	[ -n "$val" ] || return 0

	# Account actions
	trap '
		local netconf_fn="${FUNCNAME[1]}"
		netconf_account "$var_name" "$val"
		trap - RETURN
	' RETURN

	set -- $val

	printf '%s="%s"\n' "$var_name" "$*" 2>&1 |nctl_log_pipe
	nctl_get_rc
}
declare -fr netconf_ifshow

##
## IFB
##

# Usage: netconf_ifb_up {<var_name>}
netconf_ifb_up()
{
	netconf_ifup "$@"
}

# Usage: netconf_ifb_down {<var_name>}
netconf_ifb_down()
{
	netconf_ifdown "$@"
}

# Usage: netconf_ifb_show {<var_name>}
netconf_ifb_show()
{
	netconf_ifshow "$@"
}

##
## VRF
##

# Usage: netconf_vrf_up {<var_name>}
netconf_vrf_up()
{
	netconf_ifup "$@"
}

# Usage: netconf_vrf_down {<var_name>}
netconf_vrf_down()
{
	netconf_ifdown "$@"
}

# Usage: netconf_vrf_show {<var_name>}
netconf_vrf_show()
{
	netconf_ifshow "$@"
}

##
## BRIDGE
##

# Usage: netconf_bridge_up {<var_name>}
netconf_bridge_up()
{
	netconf_ifup "$@"
}

# Usage: netconf_bridge_down {<var_name>}
netconf_bridge_down()
{
	netconf_ifdown "$@"
}

# Usage: netconf_bridge_show {<var_name>}
netconf_bridge_show()
{
	netconf_ifshow "$@"
}

##
## BOND
##

# Usage: netconf_bond_up {<var_name>}
netconf_bond_up()
{
	netconf_ifup "$@"
}

# Usage: netconf_bond_down {<var_name>}
netconf_bond_down()
{
	netconf_ifdown "$@"
}

# Usage: netconf_bond_show {<var_name>}
netconf_bond_show()
{
	netconf_ifshow "$@"
}

##
## HOST
##

# Usage: netconf_host_up {<var_name>}
netconf_host_up()
{
	netconf_ifup "$@"
}

# Usage: netconf_host_down {<var_name>}
netconf_host_down()
{
	netconf_ifdown "$@"
}

# Usage: netconf_host_show {<var_name>}
netconf_host_show()
{
	netconf_ifshow "$@"
}

##
## DUMMY
##

# Usage: netconf_dummy_up {<var_name>}
netconf_dummy_up()
{
	netconf_ifup "$@"
}

# Usage: netconf_dummy_down {<var_name>}
netconf_dummy_down()
{
	netconf_ifdown "$@"
}

# Usage: netconf_dummy_show {<var_name>}
netconf_dummy_show()
{
	netconf_ifshow "$@"
}

##
## VETH
##

# Usage: netconf_veth_up {<var_name>}
netconf_veth_up()
{
	netconf_ifup "$@"
}

# Usage: netconf_veth_down {<var_name>}
netconf_veth_down()
{
	netconf_ifdown "$@"
}

# Usage: netconf_veth_show {<var_name>}
netconf_veth_show()
{
	netconf_ifshow "$@"
}

##
## GRETAP
##

# Usage: netconf_gretap_up {<var_name>}
netconf_gretap_up()
{
	netconf_ifup "$@"
}

# Usage: netconf_gretap_down {<var_name>}
netconf_gretap_down()
{
	netconf_ifdown "$@"
}

# Usage: netconf_gretap_show {<var_name>}
netconf_gretap_show()
{
	netconf_ifshow "$@"
}

##
## IP6GRETAP
##

# Usage: netconf_ip6gretap_up {<var_name>}
netconf_ip6gretap_up()
{
	netconf_ifup "$@"
}

# Usage: netconf_ip6gretap_down {<var_name>}
netconf_ip6gretap_down()
{
	netconf_ifdown "$@"
}

# Usage: netconf_ip6gretap_show {<var_name>}
netconf_ip6gretap_show()
{
	netconf_ifshow "$@"
}

##
## VXLAN
##

# Usage: netconf_vxlan_up {<var_name>}
netconf_vxlan_up()
{
	netconf_ifup "$@"
}

# Usage: netconf_vxlan_down {<var_name>}
netconf_vxlan_down()
{
	netconf_ifdown "$@"
}

# Usage: netconf_vxlan_show {<var_name>}
netconf_vxlan_show()
{
	netconf_ifshow "$@"
}

##
## VLAN
##

# Usage: netconf_vlan_up {<var_name>}
netconf_vlan_up()
{
	netconf_ifup "$@"
}

# Usage: netconf_vlan_down {<var_name>}
netconf_vlan_down()
{
	netconf_ifdown "$@"
}

# Usage: netconf_vlan_show {<var_name>}
netconf_vlan_show()
{
	netconf_ifshow "$@"
}

##
## MACVLAN
##

# Usage: netconf_macvlan_up {<var_name>}
netconf_macvlan_up()
{
	netconf_ifup "$@"
}

# Usage: netconf_macvlan_down {<var_name>}
netconf_macvlan_down()
{
	netconf_ifdown "$@"
}

# Usage: netconf_macvlan_show {<var_name>}
netconf_macvlan_show()
{
	netconf_ifshow "$@"
}

##
## IPVLAN
##

# Usage: netconf_ipvlan_up {<var_name>}
netconf_ipvlan_up()
{
	netconf_ifup "$@"
}

# Usage: netconf_ipvlan_down {<var_name>}
netconf_ipvlan_down()
{
	netconf_ifdown "$@"
}

# Usage: netconf_ipvlan_show {<var_name>}
netconf_ipvlan_show()
{
	netconf_ifshow "$@"
}

##
## GRE
##

# Usage: netconf_gre_up {<var_name>}
netconf_gre_up()
{
	netconf_ifup "$@"
}

# Usage: netconf_gre_down {<var_name>}
netconf_gre_down()
{
	netconf_ifdown "$@"
}

# Usage: netconf_gre_show {<var_name>}
netconf_gre_show()
{
	netconf_ifshow "$@"
}

##
## IP6GRE
##

# Usage: netconf_ip6gre_up {<var_name>}
netconf_ip6gre_up()
{
	netconf_ifup "$@"
}

# Usage: netconf_ip6gre_down {<var_name>}
netconf_ip6gre_down()
{
	netconf_ifdown "$@"
}

# Usage: netconf_ip6gre_show {<var_name>}
netconf_ip6gre_show()
{
	netconf_ifshow "$@"
}

##
## NEIGHBOUR
##

# Usage: netconf_neighbour_up <var_name>
netconf_neighbour_up()
{
	local var_name="$1"
	local val

	eval "val=\"\$$var_name\""
	[ -n "$val" ] || return 0

	# Account actions
	trap 'netconf_account "$var_name" "$val"; trap - RETURN' RETURN

	set -- $val

	local u_if="$1"
	shift

	ip neighbour replace dev "$u_if" "$@" 2>&1 |nctl_log_pipe
	nctl_get_rc
}

# Usage: netconf_neighbour_down <var_name>
netconf_neighbour_down()
{
	local var_name="$1"
	local val

	eval "val=\"\$$var_name\""
	[ -n "$val" ] || return 0

	# Account actions
	trap 'netconf_account "$var_name" "$val"; trap - RETURN' RETURN

	set -- $val

	local u_if="$1"
	shift

	ip neighbour del dev "$u_if" "$@" &>/dev/null
}

# Usage: netconf_neighbour_show <var_name>
netconf_neighbour_show()
{
	local var_name="$1"
	local val

	eval "val=\"\$$var_name\""
	[ -n "$val" ] || return 0

	# Account actions
	trap 'netconf_account "$var_name" "$val"; trap - RETURN' RETURN

	set -- $val

	printf '%s="%s"\n' "$var_name" "$*" 2>&1 |nctl_log_pipe
	nctl_get_rc
}

##
## ROUTE
##

# Usage: netconf_get_rtargs <var_name> <ret_var_name> ...
netconf_get_rtargs()
{
	local var_name="$1"
	local ret_var_name="$2"
	shift 2
	local u_ip u_type

	while :; do
		u_ip="$1"
		[ -n "$u_ip" ] ||
			nctl_log_msg 'bad NET for %s\n' "$var_name" ||
			return

		[ -n "${u_ip##*[[:xdigit:]:]/[[:digit:]]*}" ] || break
		[ "$u_ip" != 'default' ] || break

		if [ -z "${u_ip##*:*}" ]; then
			# IPv6
			u_ip="$u_ip/128"
		elif [ -z "${u_ip##*.*}" ]; then
			# IPv4
			u_ip="$u_ip/32"
		else
			# route type
			[ -z "$u_type" ] ||
				nctl_log_msg 'bad NET for %s\n' "$var_name" ||
				return
			u_type="$u_ip"
			shift
			continue
		fi
		break
	done
	shift

	[ -n "$u_type" ] || u_type='unicast'

	nctl_return "$ret_var_name" "$u_type" "$u_ip" "$@"
}

# Usage: netconf_route_up <var_name>
netconf_route_up()
{
	local var_name="$1"
	local val

	eval "val=\"\$$var_name\""
	[ -n "$val" ] || return 0

	# Account actions
	trap 'netconf_account "$var_name" "$val"; trap - RETURN' RETURN

	set -- $val

	local -a cmd
	netconf_get_rtargs "$var_name" cmd "$@" || return

	ip route replace "${cmd[@]}" 2>&1 |nctl_log_pipe
	nctl_get_rc
}

# Usage: netconf_route_down <var_name>
netconf_route_down()
{
	local var_name="$1"
	local val

	eval "val=\"\$$var_name\""
	[ -n "$val" ] || return 0

	# Account actions
	trap 'netconf_account "$var_name" "$val"; trap - RETURN' RETURN

	set -- $val

	local -a cmd
	netconf_get_rtargs "$var_name" cmd "$@" || return

	ip route del "${cmd[@]}" &>/dev/null
}

# Usage: netconf_route_show <var_name>
netconf_route_show()
{
	local var_name="$1"
	local val

	eval "val=\"\$$var_name\""
	[ -n "$val" ] || return 0

	# Account actions
	trap 'netconf_account "$var_name" "$val"; trap - RETURN' RETURN

	set -- $val

	printf '%s="%s"\n' "$var_name" "$*" 2>&1 |nctl_log_pipe
	nctl_get_rc
}

##
## RULE
##

# Usage: netconf_rule_up <var_name>
netconf_rule_up()
{
	local var_name="$1"
	local val

	eval "val=\"\$$var_name\""
	[ -n "$val" ] || return 0

	# Account actions
	trap 'netconf_account "$var_name" "$val"; trap - RETURN' RETURN

	set -- $val

	local u_family="$1"
	case "$u_family" in
		-4|-6)
			;;
		*)
			nctl_log_msg 'bad FAMILY for %s\n' "$var_name" || return
			;;
	esac
	shift

	local u_pref="$1"
	[ -n "$u_pref" ] || nctl_log_msg 'bad PREF for %s\n' "$var_name" || return
	shift

	ip "$u_family" rule add pref "$u_pref" "$@" 2>&1 |nctl_log_pipe
	nctl_get_rc
}

# Usage: netconf_rule_down <var_name>
netconf_rule_down()
{
	local var_name="$1"
	local val

	eval "val=\"\$$var_name\""
	[ -n "$val" ] || return 0

	# Account actions
	trap 'netconf_account "$var_name" "$val"; trap - RETURN' RETURN

	set -- $val

	local u_family="$1"
	case "$u_family" in
		-4|-6)
			;;
		*)
			nctl_log_msg 'bad FAMILY for %s\n' "$var_name" || return
			;;
	esac
	shift

	local u_pref="$1"
	[ -n "$u_pref" ] || nctl_log_msg 'bad PREF for %s\n' "$var_name" || return
	shift

	ip "$u_family" rule del pref "$u_pref" "$@" &>/dev/null
}

# Usage: netconf_rule_show <var_name>
netconf_rule_show()
{
	local var_name="$1"
	local val

	eval "val=\"\$$var_name\""
	[ -n "$val" ] || return 0

	# Account actions
	trap 'netconf_account "$var_name" "$val"; trap - RETURN' RETURN

	set -- $val

	printf '%s="%s"\n' "$var_name" "$*" 2>&1 |nctl_log_pipe
	nctl_get_rc
}

##
## VR
##

# Usage: netconf_vr_up <var_name>
netconf_vr_up()
{
	# Account actions
	trap '
		netconf_account "$var_name" "$val"
		[ $rc -eq 0 ] || [ ! -e "/var/run/netns/$u_name" ] ||
			ip netns del "$u_name"
		trap - RETURN
	' RETURN

	local -i rc=0
	local u_name u_if u_dir u_rules

	local var_name="$1"
	local val

	eval "val=\"\$$var_name\""
	[ -n "$val" ] || return 0

	# Account actions
	trap '
		netconf_account "$var_name" "$val"
		[ $rc -eq 0 ] || [ ! -e "/var/run/netns/$u_name" ] ||
			ip netns del "$u_name"
		trap - RETURN
	' RETURN

	set -- $val

	u_name="$1"
	u_dir="$netconf_data_dir/vr/$u_name"

	[ -d "$u_dir" ] ||
		nctl_inc_rc rc || return $rc

	# 1. Create vr if not exist
	[ ! -e "/var/run/netns/$u_name" ] || return $rc

	ip netns add "$u_name" 2>&1 |nctl_log_pipe
	nctl_inc_rc rc || return $rc

	# 2. Up loopback interface
	ip netns exec "$u_name" ip link set dev lo up 2>&1 |nctl_log_pipe
	nctl_inc_rc rc || return $rc

	# 3. Setup and move interfaces to VR
	while [ $# -gt 0 ]; do
		shift
		u_if="$1"
		case "$u_if" in
			''|lo)
				# Empty or system loopback
				continue
				;;
			en*.*|eth*.*|br*.*|bond*.*|dmy*.*|veth*.*|gtp*.*|g6tp*.*)
				## VLAN

				# Load configuration if not already done
				nctl_is_empty_var 'netconf_vlan_list' &&
					netconf_source 'vlan'
				;;
			en*|eth*)
				## HOST

				# Load configuration if not already done
				nctl_is_empty_var 'netconf_host_list' &&
					netconf_source 'host'
				;;
			dmy*|lo*)
				## DUMMY

				# Load configuration if not already done
				nctl_is_empty_var 'netconf_dummy_list' &&
					netconf_source 'dummy'
				;;
			veth*)
				## VETH

				# Load configuration if not already done
				nctl_is_empty_var 'netconf_veth_list' &&
					netconf_source 'veth'
				;;
			mvl*)
				## MACVLAN

				# Load configuration if not already done
				nctl_is_empty_var 'netconf_macvlan_list' &&
					netconf_source 'macvlan'

				# Destroy it first, as it might be up and
				# configuring parameters like link-layer address
				# might fail.
				netconf_ifdown "${u_if//[^[:alnum:]_]/_}"
				;;
			ivl*)
				## IPVLAN

				# Load configuration if not already done
				nctl_is_empty_var 'netconf_ipvlan_list' &&
					netconf_source 'ipvlan'
				;;
			ifb*)
				## IFB

				# Load configuration if not already done
				nctl_is_empty_var 'netconf_ifb_list' &&
					netconf_source 'ifb'
				;;
			vrf*|br*|bond*|gtp*|g6tp*|vx*|gre*|g6re*)
				## VRF, BRIDGE, BOND, GRETAP, IP6GRETAP, VXLAN, GRE, IP6GRE

				nctl_log_msg 'x-netns for IFace %s not supported' "$u_if"
				! :
				nctl_inc_rc rc
				return $rc
				;;
			*)
				# Unknown
				nctl_log_msg 'bad IFace for %s\n' "$u_if"
				! :
				nctl_inc_rc rc
				return $rc
				;;
		esac

		# Up interface
		netconf_ifup "${u_if//[^[:alnum:]_]/_}"

		# Move interface to VR
		ip link set dev "$u_if" netns "$u_name" 2>&1 |nctl_log_pipe
		nctl_inc_rc rc || return $rc
	done

	# 4. Load ipset(8) rules

	for u_rules in "$u_dir"/ipset/ipset{4,6,}.rules; do
		[ -f "$u_rules" -a -s "$u_rules" ] || continue
		ip netns exec "$u_name" \
			"$SHELL" -c "ipset -exist restore <$u_rules" 2>&1 |nctl_log_pipe ||
				nctl_inc_rc rc || return $rc
	done

	# 5. Load iptables(8)/ip6tables(8) rules

	u_rules="$u_dir/iptables/rules.v4"
	if [ -f "$u_rules" -a -s "$u_rules" ]; then
		ip netns exec "$u_name" \
			"$SHELL" -c "iptables-restore <$u_rules" 2>&1 |nctl_log_pipe ||
				nctl_inc_rc rc || return $rc
	fi

	u_rules="$u_dir/ip6tables/rules.v6"
	if [ -f "$u_rules" -a -s "$u_rules" ]; then
		ip netns exec "$u_name" \
			"$SHELL" -c "ip6tables-restore <$u_rules" 2>&1 |nctl_log_pipe ||
				nctl_inc_rc rc || return $rc
	fi

	# 6. Configure sysctls
	ip netns exec "$u_name" \
		"$SHELL" -c "sysctl -qp $u_dir/sysctl.d/netctl.conf" 2>&1 |nctl_log_pipe ||
		nctl_inc_rc rc || return $rc

	# 7. Start network subsystem in vr
	NCTL_LOG_FILE=n \
	netconf_data_dir="$u_dir/netconf" \
	ip netns exec "$u_name" \
		"$program_invocation_name" start 2>&1 |nctl_log_pipe ||
		nctl_inc_rc rc || return $rc

	return $rc
}

# Usage: netconf_vr_down <var_name>
netconf_vr_down()
{
	local var_name="$1"
	local val

	eval "val=\"\$$var_name\""
	[ -n "$val" ] || return 0

	# Account actions
	trap 'netconf_account "$var_name" "$val"; trap - RETURN' RETURN

	set -- $val

	local u_name="$1"

	# 1. Destroy vr
	if [ -e "/var/run/netns/$u_name" ]; then
		ip netns del "$u_name" 2>&1 |nctl_log_pipe
		nctl_get_rc
	fi
}

# Usage: netconf_vr_show <var_name>
netconf_vr_show()
{
	local var_name="$1"
	local val

	eval "val=\"\$$var_name\""
	[ -n "$val" ] || return 0

	# Account actions
	trap 'netconf_account "$var_name" "$val"; trap - RETURN' RETURN

	set -- $val

	local u_name="$1"
	local u_dir="$netconf_data_dir/vr/$u_name"

	[ -d "$u_dir" ] || return

	printf '%s="%s"\n' "$var_name" "$*" 2>&1 |nctl_log_pipe
	nctl_get_rc || return

	# 1. List vr netconf configuration
	NCTL_LOG_PREFIX_NONE=y \
	NCTL_LOG_FILE=n \
	netconf_data_dir="$u_dir/netconf" \
		"$program_invocation_name" list 2>&1 |nctl_log_pipe
	nctl_get_rc
}

##
## USER
##

# Usage: netconf_user_for_each_elem <action> <var_name>
netconf_user_for_each_elem()
{
	local action="${1:?missing 1st argument to function \"$FUNCNAME\"}"
	local var_name="$2"
	local val

	eval "val=\"\$$var_name\""
	[ -n "$val" ] || return 0

	# Account actions
	trap '
		local netconf_fn="${FUNCNAME[1]}"
		netconf_account "$var_name" "$val"
		trap - RETURN
	' RETURN

	# Process user config elements
	local netconf_user_map='|'

	netconf_for_each_elem "$action" $val
}

# Usage: netconf_user_up <var_name>
netconf_user_up()
{
	netconf_user_for_each_elem 'up' "$1"
}

# Usage: netconf_user_down <var_name>
netconf_user_down()
{
	netconf_user_for_each_elem 'down' "$1"
}

# Usage: netconf_user_show <var_name>
netconf_user_show()
{
	netconf_user_for_each_elem 'show' "$1"
}

##
## Helper functions
##

# Usage: netconf_source [<vlan>...,<rule>,<vr>,...]...
netconf_source()
{
	local -a ns_files
	local -i ns_file_idx=0 ns_var_idx=0
	local ns_item ns_var ns_dir ns_file ns_regex ns_eval ns_tmp

	# Need for substitution when iterating over variables names and set arguments
	ns_eval="$IFS"

	# Get arguments to pattern string excluding duplicates
	nctl_mtch4pat 'ns_regex' '|' "$netconf_items_mtch" "$@" || return
	nctl_args2pat 'ns_regex' '|' "${ns_regex[@]}"

	# Initialize all arrays
	for ns_item in "${netconf_items_dflt[@]}"; do
		eval "netconf_${ns_item}_list=()"
	done

	# Move user configuration to the end to support variable overwrites
	if [ -z "${ns_regex##*|user|*}" ]; then
		ns_regex="${ns_regex/|user/}"
		ns_regex="${ns_regex}user"

		netconf_user_list='|'
	else
		ns_regex="${ns_regex%|}"
	fi

	# Map is used to check if user config overrides variable
	netconf_user_map='|'

	ns_regex="${ns_regex#|}"

	# Put to arguments back
	IFS='|'

	set -- $ns_regex

	IFS="$ns_eval"

	# Process arguments
	for ns_item in "$@"; do
		# Skip non-existent directories
		ns_dir="$netconf_data_dir/$ns_item"

		[ -d "$ns_dir" ] || continue

		# Source file(s)
		ns_files=()
		ns_file_idx=0

		for ns_file in "$ns_dir"/*; do
			[ -f "$ns_file" -a -r "$ns_file" -a -s "$ns_file" ] ||
				continue

			. "$ns_file" || return

			ns_files[$((ns_file_idx++))]="$ns_file"
		done

		# Skip when nothing is sourced
		[ $ns_file_idx -gt 0 ] || continue

		# Source variable(s)
		if [ "$ns_item" = 'user' ]; then
			# |user| assumed to be the last one
			ns_regex="${netconf_items_mtch%|user|}"
		else
			ns_regex="$ns_item"
		fi

		ns_regex="(${ns_regex})_[[:alnum:]]+"

		IFS=$'\n'

		for ns_var in \
		$(
			# Subshell resets IFS value
			IFS=$'\n'

			echo "${ns_files[*]}" |\
			xargs sed -nE \
				-e '/^[[:space:]]*(#|$)/b' \
				-e '/^[[:space:]]*[^[:space:]]+_(ref|a)[[:digit:]]+=/b' \
				-e "s/^[[:space:]]*($ns_regex)=[\"']?[[:space:]]*[^[:space:]'\"]+.*['\"]?[[:space:]]*(#|\$)/\1/p"
		)
		do
			# Note that element indexing isn't contiguous
			eval "netconf_${ns_var%%_*}_list[\$((ns_var_idx++))]='$ns_var'"

			[ "$ns_item" = 'user' ] || continue

			# Use pattern match to exclude duplicates
			ns_tmp="user_${ns_var#*_}"
			[ -z "${netconf_user_list##*|$ns_tmp|*}" ] ||
				netconf_user_list="$netconf_user_list$ns_tmp|"

			# Create map of user managed variables
			netconf_user_map="$netconf_user_map$ns_var|"

			# Value is a list of item(s) variable names
			eval "$ns_tmp=\"\$$ns_tmp\$ns_var \""
		done

		IFS="$ns_eval"
	done

	# Turn pattern into array
	netconf_user_list="${netconf_user_list%|}"

	if [ -n "$netconf_user_list" ]; then
		netconf_user_list="${netconf_user_list#|}"

		IFS='|'

		netconf_user_list=($netconf_user_list)

		IFS="$ns_eval"
	fi

	# Unset empty arrays to keep global namespace clean
	for ns_item in "$@"; do
		eval "ns_tmp=\${#netconf_${ns_item}_list[@]}"
		[ $ns_tmp -gt 0 ] || eval "unset netconf_${ns_item}_list"
	done

	return 0
}
declare -fr netconf_source

################################################################################
# Initialization                                                               #
################################################################################

### Global items default list and string to check item presence

declare -ar netconf_items_dflt=(
	# Note that order specifies start/up order
	'ifb'
	'vrf'
	'bridge'
	'bond'
	'host'
	'dummy'
	'veth'
	'gretap'
	'ip6gretap'
	'vxlan'
	'vlan'
	'macvlan'
	'ipvlan'
	'gre'
	'ip6gre'
	'neighbour'
	'route'
	'rule'
	'vr'
	# This should be the last one (see netconf_source())
	'user'
)
declare -ir netconf_items_dflt_size=${#netconf_items_dflt[@]}
declare -ir netconf_item_name_max=9 # neighbour, ip6gretap

nctl_args2pat 'netconf_items_mtch' '|' "${netconf_items_dflt[@]}"
declare -r netconf_items_mtch

# Taken from ip-link(8)
declare -r netconf_item_ifb_desc='Intermediate Functional Block device'
declare -r netconf_item_vrf_desc='Interface for L3 VRF domains'
declare -r netconf_item_bridge_desc='Ethernet Bridge device'
declare -r netconf_item_bond_desc='Bonding device can'
declare -r netconf_item_host_desc='Existing host interface (e.g. physical NIC) interface'
declare -r netconf_item_dummy_desc='Dummy network interface'
declare -r netconf_item_veth_desc='Virtual ethernet interface'
declare -r netconf_item_gretap_desc='Virtual L2 tunnel interface GRE over IPv4'
declare -r netconf_item_ip6gretap_desc='Virtual L2 tunnel interface GRE over IPv6'
declare -r netconf_item_vxlan_desc='Virtual eXtended LAN'
declare -r netconf_item_vlan_desc='802.1q tagged virtual LAN interface'
declare -r netconf_item_macvlan_desc='Virtual interface based on link layer address (MAC)'
declare -r netconf_item_ipvlan_desc='Interface for L3 (IPv6/IPv4) based VLANs'
declare -r netconf_item_gre_desc='Virtual tunnel interface GRE over IPv4'
declare -r netconf_item_ip6gre_desc='Virtual tunnel interface GRE over IPv6'

# Taken from ip-neighbour(8), ip-route(8) and ip-rule(8)
declare -r netconf_item_neighbour_desc='Neighbour tables entries'
declare -r netconf_item_route_desc='Routing tables entries'
declare -r netconf_item_rule_desc='Routing policy database entries'

# Own description, ip-netns(8)
declare -r netconf_item_vr_desc='Virtual Router based on network namespaces'

# Include all items in single configuration file
declare -r netconf_item_user_desc='User specific configuration files'

# Netconf directories.
: ${netconf_etc_dir:="@target@/netctl/etc/netconf"}
: ${netconf_sysconfig_dir:="@root@/etc/netconf"}
: ${netconf_data_dir:="$netconf_etc_dir"}

# Open accounting file. We cant rely on automatic opening by netconf_account()
# because race condition might occur and NCTL_LOGFILE_FD == NCTL_ACCOUNT_FD.
#
# TODO: implement synchronization facilities
#
nctl_openaccount ||:
