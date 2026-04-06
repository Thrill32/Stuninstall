#!/usr/bin/env bash

#install stunnel4, openvpn, and easyrsa

get_pm () {
    for mgr in apt dnf yum pacman zypper apk; do
        if command -v "$mgr" >/dev/null 2>&1; then
            echo "$mgr Selected"
            PM="$mgr"
            return
        fi
    done
    echo "Unsupported Package Manager"
    exit 1
    
}

get_stunnel_bin () {
    if command -v stunnel4 >/dev/null 2>&1; then
        echo "stunnel4"
        return 0
    fi

    if command -v stunnel >/dev/null 2>&1; then
        echo "stunnel"
        return 0
    fi

    return 1
}

install_deps () {
    get_pm || return 1

    case "$PM" in
        apt)
            apt-get update
            apt-get install -y stunnel4 openvpn easy-rsa
            ;;
        dnf)
            dnf install -y stunnel openvpn easy-rsa
            ;;
        yum)
            yum install -y stunnel openvpn easy-rsa
            ;;
        zypper)
            zypper install -y stunnel openvpn easy-rsa
            ;;
        pacman)
            pacman -Sy --noconfirm stunnel openvpn easy-rsa
            ;;
        apk)
            apk add --no-cache stunnel openvpn easy-rsa
            ;;
        *)
            echo "Failed to install dependencies"
            exit 1
            ;;
    esac

    if [ -d /usr/share/easy-rsa ]; then
        EASYRSA_SRC="/usr/share/easy-rsa"
    elif [ -d /usr/share/easy-rsa3 ]; then
        EASYRSA_SRC="/usr/share/easy-rsa3"
    else
        echo "easy-rsa install directory not found"
        exit 1
    fi

    cp -r "$EASYRSA_SRC"/. /etc/stun/easy-rsa/

}

case "$1" in
    install)
        mkdir -p /etc/stun/easy-rsa
        cd /etc/stun/easy-rsa || exit

        install_deps
        echo "Dependencies installed"

        export EASYRSA_BATCH=1
        export EASYRSA_REQ_CN="server"

        ./easyrsa init-pki
        ./easyrsa build-ca nopass
        ./easyrsa gen-req server nopass
        ./easyrsa sign-req server server
        ./easyrsa gen-dh

        openvpn --genkey secret /etc/stun/ta.key

        cp pki/ca.crt /etc/stun
        cp pki/issued/server.crt /etc/stun
        cp pki/private/server.key /etc/stun
        cp pki/dh.pem /etc/stun

        cd /etc/stun || exit

        cat <<EOF > server.conf
port 1194
proto tcp
dev tun

local 127.0.0.1
ca /etc/stun/ca.crt
cert /etc/stun/server.crt
key /etc/stun/server.key
dh /etc/stun/dh.pem

tls-crypt /etc/stun/ta.key
topology subnet
server 10.8.0.0 255.255.255.0

ifconfig-pool-persist ipp.txt

keepalive 10 120
cipher AES-256-GCM
user nobody
group nogroup
persist-key
persist-tun

status openvpn-status.log
verb 3

push "redirect-gateway def1 bypass-dhcp"
EOF
        
        
        echo "Enter dns servers separated by slashes '/')"
        read -r RDNS
        IFS='/' read -r -a arr <<< "$RDNS"

        for _d in "${arr[@]}"; do
            echo "push \"dhcp-option DNS ${_d}\"" >> server.conf
        done

        #Stunnel -------------------------------------------------------------------------------

        echo "Enter TCP port (443 is HTTPS)"
        read -r PORT





        #cat server.crt server.key ca.crt > stunnel.pem
        openssl req -new -x509 -days 36500 -nodes -out stunnel.pem -keyout stunnel.pem

        chmod 600 stunnel.pem




        cat <<EOF > stunconfig.conf
pid = /etc/stun/stunnel.pid
cert = /etc/stun/stunnel.pem
client = no
setuid = stunnel4
setgid = stunnel4
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1
foreground = no

[openvpn]
accept = $PORT
connect = 127.0.0.1:1194
EOF
        echo "Enter Server Public IP"
        read -r SERVER_IP

        cat <<EOF > stunclientconfig.conf
client = yes

[openvpn]
accept = 127.0.0.1:1194
connect = $SERVER_IP:$PORT
EOF

        mkdir /etc/stun/clients

        ;;
    start)
        STUNNEL_BIN="$(get_stunnel_bin)" || {
            echo "stunnel binary not found"
            exit 1
        }
        openvpn --daemon --config /etc/stun/server.conf
        "$STUNNEL_BIN" /etc/stun/stunconfig.conf
        ;;
    stop)
        pkill -x openvpn 2>/dev/null
        pkill -x stunnel 2>/dev/null
        pkill -x stunnel4 2>/dev/null
        ;;
    addclient) 
        cd /etc/stun || exit
        mkdir -p /etc/stun/clients

        echo "Enter client name:"
        read -r NAME

        if [ -z "$NAME" ]; then
            echo "Client name cannot be empty"
            exit 1
        fi

        BASE_NAME="$NAME"
        NUM=2

        while [ -f "/etc/stun/clients/${NAME}.ovpn" ] || [ -f "/etc/stun/easy-rsa/pki/issued/${NAME}.crt" ] || [ -f "/etc/stun/easy-rsa/pki/private/${NAME}.key" ]; do
            echo "Client name taken.. appending $NUM"
            NAME="${BASE_NAME}${NUM}"
            NUM=$((NUM + 1))
        done

        cd /etc/stun/easy-rsa || exit
        export EASYRSA_BATCH=1
        ./easyrsa build-client-full "$NAME" nopass || {
            echo "Failed to generate client certificate and key"
            exit 1
        }
        cd /etc/stun || exit

        DEFAULT_PORT="$(awk -F '=' '/^[[:space:]]*accept[[:space:]]*=/ {gsub(/[[:space:]]/, "", $2); if ($2 ~ /^[0-9]+$/) {print $2; exit}}' /etc/stun/stunconfig.conf 2>/dev/null)"
        DEFAULT_PORT="${DEFAULT_PORT:-1194}"

        echo "Enter Server Public IP"
        read -r SERVER_IP
        echo "Enter remote port (default: $DEFAULT_PORT)"
        read -r REMOTE_PORT
        REMOTE_PORT="${REMOTE_PORT:-$DEFAULT_PORT}"

        cat <<EOF > "clients/${NAME}.ovpn"
client
proto tcp
dev tun

remote $SERVER_IP $REMOTE_PORT
cipher AES-256-GCM
persist-key
persist-tun

key-direction 1
auth SHA256

remote-cert-tls server

nobind
resolv-retry infinite

verb 3

<ca>
$(cat /etc/stun/ca.crt)
</ca>
<cert>
$(awk '/-----BEGIN CERTIFICATE-----/{print_flag=1} print_flag {print} /-----END CERTIFICATE-----/{print_flag=0}' "/etc/stun/easy-rsa/pki/issued/${NAME}.crt")
</cert>
<key>
$(cat "/etc/stun/easy-rsa/pki/private/${NAME}.key")
</key>
<tls-crypt>
$(cat /etc/stun/ta.key)
</tls-crypt>
EOF

        echo "Client profile created: /etc/stun/clients/${NAME}.ovpn"
        
        ;;
    delclient)
        cd /etc/stun || exit

        ;;
    help|"")
        echo "Usage: "
        ;;
    *)
        echo "Unknown command: $1 Aborting..."
        exit 1
        ;;
esac 
