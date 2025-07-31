#!/bin/bash

echo "
     ____        _      __  _______
    / __ \__  __(_)____/ /_/_  __(_)___  _____
   / / / / / / / / ___/ //_// / / / __ \/ ___/
  / /_/ / /_/ / / /__/ ,<  / / / / / / / /__
  \___\_\__,_/_/\___/_/|_|/_/ /_/_/ /_/\___/
                                            "
echo -ne "      Tinc MESH Automated Setup Script\n\n"
echo -ne "-----------------------------------------------\n\n"

read -p "Specify network name: " NETNAME
echo "Setting up Tinc VPN network: $NETNAME"
echo "Gathering local host information..."
read -p "Local host name: " local_name
read -p "Local SSH IP address: " local_ssh_ip
read -p "Local Tinc IP address [CIDR notation]: " local_tinc_ip
read -p "How many remote hosts will join this network? " n
declare -A hosts_ip
declare -A tinc_ip
hosts_ip[$local_name]=$local_ssh_ip
tinc_ip[$local_name]=$local_tinc_ip
for ((i=1; i<=n; i++)); do
  read -p "Remote host $i name: " name
  read -p "Remote SSH IP for $name: " ip
  read -p "Remote Tinc IP [CIDR notation] for $name: " tip
  hosts_ip[$name]=$ip
  tinc_ip[$name]=$tip
done
echo "Installing Tinc and SSH client locally..."
apt-get update -qq && apt-get install -y -qq tinc openssh-client
if [ ! -f ~/.ssh/id_rsa.pub ]; then
  echo "Generating SSH key..."
  ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa > /dev/null 2>&1
fi
mkdir -p /etc/tinc/$NETNAME/hosts
# generate all hosts files locally (without keys for now)
for name in "${!hosts_ip[@]}"; do
  cat > /etc/tinc/$NETNAME/hosts/$name <<EOF
Name = $name
Address = ${hosts_ip[$name]}
Subnet = ${tinc_ip[$name]}
EOF
done
# local tinc.conf
cat > /etc/tinc/$NETNAME/tinc.conf <<EOF
Name = $local_name
Interface = tinc0
EOF
# local tinc-up & tinc-down
cat > /etc/tinc/$NETNAME/tinc-up <<EOF
#!/bin/sh
ifconfig \$INTERFACE ${tinc_ip[$local_name]} netmask 255.255.255.0
EOF
cat > /etc/tinc/$NETNAME/tinc-down <<EOF
#!/bin/sh
ifconfig \$INTERFACE down
EOF
chmod +x /etc/tinc/$NETNAME/tinc-up /etc/tinc/$NETNAME/tinc-down
# generate key if not exists for local host
if [ ! -f /etc/tinc/$NETNAME/rsa_key.priv ]; then
  echo "Generating Tinc key pair for local host..."
  tincd -n $NETNAME -K4096 <<< "yes" > /dev/null 2>&1
fi
# setup remote nodes
for name in "${!hosts_ip[@]}"; do
  if [ "$name" == "$local_name" ]; then
    continue
  fi
  echo "Copying SSH key to ${hosts_ip[$name]}..."
  ssh-copy-id -o StrictHostKeyChecking=no root@${hosts_ip[$name]} > /dev/null 2>&1
  echo "Setting up $name remotely..."
  ssh root@${hosts_ip[$name]} "apt-get update -qq && apt-get install -y -qq tinc"
  ssh root@${hosts_ip[$name]} "mkdir -p /etc/tinc/$NETNAME/hosts"
  # copy all hosts/* to remote (initial files without keys)
  scp /etc/tinc/$NETNAME/hosts/* root@${hosts_ip[$name]}:/etc/tinc/$NETNAME/hosts/
  # tinc.conf
  cat > /tmp/tinc.conf <<EOF
Name = $name
Interface = tinc0
ConnectTo = $local_name
EOF
  scp /tmp/tinc.conf root@${hosts_ip[$name]}:/etc/tinc/$NETNAME/tinc.conf
  rm /tmp/tinc.conf
  # tinc-up & tinc-down
  cat > /tmp/tinc-up <<EOF
#!/bin/sh
ifconfig \$INTERFACE ${tinc_ip[$name]} netmask 255.255.255.0
EOF
  cat > /tmp/tinc-down <<EOF
#!/bin/sh
ifconfig \$INTERFACE down
EOF
  scp /tmp/tinc-up /tmp/tinc-down root@${hosts_ip[$name]}:/etc/tinc/$NETNAME/
  ssh root@${hosts_ip[$name]} "chmod +x /etc/tinc/$NETNAME/tinc-up /etc/tinc/$NETNAME/tinc-down"
  rm /tmp/tinc-up /tmp/tinc-down

  # generate keys on remte host
  echo "Generating Tinc keys on remote host $name..."
  ssh root@${hosts_ip[$name]} "tincd -n $NETNAME -K4096 <<< yes"

  # copy back the updatde host file with the public key from remote to local
  echo "Copying public key from $name back to local host..."
  scp root@${hosts_ip[$name]}:/etc/tinc/$NETNAME/hosts/$name /etc/tinc/$NETNAME/hosts/

  ssh root@${hosts_ip[$name]} "systemctl enable tinc@$NETNAME && systemctl restart tinc@$NETNAME"
done

# redistribute the updated host files to all remote nodes
echo "Redistributing updated host files with all public keys..."
for name in "${!hosts_ip[@]}"; do
  if [ "$name" == "$local_name" ]; then
    continue
  fi
  echo "Updating host files on $name..."
  scp /etc/tinc/$NETNAME/hosts/* root@${hosts_ip[$name]}:/etc/tinc/$NETNAME/hosts/
  ssh root@${hosts_ip[$name]} "systemctl restart tinc@$NETNAME"
done

# Start local tinc service
systemctl enable tinc@$NETNAME
systemctl restart tinc@$NETNAME
echo "Local Tinc VPN started."

echo "Tinc VPN setup complete for network: $NETNAME"