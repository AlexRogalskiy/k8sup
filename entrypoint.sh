#!/bin/bash
set -e

function etcd_creator(){
  local IPADDR="$1"
  local ETCD_NAME="$2"
  local CLIENT_PORT="$3"
  local NEW_CLUSTER="$4"
  local RESTORE_ETCD="$5"
  local PEER_PORT="2380"

  if [[ "${RESTORE_ETCD}" == "true" ]]; then
    local RESTORE_CMD="--force-new-cluster=true"
  elif [[ "${NEW_CLUSTER}" == "true" ]]; then
    rm -rf "/var/lib/etcd/"*
  fi

  docker run \
    -d \
    -v /usr/share/ca-certificates/:/etc/ssl/certs \
    -v /var/lib/etcd:/var/lib/etcd \
    --net=host \
    --restart=always \
    --name=k8sup-etcd \
    "${ENV_ETCD_IMAGE}" \
    /usr/local/bin/etcd \
      ${RESTORE_CMD} \
      --name "${ETCD_NAME}" \
      --advertise-client-urls http://${IPADDR}:${CLIENT_PORT},http://${IPADDR}:4001 \
      --listen-client-urls http://0.0.0.0:${CLIENT_PORT},http://0.0.0.0:4001 \
      --initial-advertise-peer-urls http://${IPADDR}:${PEER_PORT}  \
      --listen-peer-urls http://0.0.0.0:${PEER_PORT} \
      --initial-cluster "${ETCD_NAME}=http://${IPADDR}:${PEER_PORT}" \
      --initial-cluster-state new \
      --data-dir /var/lib/etcd
}

function etcd_follower(){
  local IPADDR="$1"
  local ETCD_NAME="$2"
  local ETCD_MEMBER="$(echo "$3" | cut -d ':' -f 1)"
  local CLIENT_PORT="$(echo "$3" | cut -d ':' -f 2)"
  local PROXY="$4"
  local PEER_PORT="2380"
  local ETCD2_MAX_MEMBER_SIZE="3"

  docker pull "${ENV_ETCD_IMAGE}" 1>&2

  # Check if this node has joined etcd this cluster
  local MEMBERS="$(curl -sf --retry 10 http://${ETCD_MEMBER}:${CLIENT_PORT}/v2/members)"
  if [[ -z "${MEMBERS}" ]]; then
    echo "Can not connect to the etcd member, exiting..." 1>&2
    sh -c 'docker rm -f k8sup-etcd' >/dev/null 2>&1 || true
    exit 1
  fi
  if [[ "${MEMBERS}" == *"${IPADDR}:${CLIENT_PORT}"* ]]; then
    local ALREADY_MEMBER="true"
    PROXY="off"
  else
    local ALREADY_MEMBER="false"
    rm -rf "/var/lib/etcd/"*
  fi

  if [[ "${ALREADY_MEMBER}" != "true" ]]; then
    # Check if cluster is full
    local ETCD_EXISTED_MEMBER_SIZE="$(echo "${MEMBERS}" | jq '.[] | length')"
    if [[ "${PROXY}" == "off" ]] \
     && [[ "${ETCD_EXISTED_MEMBER_SIZE}" -ge "${ETCD2_MAX_MEMBER_SIZE}" ]]; then
      # If cluster is not full, proxy mode off. If cluster is full, proxy mode on
      PROXY="on"
    fi

    # If cluster is not full, Use locker (etcd atomic CAS) to get a privilege for joining etcd cluster
    local LOCKER_ETCD_KEY="locker-etcd-member-add"
    until [[ "${PROXY}" == "on" ]] || curl -sf \
      "http://${ETCD_MEMBER}:${CLIENT_PORT}/v2/keys/${LOCKER_ETCD_KEY}?prevExist=false" \
      -XPUT -d value="${IPADDR}" 1>&2; do
        echo "Another node is joining etcd cluster, Waiting for it done..." 1>&2
        sleep 1

        # Check if cluster is full
        local ETCD_EXISTED_MEMBER_SIZE="$(curl -sf --retry 10 \
          http://${ETCD_MEMBER}:${CLIENT_PORT}/v2/members | jq '.[] | length')"
        if [ "${ETCD_EXISTED_MEMBER_SIZE}" -ge "${ETCD2_MAX_MEMBER_SIZE}" ]; then
          # If cluster is not full, proxy mode off. If cluster is full, proxy mode on
          PROXY="on"
        fi
    done
    if [[ "${PROXY}" == "off" ]]; then
      # Run etcd member add
      curl -s "http://${ETCD_MEMBER}:${CLIENT_PORT}/v2/members" -XPOST \
        -H "Content-Type: application/json" -d "{\"peerURLs\":[\"http://${IPADDR}:${PEER_PORT}\"]}" 1>&2
    fi
  fi

  # Update Endpoints to etcd2 parameters
  MEMBERS="$(curl -sf http://${ETCD_MEMBER}:${CLIENT_PORT}/v2/members)"
  local SIZE="$(echo "${MEMBERS}" | jq '.[] | length')"
  local PEER_IDX=0
  local ENDPOINTS="${ETCD_NAME}=http://${IPADDR}:${PEER_PORT}"
  for PEER_IDX in $(seq 0 "$((${SIZE}-1))"); do
    local PEER_NAME="$(echo "${MEMBERS}" | jq -r ".members["${PEER_IDX}"].name")"
    local PEER_URL="$(echo "${MEMBERS}" | jq -r ".members["${PEER_IDX}"].peerURLs[]" | head -n 1)"
    if [ -n "${PEER_URL}" ] && [ "${PEER_URL}" != "http://${IPADDR}:${PEER_PORT}" ]; then
      ENDPOINTS="${ENDPOINTS},${PEER_NAME}=${PEER_URL}"
    fi
  done

  docker run \
    -d \
    -v /usr/share/ca-certificates/:/etc/ssl/certs \
    -v /var/lib/etcd:/var/lib/etcd \
    --net=host \
    --restart=always \
    --name=k8sup-etcd \
    "${ENV_ETCD_IMAGE}" \
    /usr/local/bin/etcd \
      --name "${ETCD_NAME}" \
      --advertise-client-urls http://${IPADDR}:${CLIENT_PORT},http://${IPADDR}:4001 \
      --listen-client-urls http://0.0.0.0:${CLIENT_PORT},http://0.0.0.0:4001 \
      --initial-advertise-peer-urls http://${IPADDR}:${PEER_PORT} \
      --listen-peer-urls http://0.0.0.0:${PEER_PORT} \
      --initial-cluster-token etcd-cluster-1 \
      --initial-cluster "${ENDPOINTS}" \
      --initial-cluster-state existing \
      --data-dir /var/lib/etcd \
      --proxy "${PROXY}"


  if [[ "${ALREADY_MEMBER}" != "true" ]] && [[ "${PROXY}" == "off" ]]; then
    # Unlock and release the privilege for joining etcd cluster
    until curl -sf "http://${ETCD_MEMBER}:${CLIENT_PORT}/v2/keys/${LOCKER_ETCD_KEY}?prevValue=${IPADDR}" -XDELETE 1>&2; do
        sleep 1
    done
  fi
}

function flanneld(){
  local IPADDR="$1"
  local ETCD_CID="$2"
  local ETCD_CLIENT_PORT="$3"
  local ROLE="$4"

  if [[ "${ROLE}" == "creator" ]]; then
    echo "Setting flannel parameters to etcd"
    local MIN_KERNEL_VER="3.9"
    local KERNEL_VER="$(uname -r)"

    if [[ "$(echo -e "${MIN_KERNEL_VER}\n${KERNEL_VER}" | sort -V | head -n 1)" == "${MIN_KERNEL_VER}" ]]; then
      local KENNEL_VER_MEETS="true"
    fi

    if [[ "${KENNEL_VER_MEETS}" == "true" ]] && \
     [[ "$(modinfo vxlan &>/dev/null; echo $?)" -eq "0" ]] && \
     [[ -n "$(ip link add type vxlan help 2>&1 | grep vxlan)" ]]; then
      local FLANNDL_CONF="$(cat /go/flannel-conf/network-vxlan.json)"
    else
      local FLANNDL_CONF="$(cat /go/flannel-conf/network.json)"
    fi
    docker exec -d \
      "${ETCD_CID}" \
      /usr/local/bin/etcdctl \
      --endpoints http://127.0.0.1:${ETCD_CLIENT_PORT} \
      set /coreos.com/network/config "${FLANNDL_CONF}"
  fi

  docker run \
    -d \
    --name k8sup-flannel \
    --net=host \
    --privileged \
    --restart=always \
    -v /dev/net:/dev/net \
    -v /run/flannel:/run/flannel \
    "${ENV_FLANNELD_IMAGE}" \
    /opt/bin/flanneld \
      --etcd-endpoints="http://${IPADDR}:${ETCD_CLIENT_PORT}" \
      --iface="${IPADDR}"
}

# Convert CIDR to submask format. e.g. 23 => 255.255.254.0
function cidr2mask(){
   # Number of args to shift, 255..255, first non-255 byte, zeroes
   set -- $(( 5 - ($1 / 8) )) 255 255 255 255 $(( (255 << (8 - ($1 % 8))) & 255 )) 0 0 0
   [ $1 -gt 1 ] && shift $1 || shift
   echo ${1-0}.${2-0}.${3-0}.${4-0}
}

# Convert IP address from decimal to heximal. e.g. 192.168.1.200 => 0xC0A801C8
function addr2hex(){
  local IPADDR="$1"
  echo "0x$(printf '%02X' ${IPADDR//./ } ; echo)"
}

# Convert IP/Mask to SubnetID/Mask. e.g. 192.168.1.200/24 => 192.168.0.0/23
function get_subnet_id_and_mask(){
  local ADDR_AND_MASK="$1"
  local IPMASK_PATTERN="[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\/[0-9]\{1,2\}"
  echo "${ADDR_AND_MASK}" | grep -o "${IPMASK_PATTERN}" &>/dev/null || { echo "Wrong Address/Mask pattern, exiting..." 1>&2; exit 1; }

  local ADDR="$(echo "${ADDR_AND_MASK}" | cut -d '/' -f 1)"
  local MASK="$(echo "${ADDR_AND_MASK}" | cut -d '/' -f 2)"

  local HEX_ADDR=$(addr2hex "${ADDR}")
  local HEX_MASK=$(addr2hex $(cidr2mask "${MASK}"))
  local HEX_NETWORK=$(printf '%02X' $((${HEX_ADDR} & ${HEX_MASK})))

  local NETWORK=$(printf '%d.' 0x${HEX_NETWORK:0:2} 0x${HEX_NETWORK:2:2} 0x${HEX_NETWORK:4:2} 0x${HEX_NETWORK:6:2})
  SUBNET_ID="${NETWORK:0:-1}"
  echo "${SUBNET_ID}/${MASK}"
}

function get_ipaddr_and_mask_from_netinfo(){
  local NETINFO="$1"
  local IPMASK_PATTERN="[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\/[0-9]\{1,2\}"
  local IP_AND_MASK=""

  if [[ -z "${NETINFO}" ]]; then
    echo "Getting network info error, exiting..." 1>&2
    exit 1
  fi

  # If NETINFO is NIC name
  IP_AND_MASK="$(ip addr show "${NETINFO}" 2>/dev/null | grep -o "${IPMASK_PATTERN}" 2>/dev/null | head -n 1)"
  if [[ -n "${IP_AND_MASK}" ]] ; then
    echo "${IP_AND_MASK}"
    return 0
  fi

  # If NETINFO is IP_AND_MASK
  IP_AND_MASK="$(ip addr | grep -o "${NETINFO}\/[0-9]\{1,2\}" 2>/dev/null)"
  if [[ -n "${IP_AND_MASK}" ]] ; then
    echo "${IP_AND_MASK}"
    return 0
  fi

  # If NETINFO is SubnetID/MASK
  echo "${NETINFO}" | grep -o "${IPMASK_PATTERN}" &>/dev/null || { echo "Wrong NETINFO, exiting..." 1>&2 && exit 1; }
  local HOST_NET_LIST="$(ip addr show | grep -o "${IPMASK_PATTERN}")"
  local HOST_NET=""
  for NET in ${HOST_NET_LIST}; do
    HOST_NET="$(get_subnet_id_and_mask "${NET}")"
    if [[ "${NETINFO}" == "${HOST_NET}" ]]; then
      IP_AND_MASK="${NET}"
      break
    fi
  done

  if [[ -z "${IP_AND_MASK}" ]]; then
    echo "No such host IP address, exiting..." 1>&2
    exit 1
  fi

  echo "${IP_AND_MASK}"
}

function show_usage(){
  local USAGE="Usage: ${0##*/} [options...]
Options:
-n, --network=NETINFO        SubnetID/Mask or Host IP address or NIC name
                             e. g. \"192.168.11.0/24\" or \"192.168.11.1\"
                             or \"eth0\" (Required option)
-c, --cluster=CLUSTER_ID     Join a specified cluster
-v, --version=VERSION        Specify k8s version (Default: 1.3.6)
    --new                    Force to start a new cluster
    --restore                Try to restore etcd data and start a new cluster
-p, --proxy                  Force to run as etcd and k8s proxy
-h, --help                   This help text
"

  echo "${USAGE}"
}

function get_options(){
  local PROGNAME="${0##*/}"
  local SHORTOPTS="n:c:v:ph"
  local LONGOPTS="network:,cluster:,version:,new,proxy,restore,help"
  local PARSED_OPTIONS=""

  PARSED_OPTIONS="$(getopt -o "${SHORTOPTS}" --long "${LONGOPTS}" -n "${PROGNAME}" -- "$@")" || exit 1
  eval set -- "${PARSED_OPTIONS}"

  # extract options and their arguments into variables.
  while true ; do
      case "$1" in
          -n|--network)
              export EX_NETWORK="$2"
              shift 2
              ;;
          -c|--cluster)
              export EX_CLUSTER_ID="$2"
              shift 2
              ;;
          -v|--version)
              export EX_K8S_VERSION="$2"
              shift 2
              ;;
             --new)
              export EX_NEW_CLUSTER="true"
              shift
              ;;
             --restore)
              export EX_RESTORE_ETCD="true"
              shift
              ;;
          -p|--proxy)
              export EX_PROXY="on"
              shift
              ;;
          -h|--help)
              show_usage
              exit 0
              shift
              ;;
          --)
              shift
              break
              ;;
          *)
              echo "Option error!" 1>&2
              echo $1
              exit 1
              ;;
      esac
  done


  if [[ -z "${EX_NETWORK}" ]]; then
    echo "--network (-n) is required, exiting..." 1>&2
    exit 1
  fi

  if [[ -n "${EX_CLUSTER_ID}" ]] && [[ "${EX_NEW_CLUSTER}" == "true" ]]; then
    echo "Error! Either join a existed etcd cluster or start a new etcd cluster, exiting..." 1>&2
    exit 1
  fi
  if [[ "${EX_PROXY}" == "on" ]] && [[ "${EX_NEW_CLUSTER}" == "true" ]]; then
    echo "Error! Either run as proxy or start a new etcd cluster, exiting..." 1>&2
    exit 1
  fi

  if [[ "${EX_PROXY}" != "on" ]]; then
    export EX_PROXY="off"
  fi

  if [[ "${EX_RESTORE_ETCD}" == "true" ]]; then
    export EX_NEW_CLUSTER="true"
  fi

  if [[ -z "${EX_K8S_VERSION}" ]]; then
    export EX_K8S_VERSION="1.3.6"
  fi
}

function main(){

  export ENV_ETCD_VERSION="3.0.4"
  export ENV_FLANNELD_VERSION="0.5.5"
#  export ENV_K8S_VERSION="1.3.6"
  export ENV_ETCD_IMAGE="quay.io/coreos/etcd:v${ENV_ETCD_VERSION}"
  export ENV_FLANNELD_IMAGE="quay.io/coreos/flannel:${ENV_FLANNELD_VERSION}"
#  export ENV_HYPERKUBE_IMAGE="gcr.io/google_containers/hyperkube-amd64:v${ENV_K8S_VERSION}"

  get_options "$@"
  local IP_AND_MASK=""
  IP_AND_MASK="$(get_ipaddr_and_mask_from_netinfo "${EX_NETWORK}")" || exit 1
  local IPADDR="$(echo "${IP_AND_MASK}" | cut -d '/' -f 1)"
  local CLUSTER_ID="${EX_CLUSTER_ID}"
  local NEW_CLUSTER="${EX_NEW_CLUSTER}"
  local RESTORE_ETCD="${EX_RESTORE_ETCD}"
  local PROXY="${EX_PROXY}"
  local K8S_VERSION="${EX_K8S_VERSION}"
  local K8S_PORT="8080"
  local SUBNET_ID_AND_MASK="$(get_subnet_id_and_mask "${IP_AND_MASK}")"

  if [[ "${NEW_CLUSTER}" != "true" ]]; then
    # If do not force to start an etcd cluster, make a discovery.
    echo "Discovering etcd cluster..."
    local DISCOVERY_RESULTS="$(go run /go/dnssd/browsing.go | grep -w "NetworkID=${SUBNET_ID_AND_MASK}")"
    echo "${DISCOVERY_RESULTS}"

    # If find an etcd cluster that user specified or find only one etcd cluster, join it instead of starting a new.
    local EXISTED_ETCD_MEMBER=""
    if [[ -n "${CLUSTER_ID}" ]]; then
      EXISTED_ETCD_MEMBER="$(echo "${DISCOVERY_RESULTS}" | grep -w "clusterID=${CLUSTER_ID}" | head -n 1 | awk '{print $2}')"
      if [[ -z "${EXISTED_ETCD_MEMBER}" ]]; then
        echo "No such the etcd cluster that user specified, exiting..." 1>&2
        exit 1
      fi
    elif [[ "$(echo "${DISCOVERY_RESULTS}" | sed -n "s/.*clusterID=\([[:alnum:]]*\).*/\1/p" | uniq | wc -l)" -eq "1" ]]; then
      EXISTED_ETCD_MEMBER="$(echo "${DISCOVERY_RESULTS}" | head -n 1 | awk '{print $2}')"
    fi
    echo "etcd member: ${EXISTED_ETCD_MEMBER}"
  fi

  local ETCD_CLIENT_PORT=""
  if [[ -z "${EXISTED_ETCD_MEMBER}" ]]; then
    ETCD_CLIENT_PORT="2379"
  else
    ETCD_CLIENT_PORT="$(echo "${EXISTED_ETCD_MEMBER}" | cut -d ':' -f 2)"
  fi

  if [[ -z "${EXISTED_ETCD_MEMBER}" ]] && [[ "${PROXY}" == "on" ]]; then
    echo "Proxy mode needs a cluster to join, exiting..." 1>&2
    exit 1
  fi

  local ROLE=""
  if [[ -z "${EXISTED_ETCD_MEMBER}" ]] || [[ "${NEW_CLUSTER}" == "true" ]]; then
    ROLE="creator"
  else
    ROLE="follower"
  fi

  # Write configure to file
  local CONFIG_FILE="/etc/k8sup"
  echo "IPADDR=${IPADDR}" > "${CONFIG_FILE}"
  echo "ETCD_CLIENT_PORT=${ETCD_CLIENT_PORT}" >> "${CONFIG_FILE}"
  echo "K8S_VERSION=${K8S_VERSION}" >> "${CONFIG_FILE}"
  echo "K8S_PORT=${K8S_PORT}" >> "${CONFIG_FILE}"

  echo "Copy cni plugins"
  cp -rf bin /opt/cni
  mkdir -p /etc/cni/net.d/
  cp -f /go/cni-conf/10-containernet.conf /etc/cni/net.d/
  cp -f /go/cni-conf/99-loopback.conf /etc/cni/net.d/
  mkdir -p /var/lib/cni/networks/containernet; echo "" > /var/lib/cni/networks/containernet/last_reserved_ip

  sh -c 'docker stop k8sup-etcd' >/dev/null 2>&1 || true
  sh -c 'docker rm k8sup-etcd' >/dev/null 2>&1 || true
  sh -c 'docker stop k8sup-flannel' >/dev/null 2>&1 || true
  sh -c 'docker rm k8sup-flannel' >/dev/null 2>&1 || true
  sh -c 'docker stop k8sup-kubelet' >/dev/null 2>&1 || true
  sh -c 'docker rm k8sup-kubelet' >/dev/null 2>&1 || true
  sh -c 'ip link delete cni0' >/dev/null 2>&1 || true

  local NODE_NAME="node-$(uuidgen -r | cut -c1-6)"

  echo "Running etcd"
  local ETCD_CID=""
  if [[ "${ROLE}" == "creator" ]]; then
    ETCD_CID=$(etcd_creator "${IPADDR}" "${NODE_NAME}" "${ETCD_CLIENT_PORT}" "${NEW_CLUSTER}" "${RESTORE_ETCD}") || exit 1
  else
    ETCD_CID=$(etcd_follower "${IPADDR}" "${NODE_NAME}" "${EXISTED_ETCD_MEMBER}" "${PROXY}") || exit 1
  fi

  until curl -s 127.0.0.1:${ETCD_CLIENT_PORT}/v2/keys 1>/dev/null 2>&1; do
    echo "Waiting for etcd ready..."
    sleep 1
  done
  echo "Running flanneld"
  flanneld "${IPADDR}" "${ETCD_CID}" "${ETCD_CLIENT_PORT}" "${ROLE}"

  # echo "Running Kubernetes"
  local APISERVER="$(echo "${EXISTED_ETCD_MEMBER}" | cut -d ':' -f 1):${K8S_PORT}"
  if [[ "${PROXY}" == "on" ]]; then
    /go/kube-up --ip="${IPADDR}" --version="${K8S_VERSION}" --worker --apiserver="${APISERVER}"
  else
    /go/kube-up --ip="${IPADDR}" --version="${K8S_VERSION}"
  fi


  local CLUSTER_ID="$(curl 127.0.0.1:${ETCD_CLIENT_PORT}/v2/members -vv 2>&1 | grep 'X-Etcd-Cluster-Id' | sed -n "s/.*: \(.*\)$/\1/p" | tr -d '\r')"
  echo -e "etcd CLUSTER_ID: \033[1;31m${CLUSTER_ID}\033[0m"
  go run /go/dnssd/registering.go "${NODE_NAME}" "${IP_AND_MASK}" "${ETCD_CLIENT_PORT}" "${CLUSTER_ID}"

  echo "hold..." 1>&2
  tail -f /dev/null
}

main "$@"
