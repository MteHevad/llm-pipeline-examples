#!/bin/bash -e
# Copyright 2022 Google LLC

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at

#     https://www.apache.org/licenses/LICENSE-2.0

# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
EXIT_CODE=0

_invoke_cluster_tool () {
  echo "Invoking cluster tool"
  echo PROJECT_ID $PROJECT_ID
  echo NAME_PREFIX $NAME_PREFIX
  echo ZONE $ZONE
  echo INSTANCE_COUNT $INSTANCE_COUNT
  echo GPU_COUNT $GPU_COUNT
  echo VM_TYPE $VM_TYPE
  echo ACCELERATOR_TYPE $ACCELERATOR_TYPE
  echo IMAGE_FAMILY_NAME $IMAGE_FAMILY_NAME
  echo IMAGE_NAME $IMAGE_NAME
  echo DISK_SIZE_GB $DISK_SIZE_GB
  echo DISK_TYPE $DISK_TYPE
  echo TERRAFORM_GCS_PATH $TERRAFORM_GCS_PATH
  echo VM_LOCALFILE_DEST_PATH $VM_LOCALFILE_DEST_PATH
  echo METADATA $METADATA
  echo LABELS $LABELS
  echo STARTUP_COMMAND $STARTUP_COMMAND
  echo ORCHESTRATOR_TYPE $ORCHESTRATOR_TYPE
  echo GCS_MOUNT_LIST $GCS_MOUNT_LIST
  echo NFS_FILESHARE_LIST $NFS_FILESHARE_LIST
  echo SHOW_PROXY_URL $SHOW_PROXY_URL
  echo MINIMIZE_TERRAFORM_LOGGING $MINIMIZE_TERRAFORM_LOGGING
  echo NETWORK_CONFIG $NETWORK_CONFIG
  echo ACTION $ACTION
  echo GKE_NODE_POOL_COUNT $GKE_NODE_POOL_COUNT
  echo GKE_NODE_COUNT_PER_NODE_POOL $GKE_NODE_COUNT_PER_NODE_POOL
  /usr/entrypoint.sh
}

if [[ -z $REGION ]]; then
  export REGION=${ZONE%-*}
fi
if [[ -z $INFERENCING_IMAGE_TAG ]]; then
  export INFERENCING_IMAGE_TAG=release
fi
if [[ -z $POD_MEMORY_LIMIT ]]; then
  export POD_MEMORY_LIMIT="16Gi"
fi
if [[ -z $KSA_NAME ]]; then
  export KSA_NAME="aiinfra-gke-sa"
fi
if [[ -z $USE_FASTER_TRANSFORMER ]]; then
  INFERENCE_IMAGE=gcr.io/llm-containers/predict-triton
  CONVERT_MODEL=1
fi
else
  INFERENCE_IMAGE=gcr.io/llm-containers/predict
fi
if [[ -z $INFERENCING_IMAGE_URI ]]; then
  export INFERENCING_IMAGE_URI=$INFERENCE_IMAGE
fi

if [[ -z $EXISTING_CLUSTER_ID ]]; then

  export SERVICE_ACCOUNT=$(gcloud config get account)
  export OS_LOGIN_USER=$(gcloud iam service-accounts describe ${SERVICE_ACCOUNT} | grep uniqueId | sed -e "s/.* '\(.*\)'/sa_\1/")

  echo User is ${OS_LOGIN_USER}

  export ACTION=CREATE
  export METADATA="{install-unattended-upgrades=\"false\",enable-oslogin=\"TRUE\",jupyter-user=\"${OS_LOGIN_USER}\",install-nvidia-driver=\"True\"}"
  export SHOW_PROXY_URL=no
  export LABELS="{gcpllm=\"$CLUSTER_PREFIX\"}"
  export MINIMIZE_TERRAFORM_LOGGING=true
  _invoke_cluster_tool

  echo "Provisioning cluster..."
  export EXISTING_CLUSTER_ID=${NAME_PREFIX}-gke
fi

# Get kubeconfig for cluster
gcloud container clusters get-credentials $EXISTING_CLUSTER_ID --region $REGION --project $PROJECT_ID

if [[ $CONVERT_MODEL -eq 1 ]]
  # Run convert image on cluster
  export CONVERT_JOB_ID=convert-$RANDOM
  envsubst < specs/convert.yml | kubectl apply -f -
  echo "Running 'convert' job on cluster."
  CONVERT_POD_ID=$(kubectl get pods -l job-name=$CONVERT_JOB_ID -o=json | jq -r '.items[0].metadata.name')
  kubectl wait --for=condition=Ready --timeout=10m pod/$CONVERT_POD_ID
  kubectl logs $CONVERT_POD_ID -f
  kubectl wait --for=condition=Complete --timeout=60m job/$CONVERT_JOB_ID

  export MODEL_SOURCE_PATH=$CONVERTED_MODEL_PATH
fi

# Run predict image on cluster
echo "Deploying predict image to cluster"
envsubst < specs/inference.yml | kubectl apply -f -
kubectl wait --for=condition=Ready --timeout=60m pod -l app=$MODEL_NAME

# Print urls to access the model
echo Exposed Node IPs from node 0 on the cluster:
ENDPOINTS=$(kubectl get nodes -o json | jq -r '.items[0].status.addresses[]')
echo $ENDPOINTS | jq -r '.'
INTERNAL_ENDPOINT=$(kubectl get nodes -o json | jq -r '.items[0].status.addresses[] | select(.type=="InternalIP") | .address | select(startswith("10."))')

echo NodePort for Flask:
FLASK_NODEPORT=$(kubectl get svc -o json | jq -r '.items[].spec | select(.selector.app=="$MODEL_NAME") | .ports[] | select(.name=="flask")')
echo $FLASK_NODEPORT | jq -r '.'

FLASK_PORT=$(echo $FLASK_NODEPORT | jq -r '.nodePort')

echo NodePort for Triton:
kubectl get svc -o json | jq -r '.items[].spec.ports[] | select(.name=="triton")'

echo "From a machine on the same VPC as this cluster you can call http://${INTERNAL_ENDPOINT}:${FLASK_PORT}/infer"

exit $EXIT_CODE
