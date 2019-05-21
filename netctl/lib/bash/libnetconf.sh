#!/bin/bash

[ -z "$__included_libnetconf" ] || return 0
declare -r __included_libnetconf=1

# External tool dependencies, MUST always be defined,
# even if empty (e.g.: declare -a crt1_request_tools_list=())
declare -a crt1_request_tools_list=(
	'ip'			# ip(8)
	'tc'			# tc(8)
	'sort'			# sort(1)
	'find'			# find(1)
	'sed'			# sed(1)
	'cat'			# cat(1)
	'ipset'			# ipset(8)
	'iptables-restore'	# iptables-restore(8)
	'ip6tables-restore'	# ip6tables-restore(8)
	'sysctl'		# sysctl(8)
	'ethtool'		# ethtool(8)
)

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

			ip link replace dev "$u_if" up "$@" 2>&1 |nctl_log_pipe
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

# Usage: netconf_iflist {<var_name>}
netconf_iflist()
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
declare -fr netconf_iflist

##
## VRF
##

# Usage: netconf_vfup {<var_name>}
netconf_vfup()
{
	netconf_ifup "$@"
}

# Usage: netconf_vfdown {<var_name>}
netconf_vfdown()
{
	netconf_ifdown "$@"
}

# Usage: netconf_vflist {<var_name>}
netconf_vflist()
{
	netconf_iflist "$@"
}

# Usage: netconf_vfusage [<action>] [<var_name_descr>]
netconf_vfusage()
{
	nctl_log_msg 'usage: %s %s %s...\n' \
		"$program_invocation_short_name" \
		"${1:-vf\{up|down|list|usage\}}" \
		"${2:-<vrf_iface_name>}"
}

##
## BRIDGE
##

# Usage: netconf_brup {<var_name>}
netconf_brup()
{
	netconf_ifup "$@"
}

# Usage: netconf_brdown {<var_name>}
netconf_brdown()
{
	netconf_ifdown "$@"
}

# Usage: netconf_brlist {<var_name>}
netconf_brlist()
{
	netconf_iflist "$@"
}

# Usage: netconf_brusage [<action>] [<var_name_descr>]
netconf_brusage()
{
	nctl_log_msg 'usage: %s %s %s...\n' \
		"$program_invocation_short_name" \
		"${1:-br\{up|down|list|usage\}}" \
		"${2:-<bridge_iface_name>}"
}

##
## BOND
##

# Usage: netconf_bnup {<var_name>}
netconf_bnup()
{
	netconf_ifup "$@"
}

# Usage: netconf_bndown {<var_name>}
netconf_bndown()
{
	netconf_ifdown "$@"
}

# Usage: netconf_bnlist {<var_name>}
netconf_bnlist()
{
	netconf_iflist "$@"
}

# Usage: netconf_bnusage [<action>] [<var_name_descr>]
netconf_bnusage()
{
	nctl_log_msg 'usage: %s %s %s...\n' \
		"$program_invocation_short_name" \
		"${1:-bn\{up|down|list|usage\}}" \
		"${2:-<bond_iface_name>}"
}

##
## HOST
##

# Usage: netconf_htup {<var_name>}
netconf_htup()
{
	netconf_ifup "$@"
}

# Usage: netconf_htdown {<var_name>}
netconf_htdown()
{
	netconf_ifdown "$@"
}

# Usage: netconf_htlist {<var_name>}
netconf_htlist()
{
	netconf_iflist "$@"
}

# Usage: netconf_htusage [<action>] [<var_name_descr>]
netconf_htusage()
{
	nctl_log_msg 'usage: %s %s %s...\n' \
		"$program_invocation_short_name" \
		"${1:-ht\{up|down|list|usage\}}" \
		"${2:-<host_iface_name>}"
}

##
## DUMMY
##

# Usage: netconf_dmup {<var_name>}
netconf_dmup()
{
	netconf_ifup "$@"
}

# Usage: netconf_dmdown {<var_name>}
netconf_dmdown()
{
	netconf_ifdown "$@"
}

# Usage: netconf_dmlist {<var_name>}
netconf_dmlist()
{
	netconf_iflist "$@"
}

# Usage: netconf_dmusage [<action>] [<var_name_descr>]
netconf_dmusage()
{
	nctl_log_msg 'usage: %s %s %s...\n' \
		"$program_invocation_short_name" \
		"${1:-lo\{up|down|list|usage\}}" \
		"${2:-<dummy_iface_name>}"
}

##
## VETH
##

# Usage: netconf_vzup {<var_name>}
netconf_vzup()
{
	netconf_ifup "$@"
}

# Usage: netconf_vzdown {<var_name>}
netconf_vzdown()
{
	netconf_ifdown "$@"
}

# Usage: netconf_vzlist {<var_name>}
netconf_vzlist()
{
	netconf_iflist "$@"
}

# Usage: netconf_vzusage [<action>] [<var_name_descr>]
netconf_vzusage()
{
	nctl_log_msg 'usage: %s %s %s...\n' \
		"$program_invocation_short_name" \
		"${1:-vz\{up|down|list|usage\}}" \
		"${2:-<veth_iface_name>}"
}

##
## GRETAP
##

# Usage: netconf_gtup {<var_name>}
netconf_gtup()
{
	netconf_ifup "$@"
}

# Usage: netconf_gtdown {<var_name>}
netconf_gtdown()
{
	netconf_ifdown "$@"
}

# Usage: netconf_gtlist {<var_name>}
netconf_gtlist()
{
	netconf_iflist "$@"
}

# Usage: netconf_gtusage [<action>] [<var_name_descr>]
netconf_gtusage()
{
	nctl_log_msg 'usage: %s %s %s...\n' \
		"$program_invocation_short_name" \
		"${1:-gt\{up|down|list|usage\}}" \
		"${2:-<gretap_iface_name>}"
}

##
## IP6GRETAP
##

# Usage: netconf_g6tup {<var_name>}
netconf_g6tup()
{
	netconf_ifup "$@"
}

# Usage: netconf_g6tdown {<var_name>}
netconf_g6tdown()
{
	netconf_ifdown "$@"
}

# Usage: netconf_g6tlist {<var_name>}
netconf_g6tlist()
{
	netconf_iflist "$@"
}

# Usage: netconf_g6tusage [<action>] [<var_name_descr>]
netconf_g6tusage()
{
	nctl_log_msg 'usage: %s %s %s...\n' \
		"$program_invocation_short_name" \
		"${1:-g6t\{up|down|list|usage\}}" \
		"${2:-<ip6gretap_iface_name>}"
}

##
## VXLAN
##

# Usage: netconf_vxup {<var_name>}
netconf_vxup()
{
	netconf_ifup "$@"
}

# Usage: netconf_vxdown {<var_name>}
netconf_vxdown()
{
	netconf_ifdown "$@"
}

# Usage: netconf_vxlist {<var_name>}
netconf_vxlist()
{
	netconf_iflist "$@"
}

# Usage: netconf_vxusage [<action>] [<var_name_descr>]
netconf_vxusage()
{
	nctl_log_msg 'usage: %s %s %s...\n' \
		"$program_invocation_short_name" \
		"${1:-vx\{up|down|list|usage\}}" \
		"${2:-<vxlan_iface_name>}"
}

##
## VLAN
##

# Usage: netconf_vup {<var_name>}
netconf_vup()
{
	netconf_ifup "$@"
}

# Usage: netconf_vdown {<var_name>}
netconf_vdown()
{
	netconf_ifdown "$@"
}

# Usage: netconf_vlist {<var_name>}
netconf_vlist()
{
	netconf_iflist "$@"
}

# Usage: netconf_vusage [<action>] [<var_name_descr>]
netconf_vusage()
{
	nctl_log_msg 'usage: %s %s %s...\n' \
		"$program_invocation_short_name" \
		"${1:-v\{up|down|list|usage\}}" \
		"${2:-<vlan_iface_name>}"
}

##
## MACVLAN
##

# Usage: netconf_mvup {<var_name>}
netconf_mvup()
{
	netconf_ifup "$@"
}

# Usage: netconf_mvdown {<var_name>}
netconf_mvdown()
{
	netconf_ifdown "$@"
}

# Usage: netconf_mvlist {<var_name>}
netconf_mvlist()
{
	netconf_iflist "$@"
}

# Usage: netconf_mvusage [<action>] [<var_name_descr>]
netconf_mvusage()
{
	nctl_log_msg 'usage: %s %s %s...\n' \
		"$program_invocation_short_name" \
		"${1:-mv\{up|down|list|usage\}}" \
		"${2:-<macvlan_iface_name>}"
}

##
## IPVLAN
##

# Usage: netconf_ivup {<var_name>}
netconf_ivup()
{
	netconf_ifup "$@"
}

# Usage: netconf_ivdown {<var_name>}
netconf_ivdown()
{
	netconf_ifdown "$@"
}

# Usage: netconf_ivlist {<var_name>}
netconf_ivlist()
{
	netconf_iflist "$@"
}

# Usage: netconf_ivusage [<action>] [<var_name_descr>]
netconf_ivusage()
{
	nctl_log_msg 'usage: %s %s %s...\n' \
		"$program_invocation_short_name" \
		"${1:-iv\{up|down|list|usage\}}" \
		"${2:-<ipvlan_iface_name>}"
}

##
## GRE
##

# Usage: netconf_gup {<var_name>}
netconf_gup()
{
	netconf_ifup "$@"
}

# Usage: netconf_gdown {<var_name>}
netconf_gdown()
{
	netconf_ifdown "$@"
}

# Usage: netconf_glist {<var_name>}
netconf_glist()
{
	netconf_iflist "$@"
}

# Usage: netconf_gusage [<action>] [<var_name_descr>]
netconf_gusage()
{
	nctl_log_msg 'usage: %s %s %s...\n' \
		"$program_invocation_short_name" \
		"${1:-g\{up|down|list|usage\}}" \
		"${2:-<gre_iface_name>}"
}

##
## IP6GRE
##

# Usage: netconf_g6rup {<var_name>}
netconf_g6up()
{
	netconf_ifup "$@"
}

# Usage: netconf_g6down {<var_name>}
netconf_g6down()
{
	netconf_ifdown "$@"
}

# Usage: netconf_g6list {<var_name>}
netconf_g6list()
{
	netconf_iflist "$@"
}

# Usage: netconf_g6usage [<action>] [<var_name_descr>]
netconf_g6usage()
{
	nctl_log_msg 'usage: %s %s %s...\n' \
		"$program_invocation_short_name" \
		"${1:-g6\{up|down|list|usage\}}" \
		"${2:-<ip6gre_iface_name>}"
}

##
## IFB
##

# Usage: netconf_ibup {<var_name>}
netconf_ibup()
{
	netconf_ifup "$@"
}

# Usage: netconf_ibdown {<var_name>}
netconf_ibdown()
{
	netconf_ifdown "$@"
}

# Usage: netconf_iblist {<var_name>}
netconf_iblist()
{
	netconf_iflist "$@"
}

# Usage: netconf_ibusage [<action>] [<var_name_descr>]
netconf_ibusage()
{
	nctl_log_msg 'usage: %s %s %s...\n' \
		"$program_invocation_short_name" \
		"${1:-ib\{up|down|list|usage\}}" \
		"${2:-<ifb_iface_name>}"
}

##
## NEIGHBOUR
##

# Usage: netconf_ngup <var_name>
netconf_ngup()
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

# Usage: netconf_ngdown <var_name>
netconf_ngdown()
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

# Usage: netconf_nglist <var_name>
netconf_nglist()
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

# Usage: netconf_ngusage [<action>] [<var_name_descr>]
netconf_ngusage()
{
	nctl_log_msg 'usage: %s %s %s...\n' \
		"$program_invocation_short_name" \
		"${1:-ng\{up|down|list|usage\}}" \
		"${2:-<neighbour_name>}"
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

# Usage: netconf_rtup <var_name>
netconf_rtup()
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

# Usage: netconf_rtdown <var_name>
netconf_rtdown()
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

# Usage: netconf_rtlist <var_name>
netconf_rtlist()
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

# Usage: netconf_rtusage [<action>] [<var_name_descr>]
netconf_rtusage()
{
	nctl_log_msg 'usage: %s %s %s...\n' \
		"$program_invocation_short_name" \
		"${1:-rt\{up|down|list|usage\}}" \
		"${2:-<route_name>}"
}

##
## RULE
##

# Usage: netconf_reup <var_name>
netconf_reup()
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

# Usage: netconf_redown <var_name>
netconf_redown()
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

# Usage: netconf_relist <var_name>
netconf_relist()
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

# Usage: netconf_reusage [<action>] [<var_name_descr>]
netconf_reusage()
{
	nctl_log_msg 'usage: %s %s %s...\n' \
		"$program_invocation_short_name" \
		"${1:-re\{up|down|list|usage\}}" \
		"${2:-<rule_name>}"
}

##
## VR
##

# Usage: netconf_vrup <var_name>
netconf_vrup()
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
	u_dir="$netconf_dir/vr/$u_name"

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
	netconf_dir="$u_dir/netconf" \
	ip netns exec "$u_name" \
		"$program_invocation_name" start 2>&1 |nctl_log_pipe ||
		nctl_inc_rc rc || return $rc

	return $rc
}

# Usage: netconf_vrdown <var_name>
netconf_vrdown()
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

# Usage: netconf_vrlist <var_name>
netconf_vrlist()
{
	local var_name="$1"
	local val

	eval "val=\"\$$var_name\""
	[ -n "$val" ] || return 0

	# Account actions
	trap 'netconf_account "$var_name" "$val"; trap - RETURN' RETURN

	set -- $val

	local u_name="$1"
	local u_dir="$netconf_dir/vr/$u_name"

	[ -d "$u_dir" ] || return

	printf '%s="%s"\n' "$var_name" "$*" 2>&1 |nctl_log_pipe
	nctl_get_rc || return

	# 1. List vr netconf configuration
	NCTL_LOG_PREFIX_NONE=y \
	NCTL_LOG_FILE=n \
	netconf_dir="$u_dir/netconf" \
		"$program_invocation_name" list 2>&1 |nctl_log_pipe
	nctl_get_rc
}

# Usage: netconf_vrusage [<action>] [<var_name_descr>]
netconf_vrusage()
{
	nctl_log_msg 'usage: %s %s %s...\n' \
		"$program_invocation_short_name" \
		"${1:-vr\{up|down|list|usage\}}" \
		"${2:-<vr_name>}"
}

##
## Helper functions
##

# Usage: netconf_source_files <array_name> <var_name_regex> <file_name_regex> <dir_entry> ...
netconf_source_files()
{
	local nsf_a_name="${1:?missing 1st argument to function \"$FUNCNAME\" (a_name)}"
	local nsf_var_name_regex="${2:?missing 2d argument to function \"$FUNCNAME\" (var_name_regex)}"
	local nsf_file_name_regex="${3:?missing 3rd argument to function \"$FUNCNAME\" (file_name_regex)}"
	shift 3
	local -a nsf_a_data
	local -i nsf_a_size
	local -i nsf_a_i
	local nsf_eval

	nsf_eval="$IFS"
	IFS=$'\n'
	nctl_set_val nsf_a_data \
	$(
		find "$@" -maxdepth 1 -regextype 'posix-egrep' \
			-type f -regex ".*/$nsf_file_name_regex\$" |LC_ALL=C sort -u
	)
	IFS="$nsf_eval"

	for ((nsf_a_i = 0, nsf_a_size = ${#nsf_a_data[@]};
		nsf_a_i < nsf_a_size; nsf_a_i++)); do
		nctl_SourceIfNotEmpty "${nsf_a_data[$nsf_a_i]}" ||
			unset nsf_a_data[$nsf_a_i]
	done
	[ ${#nsf_a_data[@]} -gt 0 ] || return 0

	nsf_eval="$IFS"
	IFS=$'\n'
	nctl_set_val "$nsf_a_name" \
	$(
		sed -nE "${nsf_a_data[@]}" \
			-e '/^[[:space:]]*(#|$)/b' \
			-e '/[^[:space:]]_(ref|a)[[:digit:]]+=/b' \
			-e "s/^[[:space:]]*($nsf_var_name_regex)=[\"']?.*['\"]?[[:space:]]*(#|\$)/\1/p"
	)
	IFS="$nsf_eval"
}
declare -fr netconf_source_files

# Usage: netconf_source [<vlan>...,<rule>,<vr>,...]...
netconf_source()
{
	local -i ns_size
	local -i ns_i
	local -i ns_rc=0
	local ns_v_name NS_V_NAME
	local ns_regex ns_regex_f ns_dir

	: ${netconf_dir:="$NETCONF_DIR"}

	for ((ns_i = 0, ns_size=$#;
		ns_i < ns_size; ns_i++)); do
		ns_v_name="$1"
		shift

		# Adjst configuration for known subsystems, ignore unknown/empty.

		# empty
		if [ -z "$ns_v_name" ]; then
			continue
		fi
		# unknown
		if [ -n "${netconf_item_mtch##*|$ns_v_name|*}" ]; then
			: $((ns_rc++))
			break
		fi

		nctl_strtoupper "$ns_v_name" NS_V_NAME

		eval "netconf_${ns_v_name}_list=()"
		eval ": \${netconf_${ns_v_name}_regex:=\"\$NETCONF_${NS_V_NAME}_REGEX\"}"
		eval ": \${netconf_${ns_v_name}_regex_f:=\"\$NETCONF_${NS_V_NAME}_REGEX_F\"}"

		# Get variable name regex
		nctl_get_val "netconf_${ns_v_name}_regex" ns_regex ||
			continue
		# Get file name regex
		nctl_get_val "netconf_${ns_v_name}_regex_f" ns_regex_f ||
			continue
		# Get directory/file name
		ns_dir="$netconf_dir/$ns_v_name" && [ -d "$ns_dir" ] ||
			continue
		# Source file(s)
		netconf_source_files \
			"netconf_${ns_v_name}_list" \
			"$ns_regex" \
			"$ns_regex_f" \
			"$ns_dir" ||
		nctl_inc_rc ns_rc
	done

	return $ns_rc
}
declare -fr netconf_source

################################################################################
# Initialization                                                               #
################################################################################

### Global items default list and string to check item presence

declare -ar netconf_items_dflt=(
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
	'ifb'
	'neighbour'
	'route'
	'rule'
	'vr'
)
declare -ir netconf_items_dflt_size=${#netconf_items_dflt[@]}

nctl_args2pat 'netconf_items_mtch' '|' "${netconf_items_dflt[@]}"
declare -r netconf_items_mtch

# Netconf base directory.
: ${NETCONF_DIR:="$NCTL_PREFIX/etc/netconf"}

# Open accounting file. We cant rely on automatic opening by netconf_account()
# because race condition might occur and NCTL_LOGFILE_FD == NCTL_ACCOUNT_FD.
#
# TODO: implement synchronization facilities
#
nctl_openaccount ||:

# Source configuration
netconf_source "$@"
