#!/usr/bin/env bash
NODPICO_RUNNING=$1

set -m

# CAUTION: Never use these development keys for a production account!
# Doing so will most certainly result in the loss of access to your account, these private keys are publicly known.
SYSTEM_ACCOUNT_PRIVATE_KEY="5KQwrPbwdL6PhXujxW37FSSQZ1JiwsST4cqQzDeyXtP79zkvFD3"
SYSTEM_ACCOUNT_PUBLIC_KEY="PICO6MRyAjQq8ud7hVNYcfnVPJqcVpscN5So8BhtHuGYqET5GDW5CV"

EXAMPLE_ACCOUNT_PRIVATE_KEY="5JuH9fCXmU3xbj8nRmhPZaVrxxXrdPaRmZLW1cznNTmTQR2Kg5Z"
EXAMPLE_ACCOUNT_PUBLIC_KEY="PICO7bxrQUTbQ4mqcoefhWPz1aFieN4fA9RQAiozRz7FrUChHZ7Rb8"

R1_EXAMPLE_ACCOUNT_PRIVATE_KEY="PVT_R1_GrfEfbv5at9kbeHcGagQmvbFLdm6jqEpgE1wsGbrfbZNjpVgT"
R1_EXAMPLE_ACCOUNT_PUBLIC_KEY="PUB_R1_4ztaVy8L9zbmzTdpfq5GcaFYwGwXTNmN3qW7qcgHMmfUZhpzQQ"

ROOT_DIR="/opt"
CONTRACTS_DIR="$ROOT_DIR/picoio/bin/contracts"
BLOCKCHAIN_DATA_DIR=/root/.local/share
BLOCKCHAIN_CONFIG_DIR=/opt/picoio/bin/config-dir
WALLET_DIR="/root/picoio-wallet/"

mkdir -p $ROOT_DIR/bin

# Set PATH
PATH="$PATH:$ROOT_DIR/bin:$ROOT_DIR/bin/scripts"
CONFIG_DIR="$ROOT_DIR/bin/config-dir"

function start_wallet {
  echo "Starting the wallet"
  rm -rf $WALLET_DIR
  mkdir -p $WALLET_DIR
  nohup kpicod --unlock-timeout 999999999 --wallet-dir $WALLET_DIR --http-server-address 127.0.0.1:8900 2>&1 &
  sleep 1s
  wallet_password=$(clpico wallet create --to-console | awk 'FNR > 3 { print $1 }' | tr -d '"')
  echo $wallet_password > "$CONFIG_DIR"/keys/default_wallet_password.txt

  clpico wallet import --private-key $SYSTEM_ACCOUNT_PRIVATE_KEY
}

function post_preactivate {
  curl -X POST http://127.0.0.1:8888/v1/producer/schedule_protocol_feature_activations -d '{"protocol_features_to_activate": ["0ec7e080177b2c02b278d5088611686b49d739925a92d9bfcacd7fc6b74053bd"]}'
}

# $1 feature disgest to activate
function activate_feature {
  clpico push action picoio activate '["'"$1"'"]' -p picoio
  if [ $? -ne 0 ]; then
    exit 1
  fi
}

# $1 account name
# $2 contract directory
# $3 wasm file name
# $4 abi file name
function setcode {
  retry_count="4"

  while [ $retry_count -gt 0 ]; do
    clpico set code $1 $2 -p $1@active
    if [ $? -eq 0 ]; then
      break
    fi

    echo "setcode failed retrying..."
    sleep 1s
    retry_count=$[$retry_count-1]
  done

  if [ $retry_count -eq 0 ]; then
    echo "setcode failed too many times, bailing."
    exit 1
  fi
}

# $1 account name
# $2 contract directory
# $3 abi file name
function setabi {
  retry_count="4"

  while [ $retry_count -gt 0 ]; do
    clpico set abi $1 $2 -p $1@active
    if [ $? -eq 0 ]; then
      break
    fi

    echo "setcode failed retrying..."
    sleep 1s
    retry_count=$[$retry_count-1]
  done

  if [ $retry_count -eq 0 ]; then
    echo "setcode failed too many times, bailing."
    exit 1
  fi
}

# $1 - account name
# $2 - public key
# $3 - private key
function create_account {
  clpico wallet import --private-key $3
  clpico create account picoio $1 $2
}

# Move into the executable directory
cd $ROOT_DIR/bin/
mkdir -p $CONFIG_DIR
mkdir -p $BLOCKCHAIN_DATA_DIR
mkdir -p $BLOCKCHAIN_CONFIG_DIR

if [ -z "$NODPICO_RUNNING" ]; then
  echo "Starting the chain for setup"
  nodpico -e -p picoio \
  --data-dir $BLOCKCHAIN_DATA_DIR \
  --config-dir $BLOCKCHAIN_CONFIG_DIR \
  --http-validate-host=false \
  --plugin picoio::producer_api_plugin \
  --plugin picoio::chain_api_plugin \
  --plugin picoio::http_plugin \
  --http-server-address=0.0.0.0:8888 \
  --access-control-allow-origin=* \
  --contracts-console \
  --max-transaction-time=100000 \
  --verbose-http-errors &
fi

mkdir -p "$CONFIG_DIR"/keys

sleep 1s

echo "Waiting for the chain to finish startup"
until curl localhost:8888/v1/chain/get_info
do
  echo "Still waiting"
  sleep 1s
done

# Sleep for 2s to allow time for 4 blocks to be created so we have blocks to reference when sending transactions
sleep 2s
echo "Creating accounts and deploying contracts"

start_wallet

# preactivate concensus upgrades
post_preactivate

sleep 1s
clpico wallet unlock --password $(cat "$CONFIG_DIR"/keys/default_wallet_password.txt) || true
setabi picoio $CONTRACTS_DIR/boot/boot.abi
setcode picoio $CONTRACTS_DIR/boot/boot.wasm
sleep 2s
clpico push action picoio boot "[]" -p picoio@active

sleep 1s
clpico wallet unlock --password $(cat "$CONFIG_DIR"/keys/default_wallet_password.txt) || true
setcode picoio $CONTRACTS_DIR/system/system.wasm
setabi picoio $CONTRACTS_DIR/system/system.abi

# token
sleep 1s
clpico wallet unlock --password $(cat "$CONFIG_DIR"/keys/default_wallet_password.txt) || true
create_account picoio.token $SYSTEM_ACCOUNT_PUBLIC_KEY $SYSTEM_ACCOUNT_PRIVATE_KEY
create_account bob $EXAMPLE_ACCOUNT_PUBLIC_KEY $EXAMPLE_ACCOUNT_PRIVATE_KEY
create_account alice $EXAMPLE_ACCOUNT_PUBLIC_KEY $EXAMPLE_ACCOUNT_PRIVATE_KEY
create_account bobr1 $R1_EXAMPLE_ACCOUNT_PUBLIC_KEY $R1_EXAMPLE_ACCOUNT_PRIVATE_KEY
create_account alicer1 $R1_EXAMPLE_ACCOUNT_PUBLIC_KEY $R1_EXAMPLE_ACCOUNT_PRIVATE_KEY

sleep 1s
clpico set abi picoio.token $CONTRACTS_DIR/token/token.abi -p picoio.token@active -p picoio@active
clpico set code picoio.token $CONTRACTS_DIR/token/token.wasm -p picoio.token@active -p picoio@active

clpico push action picoio.token create '["bob", "10000000000.0000 SYS"]' -p picoio.token
clpico push action picoio.token issue '["bob", "5000000000.0000 SYS", "Half of available supply"]' -p bob
clpico push action picoio.token transfer '["bob", "alice", "1000000.0000 SYS", "memo"]' -p bob
clpico push action picoio.token transfer '["bob", "bobr1", "1000000.0000 SYS", "memo"]' -p bob
clpico push action picoio.token transfer '["bob", "alicer1", "1000000.0000 SYS", "memo"]' -p bob

clpico push action picoio init "[]" -p picoio@active

echo "All done initializing the blockchain"

if [[ -z $NODPICO_RUNNING ]]; then
  echo "Shut down Nodpico, sleeping for 2 seconds to allow time for at least 4 blocks to be created after deploying contracts"
  sleep 2s
  kill %1
  fg %1
fi
