#!/usr/bin/env bash

set -e          # exit on command errors
set -o nounset  # abort on unbound variable
set -o pipefail # capture fail exit codes in piped commands

echo "#================"
echo "Start Swarm setup"

# Setup path with the docker binaries
MYHOST=$(wget -qO- http://169.254.169.254/latest/meta-data/hostname)
export MYHOST
SWARM_STATE=$(docker info | grep Swarm | cut -f2 -d: | sed -e 's/^[ \t]*//')

echo "PATH=$PATH"
echo "NODE_TYPE=$NODE_TYPE"
echo "DYNAMODB_TABLE=$DYNAMODB_TABLE"
echo "HOSTNAME=$MYHOST"
echo "INSTANCE_NAME=$INSTANCE_NAME"
echo "AWS_REGION=$REGION"
echo "MANAGER_IP=$MANAGER_IP"
echo "SWARM_STATE=$SWARM_STATE"
echo "CHANNEL=$CHANNEL"
echo "#================"

get_swarm_id() {
    if [ "$NODE_TYPE" == "manager" ]; then
        SWARM_ID=$(docker info | grep ClusterID | cut -f2 -d: | sed -e 's/^[ \t]*//')
        export SWARM_ID
    else
        # not available in docker info. might be available in future release.
        export SWARM_ID='n/a'
    fi
    echo "SWARM_ID: $SWARM_ID"
}

get_node_id() {
    NODE_ID=$(docker info | grep NodeID | cut -f2 -d: | sed -e 's/^[ \t]*//')
    export NODE_ID
    echo "NODE: $NODE_ID"
}

get_primary_manager_ip() {
    echo "Get Primary Manager IP"
    # query dynamodb and get the Ip for the primary manager.
    MANAGER=$(aws dynamodb get-item --region "$REGION" --table-name "$DYNAMODB_TABLE" --key '{"node_type":{"S": "primary_manager"}}')
    MANAGER_IP=$(echo "$MANAGER" | jq -r '.Item.ip.S')
    export MANAGER_IP
    echo "MANAGER_IP=$MANAGER_IP"
}

get_manager_token() {
    if [ -n "$MANAGER_IP" ]; then
        MANAGER_TOKEN=$(wget -qO- http://"$MANAGER_IP":9024/token/manager/)
        export MANAGER_TOKEN
        echo "MANAGER_TOKEN=$MANAGER_TOKEN"
    else
        echo "MANAGER_TOKEN can't be found yet. MANAGER_IP isn't set yet."
    fi
}

get_worker_token() {
    if [ -n "$MANAGER_IP" ]; then
        WORKER_TOKEN=$(wget -qO- http://"$MANAGER_IP":9024/token/worker/)
        export WORKER_TOKEN
        echo "WORKER_TOKEN=$WORKER_TOKEN"
    else
        echo "WORKER_TOKEN can't be found yet. MANAGER_IP isn't set yet."
    fi
}

confirm_manager_ready() {
    n=0
    until [ $n -ge 5 ]; do
        get_primary_manager_ip
        echo "PRIMARY_MANAGER_IP=$MANAGER_IP"
        get_manager_token
        # if Manager IP or manager_token is empty or manager_token is null, not ready yet.
        # token would be null for a short time between swarm init, and the time the
        # token is added to dynamodb
        if [ -z "$MANAGER_IP" ] || [ -z "$MANAGER_TOKEN" ] || [ "$MANAGER_TOKEN" == "null" ]; then
            echo "Manager: Primary manager Not ready yet, sleep for 60 seconds."
            sleep 60
            n=$((n + 1))
        else
            echo "Manager: Primary manager is ready."
            break
        fi
    done
}

confirm_node_ready() {
    n=0
    until [ $n -ge 5 ]; do
        get_primary_manager_ip
        echo "PRIMARY_MANAGER_IP=$MANAGER_IP"
        get_worker_token
        # if Manager IP or manager_token is empty or manager_token is null, not ready yet.
        # token would be null for a short time between swarm init, and the time the
        # token is added to dynamodb
        if [ -z "$MANAGER_IP" ] || [ -z "$WORKER_TOKEN" ] || [ "$WORKER_TOKEN" == "null" ]; then
            echo "Worker: Primary manager Not ready yet, sleep for 60 seconds."
            sleep 60
            n=$((n + 1))
        else
            echo "Worker: Primary manager is ready."
            break
        fi
    done
}

join_as_secondary_manager() {
    echo "   Secondary Manager"
    if [ -z "$MANAGER_IP" ] || [ -z "$MANAGER_TOKEN" ] || [ "$MANAGER_TOKEN" == "null" ]; then
        confirm_manager_ready
    fi
    echo "   MANAGER_IP=$MANAGER_IP"
    echo "   MANAGER_TOKEN=$MANAGER_TOKEN"
    # sleep for 30 seconds to make sure the primary manager has enough time to setup before
    # we try and join.
    sleep 30
    # we are not primary, so join as secondary manager.
    n=0
    until [ $n -gt 5 ]; do
        docker swarm join --token "$MANAGER_TOKEN" --listen-addr "$PRIVATE_IP":2377 --advertise-addr "$PRIVATE_IP":2377 "$MANAGER_IP":2377

        get_swarm_id
        get_node_id

        # check if we have a SWARM_ID, if so, we were able to join, if not, it failed.
        if [ -z "$SWARM_ID" ]; then
            echo "Can't connect to primary manager, sleep and try again"
            sleep 60
            n=$((n + 1))

            # if we are pending, we might have hit the primary when it was shutting down.
            # we should leave the swarm, and try again, after getting the new primary ip.
            SWARM_STATE=$(docker info | grep Swarm | cut -f2 -d: | sed -e 's/^[ \t]*//')
            echo "SWARM_STATE=$SWARM_STATE"
            if [ "$SWARM_STATE" == "pending" ]; then
                echo "Swarm state is pending, something happened, lets reset, and try again."
                docker swarm leave --force
                sleep 30
            fi

            # query dynamodb again, incase the manager changed
            get_primary_manager_ip
        else
            echo "Connected to primary manager, NODE_ID=$NODE_ID , SWARM_ID=$SWARM_ID"
            break
        fi

    done
    buoy -event="node:manager_join" -swarm_id=$SWARM_ID -channel="$CHANNEL" -node_id="$NODE_ID"
    echo "   Secondary Manager complete"
}

setup_manager() {
    echo "Setup Manager"
    PRIVATE_IP=$(wget -qO- http://169.254.169.254/latest/meta-data/local-ipv4)
    export PRIVATE_IP

    echo "   PRIVATE_IP=$PRIVATE_IP"
    echo "   PRIMARY_MANAGER_IP=$MANAGER_IP"
    if [ -z "$MANAGER_IP" ]; then
        echo "Primary Manager IP not set yet, lets try and set it."
        # try to write to the table as the primary_manager, if it succeeds then it is the first
        # and it is the primary manager. If it fails, then it isn't first, and treat the record
        # that is there, as the primary manager, and join that swarm.
        aws dynamodb put-item \
            --table-name "$DYNAMODB_TABLE" \
            --region "$REGION" \
            --item '{"node_type":{"S": "primary_manager"},"ip": {"S":"'"$PRIVATE_IP"'"}}' \
            --condition-expression 'attribute_not_exists(node_type)' \
            --return-consumed-capacity TOTAL
        PRIMARY_RESULT=$?
        echo "   PRIMARY_RESULT=$PRIMARY_RESULT"

        if [ $PRIMARY_RESULT -eq 0 ]; then
            echo "   Primary Manager init"
            # we are the primary, so init the cluster
            docker swarm init --listen-addr "$PRIVATE_IP":2377 --advertise-addr "$PRIVATE_IP":2377
            # we can now get the tokens.
            get_swarm_id
            get_node_id

            echo "   Primary Manager init complete"
            # send identify message
            buoy -event=identify -iaas_provider=aws
            # send swarm init message
            buoy -event="swarm:init" -swarm_id=$SWARM_ID -node_id="$NODE_ID" -channel="$CHANNEL"
        else
            echo " Error is normal, it is because we already have a primary node, lets setup a secondary manager instead."
            join_as_secondary_manager
        fi
    elif [ "$PRIVATE_IP" == "$MANAGER_IP" ]; then
        echo "   PRIVATE_IP == MANAGER_IP, we are already the leader, maybe it was a reboot?"
        SWARM_STATE=$(docker info | grep Swarm | cut -f2 -d: | sed -e 's/^[ \t]*//')
        # should be active, pending or inactive
        echo "   Swarm State = $SWARM_STATE"
        # check if swarm is good?
    else
        echo "   join as Secondary Manager"
        join_as_secondary_manager
    fi
}

setup_node() {
    echo " Setup Node"
    # setup the node, by joining the swarm.
    if [ -z "$MANAGER_IP" ] || [ -z "$WORKER_TOKEN" ] || [ "$WORKER_TOKEN" == "null" ]; then
        confirm_node_ready
    fi
    echo "   MANAGER_IP=$MANAGER_IP"
    # try an connect to the swarm manager.
    n=0
    until [ $n -gt 5 ]; do
        docker swarm join --token "$WORKER_TOKEN" "$MANAGER_IP":2377
        get_swarm_id
        get_node_id

        # check if we have a NODE_ID, if so, we were able to join, if not, it failed.
        if [ -z "$NODE_ID" ]; then
            echo "Can't connect to primary manager, sleep and try again"
            sleep 60
            n=$((n + 1))

            # query dynamodb again, incase the manager changed
            get_primary_manager_ip
        else
            echo "Connected to manager, NODE_ID=$NODE_ID , SWARM_ID=$SWARM_ID"
            break
        fi

        SWARM_STATE=$(docker info | grep Swarm | cut -f2 -d: | sed -e 's/^[ \t]*//')
        echo "SWARM_STATE=$SWARM_STATE"
        if [ "$SWARM_STATE" == "pending" ]; then
            echo "Swarm state is pending, it will keep trying in background."
            # if this fails to join in the long run, it will require a manual cleanup.
            # Easiest cleanup would be to destroy node, and start a new one.
            break
        fi

    done
    buoy -event="node:join" -swarm_id="$SWARM_ID" -channel="$CHANNEL" -node_id="$NODE_ID"
}

# see if the primary manager IP is already set.
get_primary_manager_ip

# if it is a manager, setup as manager, if not, setup as worker node.
if [ "$NODE_TYPE" == "manager" ]; then
    echo " It's a Manager, run setup"
    get_manager_token
    setup_manager
else
    echo " It's a worker Node, run setup"
    get_worker_token
    setup_node
fi

# show the results.
echo "#================ docker info    ==="
docker info
echo "#================ docker node ls ==="
docker node ls
echo "#==================================="

echo "Complete Swarm setup"
