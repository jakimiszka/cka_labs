#!/bin/sh

clear() {
  ip netns list | awk '{print $1}' | while read -r n; do
    [ -n "$n" ] || continue
    echo "deleting ns: $n"
    sudo ip netns delete "$n"
  done

  sudo ip link del br-lab 2>/dev/null || true
}

create_bridge(){
        echo "creating host bridge ..."
        sudo ip link add br-lab type bridge
        sudo ip addr add 10.200.1.1/24 dev br-lab
        sudo ip link set br-lab up
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

        if ip netns list | grep -q .; then
                echo "clearing existing namespaces..."
                clear
        fi

        #host bridge
        create_bridge

        local i=1

        for n in "$@"; do
                #for ip addr

                echo "creating namespace $n ..."
                echo "increment i = $i"

                sudo ip netns add $n
                sudo ip netns exec $n hostname $n

                sudo ip link add veth-br$i type veth peer name veth-$n
                sudo ip link set veth-$n netns $n
                sudo ip link set veth-br$i master br-lab
                sudo ip link set veth-br$i up

                sudo ip netns exec $n ip link set lo up
                sudo ip netns exec $n ip addr add 10.200.1.1$i/24 dev veth-$n
                sudo ip netns exec $n ip link set veth-$n up
                sudo ip netns exec $n ip route add default via 10.200.1.1

                py_test "$n"

                i=$((i + 1))
        done
}

run() {
  local fn="$1"
  shift || true

  case "$fn" in
    create|clear)
      "$fn" "$@"
      ;;
    *)
      echo "Usage: $0 {create|clear} [args...]"
      exit 1
      ;;
  esac
}

run "$@"