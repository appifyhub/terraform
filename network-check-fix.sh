#!/bin/bash
# network-check-fix.sh - Check and fix network connectivity issues
# This script verifies and fixes common networking issues that could cause nodes to become unreachable

LOG_DIR="/var/log/network-fixes"
mkdir -p $LOG_DIR

TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
LOG_FILE="$LOG_DIR/network-fix-$TIMESTAMP.log"

echo "=== Network Check and Fix: $TIMESTAMP ===" > $LOG_FILE

check_and_fix_conntrack() {
  echo "=== Checking conntrack table ===" | tee -a $LOG_FILE
  
  # Get current conntrack count and limit
  CURR_CONNTRACK=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)
  MAX_CONNTRACK=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)
  
  echo "Current conntrack entries: $CURR_CONNTRACK" | tee -a $LOG_FILE
  echo "Maximum conntrack entries: $MAX_CONNTRACK" | tee -a $LOG_FILE
  
  # If conntrack usage is over 80%, increase the limit
  if [ -n "$CURR_CONNTRACK" ] && [ -n "$MAX_CONNTRACK" ]; then
    USAGE_PCT=$((CURR_CONNTRACK * 100 / MAX_CONNTRACK))
    echo "Conntrack usage: ${USAGE_PCT}%" | tee -a $LOG_FILE
    
    if [ $USAGE_PCT -gt 80 ]; then
      echo "Conntrack usage is high, increasing limit" | tee -a $LOG_FILE
      NEW_MAX=$((MAX_CONNTRACK * 2))
      echo $NEW_MAX > /proc/sys/net/netfilter/nf_conntrack_max
      echo "New conntrack max: $NEW_MAX" | tee -a $LOG_FILE
      
      # Make it persistent
      echo "net.netfilter.nf_conntrack_max=$NEW_MAX" > /etc/sysctl.d/99-conntrack.conf
      sysctl -p /etc/sysctl.d/99-conntrack.conf
    fi
  else
    echo "Conntrack module not loaded, skipping" | tee -a $LOG_FILE
  fi
}

check_and_fix_cilium() {
  echo "=== Checking Cilium status ===" | tee -a $LOG_FILE
  
  # Check if cilium pods are running
  CILIUM_STATUS=$(cilium status 2>&1)
  echo "$CILIUM_STATUS" >> $LOG_FILE
  
  if echo "$CILIUM_STATUS" | grep -q "cilium-operator.*KO"; then
    echo "Cilium operator is down, restarting..." | tee -a $LOG_FILE
    # Find the cilium operator pod and delete it to trigger a restart
    if command -v kubectl &> /dev/null; then
      kubectl -n kube-system get pods | grep cilium-operator | awk '{print $1}' | xargs kubectl -n kube-system delete pod
      echo "Cilium operator pod deleted, waiting for restart" | tee -a $LOG_FILE
    else
      echo "kubectl not found, cannot restart cilium operator" | tee -a $LOG_FILE
    fi
  fi
  
  if echo "$CILIUM_STATUS" | grep -q "cilium.*KO"; then
    echo "Cilium agent is down, restarting..." | tee -a $LOG_FILE
    systemctl restart cilium || true
    echo "Cilium restart triggered" | tee -a $LOG_FILE
  fi
}

check_and_fix_network_interfaces() {
  echo "=== Checking network interfaces ===" | tee -a $LOG_FILE
  
  # Check if the network interface is up
  INTERFACE=$(ip -o -4 route show to default | awk '{print $5}')
  
  if [ -z "$INTERFACE" ]; then
    echo "No default route found" | tee -a $LOG_FILE
    
    # Try to find the main interface
    POSSIBLE_INTERFACE=$(ip -o -4 addr | grep -v "127.0.0.1" | head -1 | awk '{print $2}')
    
    if [ -n "$POSSIBLE_INTERFACE" ]; then
      echo "Found possible interface: $POSSIBLE_INTERFACE" | tee -a $LOG_FILE
      echo "Trying to restart networking" | tee -a $LOG_FILE
      systemctl restart systemd-networkd
      sleep 5
      
      # Check if that fixed it
      NEW_INTERFACE=$(ip -o -4 route show to default | awk '{print $5}')
      if [ -n "$NEW_INTERFACE" ]; then
        echo "Default route is now established via $NEW_INTERFACE" | tee -a $LOG_FILE
      else
        echo "Still no default route after restart" | tee -a $LOG_FILE
      fi
    fi
  else
    echo "Default route is via $INTERFACE" | tee -a $LOG_FILE
    
    # Check packet loss to the gateway
    GATEWAY=$(ip -o -4 route show to default | awk '{print $3}')
    echo "Default gateway is $GATEWAY" | tee -a $LOG_FILE
    
    ping -c 4 $GATEWAY >> $LOG_FILE 2>&1
    if [ $? -ne 0 ]; then
      echo "Cannot ping gateway, restarting networking" | tee -a $LOG_FILE
      systemctl restart systemd-networkd
      sleep 5
    fi
  fi
}

check_ssh_service() {
  echo "=== Checking SSH service ===" | tee -a $LOG_FILE
  
  # Check if ssh service is running (Ubuntu 24.04 uses 'ssh' not 'sshd')
  systemctl status ssh >> $LOG_FILE 2>&1
  if [ $? -ne 0 ]; then
    echo "SSH service is not running properly, restarting" | tee -a $LOG_FILE
    systemctl restart ssh
    systemctl status ssh >> $LOG_FILE 2>&1
  else
    echo "SSH service is running" | tee -a $LOG_FILE
  fi
  
  # Check if port 22 is listening
  if ! ss -tuln | grep -q ":22"; then
    echo "Port 22 is not listening, checking firewall" | tee -a $LOG_FILE
    ufw status | grep 22 >> $LOG_FILE
    
    # Make sure SSH port is allowed
    ufw allow 22/tcp
    echo "Ensured SSH port is allowed through firewall" | tee -a $LOG_FILE
    
    # Restart SSH again
    systemctl restart ssh
  fi
}

# Run all the checks
check_and_fix_conntrack
check_and_fix_cilium
check_and_fix_network_interfaces
check_ssh_service

echo "=== Network check and fix completed ===" | tee -a $LOG_FILE
echo "Log saved to $LOG_FILE"

# Create a cron job to run this script every hour
if [ ! -f /etc/cron.d/network-check-fix ]; then
  echo "Installing hourly cron job" | tee -a $LOG_FILE
  echo "0 * * * * root /usr/local/bin/network-check-fix.sh" > /etc/cron.d/network-check-fix
  chmod 644 /etc/cron.d/network-check-fix
fi
