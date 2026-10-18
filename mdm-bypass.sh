#!/bin/bash
#
# MDM Bypass — Non-Interactive Edition
# Run from macOS Recovery as root. All inputs via flags.
#
# Usage:
#   ./mdm-bypass.sh [-u username] [-f fullname] [-p password] [-d domain0,domain1,...] [-y]
#
# Examples:
#   ./mdm-bypass.sh                          # all defaults: Apple / Apple / 1234
#   ./mdm-bypass.sh -u tech -p 's3cret!'     # custom user
#   ./mdm-bypass.sh -y -p 'Company2024!'     # skip confirmation, run unattended
#

set -u

# ── Constants ──
readonly DEFAULT_SYSTEM_VOLUME="Macintosh HD"
readonly DEFAULT_DATA_VOLUME="Macintosh HD - Data"
readonly BLOCKED_DOMAINS=(
	"deviceenrollment.apple.com"
	"mdmenrollment.apple.com"
	"iprofiles.apple.com"
	"vpp.itunes.apple.com"
	"mdm.apple.com"
)

# ── Colors / output ──
RED='\033[1;31m'; GRN='\033[1;32m'; BLU='\033[1;34m'
YEL='\033[1;33m'; CYAN='\033[1;36m'; NC='\033[0m'
error_exit() { echo -e "${RED}ERROR: $1${NC}" >&2; exit 1; }
warn()       { echo -e "${YEL}WARNING: $1${NC}" >&2; }
success()    { echo -e "${GRN}✓ $1${NC}"; }
info()       { echo -e "${BLU}ℹ $1${NC}"; }

# ── Defaults ──
username="Apple"
realName="Apple"
passw="1234"
extra_domains=""
assume_yes=false

# ── Arg parsing ──
usage() {
	sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
	exit 0
}
while getopts "u:f:p:d:yh" opt; do
	case "$opt" in
		u) username="$OPTARG" ;;
		f) realName="$OPTARG" ;;
		p) passw="$OPTARG" ;;
		d) extra_domains="$OPTARG" ;;
		y) assume_yes=true ;;
		h) usage ;;
		*) usage ;;
	esac
done

# ── Root check ──
[ "$(id -u)" -eq 0 ] || error_exit "Must run as root (boot into macOS Recovery)."

# ── Validation ──
validate_username() {
	local u="$1"
	[ -z "$u" ]                      && { echo "empty"; return 1; }
	[ ${#u} -gt 31 ]                 && { echo "too long (max 31)"; return 1; }
	[[ ! "$u" =~ ^[a-zA-Z0-9_-]+$ ]] && { echo "invalid characters"; return 1; }
	[[ ! "$u" =~ ^[a-zA-Z_] ]]       && { echo "must start with letter/underscore"; return 1; }
	return 0
}
[ ${#passw} -ge 4 ] || error_exit "Password too short (min 4 chars)."
[ -n "$realName" ]  || realName="Apple"
validate_username "$username" || error_exit "Invalid username: $(validate_username "$username")"

# Auto-rename username if it already exists (non-interactive: pick first free suffix)
user_exists_at() {
	dscl -f "$1" localhost -read "/Local/Default/Users/$2" >/dev/null 2>&1
}

# ── Volume detection (APFS role first, mounted heuristic fallback) ──
get_role_volume_name() {
	local role="$1" container volumeInfo
	container=$(diskutil list internal physical 2>/dev/null | awk -F'Container ' '/Container/ {print $2}' | awk '{print $1}' | head -n1)
	[ -z "$container" ] && return 1
	volumeInfo=$(diskutil ap list "$container" 2>/dev/null | grep -A 5 "($role)" | grep 'Name:')
	[ -z "$volumeInfo" ] && return 1
	echo "$volumeInfo" | cut -d':' -f2 | cut -d'(' -f1 | xargs
}
ensure_mounted() {
	local vol="$1"
	diskutil info "$vol" >/dev/null 2>&1 || return 1
	[ -d "/Volumes/$vol" ] || diskutil mount "$vol" >/dev/null 2>&1
}

detect_system_volume() {
	local vol
	vol=$(get_role_volume_name "System")
	if [ -n "$vol" ]; then
		ensure_mounted "$vol"
		[ -d "/Volumes/$vol/System" ] && { echo "$vol"; return 0; }
	fi
	ensure_mounted "$DEFAULT_SYSTEM_VOLUME"
	[ -d "/Volumes/$DEFAULT_SYSTEM_VOLUME/System" ] && { echo "$DEFAULT_SYSTEM_VOLUME"; return 0; }
	for v in /Volumes/*; do
		local n; n=$(basename "$v")
		[ -d "$v/System" ] && [[ ! "$n" =~ Data$ ]] && [[ ! "$n" =~ Recovery ]] && { echo "$n"; return 0; }
	done
	return 1
}
detect_data_volume() {
	local vol
	vol=$(get_role_volume_name "Data")
	if [ -n "$vol" ]; then
		ensure_mounted "$vol"
		[ -d "/Volumes/$vol/private/var/db" ] && { echo "$vol"; return 0; }
	fi
	ensure_mounted "$DEFAULT_DATA_VOLUME"
	[ -d "/Volumes/$DEFAULT_DATA_VOLUME/private/var/db" ] && { echo "$DEFAULT_DATA_VOLUME"; return 0; }
	[ -d "/Volumes/Data/private/var/db/dslocal" ] && { echo "Data"; return 0; }
	for v in /Volumes/*Data; do
		[ -d "$v/private/var/db/dslocal" ] && { echo "$(basename "$v")"; return 0; }
	done
	return 1
}

system_volume=$(detect_system_volume) || error_exit "System volume not found — boot into Recovery with macOS installed."
data_volume=$(detect_data_volume)     || error_exit "Data volume not found — boot into Recovery with macOS installed."

system_path="/Volumes/$system_volume"
data_path="/Volumes/$data_volume"
dscl_path="$data_path/private/var/db/dslocal/nodes/Default"

[ -d "$system_path" ] || error_exit "Missing: $system_path"
[ -d "$data_path" ]   || error_exit "Missing: $data_path"
[ -d "$dscl_path" ]   || error_exit "Missing: $dscl_path"

# ── Resolve username conflicts non-interactively ──
if user_exists_at "$dscl_path" "$username"; then
	base="$username" suffix=1
	while user_exists_at "$dscl_path" "${base}${suffix}"; do suffix=$((suffix + 1)); done
	warn "User '$username' exists — using '${base}${suffix}' instead"
	username="${base}${suffix}"
	# keep realName consistent if it was left at default
	[ "$realName" = "Apple" ] && realName="$username"
fi

# ── Free UID (501–599) ──
available_uid=501
while [ $available_uid -lt 600 ]; do
	dscl -f "$dscl_path" localhost -search /Local/Default/Users UniqueID "$available_uid" 2>/dev/null | grep -q "UniqueID" || break
	available_uid=$((available_uid + 1))
done
[ $available_uid -ge 600 ] && available_uid=501

# ── Summary + optional confirmation ──
echo ""
echo -e "${CYAN}═══ MDM Bypass — Non-Interactive ═══${NC}"
echo -e "  System volume : $system_volume"
echo -e "  Data volume   : $data_volume"
echo -e "  Username      : $username"
echo -e "  Fullname      : $realName"
echo -e "  Password      : ********"
echo -e "  UID           : $available_uid"
echo ""
if [ "$assume_yes" = false ]; then
	read -r -p "Proceed? [y/N]: " reply
	[[ "$reply" =~ ^[Yy]$ ]] || { info "Aborted by user."; exit 0; }
fi

# ── Create user ──
info "Creating user: $username (UID $available_uid)"
user_record="/Local/Default/Users/$username"
dscl -f "$dscl_path" localhost -create "$user_record" 2>/dev/null                    || error_exit "Failed to create user record"
dscl -f "$dscl_path" localhost -create "$user_record" UserShell "/bin/zsh"           || warn "shell"
dscl -f "$dscl_path" localhost -create "$user_record" RealName "$realName"           || warn "RealName"
dscl -f "$dscl_path" localhost -create "$user_record" UniqueID "$available_uid"      || warn "UID"
dscl -f "$dscl_path" localhost -create "$user_record" PrimaryGroupID "20"            || warn "GID"

user_home="$data_path/Users/$username"
if [ ! -d "$user_home" ]; then
	mkdir -p "$user_home" 2>/dev/null || error_exit "Failed to create home dir"
	chown -R "$available_uid:20" "$user_home" 2>/dev/null || warn "chown failed"
fi
dscl -f "$dscl_path" localhost -create "$user_record" NFSHomeDirectory "/Users/$username" || warn "NFSHomeDirectory"
dscl -f "$dscl_path" localhost -passwd "$user_record" "$passw" 2>/dev/null                || error_exit "Failed to set password"
dscl -f "$dscl_path" localhost -append "/Local/Default/Groups/admin" GroupMembership "$username" 2>/dev/null || error_exit "Failed to add to admin group"
success "User created (admin)"

# ── Block MDM domains ──
info "Blocking enrollment domains..."
hosts_file="$system_path/etc/hosts"
[ -f "$hosts_file" ] || touch "$hosts_file" || error_exit "Cannot create hosts file"
[ -f "$hosts_file.bak-mdm" ] || cp "$hosts_file" "$hosts_file.bak-mdm" 2>/dev/null

blocked=0
for domain in "${BLOCKED_DOMAINS[@]}"; do
	grep -qE "^[[:space:]]*0\.0\.0\.0[[:space:]]+$domain([[:space:]]|$)" "$hosts_file" 2>/dev/null && continue
	echo "0.0.0.0 $domain" >> "$hosts_file" && blocked=$((blocked + 1))
done
# Extra custom domains (-d "a.com,b.com")
if [ -n "$extra_domains" ]; then
	IFS=',' read -ra EXTRA <<< "$extra_domains"
	for domain in "${EXTRA[@]}"; do
		domain=$(echo "$domain" | xargs)
		[ -z "$domain" ] && continue
		grep -qE "^[[:space:]]*0\.0\.0\.0[[:space:]]+$domain([[:space:]]|$)" "$hosts_file" 2>/dev/null && continue
		echo "0.0.0.0 $domain" >> "$hosts_file" && blocked=$((blocked + 1))
	done
fi
success "$blocked domain(s) blocked"

# ── Setup flags & config records ──
touch "$data_path/private/var/db/.AppleSetupDone" 2>/dev/null && success "Setup marked complete" || warn "Setup flag failed"

config_path="$system_path/var/db/ConfigurationProfiles/Settings"
mkdir -p "$config_path" 2>/dev/null || warn "Config dir not created"
for marker in ".cloudConfigHasActivationRecord" ".cloudConfigRecordFound"; do
	[ -e "$config_path/$marker" ] && rm -rf "$config_path/$marker" 2>/dev/null
done
touch "$config_path/.cloudConfigProfileInstalled" 2>/dev/null || warn "marker 1"
touch "$config_path/.cloudConfigRecordNotFound"   2>/dev/null || warn "marker 2"
success "Enrollment records cleared"

# ── Done ──
echo ""
echo -e "${GRN}═══ MDM Bypass Complete ═══${NC}"
echo -e "${CYAN}Log in with:${NC}  user: ${YEL}$username${NC}  password: ${YEL}$passw${NC}"
echo -e "${CYAN}Reboot the Mac to apply.${NC}"
exit 0