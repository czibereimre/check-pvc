#!/bin/bash

RANCHER_URL='https://rancher.valami.hu'

help()
{
    echo -e "Usage: $0 \n"\
         "[ -h | --help  ]\n"\
         "[ -C | --cluster ]\n"\
         "[ -n | --namespace ]\n"\
         "[ -p | --pvc ]\n"\
         "[ -w | --warning ]\n"\
         "[ -c | --critical ]\n"\
         "[ -t | --token ]\n"\
	 "\n"\
	 "Verzio: v0.1"
    exit 3
}

SHORT=C:,n:,p:,w:,c:,t:,h
LONG=cluster:,namespace:,pvc:,warning:,critical:,token:,help
OPTS=$(getopt -a  --options $SHORT --longoptions $LONG -- "$@")

eval set -- "$OPTS"

while :
do
  case "$1" in
    -h | --help)
      help
      exit 0
      ;;
    -C | --cluster )
      cluster="$2"
      case "$2" in
	local)      
          PROMETHEUS_SERVER="${RANCHER_URL}/k8s/clusters/local/api/v1/namespaces/cattle-monitoring-system/services/http:rancher-monitoring-prometheus:9090/proxy"
	;;
	rke-tst)      
          PROMETHEUS_SERVER="${RANCHER_URL}/k8s/clusters/c-m-bb8xst9b/api/v1/namespaces/cattle-monitoring-system/services/http:rancher-monitoring-prometheus:9090/proxy"
	;;
	rke-prd)      
          PROMETHEUS_SERVER="${RANCHER_URL}/k8s/clusters/c-m-rrzxqlqj/api/v1/namespaces/cattle-monitoring-system/services/http:rancher-monitoring-prometheus:9090/proxy"
	;;
      esac
      shift 2
      ;;
    -n | --namespace )
      NAMESPACE="$2"
      shift 2
      ;;
    -p | --pvc )
      PVC="$2"
      shift 2
      ;;
    -w | --warning )
      WARNING=${2:0}
      shift 2
      ;;
    -c | --critical )
      CRITICAL=${2:0}
      shift 2
      ;;
    -t | --token )
      BEARER_TOKEN="$2"
      shift 2
      ;;
    --)
      shift;
      break
      ;;
    *)
      echo "Unexpected option: $1"
      ;;
  esac
done

if [[ -z "$PROMETHEUS_SERVER" ]]; then
  echo "Hiba: Rossz vagy hiányzó cluster név!"
  help
fi

if [[ -z "$NAMESPACE" ]]; then
  echo "Hiba: Hiányzó NAMESPACE paraméter!"
  help
fi

if [[ -z "$PVC" ]]; then
  echo "Hiba: Hiányzó PVC paraméter!"
  help
fi

if [[ -z "$BEARER_TOKEN" ]]; then
  echo "Hiba: Hiányzó TOKEN paraméter!"
  help
fi

#debug
#BEARER_TOKEN="token-xxxx:...."
#NAMESPACE="ns1"
#PVC="pvc1"

if [[ ! "$WARNING" =~ ^[0-9][0-9\%]*$ ]]; then
	echo "Hiba: A WARNING mező csak számot és % karaktert tartalmazhat és nem kezdőhet 0-val!"
	exit 1	
fi

if [[ ! "$CRITICAL" =~ ^[0-9][0-9\%]*$ ]]; then
	echo "Hiba: A CRITICAL mező csak számot és % karaktert tartalmazhat és nem kezdőhet 0-val!"
	exit 1	
fi

WARNING_LEVEL=false
CRITICAL_LEVEL=false

QUERY_VOLUME_AVAILABLE_BYTE="kubelet_volume_stats_available_bytes{namespace=\"$NAMESPACE\",persistentvolumeclaim=\"$PVC\"}"
QUERY_VOLUME_CAPACITY_BYTE="kubelet_volume_stats_capacity_bytes{namespace=\"$NAMESPACE\",persistentvolumeclaim=\"$PVC\"}"

VOLUME_AVAILABLE_BYTE=`curl -H "Authorization: Bearer ${BEARER_TOKEN}" -sgG --data-urlencode "query=${QUERY_VOLUME_AVAILABLE_BYTE}" "${PROMETHEUS_SERVER}/api/v1/query" | jq '.data.result[0].value[1]|tonumber'`
if [ "$?" -ne "0" ]; then
    echo "Hiba!"
    exit 99
fi

VOLUME_CAPACITY_BYTE=`curl -H "Authorization: Bearer ${BEARER_TOKEN}" -sgG --data-urlencode "query=${QUERY_VOLUME_CAPACITY_BYTE}" "${PROMETHEUS_SERVER}/api/v1/query" | jq '.data.result[0].value[1]|tonumber'`
if [ "$?" -ne "0" ]; then
    echo "Hiba!"
    exit 99
fi

VOLUME_USAGE_BYTE=$(($VOLUME_CAPACITY_BYTE - $VOLUME_AVAILABLE_BYTE))



VOLUME_CAPACITY_MBYTE=$(($VOLUME_CAPACITY_BYTE / 1024 / 1024))
VOLUME_AVAILABLE_MBYTE=$(($VOLUME_AVAILABLE_BYTE / 1024 / 1024))
VOLUME_USAGE_MBYTE=$(($VOLUME_CAPACITY_MBYTE - $VOLUME_AVAILABLE_MBYTE))


VOLUME_AVAILABLE_PERCENTAGE=$(($VOLUME_AVAILABLE_BYTE * 100 / $VOLUME_CAPACITY_BYTE  ))
VOLUME_USAGE_PERCENTAGE=$((100 - $VOLUME_AVAILABLE_PERCENTAGE))


#debug
#echo "SIZE: "$VOLUME_CAPACITY_MBYTE
#echo "FREE: "$VOLUME_AVAILABLE_MBYTE" -- "$VOLUME_AVAILABLE_PERCENTAGE  
#echo "USAGE: "$VOLUME_USAGE_MBYTE" -- "$VOLUME_USAGE_PERCENTAGE


if [[ "$CRITICAL" == *"%" ]]; then
  CRITICAL_=$(( $VOLUME_CAPACITY_MBYTE * $(echo $CRITICAL|tr -d '%') / 100 ))
else
  CRITICAL_=$CRITICAL
fi

if [[ "$WARNING" == *"%" ]]; then
  WARNING_=$(( $VOLUME_CAPACITY_MBYTE * $(echo $WARNING|tr -d '%') / 100 ))
else
  WARNING_=$WARNING
fi

#debug
#echo "WARNING_: "$WARNING_
#echo "CRITICAL_: "$CRITICAL_

#!!!it may be necessary
#if [[ $WARNING_ -lt $CRITICAL_ ]]; then
#  echo "Hiba: A \"WARNING\" riasztás magasabban van mint a \"CRITICAL\"!"
#  exit 99
#fi


if [[ $VOLUME_AVAILABLE_MBYTE -lt $CRITICAL_  ]]; then   #CRIT
  echo "DISK CRITICAL - PVC: $PVC free space: $VOLUME_AVAILABLE_MBYTE MB;| $PVC=${VOLUME_USAGE_MBYTE}MB;$(( $VOLUME_CAPACITY_MBYTE - $WARNING_ ));$(( $VOLUME_CAPACITY_MBYTE - $CRITICAL_ ));0;$VOLUME_CAPACITY_MBYTE"
  exit 2
else

  if [[ $VOLUME_AVAILABLE_MBYTE -lt $WARNING_  ]]; then   #CRIT
    echo "DISK WARNING - PVC: $PVC free space: $VOLUME_AVAILABLE_MBYTE MB;| $PVC=${VOLUME_USAGE_MBYTE}MB;$(( $VOLUME_CAPACITY_MBYTE - $WARNING_ ));$(( $VOLUME_CAPACITY_MBYTE - $CRITICAL_ ));0;$VOLUME_CAPACITY_MBYTE"
    exit 1
  else 
    echo "DISK OK - PVC: $PVC free space: $VOLUME_AVAILABLE_MBYTE MB;| $PVC=${VOLUME_USAGE_MBYTE}MB;$(( $VOLUME_CAPACITY_MBYTE - $WARNING_ ));$(( $VOLUME_CAPACITY_MBYTE - $CRITICAL_ ));0;$VOLUME_CAPACITY_MBYTE"
    exit 0
  fi

fi

  #output sample
  #DISK OK - free space: / 1766 MB (34% inode=96%);| /=3343MB;4088;4599;0;5110


