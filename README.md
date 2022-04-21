# Google Compute Engine SSH Stress Tester

The code in this repository is a framework for testing the capacity for different kinds of Google Compute Engine VMs to accept a high volume of incoming SSH connections simultaneously. The framework currently supports the following variables for testing different kinds of VMs:

- enable-oslogin - TRUE or FALSE
- machine-type - n1-standard-16, n1-standard-8, etc.
- zone - us-central1-a, etc.
- vm-image - projects/centos-cloud/global/images/centos-7-v20220406 (NOTE: the code currently only supports RedHat based images (CentOS, etc.))
- sshd-max-startups - the value to use for the server VM's sshd_config "MaxStartups" setting - <https://stackoverflow.com/a/4812505>
- paralell-num-workers - the number of parallel jobs to initiate ssh connections to the sshd host VM simultaneously <https://www.gnu.org/software/parallel/man.html>
- parallel-num-iterations - the number of times to run the parallel command - <https://www.gnu.org/software/parallel/parallel_tutorial.html#input-sources>

Additional properties provided in the test case allow for configuring in existing networks with existing firewall rules:

- vpc-network
- network-tag

The file *test-cases.csv* contains a series of sample test cases that can be customized using a spreadsheet editor that can export the data back to CSV format.

## Pre-requisities

- A GCP Organization with a Valid Billing Account
- A Cloud Identity user with access to create a project and attach it to a billing account, or user with the following IAM roles on an existing project:
  - Editor
  - Service Account User
  - Compute OS Login

## Initial GCP Project Setup

- Create Project manually or via gcloud using the following code snippet:

```bash
GOOGLE_CLOUD_PROJECT=<project-id>
GCP_BILLING_ACCOUNT_ID=<billing-account-id>
gcloud projects create $GOOGLE_CLOUD_PROJECT
gcloud beta billing projects link $GOOGLE_CLOUD_PROJECT --billing-account=$GCP_BILLING_ACCOUNT_ID

gcloud config set project $GOOGLE_CLOUD_PROJECT
```

### Setup Compute Engine Service Account IAM Permissions

This test framework relies on the default Compute Engine Service account. This account needs the following IAM roles to execute without errors:

- roles/monitoring.metricWriter - to enable the Cloud Ops Agent to monitor each VM - <https://cloud.google.com/monitoring/access-control#mon_roles_desc>
- roles/logging.logWriter - to enable the Cloud Operations Logging API calls from each VM - <https://cloud.google.com/logging/docs/access-control#permissions_and_roles>
- roles/compute.osLogin - to allow for SSH connectivity from the client VM to the server VM - <https://cloud.google.com/compute/docs/oslogin/set-up-oslogin#grant-iam-roles>

```bash
GOOGLE_CLOUD_PROJECT=$(gcloud projects list --filter="$(gcloud config get-value project)" --format="value (PROJECT_ID)")
GOOGLE_CLOUD_PROJECT_NUMBER=$(gcloud projects list --filter="$(gcloud config get-value project)" --format="value (PROJECT_NUMBER)")

gcloud projects add-iam-policy-binding $GOOGLE_CLOUD_PROJECT \
    --member=serviceAccount:$GOOGLE_CLOUD_PROJECT_NUMBER-compute@developer.gserviceaccount.com \
    --role=roles/monitoring.metricWriter

gcloud projects add-iam-policy-binding $GOOGLE_CLOUD_PROJECT \
    --member=serviceAccount:$GOOGLE_CLOUD_PROJECT_NUMBER-compute@developer.gserviceaccount.com \
    --role=roles/logging.logWriter

gcloud projects add-iam-policy-binding $GOOGLE_CLOUD_PROJECT \
    --member=serviceAccount:$GOOGLE_CLOUD_PROJECT_NUMBER-compute@developer.gserviceaccount.com \
    --role=roles/compute.osLogin

# enable Google APIs
gcloud services enable \
    compute.googleapis.com \
    iap.googleapis.com \
    monitoring.googleapis.com
```

### Setup VPC Network and Firewall Rules

```bash
REGION=us-central1
VPC_NETWORK=default
NETWORK_TAG=parallel-ssh-test

# create default VPC and subnets
gcloud compute networks create $VPC_NETWORK

# create firewall rule to allow VM-VM TCP traffic
gcloud compute firewall-rules \
    create allow-tcp-internal \
    --direction=INGRESS \
    --priority=1000 \
    --network=$VPC_NETWORK \
    --action=ALLOW \
    --rules=tcp:22 \
    --source-ranges=0.0.0.0/0 \
    --target-tags=$NETWORK_TAG \
    --enable-logging

# create firewall rule to allow IAP connections (SSH button in the Cloud Console, gcloud compute ssh --tunnel-through-iap, etc.)
gcloud compute firewall-rules \
  create allow-ssh-ingress-from-iap \
  --direction=INGRESS \
  --action=allow \
  --rules=tcp:22 \
  --source-ranges=35.235.240.0/20 \
  --enable-logging

# Cloud NAT and Cloud Router to allow VMs without public IPs to have access to the internet, 
# to enable installation of the Cloud Ops monitoring agent, and GNU parallel
gcloud compute routers create $VPC_NETWORK \
    --project=$GOOGLE_CLOUD_PROJECT \
    --network=$VPC_NETWORK \
    --region=$REGION

gcloud compute routers nats create $VPC_NETWORK \
    --router=$VPC_NETWORK \
    --region=$REGION \
    --auto-allocate-nat-external-ips \
    --nat-all-subnet-ip-ranges \
    --enable-logging
```

## Setup Test Cases in a Google Sheet

- Create a Google Sheet and import *test-cases.csv* into it
- Edit/Add test cases as needed
- Download the sheet as a CSV and place in this folder in a file called test-cases.csv

## Test Scripts

This test script can be executed from a Cloud Shell session where the desired GCP Project is already active

```bash
./run.sh  
```
