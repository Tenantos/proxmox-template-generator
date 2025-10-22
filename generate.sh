#!/bin/bash

# Proxmox Template Generator for Tenantos
# Automated cloud image template creation with cloud-init and qemu-guest-agent
# https://github.com/Tenantos/proxmox-template-generator/
# https://documentation.tenantos.com/Tenantos/virtualization/template-installations-proxmox/

set -euo pipefail

readonly SCRIPT_VERSION="1.0.1"
readonly CACHE_DIR="/var/tmp/proxmox-templates"
readonly COLOR_RESET="\033[0m"
readonly COLOR_RED="\033[0;31m"
readonly COLOR_GREEN="\033[0;32m"
readonly COLOR_YELLOW="\033[0;33m"
readonly COLOR_BLUE="\033[0;34m"

tempFiles=()
forceYes=false
noCache=false
updatePackages=false
biosMode=""
diskFormat=""
machineType="pc-i440fx"
scsiController="virtio-scsi-single"
diskDevice="scsi"
vgaDisplay="serial0"
isRhelDerivative=false
disableSelinux=false
selinuxRelabel=false
setQemuPermissive=false
cleanupCache=false
cloudImageUrl=""
storageId=""
vmId=""
vmName=""
bridgeName="vmbr0"

cleanup() {
	local exitCode=$?

	local cleanedCount=0
	for file in "${tempFiles[@]}"; do
		if [[ -f "$file" ]]; then
			rm -f "$file"
			cleanedCount=$((cleanedCount + 1))
		fi
	done

	if [[ $cleanedCount -gt 0 ]]; then
		log "Cleaned $cleanedCount temporary file(s)" "info"
	fi

	# On error, remind user about cache directory
	if [[ $exitCode -ne 0 ]] && [[ -d "$CACHE_DIR" ]]; then
		echo >&2
		log "Cache directory: $CACHE_DIR" "info"
		log "You can manually clean up cached images if needed" "info"
	fi
}

trap cleanup EXIT

log() {
	local message="$1"
	local level="${2:-info}"

	case "$level" in
	error)
		echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $message" >&2
		;;
	warn)
		echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $message" >&2
		;;
	success)
		echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} $message" >&2
		;;
	info)
		echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $message" >&2
		;;
	*)
		echo "$message" >&2
		;;
	esac
}

checkForUpdates() {
	local latestVersion

	if ! latestVersion=$(curl -s --connect-timeout 10 "https://api.github.com/repos/Tenantos/proxmox-template-generator/releases/latest" 2>/dev/null | grep -o '"tag_name": *"[^"]*"' | sed 's/"tag_name": *"v\?\(.*\)"/\1/'); then
		return 0
	fi

	[[ -z "$latestVersion" ]] && return 0

	if [[ "$latestVersion" != "$SCRIPT_VERSION" ]]; then
		echo >&2
		log "New version available: $latestVersion (current: $SCRIPT_VERSION)" "warn"
		log "Download: https://github.com/Tenantos/proxmox-template-generator/releases/latest" "info"
		echo >&2
	fi
}

showUsage() {
	cat <<EOF
Tenantos Proxmox Template Generator

USAGE:
    Interactive mode:
        $0

    Argument mode:
        $0 --url <URL> --storage <STORAGE> --vmid <ID> [OPTIONS]

OPTIONS:
    --url <URL>                    Cloud image URL
    --storage <STORAGE>            Proxmox storage ID
    --vmid <ID>                    VM ID for the template
    --name <NAME>                  Template name (optional, default: template-YYYYMMDD)
    --bridge <BRIDGE>              Network bridge (optional, default: vmbr0)
    --bios                         Use SeaBIOS (Legacy BIOS, default)
    --uefi                         Use UEFI (OVMF)
    --qcow2                        Use qcow2 disk format
    --raw                          Use raw disk format
    --machine <TYPE>               Machine type (default: pc-i440fx)
                                   Options: pc-i440fx, q35
    --scsi-controller <TYPE>       SCSI controller (default: virtio-scsi-single)
                                   Options: virtio-scsi-single, virtio-scsi-pci, lsi, lsi53c810, megasas, pvscsi
    --disk-device <TYPE>           Disk device type (default: scsi)
                                   Options: scsi, virtio, sata, ide
    --display <TYPE>               Display type (default: serial0)
                                   Options: serial0, std, virtio, qxl, vmware, none
    --rhel-derivative              Mark as RHEL derivative (enables RHEL-specific fixes)
    --disable-selinux              Disable SELinux in the template
    --selinux-relabel              Run full SELinux relabel during build
    --qemu-permissive              Set qemu-guest-agent to SELinux permissive mode
    --update-packages              Update all packages during template build (recommended)
    --no-cache                     Force re-download of cloud image
    --cleanup                      Delete cached cloud image after template creation
    -y, --yes                      Skip all confirmations

Generate a template in interactive mode to receive a command for automated builds.

For troubleshooting, visit: https://documentation.tenantos.com/Tenantos/virtualization/template-installations-proxmox/#troubleshooting
EOF
}

checkPrerequisites() {
	if [[ $EUID -ne 0 ]]; then
		log "This script must be run as root" "error"
		exit 1
	fi

	local missingCommands=()

	for cmd in qm pvesm wget; do
		if ! command -v "$cmd" &>/dev/null; then
			missingCommands+=("$cmd")
		fi
	done

	if ! command -v virt-customize &>/dev/null; then
		log "virt-customize not found! Install libguestfs-tools package." "error"
		log "See: https://documentation.tenantos.com/Tenantos/virtualization/template-installations-proxmox/#troubleshooting" "error"
		exit 1
	fi

	if [[ ${#missingCommands[@]} -gt 0 ]]; then
		log "Missing required commands: ${missingCommands[*]}" "error"
		exit 1
	fi

	mkdir -p "$CACHE_DIR"

	log "All prerequisites met" "info"
}

confirm() {
	local message="$1"

	if [[ "$forceYes" == true ]]; then
		return 0
	fi

	echo -ne "${COLOR_YELLOW}[?]${COLOR_RESET} $message [y/N]: " >&2
	read -r response

	[[ "$response" =~ ^[Yy]$ ]]
}

getCachePath() {
	local url="$1"
	local urlHash=$(echo -n "$url" | md5sum | cut -d' ' -f1)
	local fileName=$(basename "$url")

	echo "${CACHE_DIR}/${urlHash}-${fileName}"
}

downloadCloudImage() {
	local url="$1"
	local cachePath=$(getCachePath "$url")

	if [[ -f "$cachePath" && "$noCache" == false ]]; then
		log "Using cached image: $cachePath" "info"
		echo "$cachePath"
		return 0
	fi

	if [[ -f "$cachePath" && "$noCache" == true ]]; then
		rm -f "$cachePath"
	fi

	log "Downloading cloud image from: $url" "info"

	local tempDownload="${cachePath}.tmp"
	tempFiles+=("$tempDownload")

	if ! wget -q --show-progress -O "$tempDownload" "$url"; then
		log "Failed to download cloud image" "error"
		exit 1
	fi

	mv "$tempDownload" "$cachePath"
	log "Download complete: $cachePath" "info"

	echo "$cachePath"
}

getStorageList() {
	pvesm status -content images | awk 'NR>1 {print $1}'
}

vmExists() {
	local id="$1"
	qm status "$id" &>/dev/null
}

destroyVmSafe() {
	local id="$1"

	if ! vmExists "$id"; then
		return 0
	fi

	log "Destroying VM $id" "info"
	qm destroy "$id" --purge --destroy-unreferenced-disks
	log "VM $id destroyed" "info"
}

customizeImage() {
	local imagePath="$1"

	log "Customizing cloud image" "info"

	local virtCustomizeArgs=(
		"--install" "cloud-init,qemu-guest-agent"
		"--run-command" "systemctl enable qemu-guest-agent"
		"--run-command" "cloud-init clean"
		"--run-command" "rm -f /etc/cloud/cloud-init.disabled"
		"--run-command" "truncate -s 0 /etc/machine-id"
		"--run-command" "rm -f /var/lib/dbus/machine-id"
		"--run-command" "ln -s /etc/machine-id /var/lib/dbus/machine-id || true"
		"--no-logfile"
	)

	local cloudInitConfig='if [ -d /etc/cloud/cloud.cfg.d ]; then '
	cloudInitConfig+='cat > /etc/cloud/cloud.cfg.d/99-ssh.cfg <<EOF
disable_root: false
ssh_pwauth: true
EOF
'
	cloudInitConfig+='fi'

	virtCustomizeArgs+=("--run-command" "$cloudInitConfig")

	if [[ "$updatePackages" == true ]]; then
		log "Package update enabled (this may take a while)" "info"
		virtCustomizeArgs+=("--update")
	fi

	if [[ "$isRhelDerivative" == true ]]; then
		# RHEL cloud images have guest-exec commands disabled. Enable them, required for Tenantos script executions on installation
		local rhelFix='if [ -f /etc/sysconfig/qemu-ga ]; then '
		rhelFix+='sed -i "/^BLACKLIST_RPC=/s/\(^\|,\)guest-exec\(,\|$\)/\1/g; /^BLACKLIST_RPC=/s/,,/,/g; /^BLACKLIST_RPC=/s/^BLACKLIST_RPC=,/BLACKLIST_RPC=/; /^BLACKLIST_RPC=/s/,$//" /etc/sysconfig/qemu-ga; '
		rhelFix+='if ! grep -v "^#" /etc/sysconfig/qemu-ga | grep -q "guest-exec"; then '
		rhelFix+='sed -i "s/\(--allow-rpcs=\)/\1guest-exec,/" /etc/sysconfig/qemu-ga; '
		rhelFix+='fi; '
		rhelFix+='command -v restorecon > /dev/null && restorecon /etc/sysconfig/qemu-ga || true; '
		rhelFix+='fi'

		virtCustomizeArgs+=("--run-command" "$rhelFix")

		if [[ "$setQemuPermissive" == true && "$disableSelinux" == false ]]; then
			local qemuPermissiveFix='if [ -f /etc/selinux/config ] && grep -qE "^SELINUX=(enforcing|permissive)" /etc/selinux/config; then '
			qemuPermissiveFix+='dnf install -y policycoreutils-python-utils || yum install -y policycoreutils-python-utils || true; '
			qemuPermissiveFix+='semanage permissive -a qemu_ga_t || true; '
			qemuPermissiveFix+='semanage permissive -a virt_qemu_ga_t || true; '
			qemuPermissiveFix+='fi'

			virtCustomizeArgs+=("--run-command" "$qemuPermissiveFix")
		fi
	fi

	# Side note: https://bugzilla.redhat.com/show_bug.cgi?id=1554735
	# At least on Proxmox 7 (maybe on 8 too, did test only with 7), generating templates with AlmaLinux 8 (and probably other RHEL-based distros) can fail if SELinux is enabled and updates are installed during template generation (--update-packages flag).
	# This results in the root account being locked. It's an SELinux thing.
	# Most providers keep SELinux disabled by default, but if you read this code and the root login isn't working, now you know why.
	if [[ "$disableSelinux" == true ]]; then
		log "Disabling SELinux" "info"
		virtCustomizeArgs+=("--run-command" "sed -i 's/^SELINUX=\(enforcing\|permissive\)/SELINUX=disabled/' /etc/selinux/config || true")
	fi

	if [[ "$selinuxRelabel" == true ]]; then
		log "SELinux relabel enabled (this may take a while)" "info"

		# Remove existing /.autorelabel file. --selinux-relabel will create a new one if image relabling fails.
		virtCustomizeArgs+=("--run-command" "rm -f /.autorelabel")
		virtCustomizeArgs+=("--selinux-relabel")
	fi

	local virtCustomizeCmd="virt-customize -a \"$imagePath\""

	for arg in "${virtCustomizeArgs[@]}"; do
		# escape to show a working "Used command" output that can be copy pasted
		local escapedArg="${arg//\"/\\\"}"
		virtCustomizeCmd+=" \"$escapedArg\""
	done

	if ! virt-customize -a "$imagePath" "${virtCustomizeArgs[@]}"; then
		log "Image customization failed!" "error"
		echo >&2
		log "You can execute the command with -v -x for verbose output to debug the issue:" "info"
		echo "$virtCustomizeCmd -v -x" >&2
		echo >&2
		log "See: https://documentation.tenantos.com/Tenantos/virtualization/template-installations-proxmox/#troubleshooting" "info"
		echo >&2

		if [[ "$cleanupCache" == false ]] && [[ -f "$imagePath" ]]; then
			if confirm "Delete cached cloud image ($imagePath)?"; then
				rm -f "$imagePath"
				log "Cached image deleted" "info"
			else
				log "Cached image kept at: $imagePath" "info"
			fi
		fi

		exit 1
	fi

	log "Image customization complete. Used command: $virtCustomizeCmd" "info"
}

createVmTemplate() {
	local imagePath="$1"
	local storage="$2"
	local vmid="$3"
	local name="$4"
	local bios="$5"
	local format="$6"
	local bridge="$7"

	log "Creating VM template" "info"
	destroyVmSafe "$vmid"
	log "Creating VM $vmid" "info"

	local qmCreateArgs=(
		"$vmid"
		"--name" "$name"
		"--ostype" "l26"
		"--memory" "2048"
		"--cores" "2"
		"-net0" "virtio,bridge=${bridge}"
	)

	if [[ "$machineType" != "pc-i440fx" ]]; then
		qmCreateArgs+=("--machine" "$machineType")
	fi

	qm create "${qmCreateArgs[@]}"

	log "Importing disk" "info"

	if ! qm importdisk "$vmid" "$imagePath" "$storage" --format "$format" &>/dev/null; then
		log "Failed to import disk" "error"
		exit 1
	fi

	local diskSpec=$(qm config "$vmid" | grep '^unused' | grep 'disk' | awk '{ print $2 }')

	if [[ -z "$diskSpec" ]]; then
		log "Failed to find imported disk in VM config" "error"
		exit 1
	fi

	log "Disk imported: $diskSpec" "info"
	log "Configuring VM" "info"

	local diskParam="--${diskDevice}0"
	local bootOrder="${diskDevice}0"

	local qmSetArgs=(
		"$vmid"
		"--scsihw" "$scsiController"
		"${diskParam}" "${diskSpec},discard=on"
		"--boot" "order=${bootOrder}"
		"--serial0" "socket"
	)

	if [[ "$vgaDisplay" != "none" ]]; then
		qmSetArgs+=("--vga" "$vgaDisplay")
	fi

	qm set "${qmSetArgs[@]}"

	if [[ "$bios" == "uefi" ]]; then
		log "Configuring UEFI" "info"
		qm set "$vmid" \
			--bios ovmf \
			--efidisk0 "${storage}:1,efitype=4m,pre-enrolled-keys=0"
	fi

	log "Converting to template" "info"
	qm template "$vmid"

	log "Template created successfully: $name (ID: $vmid)" "success"
}

interactiveMode() {
	log "Interactive Template Generator For Tenantos + Proxmox" "info"
	log "Run with --help to see options for automated builds" "info"
	log "After creating the image, the script will output a command for automated builds" "info"
	echo

	echo -n "Cloud image URL: "
	read -r cloudImageUrl

	if [[ -z "$cloudImageUrl" ]]; then
		log "URL cannot be empty" "error"
		exit 1
	fi

	local cachePath=$(getCachePath "$cloudImageUrl")

	if [[ -f "$cachePath" && "$noCache" == false && "$forceYes" == false ]]; then
		echo
		log "Found cached image: $cachePath" "warn"
		log "This image may have been modified by previous template builds" "warn"
		echo

		if confirm "Delete cached image and re-download?"; then
			rm -f "$cachePath"
			log "Cached image deleted" "info"
		fi
	fi

	echo
	log "Available storages:" "info"
	local storages=($(getStorageList))

	if [[ ${#storages[@]} -eq 0 ]]; then
		log "No storage found" "error"
		exit 1
	fi

	for i in "${!storages[@]}"; do
		echo "  $((i + 1))) ${storages[$i]}"
	done

	echo -n "Select storage [1-${#storages[@]}]: "
	read -r storageChoice

	if ! [[ "$storageChoice" =~ ^[0-9]+$ ]] || [[ $storageChoice -lt 1 ]] || [[ $storageChoice -gt ${#storages[@]} ]]; then
		log "Invalid storage selection" "error"
		exit 1
	fi

	storageId="${storages[$((storageChoice - 1))]}"

	echo
	echo -n "New VM ID of the template VM: "
	read -r vmId

	if ! [[ "$vmId" =~ ^[0-9]+$ ]]; then
		log "VM ID must be a number" "error"
		exit 1
	fi

	if vmExists "$vmId"; then
		log "VM $vmId already exists!" "warn"

		if ! confirm "Destroy existing VM $vmId and continue? (use -y flag to skip this prompt)"; then
			log "Aborted by user" "error"
			exit 1
		fi
	fi

	echo -n "Template name [template-$(date +%Y%m%d)]: "
	read -r vmName

	if [[ -z "$vmName" ]]; then
		vmName="template-$(date +%Y%m%d)"
	fi

	# Simple cleanup of the VM name
	# We assume that users of this script know what they are doing, therefore validation stuff is not our primary goal
	local sanitizedName=$(echo "$vmName" | sed 's/[^a-zA-Z0-9.-]/-/g')

	if [[ "$sanitizedName" != "$vmName" ]]; then
		log "VM name contained invalid characters, sanitized to: $sanitizedName" "warn"
		vmName="$sanitizedName"
	fi

	echo -n "Network bridge [vmbr0]: "
	read -r bridgeName

	if [[ -z "$bridgeName" ]]; then
		bridgeName="vmbr0"
	fi

	echo
	echo "BIOS Mode:"
	echo "  1) SeaBIOS (Legacy BIOS)"
	echo "  2) UEFI (OVMF) - Check image compatibility"
	echo -n "Select BIOS mode [1-2]: "
	read -r biosChoice

	case "$biosChoice" in
	1)
		biosMode="bios"
		;;
	2)
		biosMode="uefi"
		;;
	*)
		log "Invalid BIOS selection" "error"
		exit 1
		;;
	esac

	echo
	echo "Disk Format:"
	echo "  1) qcow2"
	echo "  2) raw"
	echo -n "Select disk format [1-2]: "
	read -r formatChoice

	case "$formatChoice" in
	1)
		diskFormat="qcow2"
		;;
	2)
		diskFormat="raw"
		;;
	*)
		log "Invalid format selection" "error"
		exit 1
		;;
	esac

	echo
	echo "Machine Type:"
	echo "  1) pc-i440fx (default)"
	echo "  2) q35"
	echo -n "Select machine type [1-2]: "
	read -r machineChoice

	case "$machineChoice" in
	1)
		machineType="pc-i440fx"
		;;
	2)
		machineType="q35"
		;;
	*)
		log "Invalid machine type selection" "error"
		exit 1
		;;
	esac

	echo
	echo "SCSI Controller:"
	echo "  1) VirtIO SCSI single (recommended)"
	echo "  2) VirtIO SCSI PCI"
	echo "  3) LSI 53C895A"
	echo "  4) LSI 53C810"
	echo "  5) MegaRAID SAS 8708EM2"
	echo "  6) VMware PVSCSI"
	echo -n "Select SCSI controller [1-6]: "
	read -r scsiChoice

	case "$scsiChoice" in
	1)
		scsiController="virtio-scsi-single"
		;;
	2)
		scsiController="virtio-scsi-pci"
		;;
	3)
		scsiController="lsi"
		;;
	4)
		scsiController="lsi53c810"
		;;
	5)
		scsiController="megasas"
		;;
	6)
		scsiController="pvscsi"
		;;
	*)
		log "Invalid SCSI controller selection" "error"
		exit 1
		;;
	esac

	echo
	echo "Disk Device:"
	echo "  1) SCSI (recommended)"
	echo "  2) VirtIO Block"
	echo "  3) SATA"
	echo "  4) IDE"
	echo -n "Select disk device [1-4]: "
	read -r diskDeviceChoice

	case "$diskDeviceChoice" in
	1)
		diskDevice="scsi"
		;;
	2)
		diskDevice="virtio"
		;;
	3)
		diskDevice="sata"
		;;
	4)
		diskDevice="ide"
		;;
	*)
		log "Invalid disk device selection" "error"
		exit 1
		;;
	esac

	echo
	echo "Display:"
	echo "  1) Serial Console (recommended for cloud images)"
	echo "  2) Standard VGA"
	echo "  3) VirtIO GPU"
	echo "  4) QXL (SPICE)"
	echo "  5) VMware compatible"
	echo "  6) None"
	echo -n "Select display [1-6]: "
	read -r vgaChoice

	case "$vgaChoice" in
	1)
		vgaDisplay="serial0"
		;;
	2)
		vgaDisplay="std"
		;;
	3)
		vgaDisplay="virtio"
		;;
	4)
		vgaDisplay="qxl"
		;;
	5)
		vgaDisplay="vmware"
		;;
	6)
		vgaDisplay="none"
		;;
	*)
		log "Invalid display selection" "error"
		exit 1
		;;
	esac

	echo
	echo "Is this a RHEL derivative (RHEL/CentOS/AlmaLinux/Rocky/Fedora)?"
	echo "  1) Yes"
	echo "  2) No"
	echo -n "Select [1-2]: "
	read -r rhelChoice

	case "$rhelChoice" in
	1)
		isRhelDerivative=true
		;;
	2)
		isRhelDerivative=false
		;;
	*)
		log "Invalid selection" "error"
		exit 1
		;;
	esac

	if [[ "$isRhelDerivative" == true ]]; then
		echo
		echo "Disable SELinux?"
		echo "Note: Most providers disable SELinux by default. Keeping SELinux enabled may cause configuration"
		echo "      challenges, templates may not work out of the box, and further configurations might be necessary."
		echo "  1) Yes (disable SELinux)"
		echo "  2) No (leave SELinux unchanged from image default)"
		echo -n "Select [1-2]: "
		read -r selinuxDisableChoice

		case "$selinuxDisableChoice" in
		1)
			disableSelinux=true
			;;
		2)
			disableSelinux=false
			;;
		*)
			log "Invalid selection" "error"
			exit 1
			;;
		esac

		if [[ "$disableSelinux" == false ]]; then
			echo
			echo "Run SELinux relabel during template building?"
			echo "  1) Yes (recommended, takes 1-2 min extra)"
			echo "  2) No"
			echo -n "Select [1-2]: "
			read -r selinuxRelabelChoice

			case "$selinuxRelabelChoice" in
			1)
				selinuxRelabel=true
				;;
			2)
				selinuxRelabel=false
				;;
			*)
				log "Invalid selection" "error"
				exit 1
				;;
			esac

			echo
			echo "Set qemu-guest-agent to SELinux permissive mode? (Recommended. Otherwise, you must handle SELinux-related issues yourself, which may affect Tenantos callbacks and first-boot scripts if SELinux is enforced.)"
			echo "  1) Yes (recommended)"
			echo "  2) No"
			echo -n "Select [1-2]: "
			read -r qemuPermissiveChoice

			case "$qemuPermissiveChoice" in
			1)
				setQemuPermissive=true
				;;
			2)
				setQemuPermissive=false
				;;
			*)
				log "Invalid selection" "error"
				exit 1
				;;
			esac
		fi
	fi

	echo
	echo "Update all packages in template?"
	echo "  1) Yes (recommended)"
	echo "  2) No"
	echo -n "Select [1-2]: "
	read -r updateChoice

	case "$updateChoice" in
	1)
		updatePackages=true
		;;
	2)
		updatePackages=false
		;;
	*)
		log "Invalid selection" "error"
		exit 1
		;;
	esac

	echo
	log "Configuration Summary" "info"

	local predictedCachePath=$(getCachePath "$cloudImageUrl")
	local cacheStatus="Will download image"

	if [[ -f "$predictedCachePath" && "$noCache" == false ]]; then
		cacheStatus="Using cached image"
	fi

	echo "  URL:               $cloudImageUrl"
	echo "  Cache:             $cacheStatus"
	echo "  Cache Path:        $predictedCachePath"
	echo "  Storage:           $storageId"
	echo "  VM ID:             $vmId"
	echo "  Name:              $vmName"
	echo "  Bridge:            $bridgeName"
	echo "  BIOS:              $biosMode"
	echo "  Disk Format:       $diskFormat"
	echo "  Machine Type:      $machineType"
	echo "  SCSI Controller:   $scsiController"
	echo "  Disk Device:       $diskDevice"
	echo "  Display:           $vgaDisplay"
	echo "  RHEL Derivative:   $([ "$isRhelDerivative" == true ] && echo "Yes" || echo "No")"

	if [[ "$isRhelDerivative" == true ]]; then
		echo "  SELinux Disabled:  $([ "$disableSelinux" == true ] && echo "Yes" || echo "No")"
		if [[ "$disableSelinux" == false ]]; then
			echo "  SELinux Relabel:   $([ "$selinuxRelabel" == true ] && echo "Yes" || echo "No")"
			echo "  QEMU Permissive:   $([ "$setQemuPermissive" == true ] && echo "Yes" || echo "No")"
		fi
	fi

	echo "  Update Packages:   $([ "$updatePackages" == true ] && echo "Yes" || echo "No")"

	echo

	if ! confirm "Proceed with template creation?"; then
		log "Aborted by user" "error"
		exit 1
	fi

	local imagePath=$(downloadCloudImage "$cloudImageUrl")
	customizeImage "$imagePath"
	createVmTemplate "$imagePath" "$storageId" "$vmId" "$vmName" "$biosMode" "$diskFormat" "$bridgeName"

	echo
	if [[ "$cleanupCache" == false ]]; then
		if confirm "Delete cached cloud image ($imagePath)?"; then
			rm -f "$imagePath"
			log "Cached image deleted" "info"
		else
			log "Cached image kept at: $imagePath" "info"
		fi
	else
		rm -f "$imagePath"
		log "Cached image deleted" "info"
	fi

	echo
	log "For automated builds, use this command:" "info"

	local cliCmd="$0 --url \"$cloudImageUrl\" --storage \"$storageId\" --vmid $vmId"
	cliCmd+=" --name \"$vmName\" --bridge \"$bridgeName\""
	cliCmd+=" --$(echo "$biosMode")"
	cliCmd+=" --$(echo "$diskFormat")"

	if [[ "$machineType" != "pc-i440fx" ]]; then
		cliCmd+=" --machine \"$machineType\""
	fi

	cliCmd+=" --scsi-controller \"$scsiController\""
	cliCmd+=" --disk-device \"$diskDevice\""
	cliCmd+=" --display \"$vgaDisplay\""

	if [[ "$isRhelDerivative" == true ]]; then
		cliCmd+=" --rhel-derivative"
	fi

	if [[ "$disableSelinux" == true ]]; then
		cliCmd+=" --disable-selinux"
	fi

	if [[ "$selinuxRelabel" == true ]]; then
		cliCmd+=" --selinux-relabel"
	fi

	if [[ "$setQemuPermissive" == true ]]; then
		cliCmd+=" --qemu-permissive"
	fi

	if [[ "$updatePackages" == true ]]; then
		cliCmd+=" --update-packages"
	fi

	if [[ "$noCache" == true ]]; then
		cliCmd+=" --no-cache"
	fi

	if [[ "$cleanupCache" == true ]]; then
		cliCmd+=" --cleanup"
	fi

	cliCmd+=" -y"

	log "$cliCmd" "info"
}

argumentMode() {
	if [[ -z "$cloudImageUrl" || -z "$storageId" || -z "$vmId" ]]; then
		log "Missing required arguments: --url, --storage, --vmid" "error"
		echo
		showUsage

		exit 1
	fi

	if ! [[ "$vmId" =~ ^[0-9]+$ ]]; then
		log "VM ID must be a number" "error"

		exit 1
	fi

	if vmExists "$vmId"; then
		log "VM $vmId already exists!" "warn"

		if ! confirm "Destroy existing VM $vmId and continue? (use -y flag to skip this prompt)"; then
			log "Aborted by user" "error"

			exit 1
		fi
	fi

	if [[ -z "$vmName" ]]; then
		vmName="template-$(date +%Y%m%d)"
	fi

	if [[ -z "$biosMode" ]]; then
		biosMode="bios"
	fi

	if [[ -z "$diskFormat" ]]; then
		log "Disk format not specified. Use --qcow2 or --raw" "error"
		exit 1
	fi

	if ! getStorageList | grep -q "^${storageId}$"; then
		log "Storage '$storageId' not found" "error"
		exit 1
	fi

	local imagePath=$(downloadCloudImage "$cloudImageUrl")
	customizeImage "$imagePath"
	createVmTemplate "$imagePath" "$storageId" "$vmId" "$vmName" "$biosMode" "$diskFormat" "$bridgeName"

	if [[ "$cleanupCache" == true ]]; then
		rm -f "$imagePath"

		log "Cached image deleted" "info"
	else
		log "Cached image kept at: $imagePath" "info"
	fi
}

parseArguments() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		-h | --help)
			showUsage
			exit 0
			;;
		--url)
			cloudImageUrl="$2"
			shift 2
			;;
		--storage)
			storageId="$2"
			shift 2
			;;
		--vmid)
			vmId="$2"
			shift 2
			;;
		--name)
			vmName="$2"
			shift 2
			;;
		--bridge)
			bridgeName="$2"
			shift 2
			;;
		--bios)
			biosMode="bios"
			shift
			;;
		--uefi)
			biosMode="uefi"
			shift
			;;
		--qcow2)
			diskFormat="qcow2"
			shift
			;;
		--raw)
			diskFormat="raw"
			shift
			;;
		--machine)
			machineType="$2"
			shift 2
			;;
		--scsi-controller)
			scsiController="$2"
			shift 2
			;;
		--disk-device)
			diskDevice="$2"
			shift 2
			;;
		--display)
			vgaDisplay="$2"
			shift 2
			;;
		--rhel-derivative)
			isRhelDerivative=true
			shift
			;;
		--disable-selinux)
			disableSelinux=true
			shift
			;;
		--selinux-relabel)
			selinuxRelabel=true
			shift
			;;
		--qemu-permissive)
			setQemuPermissive=true
			shift
			;;
		--update-packages)
			updatePackages=true
			shift
			;;
		--no-cache)
			noCache=true
			shift
			;;
		--cleanup)
			cleanupCache=true
			shift
			;;
		-y | --yes)
			forceYes=true
			shift
			;;
		*)
			log "Unknown argument: $1" "error"
			echo
			showUsage
			exit 1
			;;
		esac
	done

	[[ -n "$cloudImageUrl" || -n "$storageId" || -n "$vmId" ]]
}

main() {
	checkPrerequisites

	if parseArguments "$@"; then
		argumentMode
	else
		checkForUpdates
		interactiveMode
	fi
}

main "$@"
