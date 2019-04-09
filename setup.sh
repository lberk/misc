#!/usr/bin/env bash

set -e

# Turn colors in this script off by setting the NO_COLOR variable in your
# environment to any value:
#
# $ NO_COLOR=1 test.sh
NO_COLOR=${NO_COLOR:-""}
if [ -z "$NO_COLOR" ]; then
  header=$'\e[1;33m'
  reset=$'\e[0m'
else
  header=''
  reset=''
fi

strimzi_version=`curl https://github.com/strimzi/strimzi-kafka-operator/releases/latest |  awk -F 'tag/' '{print $2}' | awk -F '"' '{print $1}' 2>/dev/null`
serving_version="0.4.1"
eventing_version="0.4.1"
eventing_sources_version="0.4.1"
istio_version="v0.4.0"
kube_version="v1.12.1"

MEMORY="$(minikube config view | awk '/memory/ { print $3 }')"
CPUS="$(minikube config view | awk '/cpus/ { print $3 }')"
DISKSIZE="$(minikube config view | awk '/disk-size/ { print $3 }')"
DRIVER="$(minikube config view | awk '/vm-driver/ { print $3 }')"

function header_text {
  echo "$header$*$reset"
}

header_text             "Starting Knative on minikube!"
header_text "Using Kubernetes Version:               ${kube_version}"
header_text "Using Strimzi Version:                  ${strimzi_version}"
header_text "Using Knative Serving Version:          ${serving_version}"
header_text "Using Knative Eventing Version:         ${eventing_version}"
header_text "Using Knative Eventing Sources Version: ${eventing_sources_version}"
header_text "Using Istio Version:                    ${istio_version}"

minikube start --memory="${MEMORY:-12288}" --cpus="${CPUS:-4}" --kubernetes-version=${kube_version} --vm-driver="${DRIVER:-kvm2}" --disk-size="${DISKSIZE:-30g}" --extra-config=apiserver.enable-admission-plugins="LimitRanger,NamespaceExists,NamespaceLifecycle,ResourceQuota,ServiceAccount,DefaultStorageClass,MutatingAdmissionWebhook"

header_text "Strimzi install"
kubectl create namespace kafka
curl -L https://github.com/strimzi/strimzi-kafka-operator/releases/download/${strimzi_version}/strimzi-cluster-operator-${strimzi_version}.yaml \
  | sed 's/namespace: .*/namespace: kafka/' \
  | kubectl -n kafka apply -f -

header_text "Applying Strimzi Cluster file"
kubectl -n kafka apply -f "https://raw.githubusercontent.com/strimzi/strimzi-kafka-operator/${strimzi_version}/examples/kafka/kafka-persistent.yaml"
#kubectl apply -f https://gist.githubusercontent.com/matzew/fdd95efc2050edd3ea6e76b56e8f50e3/raw/ec40730f476c1c98a30818931f6233f8c1941c59/exposed-kafka.yaml -n kafka
header_text "Waiting for Strimzi to become ready"
sleep 5; while echo && kubectl get pods -n kafka | grep -v -E "(Running|Completed|STATUS)"; do sleep 5; done

header_text "Setting up istio"
kubectl apply --filename "https://github.com/knative/serving/releases/download/${istio_version}/istio-crds.yaml" &&
    curl -L "https://github.com/knative/serving/releases/download/${istio_version}/istio.yaml" \
        | sed 's/LoadBalancer/NodePort/' \
        | kubectl apply --filename -

# Label the default namespace with istio-injection=enabled.
header_text "Labeling default namespace w/ istio-injection=enabled"
kubectl label namespace default istio-injection=enabled
header_text "Waiting for istio to become ready"
sleep 5; while echo && kubectl get pods -n istio-system | grep -v -E "(Running|Completed|STATUS)"; do sleep 5; done

header_text "Setting up Knative Serving"
curl -L "https://raw.githubusercontent.com/openshift-knative/knative-serving-operator/master/deploy/resources/knative-serving-${serving_version}.yaml" \
  | sed 's/LoadBalancer/NodePort/' \
  | kubectl apply --filename -

header_text "Waiting for Knative Serving to become ready"
sleep 5; while echo && kubectl get pods -n knative-serving | grep -v -E "(Running|Completed|STATUS)"; do sleep 5; done


header_text "Setting up Knative Eventing"
kubectl apply --filename https://raw.githubusercontent.com/openshift-knative/knative-eventing-operator/master/deploy/resources/knative-eventing-${eventing_sources_version}.yaml
kubectl apply --filename https://raw.githubusercontent.com/openshift-knative/knative-eventing-operator/master/deploy/resources/knative-eventing-sources-${eventing_sources_version}.yaml

header_text "Waiting for Knative Eventing to become ready"
sleep 5; while echo && kubectl get pods -n knative-eventing | grep -v -E "(Running|Completed|STATUS)"; do sleep 5; done
sleep 5; while echo && kubectl get pods -n knative-sources | grep -v -E "(Running|Completed|STATUS)"; do sleep 5; done
