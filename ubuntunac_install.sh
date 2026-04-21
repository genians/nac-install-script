#!/usr/bin/env bash

[[ -n $DEBUG ]] && set -x
set -o errtrace         # Make sure any error trap is inherited
set -o nounset          # Disallow expansion of unset variables
set -o pipefail         # Use last non-zero exit code in a pipeline

RED='\033[0;31m'
BLU='\033[0;34m'
YEL='\033[0;33m'
NC='\033[0m' # No Color

INSTALL_DIR="/disk/sys/boot/.install"

function util::warn() {
	echo -e "${YEL}WARN: $1${NC}" >&2
}

function util::error() {
	echo -e "${RED}ERR: $1${NC}" >&2
}

function util::info() {
	echo -e "${BLU}INF: $1${NC}"
}

function util::print_file() {
	local file="$1"
	if [ ! -f "$file" ]; then
		util::error "$file not found."
		return 1
	fi
	cat "$file"
}

FACTORYINSTALL="${FACTORYINSTALL:-0}"

if [[ "x$FACTORYINSTALL" != "x1" ]]; then
	ID=`whoami`

	if [[ "$ID" != "root" ]]; then
		util::error "You must be root for install."
		exit -1
	fi
else
	PROMPT=0
fi

util::info "Stop unattended upgrade service"
systemctl stop unattended-upgrades.service > /dev/null 2>&1
systemctl disable unattended-upgrades.service > /dev/null 2>&1
systemctl mask unattended-upgrades.service > /dev/null 2>&1
systemctl stop apt-daily.timer > /dev/null 2>&1
systemctl disable apt-daily.timer > /dev/null 2>&1
util::info "Mask unattended upgrade service"
systemctl stop apt-daily.timer apt-daily-upgrade.timer > /dev/null 2>&1
systemctl disable apt-daily.timer apt-daily-upgrade.timer > /dev/null 2>&1
systemctl mask apt-daily.timer apt-daily-upgrade.timer > /dev/null 2>&1
util::info "Remove unattended upgrade service"
rm -rf /var/lib/dpkg/lock-frontend > /dev/null 2>&1
rm -rf /var/lib/apt/lists/lock > /dev/null 2>&1
rm -rf /var/cache/apt/archives/lock > /dev/null 2>&1

echo 'Acquire::https::Verify-Peer "false";' | tee /etc/apt/apt.conf.d/99insecure

LOGFILE=/var/log/nac_install.log
echo "" > $LOGFILE
exec > >(tee -a $LOGFILE) 2>&1

TMP_DIR="$(rm -rf /tmp/nacupgrade* && mktemp -d -t nacupgrade.XXXXXXXXXX)"

export DEBIAN_FRONTEND=noninteractive

DEF_DNSSERVER=
DEF_GATEWAY=
ETH_INTERFACES=
ALT_INTERFACES=
KERNEL_FLAVOR=`uname -r | awk -F'-' '{print $3}'`
[ "x$KERNEL_FLAVOR" = "x" ] && KERNEL_FLAVOR="none"
PROMPT="${PROMPT:-1}"
DPKGCONFOPT="-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-overwrite"
REL="${REL:-$(awk -F'=' '/UBUNTU_CODENAME/ {print $2}' /etc/os-release)}"
PLATFORM_ARCH=$(arch)
PLATFORM="${PLATFORM:-}"
GNTARGET=UBUNTU
INIT_SETUP="${INIT_SETUP:-1}"
DEBPATCH="${DEBPATCH:-}"
LOCAL_MIRROR="${LOCAL_MIRROR:-}"
ROOT_MIRROR="${ROOT_MIRROR:-}"
REPO_MIRROR="${REPO_MIRROR:-}"
REPO_URI="${REPO_URI:-archive.ubuntu.com}"
TARGET="${TARGET:-}"
UPGRADE="${UPGRADE:-}"
INSTALL="${INSTALL:-1}"
KERNEL_UPGRADE="${KERNAL_UPGRADE:-}"
DEB="${DEB:-}"
LOCALE="${LOCALE:-}"
TIMEZONE="${TIMEZONE:-}"
DOWNLOADTARGET="${DOWNLOADTARGET:-}"
LOCALTARGET="${LOCALTARGET:-}"
SSHPORT="${SSHPORT:-}"
SSHALLALLOW="${SSHALLALLOW:-}"
KERNELUP="${KERNELUP:-}"
NETDRV="${NETDRV:-}"
BIN="${BIN:-}"
INSTALLISO="${INSTALLISO:-}"
FROMANSIBLE="${FROMANSIBLE:-}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-60}" # Default to 60 seconds (1 minutes)
MAX_RETRIES="${MAX_RETRIES:-3}" # Default to 3 retry attempts
DKBUILD="${DKBUILD:-}"
NODATASTORE="${NODATASTORE:-0}"

if [[ "x$KERNEL_FLAVOR" == "xaws" || "x$KERNEL_FLAVOR" == "xazure" ]]; then
	SSHALLALLOW=1
	SSHPORT=22
	#KERNELUP=no
fi

if [[ "x$KERNEL_FLAVOR" == "xazure" ]]; then
	NETDRV=hv_netvsc
fi

function upgrade::grub()
{
    check=`cat /etc/default/grub | grep GNTARGET`
    if [ "x$check" != "x" ]; then
        return 0;
    fi

	util::info "init-grub"
    case "$1"  in
	*)
	    # NOETH 환경에서 설치되도록 하기 위해 수정함.
	    # NOETH 환경에서는 splash 설정이 존재하지 않음.
    	#sed -i 's/splash/console=ttyS0,115200n8 net.ifnames=1 biosdevname=0 splash/g' /etc/default/grub
        sed -i '/^GRUB_CMDLINE_LINUX=/c\GRUB_CMDLINE_LINUX="PLATFORM='"$PLATFORM"' GNTARGET='"$GNTARGET"' console=ttyS0,115200n8 console=tty net.ifnames=1 biosdevname=0"' /etc/default/grub
        update-grub
    	util::info "change grub PLATFORM=$PLATFORM GNTARGET=$GNTARGET console=ttyS0,115200n8 net.ifnames=1 biosdevname=0"
		util::info "cat /etc/default/grub"
		util::print_file "/etc/default/grub"
	;;
    esac
}

function makefilesystem()
{
    util::info "makefilesystem"
    tdev="${1}1"
    util::info "${1}"
    util::info "tdev = ${tdev}"

    # umount dev
    check=`mount | grep $tdev`
    if [ "x$check" != "x" ]; then
        umount $tdev
    fi

    # MBR 제거
    dd if=/dev/zero of=${1} count=1 bs=512

    parted ${1} --script --align optimal mklabel gpt mkpart primary 1MiB 100%

    mke2fs -t ext4 -j ${tdev}
    tune2fs -i 0 -c 0 ${tdev}
    e2label ${tdev} DATA

    mkdir -p /media/DATA

    check=`cat /etc/fstab | grep LABEL=DATA`
    if [ "x$check" == "x" ]; then
        fstab_cmd="LABEL=DATA /disk/data   ext4   defaults,discard,noatime,barrier=0        0"
        echo $fstab_cmd >> /etc/fstab
    fi

    util::info "fstab_cmd = ${fstab_cmd}"
    util::info "cat /etc/fstab"
    util::print_file "/etc/fstab"
}


function makefilesystem_ssdev_directory()
{
    util::info "makefilesystem_ssdev_directory"
    ssdev_dir="${1}"
    target_dir="/disk/data/ssdev"

    util::info ${ssdev_dir}
    util::info ${target_dir}

    mkdir -p ${ssdev_dir}
    mkdir -p ${target_dir}

    check=`cat /etc/fstab | grep $target_dir`
    if [ "x$check" == "x" ]; then
        fstab_cmd="${ssdev_dir} ${target_dir}   none   bind	0        0"
        echo $fstab_cmd >> /etc/fstab
    fi

	util::info "fstab_cmd = ${fstab_cmd}"
	util::info "cat /etc/fstab"
	util::print_file "/etc/fstab"
}

function makefilesystem_ssdev()
{
    util::info "makefilesystem_ssdev"
    tdev="${1}1"
    util::info "${1}"
    util::info "tdev = ${tdev}"

    # umount dev
    check=`mount | grep $tdev`
    if [ "x$check" != "x" ]; then
        umount $tdev
    fi

    # MBR 제거
    dd if=/dev/zero of=${1} count=1 bs=512

    parted ${1} --script --align optimal mklabel gpt mkpart primary 1MiB 100%

    mke2fs -t ext4 -j ${tdev}
    tune2fs -i 0 -c 0 ${tdev}
    e2label ${tdev} SSDEV

    check=`cat /etc/fstab | grep LABEL=SSDEV`
    if [ "x$check" == "x" ]; then
        fstab_cmd="LABEL=SSDEV /disk/data/ssdev   ext4   defaults,discard,noatime,barrier=0        0"
        echo $fstab_cmd >> /etc/fstab
    fi

    util::info "fstab_cmd = ${fstab_cmd}"
    util::info "cat /etc/fstab"
	util::print_file "/etc/fstab"
}


function upgrade::storage()
{
    util::info "init-storage ${1}"

    # 모델에 상관없이 생성함.
    mkdir -p /disk/sys
    mkdir -p /disk/data
    mkdir -p /disk/data/ssdev

    case "$1"  in
	"C40"|"C50")
	    util::info "C40, C50 format disk"
	    util::info "mount ssdev directory"
	    makefilesystem_ssdev_directory "/disk/ssdev"
	    util::info "format sdb"
	    makefilesystem "/dev/sdb"
	    mount /dev/sdb1 /disk/data
	    mount -o bind /disk/ssdev /disk/data/ssdev 
	;;

	"C10_R1"|"C20_R1"|"C30_R1"|"C40_R1"|"C50_R1"|"C40_R2"|"C50_R2"|"ES30_R2"|"ES50_R2"|"C50G_R1")
	    util::info "C10_R1, C20_R1, C30_R1, C40_R1, C50_R1, C40_R2, C50_R2, ES30_R2, ES50_R2, C50G_R1 format disk"
	    util::info "mount ssdev directory"
	    makefilesystem_ssdev_directory "/disk/ssdev"
	    util::info "format sdb"
	    makefilesystem "/dev/sdb"
	    mount /dev/sdb1 /disk/data
	    mount -o bind /disk/ssdev /disk/data/ssdev 
	;;

	"C50G")
	    util::info "C50G format disk"
	    util::info "mount ssdev directory"
	    makefilesystem_ssdev_directory "/disk/ssdev"
	    util::info "format sdc"
	    makefilesystem "/dev/sdc"
	    mount /dev/sdc1 /disk/data
	    mount -o bind /disk/ssdev /disk/data/ssdev 
	;;


	"ES30"|"ES30_R1"|"ES50"|"ES50_R1")
	    umount /dev/sdb1
	    umount /dev/sdc1
	    util::info "ES30, ES30_R1, ES50, ES50_R1 format disk"
	    util::info "format ssdev sdb"
	    makefilesystem_ssdev "/dev/sdb"
	    util::info "format sdc"
	    makefilesystem "/dev/sdc"
	    mount /dev/sdc1 /disk/data
	    mount /dev/sdb1 /disk/data/ssdev
	;;

	*)
	;;
    esac
}

function upgrade::platform()
{
	util::info "init-platform"

    echo "" >> /etc/bash.bashrc
    echo "export PLATFORM=${PLATFORM}" >> /etc/bash.bashrc
    echo "export GNTARGET=${GNTARGET}" >> /etc/bash.bashrc

    util::info "mkdir -p ${INSTALL_DIR}"
    mkdir -p ${INSTALL_DIR}
}

function util::ldconfig()
{
	if [[ "x$INSTALLISO" != "x" ]]; then
		return 0
	fi

	ldconfig
}

function util::reconfigure_dpkg()
{
	if [[ "x$INSTALLISO" != "x" ]]; then
		return 0
	fi

	dpkg --configure -a > /dev/null 2>&1
}

function util::fixbroken_apt()
{
	if [[ "x$INSTALLISO" != "x" ]] || [[ "x$BIN" != "x" ]]; then
		return 0
	fi
	apt-get --fix-broken -y install ${DPKGCONFOPT} > /dev/null
}

function util::update_apt()
{
	if [[ "x$BIN" != "x" ]]; then
		return 0
	fi
	apt-get update > /dev/null 2>&1
}

function util::install_packages()
{
	if [[ "x$BIN" != "x" ]]; then
		return 0
	fi
	packages=("$@")
	for package in "${packages[@]}"; do
		util::info "Install... $package"
		retry_count=0
		success=false
		while [ $retry_count -lt 10 ]; do
			if apt-get install -y "$package" ${DPKGCONFOPT} >> $LOGFILE 2>&1; then
				success=true
				break
			else
				util::error "Failed to install $package (attempt $((retry_count+1)))"
				retry_count=$((retry_count + 1))
			fi

			sleep 5
		done

		if ! $success; then
			util::error "Failed to install $package after 10 attempts"
			apt-get install -y "$package" 2>&1 | tee -a "$LOGFILE" | grep -E "^E:" | while read -r line ; do
			util::error "${line}"
			done
			exit -1
		fi
	done
}

function util::start_systemctl()
{
	if [[ "x$INSTALLISO" != "x" ]]; then
		return 0
	fi
	services=("$@")
	for service in "${services[@]}"; do
		util::info "Start... $service"
		systemctl start "$service" > /dev/null 2>&1
	done
}

function util::stop_systemctl()
{
	if [[ "x$INSTALLISO" != "x" ]]; then
		return 0
	fi
	services=("$@")
	for service in "${services[@]}"; do
		util::info "Stop... $service"
		systemctl stop "$service" > /dev/null 2>&1
	done
}

function util::enable_systemctl()
{
	if [[ "x$INSTALLISO" != "x" ]]; then
		return 0
	fi
	services=("$@")
	for service in "${services[@]}"; do
		util::info "Enable... $service"
		systemctl enable "$service" > /dev/null 2>&1
	done
}

function util::disable_systemctl()
{
	if [[ "x$INSTALLISO" != "x" ]]; then
		return 0
	fi
	services=("$@")
	for service in "${services[@]}"; do
		util::info "Disable... $service"
		systemctl disable "$service" > /dev/null 2>&1
	done
}

function util::mask_systemctl()
{
	if [[ "x$INSTALLISO" != "x" ]]; then
		return 0
	fi
	services=("$@")
	for service in "${services[@]}"; do
		util::info "Mask... $service"
		systemctl mask "$service" > /dev/null 2>&1
	done
}

function util::unmask_systemctl()
{
	if [[ "x$INSTALLISO" != "x" ]]; then
		return 0
	fi
	services=("$@")
	for service in "${services[@]}"; do
		util::info "UnMask... $service"
		systemctl unmask "$service" > /dev/null 2>&1
	done
}

PERCONA_VERSION="${PERCONA_VERSION:-8.0.42-33-1}"
#PERCONA_VERSION="${PERCONA_VERSION:-8.0.41-32-1}"
#PERCONA_VERSION="${PERCONA_VERSION:-8.0.40-31-1}"
#PERCONA_VERSION="${PERCONA_VERSION:-8.0.39-30-1}"
#PERCONA_VERSION="${PERCONA_VERSION:-8.0.37-29-1}"
FILEBEAT_VERSION="${FILEBEAT_VERSION:-7.17.25}"
ELASTIC_VERSION="${ELASTIC_VERSION:-6.8.6}"
LOCALCONF="/disk/sys/conf/local.conf"
CENABLEPASSWORD="/disk/sys/conf/CENABLEPASSWORD"
UDEVRULE="/etc/udev/rules.d/70-persistent-net.rules"
LDCONFNAC="aaa-genian-nac.conf"

function util::getcodename()
{
	echo $(awk -F'=' '/UBUNTU_CODENAME/ {print $2}' /etc/os-release)
}

function util::setbash()
{
	if [[ "x$INSTALLISO" != "x" ]]; then
		return 0
	fi
	rm -v /bin/sh > /dev/null 2>&1
	ln -s /bin/bash /bin/sh
}

function install::basepkg()
{
	/usr/geni/alder stop > /dev/null 2>&1
	# procmon 종료
	util::stop_systemctl procmon.service

	# 설치과정에서 적용된 apt proxy 설정 제거
	#truncate -s 0 /etc/apt/apt.conf

	util::stop_systemctl rpcbind
	util::disable_systemctl rpcbind
	util::mask_systemctl rpcbind

	util::stop_systemctl snmpd snmptrapd apache2 ipsec strongswan-starter mysql elasticsearch winbind smbd \
		samba-ad-dc nmbd tomcat8 tomcat9 tomcat10 syslog-ng nfs-server samba nmb
	util::mask_systemctl snmpd snmptrapd apache2 ipsec strongswan-starter mysql elasticsearch winbind smbd \
		samba-ad-dc nmbd tomcat8 tomcat9 tomcat10 syslog-ng nfs-server samba nmb

	util::update_apt

	util::install_packages vim dialog libpam-pwquality traceroute \
		wget gnupg2 debsums libnuma1 psmisc curl libmecab2 cabextract \
		dnsutils tcpdump strace gftp python3-pip lsof jq \
		gdb systemd-coredump udhcpc libreadline-dev \
		libboost-thread-dev libboost-filesystem-dev libsodium-dev kmod \
		syslog-ng openssh-server nfs-common \
		ethtool ipcalc ifenslave vlan iptables arping unzip zip libtinyxml2.6.2v5 \
		bridge-utils dmidecode \
		nmap ntpdate net-tools libc-ares2 lrzsz \
		sysstat libtalloc2 iproute2 ansible \
		httrack lsb-release ca-certificates iw wireless-tools smartmontools e2fsprogs \
		parted tzdata

	if [[ "x$CODENAME" == "xnoble" ]]; then
		util::install_packages util-linux-extra libaio1t64 libtirpc-dev libncurses6 libtinfo6 libpcre3-dev libpcap0.8t64 libjsoncpp25 libldap2 libparted2t64
	elif [[ "x$CODENAME" == "xjammy" ]]; then
		util::install_packages libaio1 dpkg-sig libncurses5 libpcap0.8 libjsoncpp25 libldap-2.5-0 libparted2
	else
		util::install_packages libaio1 dpkg-sig libncurses5 libpcap0.8 libjsoncpp1 libldap-2.4-2 libparted2
	fi

	if [[ "x$CODENAME" == "xbionic" ]]; then
		util::install_packages libsnmp30
	fi
	if [[ "x$CODENAME" == "xfocal" ]]; then
		util::install_packages libsnmp35
	fi
	if [[ "x$CODENAME" == "xjammy" ]]; then
		util::install_packages libsnmp40
	fi
	if [[ "x$CODENAME" == "xnoble" ]]; then
		util::install_packages libsnmp40t64
	fi

	echo "krb5-config krb5-config/add_servers_realm string TESTDOMAIN" | debconf-set-selections
	echo "krb5-config krb5-config/default_realm string TESTDOMAIN" | debconf-set-selections
	echo "krb5-config krb5-config/kerberos_servers string kdc" | debconf-set-selections
	echo "krb5-config krb5-config/admin_server string kdc" | debconf-set-selections

	if [[ "$TARGET" == "GPC" ]]; then
		util::install_packages nfs-kernel-server ldap-utils pigz samba winbind krb5-user libcommons-dbcp-java \
			rrdtool libexpat1 libltdl7 libsybdb5 libpq5 \
			unixodbc-dev apt-transport-https fonts-nanum
		if [[ "x$CODENAME" == "xnoble" ]]; then
			util::install_packages libapr1t64 libaprutil1t64 libodbc2
			# 24.04 awscli
			if [[ "x$REPO_MIRROR" == "x" ]] && [[ "x$BIN" == "x" ]]; then
				util::info "Install... awscli v2"
				/usr/bin/curl -# -4 --connect-timeout $CONNECT_TIMEOUT --retry $MAX_RETRIES -SkL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o ${TMP_DIR}/awscliv2.zip
				if [ $? -ne 0 ]; then
					util::error "Failed to download awscli v2 after $MAX_RETRIES attempts."
					exit -1
				fi
				unzip -oq ${TMP_DIR}/awscliv2.zip -d ${TMP_DIR} > /dev/null 2>&1
				${TMP_DIR}/aws/install > /dev/null 2>&1
				if ! which aws > /dev/null 2>&1; then
					util::error "awscli install failed."
					exit -1
				fi
			fi
		else
			util::install_packages libapr1 libaprutil1 awscli libodbc1
		fi
	fi

	util::disable_systemctl networkd-dispatcher
	util::stop_systemctl networkd-dispatcher

	if [[ "x$PLATFORM_ARCH" == "xx86_64" ]]; then
		VLANQ=`grep -E '^8021q' /etc/modules`
		if [[ "x$VLANQ" = "x" ]]; then
			echo "8021q" >> /etc/modules
		fi
	fi

	# 초기 설치 후 dhcp 비활성화
	#sed -i "s/^[^#]*\(      dhcp4: \).*/\1no/" /etc/netplan/01-netcfg.yaml
	# 기본 bond 인터페이스 생성
	#echo -e "  bonds:\n    bond0:\n      dhcp4: no" >> /etc/netplan/01-netcfg.yaml

	util::unmask_systemctl unattended-upgrades
	# 자동 설치 서비스 비활성화
	util::stop_systemctl unattended-upgrades
	util::disable_systemctl unattended-upgrades
	if [[ "x$INSTALLISO" != "x" ]]; then
		apt -y purge --auto-remove unattended-upgrades > /dev/null 2>&1
	fi
	util::stop_systemctl apt-daily-upgrade.timer
	util::disable_systemctl apt-daily-upgrade.timer
	util::mask_systemctl apt-daily-upgrade.service
	util::stop_systemctl apt-daily.timer
	util::disable_systemctl apt-daily.timer
	util::mask_systemctl apt-daily.service
	util::disable_systemctl apt-daily.timer
	util::disable_systemctl apt-daily.service
	util::disable_systemctl apt-daily-upgrade.timer
	util::disable_systemctl apt-daily-upgrade.service
	util::stop_systemctl apt-daily.timer
	util::stop_systemctl apt-daily.service
	util::stop_systemctl apt-daily-upgrade.timer
	util::stop_systemctl apt-daily-upgrade.service
}

function install::nacpkg()
{
	util::update_apt

	util::install_packages snmptrapd snmpd snmp

	util::disable_systemctl snmpd snmptrapd

	util::install_packages apache2 libapache2-mod-security2 libapache2-mod-qos

	util::install_packages strongswan

	if [[ "$TARGET" == "GPC" ]]; then
		util::install_packages libapache2-mod-jk
	fi
	# enable apache module
	a2enmod ssl > /dev/null
	a2enmod rewrite > /dev/null
	a2enmod proxy > /dev/null
	a2enmod proxy_http > /dev/null
	a2enmod cache > /dev/null
	a2enmod cache_disk > /dev/null
	a2enmod headers > /dev/null
	a2enmod remoteip > /dev/null
	a2dismod mpm_event > /dev/null
	a2enmod mpm_worker > /dev/null
	a2enmod qos > /dev/null
	a2enmod proxy_connect > /dev/null

	if [[ "$TARGET" != "GPC" ]]; then
		util::unmask_systemctl apache2
		return 0
	fi

	# 설치하자마자 실행되는것을 방지하기 위해 mask
	util::mask_systemctl apache2
	util::mask_systemctl mysql
	util::mask_systemctl tomcat9
	util::mask_systemctl tomcat8
	util::mask_systemctl tomcat10
	util::mask_systemctl elasticsearch
	util::mask_systemctl winbind
	util::mask_systemctl smbd
	util::mask_systemctl samba-ad-dc
	util::mask_systemctl nmbd
	util::mask_systemctl nmb
	util::mask_systemctl samba

	if [[ "x$CODENAME" == "xbionic" ]]; then
		util::install_packages tomcat8 libmysql-java libmysqlclient20 libjemalloc1
	fi
	if [[ "x$CODENAME" == "xfocal" || "x$CODENAME" == "xjammy" ]]; then
		util::install_packages libmariadb-java libmysqlclient21 libjemalloc2
	fi
	if [[ "x$CODENAME" == "xnoble" ]]; then
		util::install_packages libmariadb-java libmysqlclient21 libjemalloc2
	fi

	util::install_packages libnuma1 psmisc mysql-common libmecab2 zlib1g debsums

	util::update_apt

	if [[ "x$NODATASTORE" != "x1" ]]; then
		PERCONA_VERSION=${PERCONA_VERSION}.${CODENAME}
		if [[ "x$BIN" == "x" ]]; then
			LATEST_PERCONA_VERSION=$(LANG=C apt-cache policy percona-server-server | awk '/Candidate:/ { print $2 }')
			if [[ "x$LATEST_PERCONA_VERSION" != "x" ]]; then
				PERCONA_VERSION=$LATEST_PERCONA_VERSION
			fi
		fi

		echo "percona-server-server percona-server-server/root-pass password" | debconf-set-selections
		echo "percona-server-server percona-server-server/re-root-pass password" | debconf-set-selections
		echo "percona-server-server percona-server-server/default-auth-override select Use Strong Password Encryption (RECOMMENDED)" | debconf-set-selections
		echo "percona-server-server percona-server-server/remove-data-dir boolean true" | debconf-set-selections
		echo "percona-server-server percona-server-server/data-dir note Ok" | debconf-set-selections

		PS_DOWNLOADURL="https://downloads.percona.com/downloads/Percona-Server-8.0/Percona-Server-8.0.18-9/binary/debian/bionic/x86_64"
		if [[ "x$CODENAME" == "xbionic" ]]; then
			util::info "Install... percona-server"
			/usr/bin/curl -# -4 --connect-timeout $CONNECT_TIMEOUT --retry $MAX_RETRIES -SkL ${PS_DOWNLOADURL}/percona-server-common_8.0.18-9-1.bionic_amd64.deb -o ${TMP_DIR}/percona-server-common_8.0.18-9-1.bionic_amd64.deb
			if [ $? -ne 0 ]; then util::error "Failed to download Percona Server common package."; exit -1; fi
			dpkg -i ${TMP_DIR}/percona-server-common_8.0.18-9-1.bionic_amd64.deb

			/usr/bin/curl -# -4 --connect-timeout $CONNECT_TIMEOUT --retry $MAX_RETRIES -SkL ${PS_DOWNLOADURL}/libperconaserverclient21_8.0.18-9-1.bionic_amd64.deb -o ${TMP_DIR}/libperconaserverclient21_8.0.18-9-1.bionic_amd64.deb
			if [ $? -ne 0 ]; then util::error "Failed to download Percona Server client library."; exit -1; fi
			dpkg -i ${TMP_DIR}/libperconaserverclient21_8.0.18-9-1.bionic_amd64.deb

			/usr/bin/curl -# -4 --connect-timeout $CONNECT_TIMEOUT --retry $MAX_RETRIES -SkL ${PS_DOWNLOADURL}/percona-server-client_8.0.18-9-1.bionic_amd64.deb -o ${TMP_DIR}/percona-server-client_8.0.18-9-1.bionic_amd64.deb
			if [ $? -ne 0 ]; then util::error "Failed to download Percona Server client package."; exit -1; fi
			dpkg -i ${TMP_DIR}/percona-server-client_8.0.18-9-1.bionic_amd64.deb

			/usr/bin/curl -# -4 --connect-timeout $CONNECT_TIMEOUT --retry $MAX_RETRIES -SkL ${PS_DOWNLOADURL}/percona-server-server_8.0.18-9-1.bionic_amd64.deb -o ${TMP_DIR}/percona-server-server_8.0.18-9-1.bionic_amd64.deb
			if [ $? -ne 0 ]; then util::error "Failed to download Percona Server server package."; exit -1; fi
			dpkg -i ${TMP_DIR}/percona-server-server_8.0.18-9-1.bionic_amd64.deb
		elif [[ "x$CODENAME" == "xfocal" || "x$CODENAME" == "xjammy" ]]; then
			util::install_packages libgflags2.2
			util::install_packages percona-server-common=${PERCONA_VERSION} libperconaserverclient21=${PERCONA_VERSION} \
				percona-server-client=${PERCONA_VERSION} \
				percona-server-server=${PERCONA_VERSION}
		elif [[ "x$CODENAME" == "xnoble" ]]; then
			if [[ "x$INSTALLISO" == "x" ]] && [[ "x$BIN" == "x" ]]; then
				apt remove -y libperconaserverclient* percona-server* --allow-change-held-packages > /dev/null 2>&1
			fi
			ln -s libaio.so.1t64.0.2 /lib/x86_64-linux-gnu/libaio.so.1 > /dev/null 2>&1

			util::install_packages percona-server-common=${PERCONA_VERSION} libperconaserverclient21=${PERCONA_VERSION} \
				percona-server-client=${PERCONA_VERSION} \
				percona-server-server=${PERCONA_VERSION}
		fi

		#if [[ "x$INSTALLISO" == "x" ]] && [[ "x$BIN" == "x" ]]; then
		#apt remove -y libperconaserverclient21 --allow-change-held-packages > /dev/null 2>&1
		#fi

		if [[ "x$CODENAME" == "xfocal" || "x$CODENAME" == "xjammy" || "x$CODENAME" == "xnoble" ]]; then
			util::disable_systemctl filebeat
			util::mask_systemctl filebeat
			if [[ "x$(apt list --installed 2>/dev/null | grep filebeat)" == "x" ]]; then
				echo "deb https://artifacts.elastic.co/packages/7.x/apt stable main" > /etc/apt/sources.list.d/elastic-7.x.list
				if [[ "x$REPO_MIRROR" != "x" ]]; then
					echo "deb http://$REPO_MIRROR/artifacts.elastic.co/packages/7.x/apt stable main" > /etc/apt/sources.list.d/elastic-7.x.list
				fi
				if [[ "$LOCAL_MIRROR" == "1" ]]; then
					sed -i -e "s#http:/#[trusted=yes] file:#g" -e "s#https:/#[trusted=yes] file:#g" /etc/apt/sources.list.d/elastic-7.x.list
				fi
				util::update_apt
				util::install_packages filebeat=${FILEBEAT_VERSION}
				rm -rf /etc/apt/sources.list.d/elastic-7.x.list > /dev/null 2>&1
				util::update_apt
			fi
		fi
	else
		util::info "Skip MySQL/Percona installation (NODATASTORE=1)"
	fi

	util::update_apt

	if [[ "x$CODENAME" == "xfocal" || "x$CODENAME" == "xjammy" || "x$CODENAME" == "xnoble" ]]; then
		# Java 17
		util::install_packages openjdk-17-jre-headless
		update-alternatives --set java /usr/lib/jvm/java-17-openjdk-amd64/bin/java
	else
		# Java 11
		util::install_packages openjdk-11-jre-headless
		update-alternatives --set java /usr/lib/jvm/java-11-openjdk-amd64/bin/java
	fi

	# Elastic 초기 설치는 6.x 버전
	if [[ "x$(apt list --installed 2>/dev/null | grep elasticsearch)" == "x" ]]; then
		util::install_packages elasticsearch=${ELASTIC_VERSION}
	fi

	apt-mark hold elasticsearch

	util::unmask_systemctl apache2
	util::unmask_systemctl tomcat9
	util::unmask_systemctl tomcat8
	util::unmask_systemctl tomcat10
	util::unmask_systemctl elasticsearch
	if [[ "x$NODATASTORE" != "x1" ]]; then
		util::unmask_systemctl mysql
	fi

	util::disable_systemctl winbind
	#util::unmask_systemctl winbind
	util::disable_systemctl smbd
	#util::unmask_systemctl smbd
	util::disable_systemctl samba-ad-dc
	#util::unmask_systemctl samba-ad-dc
	util::disable_systemctl nmbd
	#util::unmask_systemctl nmbd
	util::disable_systemctl nmb
	#util::unmask_systemctl nmb
	util::disable_systemctl samba
	#util::unmask_systemctl samba
}

function upgrade::kernel()
{
	local target=$1

	if [[ "x$INSTALLISO" != "x" ]]; then
		return 0
	fi

	#
	util::update_apt

	local aptkernel=`apt-cache search linux-image-${target}$ | awk -F ' ' '{print $1}'`

	if [[ "x${aptkernel}" = "x" ]]; then
		echo "UPGRADE::KERNEL. ${target} NOT FOUND."
		return 0
	fi

	util::install_packages ${aptkernel}
	util::install_packages linux-modules-extra-${target}

	OLDKERN=$(apt-mark showhold|grep linux-image|sed -ne 's/linux-image-//p')
	for i in $OLDKERN; do
		apt-mark unhold $OLDKERN > /dev/null 2>&1
	done
	apt-mark hold linux-image-$target linux-headers-$target linux-modules-extra-${target}

	local grubmenu=`awk -F\' '/submenu / {print $4}' /boot/grub/grub.cfg | head -1`
	local grubentry=`awk -F\' '/menuentry / {print $4}' /boot/grub/grub.cfg |grep ${target}|grep -v recovery|grep -v osprober`

	echo "Changing GRUB_DEFAULT=${grubmenu}>${grubentry}"

	if [[ "x${grubmenu}" = "x" || "x${grubentry}" = "x" ]]; then
		echo "UPGRADE::KERNEL. GRUB NOT FOUND."
		return 0
	fi
	sed -i "s/GRUB_DEFAULT=.*/GRUB_DEFAULT=\"${grubmenu}>${grubentry}\"/g" /etc/default/grub
	rm -rf /etc/default/grub.d/99-custom-kernel.cfg
	update-grub2
}

function upgrade::config()
{
	ln -s /usr/sbin/iptables /sbin/iptables > /dev/null 2>&1

	if [[ "x$INSTALLISO" != "x" ]]; then
		return 0
	fi
	if [[ -f $LOCALCONF && "$UPGRADE" == "1" ]]; then
		return 0
	fi

	echo "root/admin123!" > /etc/account.conf
	ADMIN=`cat /etc/account.conf | awk -F '/' '{print $1}'`
	PASS=`cat /etc/account.conf | awk -F '/' '{print $2}'`

	# local.conf 파일을 생성한다.
	mkdir -p /disk/sys/conf
	: > $LOCALCONF
	chown $ADMIN:$ADMIN $LOCALCONF
	chmod 755 $LOCALCONF

	touch $CENABLEPASSWORD
	chown $ADMIN:$ADMIN $CENABLEPASSWORD
	chmod 600 $CENABLEPASSWORD

	CPASS=`echo -n $PASS | sha256sum | awk '{print $1}'`
	echo "$ADMIN:$CPASS" > $CENABLEPASSWORD

	# 현재 설치가 양산단계에서 진행되고 있음을 표시한다.
	echo "install-point=factory" >> $LOCALCONF

	if [[ "x$SSHPORT" != "x" ]]; then
		echo "ssh_port=$SSHPORT" >> $LOCALCONF
	fi
	if [[ "x$SSHALLALLOW" != "x" ]]; then
		echo "ssh_allallow=$SSHALLALLOW" >> $LOCALCONF
	fi

	: > $UDEVRULE
    NUM=0
    INTERFACES=`ip link | grep -iE "enx[0-9]+.*:|eth[0-9]+.*:|ens[0-9]+.*:|eno[0-9]+.*:|enp[0-9]+.*:" | grep -Ev "<.*SLAVE.*>|vlan|veth|dummy|bridge|bond|macvlan|macvtap|vxlan|ip6tnl|ipip|sit|gre|gretap|ip6gre|ip6gretap|vti|nlmon|ipvlan|lowpan|geneve|vrf|macsec|@" | awk -F ': ' '{print $2}'`
    for interface in $INTERFACES; do
        MAC=`ip link show $interface | grep link/ether | awk -F ' ' '{print $2}'`
		RULE=""
		if [[ "x$NETDRV" != "x" ]]; then
        	RULE="SUBSYSTEM==\"net\", ACTION==\"add\", DRIVERS==\"$NETDRV\", ATTR{address}==\"$MAC\", ATTR{type}==\"1\", NAME=\"eth$NUM\""
		else
        	RULE="SUBSYSTEM==\"net\", ACTION==\"add\", DRIVERS==\"?*\", ATTR{address}==\"$MAC\", ATTR{type}==\"1\", NAME=\"eth$NUM\""
		fi
        echo $RULE >> $UDEVRULE
		ETH_INTERFACES+="eth$NUM,"
		ALT_INTERFACES+="$interface,"
        IP=`ifconfig $interface | grep -E 'inet ' | awk -F ' ' '{print $2}'`
        if [[ "x$IP" != "x" ]]; then
            NETMASK=`ifconfig $interface | grep -E 'inet ' | awk -F ' ' '{print $4}'`
            ETH=eth$NUM
            EXISTS=`cat $LOCALCONF | grep interface_${ETH}_address`
            if [[ "x$EXISTS" == "x" ]]; then
                echo "interface_${ETH}_address=$IP $NETMASK" >> $LOCALCONF
            fi
            DEFGW=`ip route | grep -E "^default via [0-9]+.[0-9]+.[0-9]+.[0-9]+ dev $interface" | awk -F ' ' '{print $3}'`
            if [[ "x$DEFGW" != "x" ]]; then
                DEFGWEXISTS=`cat $LOCALCONF | grep ip_default-gateway`
                if [[ "x$DEFGWEXISTS" == "x" ]]; then
                    echo "ip_default-gateway=$DEFGW" >> $LOCALCONF
					DEF_GATEWAY=$DEFGW
                fi
            fi
        fi
        NUM=$(( $NUM + 1 ))
    done
	ETH_INTERFACES="${ETH_INTERFACES%,}"
	ALT_INTERFACES="${ALT_INTERFACES%,}"

	if [[ "x$CODENAME" == "xfocal" || "x$CODENAME" == "xjammy" || "x$CODENAME" == "xnoble" ]]; then
    	NAMESERVER=`resolvectl dns | grep -E 'Link.*: [0-9]+.[0-9]+.[0-9]+.[0-9]' | awk -F ' ' '{print $4}'`
	else
		NAMESERVER=`systemd-resolve --status | grep 'DNS Servers' | awk -F ' ' '{print $3}'`
	fi
    if [[ "x$NAMESERVER" != "x" ]]; then
        EXISTS=`cat $LOCALCONF | grep ip_name-server`
        if [[ "x$EXISTS" == "x" ]]; then
            echo "ip_name-server=$NAMESERVER" >> $LOCALCONF
			DEF_DNSSERVER=$NAMESERVER
        fi
    fi
}

function fix::deb_components()
{
	local debfile="$1"

	if [ ! -f "$debfile" ]; then
		util::error "$debfile not found."
		return 1
	fi

	local workdir
	workdir=$(mktemp -d)
	util::info "[*] Extracting $debfile to $workdir ..."
	dpkg-deb -R "$debfile" "$workdir" || return 1
	local target="$workdir/usr/geni/system-init_post.sh"
	if [ -f "$target" ]; then
		util::info "[*] Patching $target ..."
		sed -i 's/^\(systemctl stop systemd-networkd\.service\)/# \1/' "$target"
	else
		util::error "Warning: $target not found in package"
	fi

	util::info "[*] Rebuilding deb package ..."
	dpkg-deb -b "$workdir" "$debfile"
	util::info "[*] Done. Modified package saved as $debfile"
	rm -rf "$workdir"
}

function upgrade::nac()
{
	if [[ "x$INSTALLISO" != "x" ]]; then
		return 0
	fi

	if [[ "x$DOWNLOADTARGET" != "x" ]]; then
		GDEB=$(/usr/bin/curl -# --connect-timeout $CONNECT_TIMEOUT --retry $MAX_RETRIES -w "%{filename_effective}" -SkLO ${DOWNLOADTARGET})
		if [ $? -ne 0 ]; then
			util::error "Failed to download NAC package from ${DOWNLOADTARGET} after $MAX_RETRIES attempts."
			exit -1
		fi
		DEBPKGCODENAME=`dpkg-deb --info $GDEB | grep Subarchitecture | awk -F ' ' '{print $2}'`
		if [[ "x$DEBPKGCODENAME" != "x" ]] && [[ "$DEBPKGCODENAME" != "$CODENAME" ]]; then
			echo "Ubuntu CodeName error. $DEBPKGCODENAME != $CODENAME"
			rm $GDEB
			exit -1
		fi
		if [ "x$DEBPATCH" != "x" ]; then
			fix::deb_components $GDEB
		fi
		dpkg -i --force-overwrite $GDEB
		rm $GDEB
	else
		if [ "x$DEBPATCH" != "x" ]; then
			fix::deb_components $LOCALTARGET
		fi
		dpkg -i --force-overwrite $LOCALTARGET
	fi

	#
	echo -n '/usr/geni/lib' > /etc/ld.so.conf.d/${LDCONFNAC}
	util::ldconfig

	if [[ "x$LOCALE" != "x" ]]; then
		sed -Ei "s#system-locale.*#system-locale=${LOCALE}#g" $LOCALCONF > /dev/null 2>&1
	fi
	if [[ "x$TIMEZONE" != "x" ]]; then
		timedatectl set-timezone ${TIMEZONE}
	fi

	#
	echo -n '/usr/geni/lib' > /etc/ld.so.conf.d/${LDCONFNAC}
	util::ldconfig

	[[ ! -d /disk/sys/conf/certs || ! -f /disk/sys/conf/certs/server.crt || ! -f /disk/sys/conf/certs/ssl.cer || ! -f /disk/data/custom/ssl.cer ]] && { rm -rf /disk/sys/conf/certs > /dev/null 2>&1; /etc/init.d/gensslkey; }

	util::enable_systemctl syslog-ng

	if [[ "x$NODATASTORE" != "x1" ]]; then
		ln -s /etc/apparmor.d/usr.sbin.mysqld /etc/apparmor.d/disable/ > /dev/null 2>&1
		apparmor_parser -R /etc/apparmor.d/usr.sbin.mysqld > /dev/null 2>&1
	fi

	#util::stop_systemctl apparmor
	#util::disable_systemctl apparmor

	if [[ "x$KERNELUP" != "xno" ]]; then
		# 커널업그레이드
		# /usr/geni 에서 가장높은 커널버전 모듈을 찾아서 커널버전을 업그레이드

		HOST_KERNELVER=$(uname -r)
		NAC_KERNELVER=$(ls /usr/geni/nac_*${KERNEL_FLAVOR}.ko 2>/dev/null | sort -V | tail -n 1 | awk -F '_' '{print $2}' | sed 's/\.ko$//')

		kvregex="^[0-9]+\.[0-9]+\.[0-9]+"
		if  [[ ! $HOST_KERNELVER =~ $kvregex ]] || [[ ! "$NAC_KERNELVER" =~ $kvregex ]]; then
			echo "Unknown kernel version format."
			echo "  HOST=$HOST_KERNELVER"
			echo "  NAC=$NAC_KERNELVER"
			return
		fi

		if [ "x$HOST_KERNELVER" != "x$NAC_KERNELVER" ]; then
			echo "-------------------"
			echo "Current kernel version: $HOST_KERNELVER"
			echo "NAC supported kernel version: $NAC_KERNELVER"
			echo "It will be install the kernel version."
			echo "-------------------"

			upgrade::kernel $NAC_KERNELVER
		fi
	fi

	if [[ "$UPGRADE" == "1" ]]; then
		return 0
	fi

	if [[ "x$PLATFORM" != "x" ]]; then
		upgrade::platform $PLATFORM
		upgrade::grub $PLATFORM
		upgrade::storage $PLATFORM
	fi

	if [[ "x$FACTORYINSTALL" != "x1" ]] && [[ "x$INIT_SETUP" == "x1" ]]; then
		# 표준 입력이 터미널인지 확인하고 재지정
		if ! [ -t 0 ]; then
			exec 0< /dev/tty || {
				echo "Error: Cannot access terminal for user input"
				exit -1
			}
		fi
		export ETH_INTERFACES=$ETH_INTERFACES
		export ALT_INTERFACES=$ALT_INTERFACES
		export DEF_GATEWAY=$DEF_GATEWAY
		export DEF_DNSSERVER=$DEF_DNSSERVER
		/usr/geni/tools/initial_setup.sh
	fi

	# initial_setup 후에 local.conf 가 초기화 되었으므로 필요한 설정 추가

	# 현재 설치가 양산단계에서 진행되고 있음을 표시한다.
	FACTORYEXISTS=`cat $LOCALCONF | grep install-point`
	if [[ "x$FACTORYEXISTS" == "x" ]]; then
		echo "install-point=factory" >> $LOCALCONF
	fi
	SSHPORTEXISTS=`cat $LOCALCONF | grep ssh_port`
	if [[ "x$SSHPORT" != "x" && "x$SSHPORTEXISTS" == "x" ]]; then
		echo "ssh_port=$SSHPORT" >> $LOCALCONF
	fi
	SSHALLALLOWEXISTS=`cat $LOCALCONF | grep ssh_allallow`
	if [[ "x$SSHALLALLOW" != "x" && "x$SSHALLALLOWEXISTS" == "x" ]]; then
		echo "ssh_allallow=$SSHALLALLOW" >> $LOCALCONF
	fi
}

function clean::pkg()
{
	if [[ "x$INSTALLISO" != "x" ]] || [[ "x$BIN" != "x" ]]; then
		return 0
	fi

	apt -y purge --auto-remove tomcat8 --allow-change-held-packages > /dev/null 2>&1
	util::disable_systemctl tomcat8
	rm -rf /etc/systemd/system/tomcat8.service > /dev/null 2>&1
	util::mask_systemctl tomcat8
	apt -y purge --auto-remove openjdk-11-jre-headless > /dev/null 2>&1
	apt -y purge --auto-remove tomcat9 --allow-change-held-packages > /dev/null 2>&1
	util::disable_systemctl tomcat9
	rm -rf /etc/systemd/system/tomcat9.service > /dev/null 2>&1
	util::mask_systemctl tomcat9
	apt -y purge --auto-remove openjdk-11-jre-headless > /dev/null 2>&1
}

# genian-nac 에서 동작하는 procmond 종료
# shell 을 dash에서 bash로 변경
# genian-nac 에서 사용하던 ldconfig 삭제
function init::env()
{
	# procmon 종료
	util::stop_systemctl procmon.service
	/usr/geni/alder stop > /dev/null 2>&1

	echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections
	echo "dash dash/sh boolean false" | debconf-set-selections
	DEBIAN_FRONTEND=noninteractive dpkg-reconfigure dash

	util::setbash

	# CURL 링크가 아닌 경우에만 삭제
	if [ -f /usr/geni/curl ] && [ ! -h /usr/geni/curl ]; then
		rm -rf /usr/geni/lib/libcurl*
		rm -rf /usr/geni/curl
	fi

	rm -rf /etc/ld.so.conf.d/genian-nac.conf > /dev/null 2>&1
	rm -rf /etc/ld.so.conf.d/aaa-genian-nac.conf > /dev/null 2>&1
	util::ldconfig
}

function hold::package()
{
	# package hold
	if [[ "x$NODATASTORE" == "x1" ]]; then
		apt-mark hold apache2* tomcat8* tomcat9* tomcat10* elasticsearch filebeat > /dev/null 2>&1
	else
		apt-mark hold libpercona* percona-server* apache2* tomcat8* tomcat9* tomcat10* > /dev/null 2>&1
	fi
}

function unhold::package()
{
	# package unhold
	if [[ "x$NODATASTORE" == "x1" ]]; then
		apt-mark unhold apache2* tomcat8* tomcat9* tomcat10* linux-image* linux-headers* elasticsearch filebeat > /dev/null 2>&1
	else
		apt-mark unhold libpercona* percona-server* apache2* tomcat8* tomcat9* tomcat10* linux-image* linux-headers* > /dev/null 2>&1
	fi

	if [[ "x$(apt list --installed 2>/dev/null | grep elasticsearch)" != "x" ]]; then
		apt-mark hold elasticsearch > /dev/null 2>&1
	fi
	if [[ "x$(apt list --installed 2>/dev/null | grep filebeat)" != "x" ]]; then
		apt-mark hold filebeat > /dev/null 2>&1
	fi
}

function init::depends()
{
	sed -Ei '/^Pre-Depends.*(tomcat[0-9]+, elasticsearch, percona-server-server.*)|(dialog, syslog-ng, unzip, zip.*libtinyxml2.6.2v5.*apache2.*)/d' /var/lib/dpkg/status > /dev/null 2>&1
	sed -Ei 's#/usr/geni/alder stop.*#/usr/geni/alder stop >/dev/null || true#g' /var/lib/dpkg/info/genian-nac-ns.prerm > /dev/null 2>&1
	sed -Ei '/.*(remove|rm).*(\\/disk|\\/var\\/geni|\\/usr\\/geni).*/d' /var/lib/dpkg/info/genian-nac-ns.postrm > /dev/null 2>&1
	sed -Ei 's#/usr/geni/alder stop.*#/usr/geni/alder stop >/dev/null || true#g' /var/lib/dpkg/info/genian-nac.prerm > /dev/null 2>&1
	sed -Ei '/.*(remove|rm).*(\\/disk|\\/var\\/geni|\\/usr\\/geni).*/d' /var/lib/dpkg/info/genian-nac.postrm > /dev/null 2>&1
	sed -Ei '/^(rm|cp).*log4j/d' /usr/geni/systemdscript/elasticsearch/elasticsearch-genconf.sh > /dev/null 2>&1

	rm -rf /etc/systemd/system/{smbd*,samba*,nmb*} > /dev/null 2>&1

	[[ -f /etc/samba/smb.conf ]] && { rm -rf /etc/samba/smb.conf; touch /etc/samba/smb.conf; rm -rf /etc/systemd/system/smbd.service; util::mask_systemctl smbd.service; }
	[[ -f /etc/systemd/system/nmbd.service ]] && { rm -rf /etc/systemd/system/nmbd.service; util::mask_systemctl nmbd.service; }
	[[ -f /etc/systemd/system/winbind.service ]] && { rm -rf /etc/systemd/system/winbind.service; util::mask_systemctl winbind.service; }
	[[ -f /etc/systemd/system/mysql.service ]] && { rm -rf /etc/systemd/system/mysql.service; util::mask_systemctl mysql.service; }
	[[ -f /etc/systemd/system/elasticsearch.service ]] && { rm -rf /etc/systemd/system/elasticsearch.service; util::mask_systemctl elasticsearch.service; }
	[[ -f /etc/systemd/system/apache2.service ]] && { rm -rf /etc/systemd/system/apache2.service; util::mask_systemctl apache2.service; }

	util::stop_systemctl smbd winbind samba-ad-dc nmbd nmb samba
	util::mask_systemctl smbd winbind samba-ad-dc nmbd nmb samba

	util::update_apt
	util::fixbroken_apt

	if [[ "x$INSTALLISO" != "x" ]] && [[ "x$BIN" != "x" ]]; then
		# syslog-ng-core 때문에 설치가 실패하는 문제가 있음
		apt remove --purge -y syslog-ng* > /dev/null 2>&1
		rm -rf /etc/syslog-ng
		rm -rf /etc/systemd/system/syslog-ng.service
		util::mask_systemctl syslog-ng.service
	fi

	util::install_packages curl
}

# sources.list 초기화
function init::sourcelist()
{
	if [[ "x$INSTALLISO" != "x" ]] || [[ "x$BIN" != "x" ]]; then
		return 0
	fi
	# genian-nac 에서 사용하던것 삭제
	rm -rf /etc/apt/sources.list.d/genian*
	rm -rf /etc/apt/sources.list.d/elastic-*
	rm -rf /etc/apt/sources.list.d/percona*
	rm -rf /etc/apt/sources.list.d/ubuntu.sources*

	# bionic 에서 시작
	echo -n "" > /etc/apt/sources.list
	echo "deb http://ports.ubuntu.com/ubuntu-ports bionic main restricted" >> /etc/apt/sources.list
	echo "deb http://ports.ubuntu.com/ubuntu-ports bionic universe" >> /etc/apt/sources.list
	echo "deb http://ports.ubuntu.com/ubuntu-ports bionic multiverse" >> /etc/apt/sources.list
	echo "deb http://ports.ubuntu.com/ubuntu-ports bionic-updates main restricted" >> /etc/apt/sources.list
	echo "deb http://ports.ubuntu.com/ubuntu-ports bionic-updates universe" >> /etc/apt/sources.list
	echo "deb http://ports.ubuntu.com/ubuntu-ports bionic-updates multiverse" >> /etc/apt/sources.list
	echo "deb http://ports.ubuntu.com/ubuntu-ports bionic-backports main restricted universe multiverse" >> /etc/apt/sources.list
	echo "deb http://ports.ubuntu.com/ubuntu-ports bionic-security main restricted" >> /etc/apt/sources.list
	echo "deb http://ports.ubuntu.com/ubuntu-ports bionic-security universe" >> /etc/apt/sources.list
	echo "deb http://ports.ubuntu.com/ubuntu-ports bionic-security multiverse" >> /etc/apt/sources.list

	# x86이면 ubuntu-ports(ARM) 에서 ubuntu 로 변경
	if [[ "x$PLATFORM_ARCH" == "xx86_64" ]]; then
		sed -i "s#ubuntu-ports#ubuntu#g" /etc/apt/sources.list
	fi

	# ROOT_MIRROR 예) $REPO_URI 
	if [[ "x$ROOT_MIRROR" != "x" ]]; then
		sed -i "s#ports.ubuntu.com#$ROOT_MIRROR#g" /etc/apt/sources.list
	fi

	# ROOT_MIRROR 와 REPO_MIRROR은 함께 사용할 수 없음

	# REPO_MIRROR 설정은 폐쇄망

	if [[ "x$REPO_MIRROR" == "x" ]] && [[ "x$PLATFORM_ARCH" == "xx86_64" ]]; then
		# ROOT_MIRROR에 의해서 변경되었으면 sed 에 의해서 변경 안되므로 OK
		sed -i "s#ports.ubuntu.com#archive.ubuntu.com#g" /etc/apt/sources.list
	elif [[ "x$PLATFORM_ARCH" == "xx86_64" ]]; then
		sed -i "s#ports.ubuntu.com#$REPO_MIRROR/$REPO_URI#g" /etc/apt/sources.list

		if [[ "$TARGET" == "GPC" ]]; then
			cat << EOF > ${TMP_DIR}/GPG-KEY-elasticsearch
-----BEGIN PGP PUBLIC KEY BLOCK-----

mQENBFI3HsoBCADXDtbNJnxbPqB1vDNtCsqhe49vFYsZN9IOZsZXgp7aHjh6CJBD
A+bGFOwyhbd7at35jQjWAw1O3cfYsKAmFy+Ar3LHCMkV3oZspJACTIgCrwnkic/9
CUliQe324qvObU2QRtP4Fl0zWcfb/S8UYzWXWIFuJqMvE9MaRY1bwUBvzoqavLGZ
j3SF1SPO+TB5QrHkrQHBsmX+Jda6d4Ylt8/t6CvMwgQNlrlzIO9WT+YN6zS+sqHd
1YK/aY5qhoLNhp9G/HxhcSVCkLq8SStj1ZZ1S9juBPoXV1ZWNbxFNGwOh/NYGldD
2kmBf3YgCqeLzHahsAEpvAm8TBa7Q9W21C8vABEBAAG0RUVsYXN0aWNzZWFyY2gg
KEVsYXN0aWNzZWFyY2ggU2lnbmluZyBLZXkpIDxkZXZfb3BzQGVsYXN0aWNzZWFy
Y2gub3JnPokBTgQTAQgAOAIbAwIXgBYhBEYJWsyFSFgsGiaZqdJ9ZmzYjkK0BQJk
9vrZBQsJCAcDBRUKCQgLBRYCAwEAAh4FAAoJENJ9ZmzYjkK00hoH+wYXZKgVb3Wv
4AA/+T1IAf7edwgajr58bEyqds6/4v6uZBneUaqahUqMXgLFRX5dBSrAS7bvE/jx
+BBQx+rpFGxSwvFegRevE1zAGVtpgkFQX0RpRcKSmksucSBxikR/dPn9XdJSEVa8
vPcs11V+2E5tq3LEP14zJL4MkJKQF0VJl5UUmKLS7U2F/IB5aXry9UWdMTnwNntX
kl2iDaViYF4MC6xTS24uLwND2St0Jvjt+xGEwbdBVvp+UZ/kG6IGkYM5eWGPuok/
DHvjUdwTfyO9b5xGbqn5FJ3UFOwB/nOSFXHM8rsHRT/67gHcIl8YFqSQXpIkk9D3
dCY+KieW0ue5AQ0EUjceygEIAOSVJc3DFuf3LsmUfGpUmnCqoUm76Eqqm8xynFEG
ZpczTChkwARRtckcfa/sGv376j+jk0c0Q71Uv3MnMLPGF+w3bpu8fLiPeW/cntf1
8uZ6DxJvHA/oaZZ6VPjwUGSeVydiPtZfTYsceO8Dxl3gpS6nHZ9Gsnfr/kcH9/11
Ca73HBtmGVIkOI1mZKMbANO8cewY/i7fPxShu7B0Rb3jxVNGUuiRcfRiao0gWx0U
ZGpvuHplt7loFX2cbsHFAp9WsjYEbSohb/Y0K4NkyFhL82MfbcsEwsXPhRTFgJWw
s4vpuFg/kFFlnw0NNPVP1jNJLNCsMBMEpP1A7k6MRpylNnUAEQEAAYkBNgQYAQgA
IAIbDBYhBEYJWsyFSFgsGiaZqdJ9ZmzYjkK0BQJk9vsHAAoJENJ9ZmzYjkK0hWsH
/ArKtn12HM3+41zYo9qO4rTri7+IYTjSB/JDTOusZgZLd/HCp1xQo4SI2Eur3Rtx
USMWK1LEeBzsjwDT9yVceYekrBEqUVyRMSVYj+UeZK2s4LbXm9b4jxXVtaivmkMA
jtznndrD7kmm8ak+UsZplf6p6uZS9TZ9hjwoMmw5oMaS6TZkLT4KYGWeyzHJSUBX
YikY6vssDQu4SJ07m1f4Hz81J39QOcHln5I5HTK8Rh/VUFcxNnGg9360g55wWpiF
eUTeMyoXpOtffiUhiOtbRYsmSYC0D4Fd5yJnO3n1pwnVVVsM7RAC22rc5j/Dw8dR
GIHikRcYWeXTYW7veewK5Ss=
=ftS0
-----END PGP PUBLIC KEY BLOCK-----
EOF
			cat ${TMP_DIR}/GPG-KEY-elasticsearch | apt-key add - 2>/dev/null

			cat << EOF > ${TMP_DIR}/percona-keyring.pub
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
EOF
			openssl base64 -d -in ${TMP_DIR}/percona-keyring.pub -out /etc/apt/trusted.gpg.d/percona-keyring.gpg
		fi
	fi

	# LOCAL_MIRROR 는 저장장치에 repository 가 구성되어있음
	if [[ "$LOCAL_MIRROR" == "1" ]]; then
		sed -i -e "s#http:/#[trusted=yes] file:#g" -e "s#https:/#[trusted=yes] file:#g" /etc/apt/sources.list \
			/etc/apt/sources.list.d/elastic-7.x.list /etc/apt/sources.list.d/elastic-6.x.list \
			/etc/apt/sources.list.d/percona-prel-release.list /etc/apt/sources.list.d/percona-ps-80-release.list /etc/apt/sources.list.d/percona-tools-release.list
	fi
}

function clean::apt()
{
	if [[ "x$INSTALLISO" != "x" ]] || [[ "x$BIN" != "x" ]]; then
		return 0
	fi

	apt remove -y libperconaserverclient* percona-release percona-server* --allow-change-held-packages > /dev/null 2>&1
	apt-get clean
}

function update::currentpkg()
{
	if [[ "x$INSTALLISO" != "x" ]] || [[ "x$BIN" != "x" ]]; then
		return 0
	fi
	if [[ "$UPGRADE" != "1" ]]; then
		return 0
	fi

	util::update_apt
	util::fixbroken_apt
	apt -y upgrade ${DPKGCONFOPT} > /dev/null 2>&1
	apt -y dist-upgrade ${DPKGCONFOPT}
}

function upgrade::sourcelist()
{
	local target=$1

	if [[ "x$BIN" != "x" ]]; then
		return 0
	fi

	sed -i "s/bionic/${target}/g" /etc/apt/sources.list > /dev/null 2>&1
	sed -i "s/bionic/${target}/g" /etc/apt/sources.list.d/* > /dev/null 2>&1

	if [[ "x$target" = "xjammy" ]]; then
		sed -i "s/focal/${target}/g" /etc/apt/sources.list > /dev/null 2>&1
		sed -i "s/focal/${target}/g" /etc/apt/sources.list.d/* > /dev/null 2>&1
	fi

	if [[ "x$target" = "xnoble" ]]; then
		sed -i "s/focal/${target}/g" /etc/apt/sources.list > /dev/null 2>&1
		sed -i "s/focal/${target}/g" /etc/apt/sources.list.d/* > /dev/null 2>&1
		sed -i "s/jammy/${target}/g" /etc/apt/sources.list > /dev/null 2>&1
		sed -i "s/jammy/${target}/g" /etc/apt/sources.list.d/* > /dev/null 2>&1
	fi
}

function install::repo()
{
	if [[ "x$BIN" != "x" ]]; then
		return 0
	fi
	if [[ "$TARGET" != "GPC" ]]; then
		return
	fi

	# REPO_MIRROR를 사용하면 폐쇄망
	if [[ "x$REPO_MIRROR" != "x" ]] || [[ "x$PLATFORM_ARCH" != "xx86_64" ]]; then
		if [[ "x$REPO_MIRROR" != "x" ]]; then
			#echo "deb http://$REPO_MIRROR/artifacts.elastic.co/packages/7.x/apt stable main" > /etc/apt/sources.list.d/elastic-7.x.list
			echo "deb http://$REPO_MIRROR/artifacts.elastic.co/packages/6.x/apt stable main" > /etc/apt/sources.list.d/elastic-6.x.list

			if [[ "x$NODATASTORE" != "x1" ]]; then
				echo "deb http://$REPO_MIRROR/repo.percona.com/prel/apt bionic main" > /etc/apt/sources.list.d/percona-prel-release.list
				echo "deb http://$REPO_MIRROR/repo.percona.com/ps-80/apt bionic main" > /etc/apt/sources.list.d/percona-ps-80-release.list
				echo "deb http://$REPO_MIRROR/repo.percona.com/tools/apt bionic main" > /etc/apt/sources.list.d/percona-tools-release.list
			fi

			upgrade::sourcelist $CODENAME

			# LOCAL_MIRROR 는 저장장치에 repository 가 구성되어있음
			if [[ "$LOCAL_MIRROR" == "1" ]]; then
				sed -i -e "s#http:/#[trusted=yes] file:#g" -e "s#https:/#[trusted=yes] file:#g" /etc/apt/sources.list.d/elastic-7.x.list /etc/apt/sources.list.d/elastic-6.x.list \
					/etc/apt/sources.list.d/percona-prel-release.list /etc/apt/sources.list.d/percona-ps-80-release.list /etc/apt/sources.list.d/percona-tools-release.list > /dev/null 2>&1
			fi

			util::update_apt
		fi
		return
	fi

	/usr/bin/curl -# -4 --connect-timeout $CONNECT_TIMEOUT --retry $MAX_RETRIES -SkL https://repo.percona.com/percona/apt/percona-release_latest.$(lsb_release -sc 2>/dev/null)_all.deb -o ${TMP_DIR}/percona-release_latest.$(lsb_release -sc 2>/dev/null)_all.deb
	if [ $? -ne 0 ]; then
		util::error "Failed to download Percona release package after $MAX_RETRIES attempts."
		exit -1
	fi
	dpkg -i --force-overwrite ${TMP_DIR}/percona-release_latest.$(lsb_release -sc 2>/dev/null)_all.deb
	if ! percona-release setup ps80 > /dev/null 2>&1; then
		util::error "percona-release setup failed."
		exit -1
	fi

	wget -4 --connect-timeout=$CONNECT_TIMEOUT --tries=$MAX_RETRIES --no-check-certificate -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch | apt-key add - 2>/dev/null
	#echo "deb https://artifacts.elastic.co/packages/7.x/apt stable main" > /etc/apt/sources.list.d/elastic-7.x.list
	echo "deb https://artifacts.elastic.co/packages/6.x/apt stable main" > /etc/apt/sources.list.d/elastic-6.x.list

	util::update_apt
}

function upgrade::rel()
{
	local target=$1

	if [[ "x$INSTALLISO" != "x" ]] || [[ "x$BIN" != "x" ]]; then
		return 0
	fi

	update::currentpkg

	apt-get install -y ubuntu-release-upgrader-core > /dev/null 2>&1
	apt-get install -y usrmerge > /dev/null 2>&1
	apt-get install -y fakeroot > /dev/null 2>&1
	apt-get install -y libfakeroot > /dev/null 2>&1

	upgrade::sourcelist "${target}"

	apt-get clean > /dev/null 2>&1
	util::update_apt
	util::fixbroken_apt
	apt -y dist-upgrade ${DPKGCONFOPT}

	apt-get install -y ubuntu-release-upgrader-core > /dev/null 2>&1
	apt-get install -y usrmerge > /dev/null 2>&1
	apt-get install -y fakeroot > /dev/null 2>&1
	apt-get install -y libfakeroot > /dev/null 2>&1

	currcode=$(util::getcodename)
	if [[ "x$target" != "x$currcode" ]]; then
		util::error "Could not upgrade UBUNTU Release. $currcode to $target"
		exit -1
	fi
	if [[ "x$currcode" == "xjammy" || "x$currcode" == "xnoble" ]]; then
		apt-get install -y --reinstall libssl3 > /dev/null 2>&1
	fi

	util::ldconfig
	cp -f /etc/lsb-release.dpkg-dist /etc/lsb-release > /dev/null 2>&1
}


function help::usage()
{
  cat << EOF

Upgrade NAC to focal/jammy NAC.
  20.04 -> focal
  22.04 -> jammy
  24.04 -> noble
Usage:
  $(basename "$0") [command]

Available Commands:

Flag:
  -rel (focal or jammy or noble)
  -nodatastore (skip MySQL/Percona installation and mysql service handling)

Example:

  ########## 폐쇄망환경에서 외부저장디스크를 통해서 업그레이드 ##########
  
  mkdir -p /var/spool/apt-mirror && mount /dev/sdxxxxx /var/spool/apt-mirror

  (정책서버)
  $0 upgrade -rel focal -locale ko -timezone Asia/Seoul -localmirror -repomirror var/spool/apt-mirror/mirror -target GPC -deb [http://download]/tmp/NAC-UBUNTU-R-113129-5.0.54.0425.deb
  OR
  $0 install -locale ko -timezone Asia/Seoul -localmirror -repomirror var/spool/apt-mirror/mirror -target GPC -deb [http://download]/tmp/NAC-UBUNTU-R-113129-5.0.54.0425.deb

  (네트워크센서)
  $0 upgrade -rel focal -locale ko -timezone Asia/Seoul -localmirror -repomirror var/spool/apt-mirror/mirror -target GNS -deb [http://download]/tmp/NAC-UBUNTUNS-R-113129-5.0.54.0425.deb
  OR
  $0 install -locale ko -timezone Asia/Seoul -localmirror -repomirror var/spool/apt-mirror/mirror -target GNS -deb [http://download]/tmp/NAC-UBUNTUNS-R-113129-5.0.54.0425.deb

  ########## 인터넷망환경에서 업그레이드 ##########

  (정책서버)
  $0 upgrade -rel focal -locale ko -timezone Asia/Seoul -target GPC -deb [http://download]/tmp/NAC-UBUNTU-R-113129-5.0.54.0425.deb
  OR
  $0 install -locale ko -timezone Asia/Seoul -target GPC -deb [http://download]/tmp/NAC-UBUNTU-R-113129-5.0.54.0425.deb

  (네트워크센서)
  $0 upgrade -rel focal -locale ko -timezone Asia/Seoul -target GNS -deb [http://download]/tmp/NAC-UBUNTUNS-R-113129-5.0.54.0425.deb
  OR
  $0 install -locale ko -timezone Asia/Seoul -target GNS -deb [http://download]/tmp/NAC-UBUNTUNS-R-113129-5.0.54.0425.deb

  curl -sSLk https://bit.ly/4vIe5Fs/`basename $0` | sudo DEBUG=1 INSTALL=1 PROMPT=0 TARGET=GPC LOCALE=ko TIMEZONE=Asia/Seoul \
DEB=https://download.geninetworks.com/tftpboot/NAC/GNOS/v5.0/RELEASE/AAT/NAC-UBUNTU-R-121077-5.0.57.1106.deb bash -
  curl -sSLk https://bit.ly/4vIe5Fs/`basename $0` | sudo DEBUG=1 UPGRADE=1 PROMPT=0 TARGET=GPC LOCALE=ko TIMEZONE=Asia/Seoul REL=focal \
DEB=https://download.geninetworks.com/tftpboot/NAC/GNOS/v5.0/RELEASE/AAT/NAC-UBUNTU-R-121077-5.0.57.1106.deb bash -


  curl -sSLk https://bit.ly/4vIe5Fs/`basename $0` | sudo DEBUG=1 INSTALL=1 PROMPT=0 TARGET=GNS LOCALE=ko TIMEZONE=Asia/Seoul \
DEB=https://download.geninetworks.com/tftpboot/NAC/GNOS/v5.0/RELEASE/AAT/NAC-UBUNTUNS-R-121077-5.0.57.1106.deb bash -
  curl -sSLk https://bit.ly/4vIe5Fs/`basename $0` | sudo DEBUG=1 UPGRADE=1 PROMPT=0 TARGET=GNS LOCALE=ko TIMEZONE=Asia/Seoul REL=focal \
DEB=https://download.geninetworks.com/tftpboot/NAC/GNOS/v5.0/RELEASE/AAT/NAC-UBUNTUNS-R-121077-5.0.57.1106.deb bash -
EOF
  exit -1
}

while [ "${1:-}" != "" ]; do
  case $1 in
    install )       INSTALL=1
                    ;;
    upgrade )       UPGRADE=1
                    INSTALL=0
                    ;;
    -sshport )      shift
                    SSHPORT=${1:-$SSHPORT}
                    ;;
    -sshall )       SSHALLALLOW=1
                    ;;
    -kernelup )     shift
                    KERNELUP=${1:-$KERNELUP}
                    ;;
    -target )       shift
                    TARGET=${1:-$TARGET}
                    ;;
    -locale )       shift
                    LOCALE=${1:-$LOCALE}
                    ;;
    -timezone )     shift
                    TIMEZONE=${1:-$TIMEZONE}
                    ;;
    -platform )     shift
                    PLATFORM=${1:-$PLATFORM}
                    ;;
    -noprompt )     PROMPT=0
                    ;;
    -localmirror )  LOCAL_MIRROR=1
                    ;;
    -repomirror )   shift
                    REPO_MIRROR=${1:-$REPO_MIRROR}
                    ;;
    -repouri )      shift
                    REPO_URI=${1:-$REPO_URI}
                    ;;
    -rootmirror )   shift
                    ROOT_MIRROR=${1:-$ROOT_MIRROR}
                    ;;
    -deb )          shift
                    DEB=${1:-$DEB}
                    ;;
    -rel )          shift
                    REL=${1:-$REL}
                    ;;
    -kernel )       shift
                    KERNEL_UPGRADE=${1:-$KERNEL_UPGRADE}
                    ;;
    -netdrv )       shift
                    NETDRV=${1:-$NETDRV}
                    ;;
    -nodatastore )  NODATASTORE=1
                    ;;
    * )             help::usage
                    exit -1
  esac
  shift
done

if [[ "x$TARGET" == "x" && "$DEB" == *UBUNTUNS* ]]; then
	TARGET=GNS
elif [[ "x$TARGET" == "x" && "$DEB" == *UBUNTU* ]]; then
	TARGET=GPC
fi

CODENAME=$(util::getcodename)
DPKGARCH=`dpkg --print-architecture`

# 공장설치,aws,azure 설치가 아닌 경우에는 sourcelist 를 초기화
if [[ "x$DKBUILD" != "x" || ( "x$FACTORYINSTALL" != "x1" && "x$KERNEL_FLAVOR" != "xaws" && "x$KERNEL_FLAVOR" != "xazure" ) ]]; then
	# sourcelist 를 초기화 한다. bionic 에서 시작
	init::sourcelist
	# 현재 운영체제에 따라서 sourcelist 변경
	if [[ "x$CODENAME" == "xfocal" ]]; then
		upgrade::sourcelist "focal"
	fi
	if [[ "x$CODENAME" == "xjammy" ]]; then
		upgrade::sourcelist "jammy"
	fi
	if [[ "x$CODENAME" == "xnoble" ]]; then
		upgrade::sourcelist "noble"
	fi
fi

apt-get update

util::info "TARGET=$TARGET"
util::info "PLATFROM=$PLATFORM"
util::info "FACTORYINSTALL=$FACTORYINSTALL"
util::info "INSTALL=$INSTALL"
util::info "UPGRADE=$UPGRADE"
util::info "LOCALE=$LOCALE"
util::info "TIMEZONE=$TIMEZONE"
util::info "REL=$REL"
util::info "DEB=$DEB"
util::info "INSTALLISO=$INSTALLISO"
util::info "BIN=$BIN"

if [[ "x$FACTORYINSTALL" != "x1" ]]; then
	# check dpkg lock
	PKGLOCK=`lsof /var/lib/dpkg/lock 2>/dev/null`
	if [[ "x$PKGLOCK" != "x" ]]; then
		util::error "Could not get lock /var/lib/dpkg/lock"
		exit -1
	fi
fi

if [[ "x$INSTALLISO" != "x" ]]; then
	unset LD_LIBRARY_PATH
fi

util::update_apt
util::reconfigure_dpkg
util::fixbroken_apt
util::update_apt
#apt -y upgrade
util::install_packages sudo wget gnupg2 lsof net-tools lsb-release

if [[ "x$KERNEL_UPGRADE" != "x" ]]; then
	upgrade::kernel "${KERNEL_UPGRADE}"
	exit 0
fi

printf "Genians $TARGET. $CODENAME(REL=$REL) $DEB\n"
if [[ "x$TARGET" != "xGPC" ]] && [[ "x$TARGET" != "xGNS" ]]; then
	echo
	echo "-target options:"
	echo "GPC     POLICY CENTER SERVER"
	echo "GNS     NETWORK SENSOR"
	echo
	exit -1
fi

if [[ "$PROMPT" == "1" ]]; then
	printf "Genians NAC Upgrade. Continue (y/n)?"
	read answer < /dev/tty
	if [[ "x$answer" != "xy" ]]; then
		exit -1
	fi
elif [[ "$INSTALL" != "1" ]]; then
	UPGRADE=1
fi

init::env
init::depends
unhold::package
clean::pkg
clean::apt

update::currentpkg

# 업그레이드 (bionic -> focal)
if [[ "x$CODENAME" == "xbionic" && "$UPGRADE" == "1" && "x$REL" != "xbionic" ]]; then
	upgrade::rel "focal"
fi
CODENAME=$(util::getcodename)
# 업그레이드 (focal -> jammy)
if [[ "x$CODENAME" == "xfocal" && "$UPGRADE" == "1" && "x$REL" != "xfocal" ]]; then
	upgrade::rel "jammy"
fi
CODENAME=$(util::getcodename)
# 업그레이드 (jammy -> noble)
if [[ "x$CODENAME" == "xjammy" && "$UPGRADE" == "1" && "x$REL" != "xjammy" ]]; then
	upgrade::rel "noble"
fi
CODENAME=$(util::getcodename)

if [[ "$UPGRADE" == "1" && "x$REL" != "x$CODENAME" ]]; then
	echo
	echo "ERROR: OS Upgrade from $CODENAME to $REL fails."
	echo
	exit -1
fi

if [[ "x$DEB" == "xv5" || "x$DEB" == "xnac" || "x$DEB" == "xnac5" ]]; then
	DEB=https://d1s536j2uzv1h7.cloudfront.net/images/NAC/GNOS/v5.0/RELEASE
	if [ "x$TARGET" = "xGPC" ]; then
		DEB=$DEB/NAC-UBUNTU-R-current.${CODENAME}_${DPKGARCH}.deb
	else
		DEB=$DEB/NAC-UBUNTUNS-R-current.${CODENAME}_${DPKGARCH}.deb
	fi
elif [[ "x$DEB" == "xv6" || "x$DEB" == "xztna" || "x$DEB" == "xnac6" ]]; then
	DEB=https://d1s536j2uzv1h7.cloudfront.net/images/NAC/GNOS/v6.0/RELEASE
	if [ "x$TARGET" = "xGPC" ]; then
		DEB=$DEB/NAC-UBUNTU-R-current.${CODENAME}_${DPKGARCH}.deb
	else
		DEB=$DEB/NAC-UBUNTUNS-R-current.${CODENAME}_${DPKGARCH}.deb
	fi
elif [[ "x$DEB" != "x" && "$DEB" != http* && "$DEB" != */* && ! -f "$DEB" ]]; then
	NV=$(echo "$DEB" | grep -oP '\d+\.\d+\.\d+')
	if [[ "$NV" == 6* ]]; then
		DEB=https://d1s536j2uzv1h7.cloudfront.net/images/NAC/GNOS/v6.0/RELEASE/$NV/$DEB.${CODENAME}_${DPKGARCH}.deb
	else
		DEB=https://d1s536j2uzv1h7.cloudfront.net/images/NAC/GNOS/v5.0/RELEASE/$NV/$DEB.${CODENAME}_${DPKGARCH}.deb
	fi
fi

util::info "Install NAC Package: $DEB"

[[ "x$CODENAME" == "xbionic" ]] && LDCONFNAC="genian-nac.conf"

# 업그레이드 후에 percona, elastic repo 등록
install::repo

if [[ "$UPGRADE" == "1" || "$INSTALL" == "1" ]]; then
	if [[ "x$DEB" != "x" ]]; then
		# 로컬에 파일이 존재하거나 다운로드 가능한지 확인
		LOCALTARGET=$DEB
		if [[ $LOCALTARGET == http* ]]; then
			DOWNLOADTARGET=$LOCALTARGET
			LOCALTARGET=
		fi
		printf "	DEB $LOCALTARGET $DOWNLOADTARGET\n"
		if [[ "x$DOWNLOADTARGET" != "x" ]]; then
			if ( /usr/bin/curl -o/dev/null -sfI --connect-timeout $CONNECT_TIMEOUT --retry $MAX_RETRIES "$DOWNLOADTARGET" ); then
				GDEB=$(/usr/bin/curl -# --connect-timeout $CONNECT_TIMEOUT --retry $MAX_RETRIES -w "%{filename_effective}" -SkLO ${DOWNLOADTARGET})
				if [ $? -ne 0 ]; then
					util::error "Failed to download NAC package from ${DOWNLOADTARGET} after $MAX_RETRIES attempts."
					rm $GDEB
					exit -1
				fi
				DEBPKGCODENAME=`dpkg-deb --info $GDEB | grep Subarchitecture | awk -F ' ' '{print $2}'`
				if [[ "x$DEBPKGCODENAME" != "x" ]] && [[ "$DEBPKGCODENAME" != "$CODENAME" ]]; then
					util::error "Ubuntu CodeName. $DEBPKGCODENAME != $CODENAME"
					rm $GDEB
					exit -1
				fi

				DEBPKGTARGET=`dpkg-deb --info $GDEB | grep Package | awk -F ' ' '{print $2}'`
				[[ "x$DEBPKGTARGET" != "xgenian-nac-ns" ]] && [[ "x$DEBPKGTARGET" != "xgenian-nac" ]] && util::error "Cannot be installed because the package is unknown." && rm $GDEB && exit -1
				[[ "x$DEBPKGTARGET" == "xgenian-nac-ns" ]] && [[ "x$TARGET" == "xGPC" ]] && util::error "$TARGET cannot be installed because the package is a network sensor." && rm $GDEB && exit -1
				[[ "x$DEBPKGTARGET" == "xgenian-nac" ]] && [[ "x$TARGET" == "xGNS" ]] && util::error "$TARGET cannot be installed because the package is a policy center." && rm $GDEB && exit -1
			else
				util::error "NAC package not found at ${DOWNLOADTARGET} after $MAX_RETRIES attempts."
				echo "$DOWNLOADTARGET not exist"
				exit -1
			fi
		else
			if [[ -f "$LOCALTARGET" ]]; then
				DEBPKGCODENAME=`dpkg-deb --info $LOCALTARGET | grep Subarchitecture | awk -F ' ' '{print $2}'`
				if [[ "x$DEBPKGCODENAME" != "x" ]] && [[ "$DEBPKGCODENAME" != "$CODENAME" ]]; then
					util::error "Ubuntu CodeName error. $DEBPKGCODENAME != $CODENAME"
					exit -1
				fi

				DEBPKGTARGET=`dpkg-deb --info $LOCALTARGET | grep Package | awk -F ' ' '{print $2}'`
				[[ "x$DEBPKGTARGET" != "xgenian-nac-ns" ]] && [[ "x$DEBPKGTARGET" != "xgenian-nac" ]] && util::error "Cannot be installed because the package is unknown." && exit -1
				[[ "x$DEBPKGTARGET" == "xgenian-nac-ns" ]] && [[ "x$TARGET" == "xGPC" ]] && util::error "$TARGET cannot be installed because the package is a network sensor." && exit -1
				[[ "x$DEBPKGTARGET" == "xgenian-nac" ]] && [[ "x$TARGET" == "xGNS" ]] && util::error "$TARGET cannot be installed because the package is a policy center." && exit -1
			else
				echo "$LOCALTARGET not exist"
				exit -1
			fi
		fi
	fi

	util::info "Start installing Genians $TARGET"

	util::setbash

	util::update_apt

	install::basepkg

	install::nacpkg

	upgrade::config

	hold::package

	if [[ "x$DEB" != "x" ]]; then
		upgrade::nac
	fi

	util::setbash

	rm -rf /etc/netplan/*
	rm -rf /etc/NetworkManager/NetworkManager.conf
	util::disable_systemctl NetworkManager
	util::disable_systemctl ModemManager
 
 	systemctl stop percona-telemetry-agent.service > /dev/null 2>&1
  	systemctl disable percona-telemetry-agent.service > /dev/null 2>&1
   	systemctl mask percona-telemetry-agent.service > /dev/null 2>&1

	if [[ "x$INSTALLISO" != "x" ]]; then
		apt remove -y landscape-common > /dev/null 2>&1
	fi

	update-initramfs -u -k all > /dev/null 2>&1

	apt remove -y landscape-common > /dev/null 2>&1
 	
  	rm -rf /etc/apt/apt.conf.d/99insecure

	if [[ "x$BIN" = "x1" ]]; then
		PROMPT=0 /etc/init.d/upgrade_kernel.sh
	fi

	chown root:root /usr/geni -R > /dev/null 2>&1
	chown root:root /usr/raddb -R > /dev/null 2>&1
	chown root:root /usr/db2 -R > /dev/null 2>&1
	chown root:root /usr/nodejs -R > /dev/null 2>&1
	chown root:root /usr/tomcat -R > /dev/null 2>&1
	chown root:root /usr/httpd -R > /dev/null 2>&1
	chown root:root /.version > /dev/null 2>&1
	chown root:root /.build_date > /dev/null 2>&1

	if [[ "x$FACTORYINSTALL" != "x1" ]]; then
		sync
		if [[ "$PROMPT" == "1" ]]; then
			printf "Genians $TARGET installed. now reboot (y/n)?"
			read answer < /dev/tty
			if [[ "x$answer" = "xy" ]]; then
				reboot -f
			fi
		elif [[ "x$FROMANSIBLE" == "x" ]]; then
			echo ""
			echo ""
			printf "[*] Genians $TARGET installed. now reboot......"
			sleep 5
			reboot -f
		fi
	fi
fi

exit 0
