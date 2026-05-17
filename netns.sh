#!/bin/sh

# netns.sh - network namespace lab helper
#
# Flow:
# - Default create behavior clears existing lab first.
# - Add mode (--add) skips clearing and appends another bridge/subnet + namespaces.
# - You can pass both --bridge-name and --bridge-cidr on each create call.
# - clear removes all bridges tracked by this script, even when multiple bridge names were added.
#
# Example usage:
#   ./netns.sh create --bridge-name br-a --bridge-cidr 10.200.1.1/24 ns1 ns2
#   ./netns.sh create --add --bridge-name br-b --bridge-cidr 10.200.2.1/24 ns3 ns4
#
# Internet/NAT setup for current bridge context:
#   ./netns.sh ns_int_access
#
# DNS setup for one namespace:
#   ./netns.sh ns_dns_config ns1
#
# Cleanup:
#   ./netns.sh clear

BRIDGE_NAME="br-lab"
BRIDGE_CIDR="10.200.1.1/24"
BRIDGE_IP="${BRIDGE_CIDR%/*}"
BRIDGE_MASK="${BRIDGE_CIDR#*/}"
NS_SUBNET_PREFIX="${BRIDGE_IP%.*}"
NS_HOST_START=11
BRIDGE_SUBNET="${NS_SUBNET_PREFIX}.0/${BRIDGE_MASK}"
STATE_FILE="/tmp/netns_bridges.state"

set_bridge_network() {
  BRIDGE_CIDR="$1"
  BRIDGE_IP="${BRIDGE_CIDR%/*}"
  BRIDGE_MASK="${BRIDGE_CIDR#*/}"
  NS_SUBNET_PREFIX="${BRIDGE_IP%.*}"
  BRIDGE_SUBNET="${NS_SUBNET_PREFIX}.0/${BRIDGE_MASK}"
}

clear() {
  ip netns list | awk '{print $1}' | while read -r n; do
    [ -n "$n" ] || continue
    echo "deleting ns: $n"
    sudo ip netns delete "$n"
  done

  if [ -f "$STATE_FILE" ]; then
    while read -r b; do
      [ -n "$b" ] || continue
      sudo ip link del "$b" 2>/dev/null || true
    done < "$STATE_FILE"
    rm -f "$STATE_FILE"
  else
    sudo ip link del "$BRIDGE_NAME" 2>/dev/null || true
  fi
}

create_bridge(){
        echo "creating host bridge ..."
        sudo ip link add "$BRIDGE_NAME" type bridge
        sudo ip addr add "$BRIDGE_CIDR" dev "$BRIDGE_NAME"
        sudo ip link set "$BRIDGE_NAME" up
  grep -qx "$BRIDGE_NAME" "$STATE_FILE" 2>/dev/null || echo "$BRIDGE_NAME" >> "$STATE_FILE"
}

py_test() {
        local ns="$1"

        echo "py scritp test in $ns..."

        sudo ip netns exec "$ns" bash -c "mkdir -p /tmp/$ns && echo hello-from-$ns > /tmp/$ns/index.html"
        sudo ip netns exec "$ns" bash -c "cd /tmp/$ns && nohup python3 -m http.server 8080 >/tmp/$ns/http.log 2>&1 &"

        ip_addr=$(sudo ip -n "$ns" -4 -o addr show dev "veth-$ns" | awk '{print $4}')
        echo "py script $ns - $ip_addr listening on port 8080 ..."
}

create(){
  add_mode="$1"
  if [ "$add_mode" != "add" ]; then
    if ip netns list | grep -q .; then
      echo "clearing existing namespaces..."
      clear
    fi
  else
    shift
  fi

        #host bridge
        create_bridge

        local i=1

        for n in "$@"; do
                #for ip addr
          ns_ip="${NS_SUBNET_PREFIX}.$((NS_HOST_START + i - 1))/${BRIDGE_MASK}"
    host_veth="vbr-$n"

                echo "creating namespace $n ..."
                echo "increment i = $i"

                sudo ip netns add $n
                sudo ip netns exec $n hostname $n

                sudo ip link add "$host_veth" type veth peer name veth-$n
                sudo ip link set veth-$n netns $n
                sudo ip link set "$host_veth" master "$BRIDGE_NAME"
                sudo ip link set "$host_veth" up

                sudo ip netns exec $n ip link set lo up
                sudo ip netns exec $n ip addr add "$ns_ip" dev veth-$n
                sudo ip netns exec $n ip link set veth-$n up
                sudo ip netns exec $n ip route add default via "$BRIDGE_IP"

                py_test "$n"

                i=$((i + 1))
        done
}

ns_int_access(){
    UPLINK=$(ip route | awk '/default/ {print $5; exit}')
    echo "$UPLINK"
    sudo sysctl -w net.ipv4.ip_forward=1
    sudo iptables -A FORWARD -i "$BRIDGE_NAME" -o "$UPLINK" -j ACCEPT
    sudo iptables -A FORWARD -i "$UPLINK" -o "$BRIDGE_NAME" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    sudo iptables -t nat -A POSTROUTING -s "$BRIDGE_SUBNET" -o "$UPLINK" -j MASQUERADE
}

ns_dns_config() {
    local ns="$1"
    sudo ip netns exec "$ns" bash -c "echo 'nameserver 8.8.8.8' > /etc/resolv.conf"
}

run() {
  local fn="$1"
  shift || true

  case "$fn" in
    create)
      add_mode=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --add)
            add_mode="add"
            shift
            ;;
          --bridge-cidr)
            [ -n "$2" ] || {
              echo "missing value for --bridge-cidr"
              exit 1
            }
            set_bridge_network "$2"
            shift 2
            ;;
          --bridge-name)
            [ -n "$2" ] || {
              echo "missing value for --bridge-name"
              exit 1
            }
            BRIDGE_NAME="$2"
            shift 2
            ;;
          --)
            shift
            break
            ;;
          -*)
            echo "unknown option: $1"
            exit 1
            ;;
          *)
            break
            ;;
        esac
      done
      if [ -n "$add_mode" ]; then
        "$fn" "$add_mode" "$@"
      else
        "$fn" "$@"
      fi
      ;;
    clear|ns_int_access|ns_dns_config)
      "$fn" "$@"
      ;;
    *)
      echo "Usage: $0 create [--add] [--bridge-name NAME] [--bridge-cidr X.X.X.X/YY] ns1 ns2 ..."
      echo "       $0 {clear|ns_int_access|ns_dns_config} [args...]"
      exit 1
      ;;
  esac
}

run "$@"