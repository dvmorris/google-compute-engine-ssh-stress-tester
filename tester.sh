#! /bin/bash

# install parallel command
sudo yum -y install parallel > /dev/null 2>&1
# install ops agent
curl -sSO https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh
sudo bash add-google-cloud-ops-agent-repo.sh --also-install  > /dev/null 2>&1

getMetadataValue() {
  curl -fs http://metadata/computeMetadata/v1/$1 \
    -H "Metadata-Flavor: Google"
}

# OOB Metadata Attributes
TEST_NAME=`getMetadataValue instance/name`
ENABLE_OSLOGIN=`getMetadataValue instance/attributes/enable-oslogin`
MACHINE_TYPE=`getMetadataValue instance/machine-type`
ZONE=`getMetadataValue instance/zone`
VM_IMAGE=`getMetadataValue instance/image`
GOOGLE_CLOUD_PROJECT=`getMetadataValue project/project-id`

# Custom Metadata Attributes
SSHD_MAX_STARTUPS=`getMetadataValue instance/attributes/sshd-max-startups`
PARALLEL_NUM_WORKERS=`getMetadataValue instance/attributes/parallel-num-workers`
PARALLEL_NUM_ITERATIONS=`getMetadataValue instance/attributes/parallel-num-iterations`
SERVER_NAME=`getMetadataValue instance/attributes/server-name`
TEST_REPETITIONS=`getMetadataValue instance/attributes/test-repetitions`

for i in $(seq 00 $TEST_REPETITIONS)
do
    # run the tests with the oslogin SSH key
    # ssh -o "StrictHostKeyChecking no" -vvv -i ~/.ssh/id_rsa_for_oslogin ${SERVER_NAME} uptime
    { time parallel -kj${PARALLEL_NUM_WORKERS} --tag "ssh -o \"StrictHostKeyChecking no\" -i ~/.ssh/id_rsa_for_oslogin ${SERVER_NAME} uptime" ::: $(seq 00 $PARALLEL_NUM_ITERATIONS) > $TEST_NAME.log 2>&1 ; } 2> time.txt

    # gather test results
    OUTPUT_DATA="${TEST_NAME},oslogin-repetition-${i},${ENABLE_OSLOGIN},${MACHINE_TYPE},${ZONE},${VM_IMAGE},${SSHD_MAX_STARTUPS},${PARALLEL_NUM_WORKERS},${PARALLEL_NUM_ITERATIONS}"
    OUTPUT_DATA="${OUTPUT_DATA},$(grep denied *.log | wc -l)"
    OUTPUT_DATA="${OUTPUT_DATA},$(grep  reset *.log | wc -l)"
    OUTPUT_DATA="${OUTPUT_DATA},$(grep closed *.log | wc -l)"
    OUTPUT_DATA="${OUTPUT_DATA},$(grep failed *.log | wc -l)"
    OUTPUT_DATA="${OUTPUT_DATA},$(grep 'load average:' *.log | wc -l)"
    OUTPUT_DATA="${OUTPUT_DATA},$(cat *.log | wc -l)"
    OUTPUT_DATA="${OUTPUT_DATA},$(grep real time.txt)"

    # output test results
    echo $OUTPUT_DATA

    # run the tests with the local SSH key
    { time parallel -kj${PARALLEL_NUM_WORKERS} --tag "ssh -o \"StrictHostKeyChecking no\" -i ~/.ssh/id_rsa_for_local ${SERVER_NAME} uptime" ::: $(seq 00 $PARALLEL_NUM_ITERATIONS) > $TEST_NAME.log 2>&1 ; } 2> time.txt

    # gather test results
    OUTPUT_DATA="${TEST_NAME},non-oslogin-repetition-${i},${ENABLE_OSLOGIN},${MACHINE_TYPE},${ZONE},${VM_IMAGE},${SSHD_MAX_STARTUPS},${PARALLEL_NUM_WORKERS},${PARALLEL_NUM_ITERATIONS}"
    OUTPUT_DATA="${OUTPUT_DATA},$(grep denied *.log | wc -l)"
    OUTPUT_DATA="${OUTPUT_DATA},$(grep  reset *.log | wc -l)"
    OUTPUT_DATA="${OUTPUT_DATA},$(grep closed *.log | wc -l)"
    OUTPUT_DATA="${OUTPUT_DATA},$(grep failed *.log | wc -l)"
    OUTPUT_DATA="${OUTPUT_DATA},$(grep 'load average:' *.log | wc -l)"
    OUTPUT_DATA="${OUTPUT_DATA},$(cat *.log | wc -l)"
    OUTPUT_DATA="${OUTPUT_DATA},$(grep real time.txt)"

    # output test results
    echo $OUTPUT_DATA
done
