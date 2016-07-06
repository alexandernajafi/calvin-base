#!/bin/sh

IMAGE="erctcalvin/calvin:develop"
EXTERNAL_IP=""
PORT="5000" 
CONTROLPORT="5001"
RUNTIMES=3
USE_DOCKERS=yes
RUNTESTS=

usage() {
    echo "Usage: $(basename $0) -c -i <image> -e <ip> [proxy/dht/cleanup]\n\
    -i <image>[:<tag>]   : Calvin image (and tag) to use [$IMAGE]\n\
    -e <external-ip>     : External IP to use\n\
    -n                   : Native, not dockers\n\
    -r <number>          : Number of extra runtimes beyond the first one\n\
    -t                   : Run tests (requires 3+1 runtimes)\n\
    -c                   : Cleanup after tests"
    exit 1
}

check_calvin() {
    if test ! $(which csruntime); then
        echo "no csruntime in path, is calvin installed?"
        exit 1
    fi
}

wait_for_runtime() {
    retries=10
    rt=$1
    while test $retries -gt 0; do
        res=$(cscontrol http://$EXTERNAL_IP:$CONTROLPORT storage get_index '["node_name", {"name": "runtime-'$rt'"}]')
        result=${res#*result}
        if test ${#result} -eq 45; then
            echo "runtime-$rt on-line"
            break
        fi
        retries=$((retries-1))
        sleep 0.5
    done
    if test $retries -eq 0; then
        echo Too many retries for runtime-$rt, giving up
        exit 1
    fi
}

wait_for_runtimes() {
    for rt in $seq; do
        wait_for_runtime $rt
    done
}

cleanup_dockers() {
     docker kill $(docker ps | awk 'NR>1{ print $1 }' ) >& /dev/null
     docker rm $(docker ps -f status=exited -f status=created | awk 'NR>1{ print $1 }') >& /dev/null
}

cleanup_native() {
    kill $(ps | grep csruntime | awk '{print $1}') >& /dev/null

}

cleanup_all() {
    cleanup_dockers
    cleanup_native
    rm runtime-?.log >& /dev/null
}

proxy_docker_system() {
    ../dcsruntime.sh -i $IMAGE -e $EXTERNAL_IP -l -p $PORT -c $CONTROLPORT -n runtime-0
    wait_for_runtime 0
    for i in $seq; do
        ../dcsruntime.sh -i $IMAGE -e $EXTERNAL_IP -r $EXTERNAL_IP:$PORT -n runtime-$i
    done
    wait_for_runtimes
}

dht_docker_system() {
    ../dcsruntime.sh -i $IMAGE -e $EXTERNAL_IP -p $PORT -c $CONTROLPORT -n runtime-0
    wait_for_runtime 0
    for i in $seq; do
        ../dcsruntime.sh -i $IMAGE -e $EXTERNAL_IP -n runtime-$i
        sleep 0.5
    done
    wait_for_runtimes
}

dht_native_system() {
    check_calvin

    csruntime --host $EXTERNAL_IP -p $PORT -c $CONTROLPORT --name runtime-0 -f runtime-0.log >& /dev/null &
    wait_for_runtime 0
    for i in $seq ; do
        csruntime --host $EXTERNAL_IP -p $(($PORT+2*$i)) -c $(($CONTROLPORT+2*$i)) --name runtime-$i -f runtime-$i.log >& /dev/null &
    done
    wait_for_runtimes
}

proxy_native_system() {
    CALVIN_GLOBAL_STORAGE_TYPE=\"local\"\
        csruntime --host $EXTERNAL_IP -p $PORT -c $CONTROLPORT --name runtime-0 -f runtime-0.log &
    wait_for_runtime 0
    for i in $seq ; do
        CALVIN_GLOBAL_STORAGE_TYPE=\"proxy\" CALVIN_GLOBAL_STORAGE_PROXY=\"calvinip://$EXTERNAL_IP:$PORT\"\
            csruntime --host $EXTERNAL_IP -p $(($PORT+2*$i)) -c $(($CONTROLPORT+2*$i)) --name runtime-$i -f runtime-$i.log >& /dev/null &
    done
    wait_for_runtimes
}

setup_dht_system() {
    if test -n "$USE_DOCKERS"; then
        echo setup dht system w/ dockers
        dht_docker_system
    else
        echo setup dht system native
        dht_native_system
    fi
}

setup_proxy_system() {
    if test -n "$USE_DOCKERS"; then
        echo setup proxy system w/ dockers
        proxy_docker_system
    else
        echo setup proxy system native
        proxy_native_system
    fi
}


test_deploy() {
    echo deploying application
    deploy_result=$(cscontrol http://$EXTERNAL_IP:$CONTROLPORT deploy --reqs pipeline.deployjson pipeline.calvin)
    sleep 1

    output=""
    retries=10
    SUCCESS=

    while test $retries -gt 0; do
        if test -n "$USE_DOCKERS"; then
            # fetch from docker runtime-3
            output=$(../dcslog.sh -1 runtime-3)
        else
            # fetch from file runtime-3.log
            output=$(tail -1 runtime-3.log)
        fi
        if test "${output#*-calvin.Log: }" = "fire"; then
            SUCCESS=success
            break
        fi
        sleep 0.2
        retries=$(($retries-1))
    done

    echo tests done
    
    if test -z "$SUCCESS"; then
        echo "failure"
        echo "error: $output"
        echo "deploy: $deploy_result"
        
        exit 1
    else
        echo $SUCCESS        
    fi
}

while getopts "ctr:i:e:hn" opt; do
	case $opt in
        c)
            CLEANUP=yes
            ;;
		h) 
            usage
            ;;
        t)
            RUNTESTS=yes
            ;;
        r)
            RUNTIMES=$OPTARG
            ;;
        n)
            USE_DOCKERS=
            ;;
        i) 
            IMAGE="$OPTARG"
            ;; 
        e)
            EXTERNAL_IP="$OPTARG"
            ;;
	esac
done

shift $(($OPTIND-1))

CMD=$1

if test -z $CMD; then
    usage
fi

# Setup number of runtimes

i=1
seq=""
while test $i -le $RUNTIMES; do
    seq+=" "$i
    i=$(($i+1)) 
done


case $CMD in
    cleanup)
        cleanup_all
        exit 0
        ;;
    proxy)
        setup_proxy_system
        ;;
    dht)
        setup_dht_system
    esac

if test -n "$RUNTESTS"; then
    test_deploy
else 
    echo system setup done
fi

if test -n $CLEANUP; then
    cleanup_all
fi