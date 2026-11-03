#!/bin/bash
# LEGACY: superseded by setup.sh. Kept for reference only.
# Non-Angie/Nginx/PHP-FPM configuration now lives in this repository under
# configs/; Angie/PHP configuration lives in server-configs-nginx.
#sudo ./basic_setup.sh -h ubuntu22.com -t Asia/Manila

set -e

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root."
    exit 1
fi

# Default values for options
hostname_set=false
timezone_set=false

while [[ $# -gt 0 ]]; do
    key="$1"

    case $key in
        -h|--hostname)
            hostname_set=true
            hostname_value="$2"
            shift # past argument
            shift # past value
            ;;
        -t|--timezone)
            timezone_set=true
            timezone_value="$2"
            shift # past argument
            shift # past value
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Check if hostname is set
if ! $hostname_set; then
    echo "Hostname is required. Use -h or --hostname to set it."
    exit 1
fi

# Check if timezone is set
if ! $timezone_set; then
    echo "Timezone is required. Use -t or --timezone to set it."
    exit 1
fi

# Disable UFW
ufw disable

# Configure DNS servers
mkdir -p /etc/systemd/resolved.conf.d/
rm -f /etc/systemd/resolved.conf.d/*
wget -O /etc/systemd/resolved.conf.d/dns_servers.conf https://raw.githubusercontent.com/droplinxuser/ubuntu-setup-script/main/configs/system/dns_servers.conf
systemctl restart systemd-resolved
resolvectl status

# Update Ubuntu
apt update -y
apt upgrade -y
apt autoremove --purge -y
apt autoclean -y
apt clean -y

# Install and configure cpufrequtils for dedicated servers
if [ -d /sys/firmware/efi/efivars ]; then
    apt remove tuned -y
    apt install cpufrequtils -y --no-install-recommends
    cpufreq-info
    cpufreq-set -g performance
    echo 'GOVERNOR="performance"' | tee /etc/default/cpufrequtils
fi

# Set Hostname
hostnamectl set-hostname "$hostname_value"
hostnamectl status

# Install basic tools
apt -y install wget unzip nano zip software-properties-common rsync --no-install-recommends

# Set Timezone and Date
timedatectl set-timezone "$timezone_value"

# Create Swap
if [ ! -f /swapfile ]; then
    ram_size=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    if [ $ram_size -lt 33554432 ]; then # RAM < 32 GB
        swap_size=$((2*ram_size))
    else
        swap_size=$ram_size
    fi

    fallocate -l ${swap_size}K /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile

    cp /etc/fstab /etc/fstab.bak
    echo '/swapfile swap swap defaults 0 0' | tee -a /etc/fstab
fi

# SysCTL Tweaks
modprobe tcp_bbr
modprobe tls
wget -O /etc/sysctl.conf https://raw.githubusercontent.com/droplinxuser/ubuntu-setup-script/main/configs/system/sysctl.conf
sysctl -e -p /etc/sysctl.conf

# Increase Limits
wget -O /etc/security/limits.conf https://raw.githubusercontent.com/droplinxuser/ubuntu-setup-script/main/configs/system/limits.conf
cat /etc/security/limits.conf

# All done!
echo "✅ Ubuntu Basic Install Completed ✅"
