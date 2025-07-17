#!/bin/bash
set -e

#### MODIFY THESE TO FIT YOUR ENV ####
export storage_policy="standard"
export sre_email="admin@tdmc.example.com"
export cp_hostname="tdmc-cp-epc.example.domain.com"
#### DON'T MODIFY BELOW HERE ####
export TDMC_PROFILE_NAME="demo-org"
SCRIPTPATH=$( realpath "$0" | dirname "$temp")
PATH=$PATH:$SCRIPTPATH/tdmc
function requires() {
    if ! command -v $1 &>/dev/null; then
        echo "Requires $1"
        exit 1
    fi
}

function awaitTask() {
  task_id=$1
  task_status=$(tdmc --profile-name $TDMC_PROFILE_NAME task get --id $task_id | jq -er '.status')

  until [ "$task_status" == "SUCCESS" ]; do
    echo -ne "  Waiting for task $task_id to complete:"
    task_status=$(tdmc --profile-name $TDMC_PROFILE_NAME task get --id $task_id | jq -r '.status')
    echo -ne " ${GREEN}${task_status}${RESET}"
    if [ $task_status == "SUCCESS" ]; then
      break
    else
      sleep 5
    fi
    echo -ne "\r\033[K"
  done
  echo
}

scriptname=$(basename $0)
GREEN="\e[32m"
RED="\e[31m"
RESET="\e[0m"

requires "tdmc"
requires "jq"

# Check for tdmc CLI config for SRE
if [ $(tdmc configure list | jq -r '.EndpointUrl == ""') == true ]; then
  echo -e "${YELLOW}SRE configuration not found, use $cp_hostname as the URL, $sre_email as the email, and the configured password${RESET}"
  tdmc profile create --name default
  tdmc configure
else
  echo -e "${GREEN}Found SRE configuration, skipping creation${RESET}"
fi

echo -ne "Checking for tanzu-cluster-tdmc cloud account: "

if ! tdmc sre cloud-account list | jq -e '.[] | select (.name == "tanzu-cluster-tdmc")' 2>&1 > /dev/null ; then
  echo -e "${GREEN}tanzu-cluster-tdmc cloud account not found, creating${RESET}"
  tdmc sre cloud-account create -p tkgs -f create_cloud_provider_account.json.template 
else
  echo -e "${GREEN}Found tanzu-cluster-tdmc, skipping creation${RESET}"
fi

echo -e -n "Getting ID for cloud account tanzu-cluster-tdmc:"
export cloud_account_id=$(tdmc sre cloud-account list | jq -r '.[] | select (.name == "tanzu-cluster-tdmc") | .id')
echo -e " ${GREEN}$cloud_account_id${RESET}"

echo -e -n "Getting ID for certificate tdmc.tanzu.lab-tkgs-cert:"
export certificate_id=$(tdmc sre certificate list | jq -r '.[] | select (.name == "tdmc.tanzu.lab-tkgs-cert") | .id')
echo -e " ${GREEN}$certificate_id${RESET}"

echo -e -n "Getting ID for DNS config tdh-managed-dns:"
export dns_config_id=$(tdmc sre dns list | jq -r '.[] | select (.name == "tdh-managed-dns") | .id')
echo -e " ${GREEN}$dns_config_id${RESET}"

echo -e -n "Getting ID of first Dataplane Release:"
session_file=$(mktemp -u)
password=$TDMC_PASSWORD
http --session=$session_file --verify=false --quiet https://tdmc-cp-epc.example.domain.com/api/authservice/auth/login username=$sre_email password=$sre_password Accept:text/plain
export dataplane_release_id=$(http --session=$session_file --verify=false GET https://tdmc-cp-epc.example.domain.com/api/infra-connector/dataplane-helm-release/release Accept:application/json | jq -r '._embedded.dataPlaneHelmReleaseDTOes[0].id' )
echo -e " ${GREEN}$dataplane_release_id${RESET}"

for cluster_name in "tdmc-dp-1" "tdmc-dp-2"; do

  export cluster_name
  echo -ne "Checking for ${cluster_name} data plane:"

  if ! tdmc sre data-plane list | jq -e '.[] | select (.dataplaneName == "'$cluster_name'")' 2>&1 > /dev/null ; then
    echo -e " ${GREEN}$cluster_name data plane not found, creating${RESET}"
    tdmc sre data-plane create -p tkgs -f <(envsubst < dataplane_create.json.template)
  else
    echo -e " ${GREEN}Found $cluster_name, skipping creation${RESET}"
  fi

done

for cluster_name in "tdmc-dp-1" "tdmc-dp-2"; do
  dp_status=""
  until [ "$dp_status" == "DATA_PLANE_READY" ]; do
    echo -ne "Waiting for $cluster_name data plane ready:"
    dp_status="$(tdmc sre data-plane list | jq -r '.[] | select(.name == "'$cluster_name'") | .status')"
    echo -ne " ${GREEN}${dp_status}${RESET}"
    if [ $dp_status == "DATA_PLANE_READY" ]; then
      break
    else
      sleep 5
    fi
    echo -ne "\r\033[K"
  done
  echo 
done

echo -ne "Getting tdmc-dp-1 data plane ID:"
export dp1_id=$(tdmc sre data-plane list | jq -r '.[] | select (.name == "tdmc-dp-1") | .id')
echo -e " ${GREEN}$dp1_id${RESET}"

echo -ne "Getting tdmc-dp-2 data plane ID:"
export dp2_id=$(tdmc sre data-plane list | jq -r '.[] | select (.name == "tdmc-dp-2") | .id')
echo -e " ${GREEN}$dp2_id${RESET}"

echo -ne "Getting demo org ID:"
export org_id=$(tdmc sre org list | jq -r '.[] | select (.name == "demo") | .orgId')
if [ -z "$org_id" ]; then
  echo -ne " ${GREEN}demo org not found, creating."
  tdmc sre org create -f <(envsubst < create_org.json.template)
  org_id=$(tdmc sre org list | jq -r '.[] | select (.name == "demo") | .orgId')
  echo -e "  Created with id $org_id${RESET}."
else
  echo -e " ${GREEN}Found demo org with id $org_id, skipping creation${RESET}"
fi

echo -ne "Checking for $TDMC_PROFILE_NAME profile:"
if [ ! $(tdmc profile list | jq -r '. | any(index("$TDMC_PROFILE_NAME"))') == 'true' ]; then
  echo -e " ${GREEN}$TDMC_PROFILE_NAME profile not found, creating${RESET}"
  tdmc profile create --name $TDMC_PROFILE_NAME --org $org_id --username 'grog@grogscave.net'
else
  echo -e " ${GREEN}Found $TDMC_PROFILE_NAME profile, skipping creation${RESET}"
fi

echo -ne "Enable Self-DR: ${RED}must do manually${RESET} https://techdocs.broadcom.com/us/en/vmware-tanzu/data-solutions/tanzu-data-management-console/1-0/tdmc/disaster-recovery.html"
read

echo -ne "Checking for Allow All network policy in $TDMC_PROFILE_NAME:"
export allow_all_policy_id=$(tdmc --profile-name $TDMC_PROFILE_NAME iam network-policy list | jq -r '._embedded.mdsPolicyDTOes.[] | select (.name == "Allow All") | .id')
if [ -z "$allow_all_policy_id" ]; then
  echo -ne " ${GREEN}Allow All network policy not found, creating."
  tdmc --profile-name $TDMC_PROFILE_NAME iam network-policy create -f network_policy_create.json.template
  allow_all_policy_id=$(tdmc --profile-name $TDMC_PROFILE_NAME iam network-policy list | jq -r '._embedded.mdsPolicyDTOes.[] | select (.name == "Allow All") | .id')
  echo -e "  Created with id $allow_all_policy_id${RESET}."
else
  echo -e " ${GREEN}Found Allow All network policy with id $allow_all_policy_id, skipping creation${RESET}"
fi

echo -ne "Checking for test-pg Postgres database in $TDMC_PROFILE_NAME:"
export test_pg_id=$(tdmc --profile-name $TDMC_PROFILE_NAME postgres list | jq -r '.[]? | select (.name == "test-pg") | .id')
if [ -z "$test_pg_id" ]; then
  echo -e " ${GREEN}test-pg Postgres database not found, creating.${RESET}"

  task_id=$(tdmc --profile-name $TDMC_PROFILE_NAME -p tkgs postgres create -f <(envsubst < postgres_cluster_create.json.template) | jq -r '.taskId')
  awaitTask $task_id
  test_pg_id=$(tdmc --profile-name $TDMC_PROFILE_NAME postgres list | jq -r '.[] | select (.name == "test-pg") | .id')
  echo -e "  Created with id $test_pg_id${RESET}."
else
  echo -e " ${GREEN}Found test-pg Postgres database with id $test_pg_id, skipping creation${RESET}"
fi

echo -ne "Checking for test-mysql MySQL database in $TDMC_PROFILE_NAME:"
export test_mysql_id=$(tdmc --profile-name $TDMC_PROFILE_NAME mysql list | jq -r '.[]? | select (.name == "test-mysql") | .id')
if [ -z "$test_mysql_id" ]; then
  echo -e " ${GREEN}test-mysql MySQL database not found, creating.${RESET}"

  task_id=$(tdmc --profile-name $TDMC_PROFILE_NAME -p tkgs mysql create -f <(envsubst < mysql_cluster_create.json.template) | jq -r '.taskId')
  awaitTask $task_id

  test_mysql_id=$(tdmc --profile-name $TDMC_PROFILE_NAME mysql list | jq -r '.[] | select (.name == "test-mysql") | .id')
  echo -e "  Created with id $test_mysql_id${RESET}."
else
  echo -e " ${GREEN}Found test-mysql MySQL database with id $test_mysql_id, skipping creation${RESET}"
fi

echo -ne "Checking for test-rabbitmq RabbitMQ service in $TDMC_PROFILE_NAME:"
export test_rabbitmq_id=$(tdmc --profile-name $TDMC_PROFILE_NAME rmq list | jq -r '.[]? | select (.name == "test-rabbitmq") | .id')
if [ -z "$test_rabbitmq_id" ]; then
  echo -e " ${GREEN}test-rabbitmq RabbitMQ service not found, creating.${RESET}"

  task_id=$(tdmc --profile-name $TDMC_PROFILE_NAME -p tkgs rmq create -f <(envsubst < rabbitmq_cluster_create.json.template) | jq -r '.taskId')
  awaitTask $task_id
  
  test_rabbitmq_id=$(tdmc --profile-name $TDMC_PROFILE_NAME rmq list | jq -r '.[] | select (.name == "test-rabbitmq") | .id')
  echo -e "  Created with id $test_rabbitmq_id${RESET}."
else
  echo -e " ${GREEN}Found test-rabbitmq RabbitMQ service with id $test_rabbitmq_id, skipping creation${RESET}"
fi

echo -ne "Checking for test-valkey Valkey service in $TDMC_PROFILE_NAME:"
export test_valkey_id=$(tdmc --profile-name $TDMC_PROFILE_NAME valkey list | jq -r '.[]? | select (.name == "test-valkey") | .id')
if [ -z "$test_valkey_id" ]; then
  echo -e " ${GREEN}test-valkey Valkey service not found, creating.${RESET}"

  task_id=$(tdmc --profile-name $TDMC_PROFILE_NAME -p tkgs valkey create -f <(envsubst < valkey_cluster_create.json.template) | jq -r '.taskId')
  awaitTask $task_id
  
  test_valkey_id=$(tdmc --profile-name $TDMC_PROFILE_NAME valkey list | jq -r '.[] | select (.name == "test-valkey") | .id')
  echo -e "  Created with id $test_valkey_id${RESET}."
else
  echo -e " ${GREEN}Found test-valkey Valkey service with id $test_valkey_id, skipping creation${RESET}"
fi
