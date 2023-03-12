# shellcheck shell=bash

export LEGACY_HARDCODED_INSTANCE_ID_WALLET="2"

function mine_blocks() {
    PEG_IN_ADDR="$($FM_BTC_CLIENT getnewaddress)"
    $FM_BTC_CLIENT generatetoaddress $1 $PEG_IN_ADDR
}

function open_channel() {
    # check that both nodes are synced
    await_lightning_node_block_processing

    LN_ADDR="$($FM_LIGHTNING_CLI newaddr | jq -e -r '.bech32')"
    $FM_BTC_CLIENT sendtoaddress $LN_ADDR 1
    mine_blocks 10
    LND_PUBKEY="$($FM_LNCLI getinfo | jq -e -r '.identity_pubkey')"
    $FM_LIGHTNING_CLI connect $LND_PUBKEY@127.0.0.1:9734
    until $FM_LIGHTNING_CLI -k fundchannel id=$LND_PUBKEY amount=0.1btc push_msat=5000000000; do sleep $FM_POLL_INTERVAL; done
    mine_blocks 10
    until [[ $($FM_LIGHTNING_CLI listpeers | jq -e -r ".peers[] | select(.id == \"$LND_PUBKEY\") | .channels[0].state") = "CHANNELD_NORMAL" ]]; do sleep $FM_POLL_INTERVAL; done
}

function await_bitcoin_rpc() {
    until $FM_BTC_CLIENT getblockchaininfo 1>/dev/null 2>/dev/null ; do
        >&2 echo "Bitcoind rpc not ready yet. Waiting ..."
        sleep "$FM_POLL_INTERVAL"
    done
}

function await_fedimint_block_sync() {
  $FM_BIN_DIR/fixtures await-fedimint-block-sync
}

function await_all_peers() {
  $FM_MINT_CLIENT api /module/${LEGACY_HARDCODED_INSTANCE_ID_WALLET}/block_height
}

function await_server_on_port() {
  until nc -z 127.0.0.1 $1
  do
      sleep $FM_POLL_INTERVAL
  done
}

# Check that lightning block-proccessing is caught up
# CLI integration tests should call this before attempting to pay invoices
function await_lightning_node_block_processing() {
  # CLN
  EXPECTED_BLOCK_HEIGHT="$($FM_BTC_CLIENT getblockchaininfo | jq -e -r '.blocks')"
  until [ $EXPECTED_BLOCK_HEIGHT == "$($FM_LIGHTNING_CLI getinfo | jq -e -r '.blockheight')" ]
  do
    sleep $FM_POLL_INTERVAL
  done
  echo "done waiting for cln"

  # LND
  until [ "true" == "$($FM_LNCLI getinfo | jq -r '.synced_to_chain')" ]
  do
    echo "sleeping"
    sleep $FM_POLL_INTERVAL
  done
  echo "done waiting for lnd"
}

# Function for killing processes stored in FM_PID_FILE in reverse-order they were created in
function kill_fedimint_processes {
  echo "Killing fedimint processes"
  PIDS=$(cat $FM_PID_FILE | sed '1!G;h;$!d') # sed reverses order
  kill $PIDS 2>/dev/null
  rm -f $FM_PID_FILE
}

function await_gateway_cln_extension() {
  while ! echo exit | nc localhost 8177; do sleep $FM_POLL_INTERVAL; done
}

function gw_connect_fed() {
  # get connection string ... retry in case fedimint-cli command fails
  FM_CONNECT_STR=""
  while [[ $FM_CONNECT_STR = "" ]]
  do
    FM_CONNECT_STR=$($FM_MINT_CLIENT connect-info | jq -e -r '.connect_info') || true
    echo "fedimint-cli connect-info failed ... retrying"
    sleep $FM_POLL_INTERVAL
  done

  # get connection string ... retry in case gateway-cli command fails
  while ! $FM_GATEWAY_CLI connect-fed "$FM_CONNECT_STR"
  do
    echo "gateway-cli connect-fed failed ... retrying"
    sleep $FM_POLL_INTERVAL
  done
}

function get_finality_delay() {
    cat $FM_CFG_DIR/client.json | jq -e -r ".modules.\"${LEGACY_HARDCODED_INSTANCE_ID_WALLET}\".config.finality_delay"
}

function sat_to_btc() {
    echo "scale=8; $1/100000000" | bc | awk '{printf "%.8f\n", $0}'
}

#caller should call mine_blocks() after this
function send_bitcoin() {
    local RECV_ADDRESS
    RECV_ADDRESS=$1
    local SEND_AMT
    SEND_AMT=$2

    local TX_ID
    TX_ID="$($FM_BTC_CLIENT sendtoaddress $RECV_ADDRESS "$(sat_to_btc $SEND_AMT)")"
    echo $TX_ID
}

function get_txout_proof() {
    local TX_ID
    TX_ID=$1

    local TXOUT_PROOF
    TXOUT_PROOF="$($FM_BTC_CLIENT gettxoutproof "[\"$TX_ID\"]")"
    echo $TXOUT_PROOF
}

function get_raw_transaction() {
    local TX_ID
    TX_ID=$1

    local TRANSACTION
    TRANSACTION="$($FM_BTC_CLIENT getrawtransaction $TX_ID)"
    echo $TRANSACTION
}

function get_federation_id() {
    cat $FM_CFG_DIR/client.json | jq -e -r '.federation_id'
}

function show_verbose_output()
{
    if [[ $FM_VERBOSE_OUTPUT -ne 1 ]] 
    then
        cat > /dev/null 2>&1
    else
        cat
    fi
}

function await_gateway_registered() {
    until [ "$($FM_MINT_CLIENT list-gateways | jq -e ".num_gateways")" = "1" ]; do
        sleep $FM_POLL_INTERVAL
    done
}

function run_dkg() {
  # Generate federation configs
  BASE_PORT=$((8173 + 10000))
  CERTS=""
  for ((ID=0; ID<FM_FED_SIZE; ID++));
  do
    setup_fedimintd_env $ID
    echo "making creating cert for ports server $ID"
    $FM_BIN_DIR/distributedgen create-cert --p2p-url $FM_P2P_URL --api-url $FM_API_URL --out-dir $FM_FEDIMINTD_DATA_DIR --name "Server-$ID"
    CERTS="$CERTS,$(cat $FM_CFG_DIR/server-$ID/tls-cert)"
  done
  CERTS=${CERTS:1}
  echo "Running DKG with certs: $CERTS"

  DKG_PIDS=""
  for ((ID=0; ID<FM_FED_SIZE; ID++));
  do
    setup_fedimintd_env $ID
    $FM_BIN_DIR/distributedgen run  --bind-p2p $FM_BIND_P2P --bind-api $FM_BIND_API --out-dir $FM_FEDIMINTD_DATA_DIR --certs $CERTS &
    DKG_PIDS="$DKG_PIDS $!"
  done
  wait $DKG_PIDS

  # Move the client config
  mv $FM_CFG_DIR/server-0/client* $FM_CFG_DIR/
}

function setup_fedimintd_env() {
  ID=$1
  BASE_PORT=$((8173 + 10000))
  P2P_PORT=$(echo "$BASE_PORT + $ID * 10" | bc -l)
  API_PORT=$(echo "$BASE_PORT + $ID * 10 + 1" | bc -l)
  UI_PORT=$(echo "$BASE_PORT + $ID * 10 + 2" | bc -l)
  export FM_BIND_P2P=127.0.0.1:$P2P_PORT
  export FM_P2P_URL=fedimint://127.0.0.1:$P2P_PORT
  export FM_BIND_API=127.0.0.1:$API_PORT
  export FM_API_URL=ws://127.0.0.1:$API_PORT
  export FM_LISTEN_UI=127.0.0.1:$UI_PORT
  export FM_PASSWORD="pass$ID"
  export FM_FEDIMINTD_DATA_DIR="$FM_CFG_DIR/server-$ID"

  # ensure datadir exists ... pipe to `true` because run_dkg() and setup_federation()
  # both call this so the directory might already be here ...
  mkdir $FM_FEDIMINTD_DATA_DIR || true
}

### Start Daemons ###

function start_bitcoind() {
  $FM_BIN_DIR/fixtures bitcoind
  echo $! >> $FM_PID_FILE
}

function start_lightningd() {
  $FM_BIN_DIR/fixtures lightningd
  echo $! >> $FM_PID_FILE
}

function start_lnd() {
  $FM_BIN_DIR/fixtures lnd
  echo $! >> $FM_PID_FILE
}

function start_gatewayd() {
  echo "starting gatewayd"
  await_gateway_cln_extension
  await_fedimint_block_sync
  $FM_BIN_DIR/fixtures gatewayd &
  gw_connect_fed
  echo "started gatewayd"
}

function start_electrs() {
  $FM_BIN_DIR/fixtures electrs
  echo $! >> $FM_PID_FILE
}

function start_esplora() {
  $FM_BIN_DIR/fixtures esplora
  echo $! >> $FM_PID_FILE
}

function start_federation() {
  START_SERVER=${1:-0}
  END_SERVER=${2:-$FM_FED_SIZE}
  $FM_BIN_DIR/fixtures federation $START_SERVER $END_SERVER &
}

function start_daemons() {
  $FM_BIN_DIR/fixtures daemons &
  echo $! >> $FM_PID_FILE
}
