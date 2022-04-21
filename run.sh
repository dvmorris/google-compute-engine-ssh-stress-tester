#! /bin/bash

# generate an SSH keypair locally
rm -rf $HOME/.ssh/id_rsa_test*
ssh-keygen -b 2048 -t rsa -f $HOME/.ssh/id_rsa_test -q -N ""

# add the public key to the user profile's OSLogin ssh-keys object
# https://cloud.google.com/compute/docs/connect/add-ssh-keys#os-login
gcloud compute os-login ssh-keys add --key-file=$HOME/.ssh/id_rsa_test.pub

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
echo "test-name,enable-oslogin,machine-type,zone,vm-image,sshd-max-startups,paralell-num-workers,parallel-num-iterations,denied-count,reset-count,closed-count,failed-count,load-average-count,log-lines-count,parallel-runtime, delete-instances" > $TEST_RESULTS_FILE

echo "Test case file: $TEST_CASE_FILE"

# loop over test-cases.csv
exec < $TEST_CASE_FILE
read header
while IFS="," read -r TEST_NAME VPC_NETWORK SUBNET NETWORK_TAG ENABLE_OSLOGIN MACHINE_TYPE ZONE VM_IMAGE SSHD_MAX_STARTUPS PARALLEL_NUM_WORKERS PARALLEL_NUM_ITERATIONS DELETE_INSTANCES
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
        --metadata=enable-oslogin=$ENABLE_OSLOGIN,sshd-max-startups=$SSHD_MAX_STARTUPS,startup-script='#! /bin/bash
getMetadataValue() {
curl -fs http://metadata/computeMetadata/v1/$1 \
    -H "Metadata-Flavor: Google"
}

SSHD_MAX_STARTUPS=`getMetadataValue instance/attributes/sshd-max-startups`

# install ops agent
curl -sSO https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh
sudo bash add-google-cloud-ops-agent-repo.sh --also-install
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
        --metadata=^@^enable-oslogin=$ENABLE_OSLOGIN@server-name=$SERVER_NAME@parallel-num-iterations=$PARALLEL_NUM_ITERATIONS@parallel-num-workers=$PARALLEL_NUM_WORKERS@sshd-max-startups=$SSHD_MAX_STARTUPS \
        --no-user-output-enabled
    
    # TODO wait for the client to have SSH access available, but for now, just sleep for 35 seconds, as that should take care of most edge cases
    # TODO ... gcloud compute --verbosity error --ZONE $ZONE ssh $CLIENT_NAME --tunnel-through-iap -- "echo instance now up" -o StrictHostKeyChecking=no
    sleep 35

    # copy the SSH key to the client VM
    export CLOUDSDK_PYTHON_SITEPACKAGES=1
    gcloud compute ssh $CLIENT_NAME --zone $ZONE --tunnel-through-iap --command="mkdir -p .ssh && chmod 700 .ssh"  < /dev/null
    gcloud compute scp $HOME/.ssh/id_rsa_test.pub $CLIENT_NAME:.ssh/id_rsa_test.pub --zone $ZONE --tunnel-through-iap
    gcloud compute scp $HOME/.ssh/id_rsa_test $CLIENT_NAME:.ssh/id_rsa_test --zone $ZONE --tunnel-through-iap

    # if OS Login is disabled, create an authorized_keys files on the server VM
    if [ $ENABLE_OSLOGIN = "FALSE" ] ; then
        gcloud compute ssh $SERVER_NAME --zone $ZONE --tunnel-through-iap --command="mkdir -p .ssh && chmod 700 .ssh"  < /dev/null
        gcloud compute scp $HOME/.ssh/id_rsa_test.pub $SERVER_NAME:.ssh/authorized_keys --zone $ZONE --tunnel-through-iap
    fi

    # copy the tester script to the VM
    gcloud compute scp tester.sh $CLIENT_NAME:tester.sh --zone $ZONE --tunnel-through-iap

    # run the tester script and capture the output to test-results.csv
    gcloud compute ssh $CLIENT_NAME --zone $ZONE --tunnel-through-iap --command "./tester.sh" < /dev/null >> $TEST_RESULTS_FILE

    # delete the client and server VMs for this test
   if [ $DELETE_INSTANCES = "TRUE" ] ; then
        gcloud compute instances delete $CLIENT_NAME $SERVER_NAME --zone=$ZONE --quiet 
   fi

    echo "Finished test-case $TEST_NAME"
done
