#!/bin/bash

cd $(readlink -f $(dirname ${BASH_SOURCE[0]}))

set -e

ACTION_ADD=add
ACTION_REMOVE=remove

if [ ! -e "config.ini" ]; then
	echo "config.ini not found." >&2
	exit 1
fi

. config.ini

if [ -z "$1" ]; then
	echo "$0 add/remove HOSTNAME" >&2
	exit 1
fi

action="${1,,}"

if [ "$action" != "$ACTION_ADD" ] && [ "$action" != "$ACTION_REMOVE" ]; then
	echo "$0 add/remove HOSTNAME" >&2
	exit 1
fi

WG_createPrivateKey(){
	wg genkey
}

WG_getPublicKey(){
	echo "$1" | wg pubkey
}

WG_getPeers(){
	grep "^$SUBNET_ADDR" /etc/hosts | sed "s/\s\+/ /g"
}

WG_getNextIP(){
	for i in $(seq 2 1 254); do
		if ! grep "^$SUBNET_ADDR$i" /etc/hosts > /dev/null; then
			echo -n "$SUBNET_ADDR$i"
			return 0
		fi
	done
	return 1
}

WG_addPeer(){
	local host_name="$1"
	local pub_key="$2"
	if [ -z "$3" ]; then
		local ip=$(WG_getNextIP)
	else
		local ip="$3"
	fi
	if [ $? -eq 0 ]; then
		wg set $SUBNET_NAME peer "$pub_key" allowed-ips $ip/32 1>&2
		echo "$ip	$host_name" >> /etc/hosts
	else
		echo "$SUBNET_NAME ($SUBNET_ADDR.0/$SUBNET_MASK) is out of IPs." >&2
		return 1
	fi
}

WG_removePeer(){
	peer_ip_or_hostname="$1"
	peer_ip=$(WG_getPeers | grep "$peer_ip_or_hostname" | cut -f "1" -d " " | tail -n 1)
	if [ -z "$peer_ip" ]; then
		echo "$target cannot be found." >&2
		exit 1
	fi
	peer_public_key=$(wg show $SUBNET_NAME | grep -B1 "$peer_ip" | grep "peer:" | cut -f 2 -d " ")	
	if [ -z "$peer_public_key" ]; then
		echo "$target public key cannot be found." >&2
		exit 1
	fi
	wg set $SUBNET_NAME peer "$peer_public_key" remove
	echo "Peer $peer_ip_or_hostname ($peer_ip $peer_public_key) has been removed."
}

WG_getHostPublicKey(){
	wg show $SUBNET_NAME public-key
}

WG_getHostListenPort(){
	wg show $SUBNET_NAME listen-port
}

target="$2"

if [ "$action" = "$ACTION_ADD" ]; then
	peer_private_key=$(WG_createPrivateKey)
	peer_public_key=$(WG_getPublicKey "$peer_private_key")
	peer_ip=$(WG_getNextIP)
	WG_addPeer "$target" "$peer_public_key" "$peer_ip"
	host_public_key=$(WG_getHostPublicKey)
	host_listen_port=$(WG_getHostListenPort)

	cat <<EOF
cat <<${SUBNET_NAME^^} | sudo tee /etc/wireguard/$SUBNET_NAME.conf

[Interface]
Address = $peer_ip/$SUBNET_MASK
PrivateKey = $peer_private_key

[Peer]
PublicKey = $host_public_key
AllowedIPs = ${SUBNET_ADDR}0/$SUBNET_MASK
Endpoint = $SUBNET_PUBLIC_IP:$host_listen_port
PersistentKeepalive = 60
${SUBNET_NAME^^}

sudo systemctl enable wg-quick@$SUBNET_NAME
sudo systemctl start wg-quick@$SUBNET_NAME
EOF

elif [ "$action" = "$ACTION_REMOVE" ]; then
	WG_removePeer "$target"
fi
