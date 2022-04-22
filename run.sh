#! /bin/bash

OSLOGIN_USERNAME=$(gcloud compute os-login describe-profile --format="value(posixAccounts[0].username)")

# generate an SSH keypair locally
rm -rf $HOME/.ssh/id_rsa_for_oslogin*
ssh-keygen -b 2048 -t rsa -f $HOME/.ssh/id_rsa_for_oslogin -q -N ""

# create SSH key for local testing
rm -rf $HOME/.ssh/id_rsa_for_local*
ssh-keygen -b 2048 -t rsa -f $HOME/.ssh/id_rsa_for_local -q -N ""

# add the public key to the user profile's OSLogin ssh-keys object
# https://cloud.google.com/compute/docs/connect/add-ssh-keys#os-login
gcloud compute os-login ssh-keys add --key-file=$HOME/.ssh/id_rsa_for_oslogin.pub

# Get command line args -t
TEST_CASE_FILE=test-cases.csv
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -t) TEST_CASE_FILE="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

TEST_RESULTS_FILE=$(echo $TEST_CASE_FILE | cut -d. -f1)-results.csv
# prepare test-results.csv file
echo "test-name,test-repetition,enable-oslogin,machine-type,zone,vm-image,sshd-max-startups,paralell-num-workers,parallel-num-iterations,denied-count,reset-count,closed-count,failed-count,load-average-count,log-lines-count,parallel-runtime" > $TEST_RESULTS_FILE

echo "Test case file: $TEST_CASE_FILE"

# loop over test-cases.csv
exec < $TEST_CASE_FILE
read header
while IFS="," read -r TEST_NAME VPC_NETWORK SUBNET NETWORK_TAG ENABLE_OSLOGIN MACHINE_TYPE ZONE VM_IMAGE SSHD_MAX_STARTUPS PARALLEL_NUM_WORKERS PARALLEL_NUM_ITERATIONS TEST_REPETITIONS DELETE_INSTANCES
do
    echo "Starting test-case $TEST_NAME"

    SERVER_NAME=server-$TEST_NAME
    CLIENT_NAME=client-$TEST_NAME

    # create the "server" VM
    gcloud compute instances create \
        $SERVER_NAME \
        --zone=$ZONE \
        --machine-type=$MACHINE_TYPE \
        --network-interface=network-tier=PREMIUM,network=$VPC_NETWORK,subnet=$SUBNET,no-address \
        --image=$VM_IMAGE \
        --scopes=https://www.googleapis.com/auth/cloud-platform \
        --tags=$NETWORK_TAG \
        --metadata=^@^enable-oslogin=$ENABLE_OSLOGIN@sshd-max-startups=$SSHD_MAX_STARTUPS@startup-script='#! /bin/bash
getMetadataValue() {
curl -fs http://metadata/computeMetadata/v1/$1 \
    -H "Metadata-Flavor: Google"
}

SSHD_MAX_STARTUPS=`getMetadataValue instance/attributes/sshd-max-startups`

# set selinux to permissive
echo 0 > /sys/fs/selinux/enforce

cat <<EOT >> /etc/security/limits.conf
*                -       nproc           unlimited
*                -       memlock         unlimited
*                -       stack           unlimited
*                -       nofile          1048576
*                -       cpu             unlimited
*                -       rtprio          unlimited
EOT

# install ops agent
curl -sSO https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh
sudo bash add-google-cloud-ops-agent-repo.sh --also-install
cat <<EOT >> /etc/google-cloud-ops-agent/config.yaml
logging:
  receivers:
    syslog:
      type: files
      include_paths:
      - /var/log/messages
      - /var/log/syslog
    sshd:
      type: files
      include_paths:
      - /var/log/secure
  service:
    pipelines:
      default_pipeline:
        receivers: [syslog,sshd]
metrics:
  receivers:
    hostmetrics:
      type: hostmetrics
      collection_interval: 60s
  processors:
    metrics_filter:
      type: exclude_metrics
      metrics_pattern: []
  service:
    pipelines:
      default_pipeline:
        receivers: [hostmetrics]
        processors: [metrics_filter]
EOT
sudo service google-cloud-ops-agent restart

# set SSHD MaxStartups to $SSHD_MAX_STARTUPS and restart SSHD
echo -e "\nLogLevel DEBUG3\nMaxStartups ${SSHD_MAX_STARTUPS}" >> /etc/ssh/sshd_config
systemctl restart sshd.service' \
        --no-user-output-enabled

    # after the server is created, create the "client" VM
    gcloud compute instances create \
        $CLIENT_NAME \
        --zone=$ZONE \
        --machine-type=$MACHINE_TYPE \
        --network-interface=network-tier=PREMIUM,network=$VPC_NETWORK,subnet=$SUBNET,no-address \
        --image=$VM_IMAGE \
        --scopes=https://www.googleapis.com/auth/cloud-platform \
        --tags=$NETWORK_TAG \
        --metadata=^@^enable-oslogin=$ENABLE_OSLOGIN@server-name=$SERVER_NAME@parallel-num-iterations=$PARALLEL_NUM_ITERATIONS@parallel-num-workers=$PARALLEL_NUM_WORKERS@sshd-max-startups=$SSHD_MAX_STARTUPS@test-repetitions=$TEST_REPETITIONS@startup-script='#! /bin/bash
cat <<EOT >> /etc/security/limits.conf
*                -       nproc           unlimited
*                -       memlock         unlimited
*                -       stack           unlimited
*                -       nofile          1048576
*                -       cpu             unlimited
*                -       rtprio          unlimited
EOT' \
        --no-user-output-enabled
    
    # TODO wait for the client to have SSH access available, but for now, just sleep for 35 seconds, as that should take care of most edge cases
    # TODO ... gcloud compute --verbosity error --ZONE $ZONE ssh $CLIENT_NAME --tunnel-through-iap -- "echo instance now up" -o StrictHostKeyChecking=no
    sleep 35

    # copy the SSH key to the client VM
    echo "Copying SSH keys to the client VM"
    export CLOUDSDK_PYTHON_SITEPACKAGES=1
    gcloud compute ssh $OSLOGIN_USERNAME@$CLIENT_NAME --zone $ZONE --tunnel-through-iap --command="mkdir -p .ssh && chmod 700 .ssh"  < /dev/null
    gcloud compute scp $HOME/.ssh/id_rsa_for_oslogin.pub $OSLOGIN_USERNAME@$CLIENT_NAME:.ssh/id_rsa_for_oslogin.pub --zone $ZONE --tunnel-through-iap
    gcloud compute scp $HOME/.ssh/id_rsa_for_oslogin $OSLOGIN_USERNAME@$CLIENT_NAME:.ssh/id_rsa_for_oslogin --zone $ZONE --tunnel-through-iap

    gcloud compute scp $HOME/.ssh/id_rsa_for_local.pub $OSLOGIN_USERNAME@$CLIENT_NAME:.ssh/id_rsa_for_local.pub --zone $ZONE --tunnel-through-iap
    gcloud compute scp $HOME/.ssh/id_rsa_for_local $OSLOGIN_USERNAME@$CLIENT_NAME:.ssh/id_rsa_for_local --zone $ZONE --tunnel-through-iap

    # add the "local" SSH public key to the local authorized_keys file
    echo "Copying SSH keys to the server VM"
    SERVER_SSH_COMMAND="mkdir -p .ssh && chmod 700 .ssh && echo $(cat $HOME/.ssh/id_rsa_for_local.pub) >> .ssh/authorized_keys"
    gcloud compute ssh $OSLOGIN_USERNAME@$SERVER_NAME --zone $ZONE --tunnel-through-iap --command="$SERVER_SSH_COMMAND"  < /dev/null
    gcloud compute ssh $OSLOGIN_USERNAME@$SERVER_NAME --zone $ZONE --tunnel-through-iap --command="chmod 600 ~/.ssh/authorized_keys"  < /dev/null

    # copy the tester script to the VM
    echo "Copying tester.sh to the client VM"
    gcloud compute scp tester.sh $OSLOGIN_USERNAME@$CLIENT_NAME:tester.sh --zone $ZONE --tunnel-through-iap

    # run the tester script and capture the output to test-results.csv
    echo "Running the tester.sh script on the client VM"
    gcloud compute ssh $OSLOGIN_USERNAME@$CLIENT_NAME --zone $ZONE --tunnel-through-iap --command "./tester.sh" < /dev/null >> $TEST_RESULTS_FILE

    # delete the client and server VMs for this test
   if [ $DELETE_INSTANCES = "TRUE" ] ; then
        gcloud compute instances delete $CLIENT_NAME $SERVER_NAME --zone=$ZONE --quiet 
   fi

    echo "Finished test-case $TEST_NAME"
done
