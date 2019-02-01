#!/bin/bash

[ -z "$__included_libnetconf" ] || return 0
declare -r __included_libnetconf=1

# External tool dependencies, MUST always be defined,
# even if empty (e.g.: declare -a crt1_request_tools_list=())
declare -a crt1_request_tools_list=(
	'ip'			# ip(8)
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
. /netctl/lib/bash/crt1.sh

# Source functions libraries
. /netctl/lib/bash/libbool.sh
. /netctl/lib/bash/librtti.sh
. /netctl/lib/bash/libfile.sh
. /netctl/lib/bash/liblog.sh
. /netctl/lib/bash/libacct.sh

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
	command="${FUNCNAME[1]:-$FUNCNAME}"
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

# Usage: netconf_usage [<action>]
netconf_usage()
{
	local -i rc=$?

	local a="${1:-${FUNCNAME[1]}}"
	a="${a#netconf_}"
	[ -n "$a" ] || exit $rc

	local __shopt=`shopt -p extglob`
	shopt -s extglob
	local action="${a%@(up|down|list|usage)}"
	eval "$__shopt"
	[ -n "$action" ] || exit $rc

	action="netconf_${action}usage"
	nctl_is_function "$action" && "$action" "$a"

	exit $rc
}
declare -fr netconf_usage

# Usage: netconf_get_val <var_get> [<var>] [<index>]
netconf_get_val()
{
	local ngv_var_get="$1"
	[ -n "$ngv_var_get" ] || netconf_usage
	local -i ngv_rc=0

	ngv__nctl_get_val_check()
	{
		[ -n "$nctl_get_val_val" ] ||
			nctl_log_msg 'empty or unset variable %s\n' \
				"$ngv_var_get"
	}
	nctl_get_val_check='ngv__nctl_get_val_check' \
		nctl_get_val "$@" || nctl_inc_rc ngv_rc

	# Remove internal function from global namespace
	unset -f ngv__nctl_get_val_check

	return $ngv_rc
}
declare -fr netconf_get_val

# Path to /[s]ys/[c]lass/[n]et directory.
declare -r NCTL_SCN_DIR="$NCTL_SYS_DIR/class/net"

# Usage: netconf_ifup {<if_name>|<var_name>}
netconf_ifup()
{
	# Account actions
	trap 'netconf_account "$var_name" "$val"; trap - RETURN' RETURN

	local var_name="$1"
	var_name="${var_name//\./_}"
	var_name="${var_name//:/_a}"

	local val
	netconf_get_val "$var_name" val || return

	eval set -- $val

	local u_if="$1"
	shift
	case "$u_if" in
		*:*)
			## Address

			u_if="${u_if%:*}"
			ip addr replace dev "$u_if" "$@" 2>&1 |nctl_log_pipe
			nctl_get_rc
			# nothing to configure
			return
			;;
		*@*)
			## Existing interface (e.g. physical)

			local u_if_old_name="${u_if#*@}"
			ip link set dev "$u_if_old_name" "$@" 2>&1 |nctl_log_pipe
			nctl_get_rc || return
			local u_if_new_name="${u_if%@*}"
			u_if="${u_if_new_name:-$u_if_old_name}"
			;;
		*)
			## Non-existing interface (e.g. veth, vlan, gre, ...)

			ip link replace dev "$u_if" up "$@" 2>&1 |nctl_log_pipe
			nctl_get_rc || return
			;;
	esac

	# Make sure interface created
	[ -e "$NCTL_SCN_DIR/$u_if" ] || return

	# Apply sysctl(8) settings
	local sysctl_file="/netctl/etc/netconf/sysctl.d/$u_if"
	if [ -f "$sysctl_file" -a -s "$sysctl_file" ]; then
		sysctl -q \
			--pattern="^net[./]ipv[46][./](conf|neigh)[./]$u_if[./].+" \
			--load="$sysctl_file" 2>&1 |nctl_log_pipe
		nctl_get_rc || return
	fi
}
declare -fr netconf_ifup

# Usage: netconf_ifdown {<if_name>|<var_name>}
netconf_ifdown()
{
	# Account actions
	trap 'netconf_account "$var_name" "$val"; trap - RETURN' RETURN

	local var_name="$1"
	var_name="${var_name//\./_}"
	var_name="${var_name//:/_a}"

	local val
	netconf_get_val "$var_name" val || return

	eval set -- $val

	local u_if="$1"
	shift
	case "$u_if" in
		*:*)
			## Address

			local u_ip="$1"

			if [ -n "$(ip addr show to "$u_ip" dev "$u_if" 2>/dev/null)" ]; then
				ip addr del dev "$u_if" "$u_ip" 2>&1 |nctl_log_pipe
				nctl_get_rc || return
			fi
			;;
		*)
			## Link

			local u_if_old_name="${u_if#*@}"
			local u_if_new_name="${u_if%@*}"
			u_if="${u_if_new_name:-$u_if_old_name}"

			local u_if_scn="$NCTL_SCN_DIR/$u_if"
			if [ -e "$u_if_scn" -a ! -e "$u_if_scn/device" ]; then
				ip link del dev "$u_if" 2>&1 |nctl_log_pipe
				nctl_get_rc || return
			fi
			;;
	esac
}
declare -fr netconf_ifdown

# Usage: netconf_iflist {<if_name>|<var_name>}
netconf_iflist()
{
	# Account actions
	trap 'netconf_account "$var_name" "$val"; trap - RETURN' RETURN

	local var_name="$1"
	var_name="${var_name//\./_}"
	var_name="${var_name//:/_a}"

	local val
	netconf_get_val "$var_name" val || return

	set -- $val

	printf '%s="%s"\n' "$var_name" "$*" 2>&1 |nctl_log_pipe
	nctl_get_rc
}
declare -fr netconf_iflist

##
## BRIDGE
##

# Usage: netconf_brup {<if_name>|<var_name>}
netconf_brup()
{
	netconf_ifup "$@"
}

# Usage: netconf_brdown {<if_name>|<var_name>}
netconf_brdown()
{
	netconf_ifdown "$@"
}

# Usage: netconf_brlist {<if_name>|<var_name>}
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

# Usage: netconf_bnup {<if_name>|<var_name>}
netconf_bnup()
{
	netconf_ifup "$@"
}

# Usage: netconf_bndown {<if_name>|<var_name>}
netconf_bndown()
{
	netconf_ifdown "$@"
}

# Usage: netconf_bnlist {<if_name>|<var_name>}
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
## PHYS
##

# Usage: netconf_phup {<if_name>|<var_name>}
netconf_phup()
{
	netconf_ifup "$@"
}

# Usage: netconf_phdown {<if_name>|<var_name>}
netconf_phdown()
{
	netconf_ifdown "$@"
}

# Usage: netconf_phlist {<if_name>|<var_name>}
netconf_phlist()
{
	netconf_iflist "$@"
}

# Usage: netconf_phusage [<action>] [<var_name_descr>]
netconf_phusage()
{
	nctl_log_msg 'usage: %s %s %s...\n' \
		"$program_invocation_short_name" \
		"${1:-ph\{up|down|list|usage\}}" \
		"${2:-<phys_iface_name>}"
}

##
## DUMMY
##

# Usage: netconf_dmup {<if_name>|<var_name>}
netconf_dmup()
{
	netconf_ifup "$@"
}

# Usage: netconf_dmdown {<if_name>|<var_name>}
netconf_dmdown()
{
	netconf_ifdown "$@"
}

# Usage: netconf_dmlist {<if_name>|<var_name>}
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

# Usage: netconf_vzup {<if_name>|<var_name>}
netconf_vzup()
{
	netconf_ifup "$@"
}

# Usage: netconf_vzdown {<if_name>|<var_name>}
netconf_vzdown()
{
	netconf_ifdown "$@"
}

# Usage: netconf_vzlist {<if_name>|<var_name>}
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

# Usage: netconf_gtup {<if_name>|<var_name>}
netconf_gtup()
{
	netconf_ifup "$@"
}

# Usage: netconf_gtdown {<if_name>|<var_name>}
netconf_gtdown()
{
	netconf_ifdown "$@"
}

# Usage: netconf_gtlist {<if_name>|<var_name>}
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

# Usage: netconf_g6tup {<if_name>|<var_name>}
netconf_g6tup()
{
	netconf_ifup "$@"
}

# Usage: netconf_g6tdown {<if_name>|<var_name>}
netconf_g6tdown()
{
	netconf_ifdown "$@"
}

# Usage: netconf_g6tlist {<if_name>|<var_name>}
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

# Usage: netconf_vxup {<if_name>|<var_name>}
netconf_vxup()
{
	netconf_ifup "$@"
}

# Usage: netconf_vxdown {<if_name>|<var_name>}
netconf_vxdown()
{
	netconf_ifdown "$@"
}

# Usage: netconf_vxlist {<if_name>|<var_name>}
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

# Usage: netconf_vup {<if_name>|<var_name>}
netconf_vup()
{
	netconf_ifup "$@"
}

# Usage: netconf_vdown {<if_name>|<var_name>}
netconf_vdown()
{
	netconf_ifdown "$@"
}

# Usage: netconf_vlist {<if_name>|<var_name>}
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

# Usage: netconf_mvup {<if_name>|<var_name>}
netconf_mvup()
{
	netconf_ifup "$@"
}

# Usage: netconf_mvdown {<if_name>|<var_name>}
netconf_mvdown()
{
	netconf_ifdown "$@"
}

# Usage: netconf_mvlist {<if_name>|<var_name>}
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
## GRE
##

# Usage: netconf_gup {<if_name>|<var_name>}
netconf_gup()
{
	netconf_ifup "$@"
}

# Usage: netconf_gdown {<if_name>|<var_name>}
netconf_gdown()
{
	netconf_ifdown "$@"
}

# Usage: netconf_glist {<if_name>|<var_name>}
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

# Usage: netconf_g6rup {<if_name>|<var_name>}
netconf_g6up()
{
	netconf_ifup "$@"
}

# Usage: netconf_g6down {<if_name>|<var_name>}
netconf_g6down()
{
	netconf_ifdown "$@"
}

# Usage: netconf_g6list {<if_name>|<var_name>}
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

# Usage: netconf_ibup {<if_name>|<var_name>}
netconf_ibup()
{
	netconf_ifup "$@"
}

# Usage: netconf_ibdown {<if_name>|<var_name>}
netconf_ibdown()
{
	netconf_ifdown "$@"
}

# Usage: netconf_iblist {<if_name>|<var_name>}
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
## ETHTOOL
##

# Usage: netconf_etup <var_name>
netconf_etup()
{
	# Account actions
	trap 'netconf_account "$var_name" "$val"; trap - RETURN' RETURN

	local var_name="$1"

	local val
	netconf_get_val "$var_name" val || return

	eval set -- $val

	ethtool "$@" 2>&1 |nctl_log_pipe
	nctl_get_rc
}

# Usage: netconf_etdown <var_name>
netconf_etdown()
{
	# Account actions
	trap 'netconf_account "$var_name" "$val"; trap - RETURN' RETURN

	local var_name="$1"

	local val
	netconf_get_val "$var_name" val || return

	eval set -- $val

	# No-op here
	:
}

# Usage: netconf_etlist <var_name>
netconf_etlist()
{
	# Account actions
	trap 'netconf_account "$var_name" "$val"; trap - RETURN' RETURN

	local var_name="$1"

	local val
	netconf_get_val "$var_name" val || return

	set -- $val

	printf '%s="%s"\n' "$var_name" "$*" 2>&1 |nctl_log_pipe
	nctl_get_rc
}

# Usage: netconf_etusage [<action>] [<var_name_descr>]
netconf_etusage()
{
	nctl_log_msg 'usage: %s %s %s...\n' \
		"$program_invocation_short_name" \
		"${1:-et\{up|down|list|usage\}}" \
		"${2:-<ethtool_iface_name>}"
}

##
## NEIGHBOUR
##

# Usage: netconf_ngup <var_name>
netconf_ngup()
{
	# Account actions
	trap 'netconf_account "$var_name" "$val"; trap - RETURN' RETURN

	local var_name="$1"

	local val
	netconf_get_val "$var_name" val || return

	eval set -- $val

	local u_if="$1"
	shift

	ip neighbour replace dev "$u_if" "$@" 2>&1 |nctl_log_pipe
	nctl_get_rc
}

# Usage: netconf_ngdown <var_name>
netconf_ngdown()
{
	# Account actions
	trap 'netconf_account "$var_name" "$val"; trap - RETURN' RETURN

	local var_name="$1"

	local val
	netconf_get_val "$var_name" val || return

	eval set -- $val

	local u_if="$1"
	shift

	ip neighbour del dev "$u_if" "$@" &>/dev/null
}

# Usage: netconf_nglist <var_name>
netconf_nglist()
{
	# Account actions
	trap 'netconf_account "$var_name" "$val"; trap - RETURN' RETURN

	local var_name="$1"

	local val
	netconf_get_val "$var_name" val || return

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
	# Account actions
	trap 'netconf_account "$var_name" "$val"; trap - RETURN' RETURN

	local var_name="$1"

	local val
	netconf_get_val "$var_name" val || return

	eval set -- $val

	local -a cmd
	netconf_get_rtargs "$var_name" cmd "$@" || return

	ip route replace "${cmd[@]}" 2>&1 |nctl_log_pipe
	nctl_get_rc
}

# Usage: netconf_rtdown <var_name>
netconf_rtdown()
{
	# Account actions
	trap 'netconf_account "$var_name" "$val"; trap - RETURN' RETURN

	local var_name="$1"

	local val
	netconf_get_val "$var_name" val || return

	eval set -- $val

	local -a cmd
	netconf_get_rtargs "$var_name" cmd "$@" || return

	ip route del "${cmd[@]}" &>/dev/null
}

# Usage: netconf_rtlist <var_name>
netconf_rtlist()
{
	# Account actions
	trap 'netconf_account "$var_name" "$val"; trap - RETURN' RETURN

	local var_name="$1"

	local val
	netconf_get_val "$var_name" val || return

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
	# Account actions
	trap 'netconf_account "$var_name" "$val"; trap - RETURN' RETURN

	local var_name="$1"

	local val
	netconf_get_val "$var_name" val || return

	eval set -- $val

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
	# Account actions
	trap 'netconf_account "$var_name" "$val"; trap - RETURN' RETURN

	local var_name="$1"

	local val
	netconf_get_val "$var_name" val || return

	eval set -- $val

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
	# Account actions
	trap 'netconf_account "$var_name" "$val"; trap - RETURN' RETURN

	local var_name="$1"

	local val
	netconf_get_val "$var_name" val || return

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
		[ -n "$u_name" -a $rc -ne 0 ] && ip netns del "$u_name"
		trap - RETURN
	' RETURN

	local -i rc=0
	local u_name u_if u_dir u_dir_netns u_rules

	local var_name="$1"
	var_name="${var_name//-/_}"

	local val
	netconf_get_val "$var_name" val ||
		nctl_inc_rc rc || return $rc

	eval set -- $val

	u_name="$1"
	u_dir="$netconf_vr_dir/$u_name"
	u_dir_netns="/etc/netns/$u_name"

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
				## PHYS

				# Load configuration if not already done
				nctl_is_empty_var 'netconf_phys_list' &&
					netconf_source 'phys'
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
				netconf_ifdown "$u_if"
				;;
			ifb*)
				## IFB

				# Load configuration if not already done
				nctl_is_empty_var 'netconf_ifb_list' &&
					netconf_source 'ifb'
				;;
			br*|bond*|gtp*|g6tp*|vx*|gre*|g6re*)
				## BRIDGE, BOND, GRETAP, IP6GRETAP, VXLAN, GRE, IP6GRE

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
		netconf_ifup "$u_if"

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

	u_rules='iptables/rules.v4'
	u_rules_netns="$u_dir_netns/$u_rules"
	u_rules_vr="$u_dir/$u_rules"
	if [ -f "$u_rules_vr" -a -s "$u_rules_vr" ]; then
		[ "$u_rules_vr" -ef "$u_rules_netns" ] && \
			u_rules="/etc/$u_rules" || \
			u_rules="$u_rules_vr"
		ip netns exec "$u_name" \
			"$SHELL" -c "iptables-restore <$u_rules" 2>&1 |nctl_log_pipe ||
				nctl_inc_rc rc || return $rc
	fi

	u_rules='ip6tables/rules.v6'
	u_rules_netns="$u_dir_netns/$u_rules"
	u_rules_vr="$u_dir/$u_rules"
	if [ -f "$u_rules_vr" -a -s "$u_rules_vr" ]; then
		[ "$u_rules_vr" -ef "$u_rules_netns" ] && \
			u_rules="/etc/$u_rules" || \
			u_rules="$u_rules_vr"
		ip netns exec "$u_name" \
			"$SHELL" -c "ip6tables-restore <$u_rules" 2>&1 |nctl_log_pipe ||
				nctl_inc_rc rc || return $rc
	fi

	# 6. Configure sysctls

	u_sysctl="sysctl.d/netctl.conf"
	u_sysctl_netns="$u_dir_netns/$u_sysctl"
	u_sysctl_vr="$u_dir/$u_sysctl"
	if [ -f "$u_sysctl_vr" -a -s "$u_sysctl_vr" ]; then
		[ "$u_sysctl_vr" -ef "$u_sysctl_netns" ] && \
			u_sysctl="/etc/$u_sysctl" || \
			u_sysctl="$u_sysctl_vr"
		ip netns exec "$u_name" \
			"$SHELL" -c "sysctl -qp $u_sysctl" 2>&1 |nctl_log_pipe ||
				nctl_inc_rc rc || return $rc
	fi

	# 7. Start network subsystem in vr
	{
		u_netconf='netconf'
		u_netconf_netns="$u_dir_netns/$u_netconf"
		u_netconf_vr="$u_dir/$u_netconf"

		[ "$u_netconf_vr" -ef "$u_netconf_netns" ] && \
			u_netconf="/etc/$u_netconf" || \
			u_netconf="$u_netconf_vr"

		NCTL_LOG_FILE=n \
		netconf_bridge_dir="$u_netconf/bridge" \
		netconf_bond_dir="$u_netconf/bond" \
		netconf_phys_dir="$u_netconf/phys" \
		netconf_dummy_dir="$u_netconf/dummy" \
		netconf_veth_dir="$u_netconf/veth" \
		netconf_gretap_dir="$u_netconf/gretap" \
		netconf_ip6gretap_dir="$u_netconf/ip6gretap" \
		netconf_vxlan_dir="$u_netconf/vxlan" \
		netconf_vlan_dir="$u_netconf/vlan" \
		netconf_macvlan_dir="$u_netconf/macvlan" \
		netconf_gre_dir="$u_netconf/gre" \
		netconf_ip6gre_dir="$u_netconf/ip6gre" \
		netconf_ifb_dir="$u_netconf/ifb" \
		netconf_ethtool_dir="$u_netconf/ethtool" \
		netconf_neighbour_dir="$u_netconf/neighbour" \
		netconf_route_dir="$u_netconf/route" \
		netconf_rule_dir="$u_netconf/rule" \
		netconf_vr_dir="$u_netconf/vr" \
			ip netns exec "$u_name" \
				"$program_invocation_name" start
	} 2>&1 |nctl_log_pipe ||
		nctl_inc_rc rc || return $rc

	return $rc
}

# Usage: netconf_vrdown <var_name>
netconf_vrdown()
{
	# Account actions
	trap 'netconf_account "$var_name" "$val"; trap - RETURN' RETURN

	local var_name="$1"
	var_name="${var_name//-/_}"

	local val
	netconf_get_val "$var_name" val || return

	eval set -- $val

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
	# Account actions
	trap 'netconf_account "$var_name" "$val"; trap - RETURN' RETURN

	local var_name="$1"
	var_name="${var_name//-/_}"

	local val
	netconf_get_val "$var_name" val || return

	set -- $val

	local u_name="$1"
	local u_dir="$netconf_vr_dir/$u_name"

	printf '%s="%s"\n' "$var_name" "$*" 2>&1 |nctl_log_pipe
	nctl_get_rc || return

	# 1. List vr netconf configuration
	{
		NCTL_LOG_PREFIX_NONE=y \
		NCTL_LOG_FILE=n \
		netconf_bridge_dir="$u_dir/netconf/bridge" \
		netconf_bond_dir="$u_dir/netconf/bond" \
		netconf_phys_dir="$u_dir/netconf/phys" \
		netconf_dummy_dir="$u_dir/netconf/dummy" \
		netconf_veth_dir="$u_dir/netconf/veth" \
		netconf_gretap_dir="$u_dir/netconf/gretap" \
		netconf_ip6gretap_dir="$u_dir/netconf/ip6gretap" \
		netconf_vxlan_dir="$u_dir/netconf/vxlan" \
		netconf_vlan_dir="$u_dir/netconf/vlan" \
		netconf_macvlan_dir="$u_dir/netconf/macvlan" \
		netconf_gre_dir="$u_dir/netconf/gre" \
		netconf_ip6gre_dir="$u_dir/netconf/ip6gre" \
		netconf_ifb_dir="$u_dir/netconf/ifb" \
		netconf_ethtool_dir="$u_dir/netconf/ethtool" \
		netconf_neighbour_dir="$u_dir/netconf/neighbour" \
		netconf_route_dir="$u_dir/netconf/route" \
		netconf_rule_dir="$u_dir/netconf/rule" \
		netconf_vr_dir="$u_dir/netconf/vr" \
			"$program_invocation_name" list
	} 2>&1 |nctl_log_pipe
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
			-e"/^[[:space:]]*(#|\$)/b;\
			  s/^[[:space:]]*($nsf_var_name_regex)=[\"']?.*['\"]?[[:space:]]*(#|\$)/\1/p"
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
	local ns_v_name
	local ns_regex ns_regex_f ns_dir

	for ((ns_i = 0, ns_size=$#;
		ns_i < ns_size; ns_i++)); do
		ns_v_name="$1"
		shift
		# Adjst configuration for known subsystems, ignore unknown/empty.
		#
		# Please note that variables prefixed with "netconf_*" are
		# created/updated in parent bash namespace, so they could be set
		# to overwrite defaults to starting only parts from the facility
		# (e.g. only start vlan 100).
		case "$ns_v_name" in
			'bridge')
				netconf_bridge_list=()
				: ${netconf_bridge_regex:="$NETCONF_BRIDGE_REGEX"}
				: ${netconf_bridge_regex_f:="$NETCONF_BRIDGE_REGEX_F"}
				: ${netconf_bridge_dir:="$NETCONF_BRIDGE_DIR"}
				;;
			'bond')
				netconf_bond_list=()
				: ${netconf_bond_regex:="$NETCONF_BOND_REGEX"}
				: ${netconf_bond_regex_f:="$NETCONF_BOND_REGEX_F"}
				: ${netconf_bond_dir:="$NETCONF_BOND_DIR"}
				;;
			'phys')
				netconf_phys_list=()
				: ${netconf_phys_regex:="$NETCONF_PHYS_REGEX"}
				: ${netconf_phys_regex_f:="$NETCONF_PHYS_REGEX_F"}
				: ${netconf_phys_dir:="$NETCONF_PHYS_DIR"}
				;;
			'dummy')
				netconf_dummy_list=()
				: ${netconf_dummy_regex:="$NETCONF_DUMMY_REGEX"}
				: ${netconf_dummy_regex_f:="$NETCONF_DUMMY_REGEX_F"}
				: ${netconf_dummy_dir:="$NETCONF_DUMMY_DIR"}
				;;
			'veth')
				netconf_veth_list=()
				: ${netconf_veth_regex:="$NETCONF_VETH_REGEX"}
				: ${netconf_veth_regex_f:="$NETCONF_VETH_REGEX_F"}
				: ${netconf_veth_dir:="$NETCONF_VETH_DIR"}
				;;
			'gretap')
				netconf_gretap_list=()
				: ${netconf_gretap_regex:="$NETCONF_GRETAP_REGEX"}
				: ${netconf_gretap_regex_f:="$NETCONF_GRETAP_REGEX_F"}
				: ${netconf_gretap_dir:="$NETCONF_GRETAP_DIR"}
				;;
			'ip6gretap')
				netconf_ip6gretap_list=()
				: ${netconf_ip6gretap_regex:="$NETCONF_IP6GRETAP_REGEX"}
				: ${netconf_ip6gretap_regex_f:="$NETCONF_IP6GRETAP_REGEX_F"}
				: ${netconf_ip6gretap_dir:="$NETCONF_IP6GRETAP_DIR"}
				;;
			'vxlan')
				netconf_vxlan_list=()
				: ${netconf_vxlan_regex:="$NETCONF_VXLAN_REGEX"}
				: ${netconf_vxlan_regex_f:="$NETCONF_VXLAN_REGEX_F"}
				: ${netconf_vxlan_dir:="$NETCONF_VXLAN_DIR"}
				;;
			'vlan')
				netconf_vlan_list=()
				: ${netconf_vlan_regex:="$NETCONF_VLAN_REGEX"}
				: ${netconf_vlan_regex_f:="$NETCONF_VLAN_REGEX_F"}
				: ${netconf_vlan_dir:="$NETCONF_VLAN_DIR"}
				;;
			'macvlan')
				netconf_macvlan_list=()
				: ${netconf_macvlan_regex:="$NETCONF_MACVLAN_REGEX"}
				: ${netconf_macvlan_regex_f:="$NETCONF_MACVLAN_REGEX_F"}
				: ${netconf_macvlan_dir:="$NETCONF_MACVLAN_DIR"}
				;;
			'gre')
				netconf_gre_list=()
				: ${netconf_gre_regex:="$NETCONF_GRE_REGEX"}
				: ${netconf_gre_regex_f:="$NETCONF_GRE_REGEX_F"}
				: ${netconf_gre_dir:="$NETCONF_GRE_DIR"}
				;;
			'ip6gre')
				netconf_ip6gre_list=()
				: ${netconf_ip6gre_regex:="$NETCONF_IP6GRE_REGEX"}
				: ${netconf_ip6gre_regex_f:="$NETCONF_IP6GRE_REGEX_F"}
				: ${netconf_ip6gre_dir:="$NETCONF_IP6GRE_DIR"}
				;;
			'ifb')
				netconf_ifb_list=()
				: ${netconf_ifb_regex:="$NETCONF_IFB_REGEX"}
				: ${netconf_ifb_regex_f:="$NETCONF_IFB_REGEX_F"}
				: ${netconf_ifb_dir:="$NETCONF_IFB_DIR"}
				;;
			'ethtool')
				netconf_ethtool_list=()
				: ${netconf_ethtool_regex:="$NETCONF_ETHTOOL_REGEX"}
				: ${netconf_ethtool_regex_f:="$NETCONF_ETHTOOL_REGEX_F"}
				: ${netconf_ethtool_dir:="$NETCONF_ETHTOOL_DIR"}
				;;
			'neighbour')
				netconf_neighbour_list=()
				: ${netconf_neighbour_regex:="$NETCONF_NEIGHBOUR_REGEX"}
				: ${netconf_neighbour_regex_f:="$NETCONF_NEIGHBOUR_REGEX_F"}
				: ${netconf_neighbour_dir:="$NETCONF_NEIGHBOUR_DIR"}
				;;
			'route')
				netconf_route_list=()
				: ${netconf_route_regex:="$NETCONF_ROUTE_REGEX"}
				: ${netconf_route_regex_f:="$NETCONF_ROUTE_REGEX_F"}
				: ${netconf_route_dir:="$NETCONF_ROUTE_DIR"}
				;;
			'rule')
				netconf_rule_list=()
				: ${netconf_rule_regex:="$NETCONF_RULE_REGEX"}
				: ${netconf_rule_regex_f:="$NETCONF_RULE_REGEX_F"}
				: ${netconf_rule_dir:="$NETCONF_RULE_DIR"}
				;;
			'vr')
				netconf_vr_list=()
				: ${netconf_vr_regex:="$NETCONF_VR_REGEX"}
				: ${netconf_vr_regex_f:="$NETCONF_VR_REGEX_F"}
				: ${netconf_vr_dir:="$NETCONF_VR_DIR"}
				;;
			'')
				continue
				;;
			*)
				! :
				nctl_inc_rc ns_rc
				break
				;;
		esac
		# Get variable name regex
		nctl_get_val "netconf_${ns_v_name}_regex" ns_regex ||
			continue
		# Get file name regex
		nctl_get_val "netconf_${ns_v_name}_regex_f" ns_regex_f ||
			continue
		# Get directory/file name
		nctl_get_val "netconf_${ns_v_name}_dir" ns_dir && [ -d "$ns_dir" ] ||
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

### Global variable namespace

## BRIDGE
declare -a netconf_bridge_list
declare netconf_bridge_regex
declare netconf_bridge_regex_f
declare netconf_bridge_dir

## BOND
declare -a netconf_bond_list
declare netconf_bond_regex
declare netconf_bond_regex_f
declare netconf_bond_dir

## PHYS
declare -a netconf_phys_list
declare netconf_phys_regex
declare netconf_phys_regex_f
declare netconf_phys_dir

## DUMMY
declare -a netconf_dummy_list
declare netconf_dummy_regex
declare netconf_dummy_regex_f
declare netconf_dummy_dir

## VETH
declare -a netconf_veth_list
declare netconf_veth_regex
declare netconf_veth_regex_f
declare netconf_veth_dir

## GRETAP
declare -a netconf_gretap_list
declare netconf_gretap_regex
declare netconf_gretap_regex_f
declare netconf_gretap_dir

## IP6GRETAP
declare -a netconf_ip6gretap_list
declare netconf_ip6gretap_regex
declare netconf_ip6gretap_regex_f
declare netconf_ip6gretap_dir

## VXLAN
declare -a netconf_vxlan_list
declare netconf_vxlan_regex
declare netconf_vxlan_regex_f
declare netconf_vxlan_dir


## VLAN
declare -a netconf_vlan_list
declare netconf_vlan_regex
declare netconf_vlan_regex_f
declare netconf_vlan_dir

## MACVLAN
declare -a netconf_macvlan_list
declare netconf_macvlan_regex
declare netconf_macvlan_regex_f
declare netconf_macvlan_dir

## GRE
declare -a netconf_gre_list
declare netconf_gre_regex
declare netconf_gre_regex_f
declare netconf_gre_dir

## IP6GRE
declare -a netconf_ip6gre_list
declare netconf_ip6gre_regex
declare netconf_ip6gre_regex_f
declare netconf_ip6gre_dir

## IFB
declare -a netconf_ifb_list
declare netconf_ifb_regex
declare netconf_ifb_regex_f
declare netconf_ifb_dir

## ETHTOOL
declare -a netconf_ethtool_list
declare netconf_ethtool_regex
declare netconf_ethtool_regex_f
declare netconf_ethtool_dir

## NEIGHBOUR
declare -a netconf_neighbour_list
declare netconf_neighbour_regex
declare netconf_neighbour_regex_f
declare netconf_neighbour_dir

## ROUTE
declare -a netconf_route_list
declare netconf_route_regex
declare netconf_route_regex_f
declare netconf_route_dir

## RULE
declare -a netconf_rule_list
declare netconf_rule_regex
declare netconf_rule_regex_f
declare netconf_rule_dir

## VR
declare -a netconf_vr_list
declare netconf_vr_regex
declare netconf_vr_regex_f
declare netconf_vr_dir

# Open accounting file. We cant rely on automatic opening by netconf_account()
# because race condition might occur and NCTL_LOGFILE_FD == NCTL_ACCOUNT_FD.
#
# TODO: implement synchronization facilities
#
nctl_openaccount ||:

# Source configuration
netconf_source "$@"
