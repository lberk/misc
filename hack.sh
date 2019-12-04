#!/usr/bin/env bash

#set -e

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

function mk_setup_env() {

strimzi_version=`curl https://github.com/strimzi/strimzi-kafka-operator/releases/latest |  awk -F 'tag/' '{print $2}' | awk -F '"' '{print $1}' 2>/dev/null`
serving_version="v0.10.0"
eventing_version="v0.10.0"
ISTIO_VERSION="1.1.7"
kube_version="v1.14.0"

MEMORY="$(minikube config view | awk '/memory/ { print $3 }')"
CPUS="$(minikube config view | awk '/cpus/ { print $3 }')"
DISKSIZE="$(minikube config view | awk '/disk-size/ { print $3 }')"
DRIVER="$(minikube config view | awk '/vm-driver/ { print $3 }')"
}

function header_text {
  echo "$header$*$reset"
}

function istio_without_sidecar() {
    header_text "Installing Istio without sidecar injection enabled."
    # A lighter template, with just pilot/gateway.
    # Based on install/kubernetes/helm/istio/values-istio-minimal.yaml
    helm template --namespace=istio-system \
         --set prometheus.enabled=false \
         --set mixer.enabled=false \
         --set mixer.policy.enabled=false \
         --set mixer.telemetry.enabled=false \
         --set pilot.sidecar=false \
         --set pilot.resources.requests.memory=128Mi \
         --set galley.enabled=false \
         --set global.useMCP=false \
         --set security.enabled=false \
         --set global.disablePolicyChecks=true \
         --set sidecarInjectorWebhook.enabled=false \
         --set global.proxy.autoInject=disabled \
         --set global.omitSidecarInjectorConfigMap=true \
         --set gateways.istio-ingressgateway.autoscaleMin=1 \
         --set gateways.istio-ingressgateway.autoscaleMax=2 \
         --set pilot.traceSampling=100 \
         install/kubernetes/helm/istio \
         > ./istio-lean.yaml

    kubectl apply -f istio-lean.yaml
}

function istio_with_sidecar() {
    header_text "Installing Istio with sidecar injection enabled."
    # A template with sidecar injection enabled.
    helm template --namespace=istio-system \
         --set sidecarInjectorWebhook.enabled=true \
         --set sidecarInjectorWebhook.enableNamespacesByDefault=true \
         --set global.proxy.autoInject=disabled \
         --set global.disablePolicyChecks=true \
         --set prometheus.enabled=false \
         --set mixer.adapters.prometheus.enabled=false \
         --set global.disablePolicyChecks=true \
         --set gateways.istio-ingressgateway.autoscaleMin=1 \
         --set gateways.istio-ingressgateway.autoscaleMax=2 \
         --set gateways.istio-ingressgateway.resources.requests.cpu=500m \
         --set gateways.istio-ingressgateway.resources.requests.memory=256Mi \
         --set pilot.autoscaleMin=2 \
         --set pilot.traceSampling=100 \
         install/kubernetes/helm/istio \
         > ./istio.yaml

    kubectl apply -f istio.yaml
 }

function setup_istio() {
    pushd
    export ISTIO_VERSION=1.1.7
    ISTIO_DIR=`mktemp -d istioXXX -p /tmp/`; cd $ISTIO_DIR
    header_text "Setting up Istio from ${ISTIO_DIR}"
    curl -L https://git.io/getLatestIstio | sh -
    cd istio-${ISTIO_VERSION}

    for i in install/kubernetes/helm/istio-init/files/crd*yaml; do
        kubectl apply -f ${i};
    done
    sleep 5
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
 name: istio-system
 labels:
   istio-injection: disabled
EOF
    while echo && kubectl get pods -n istio-system | grep -v -E "(Running|Completed|STATUS)"; do sleep 5; done
    istio_with_sidecar

    # Label the default namespace with istio-injection=enabled.
    header_text "Labeling default namespace w/ istio-injection=enabled"
    kubectl label namespace default istio-injection=enabled
    header_text "Waiting for istio to become ready"
    sleep 5; while echo && kubectl get pods -n istio-system | grep -v -E "(Running|Completed|STATUS)"; do sleep 5; done
    popd
}
function install_upstream_serving() {
    mk_setup_env
    kubectl apply --selector knative.dev/crd-install=true -f "https://github.com/knative/serving/releases/download/${serving_version}/serving.yaml"
    kubectl apply -f "https://github.com/knative/serving/releases/download/${serving_version}/serving.yaml"
    header_text "Waiting for Knative Serving to become ready"
    sleep 5; while echo && kubectl get pods -n knative-serving | grep -v -E "(Running|Completed|STATUS)"; do sleep 5; done

}

function mk_stop() {
    minikube delete
}
function mk_start() {
    mk_setup_env

    header_text             "Starting Knative on minikube!"
    header_text "Using Kubernetes Version:               ${kube_version}"
    header_text "Using Strimzi Version:                  ${strimzi_version}"
    header_text "Using Knative Serving Version:          ${serving_version}"
    header_text "Using Knative Eventing Version:         ${eventing_version}"
    header_text "Using Istio Version:                    ${ISTIO_VERSION}"

    minikube start --memory="${MEMORY:-16384}" --cpus="${CPUS:-6}" --kubernetes-version="${kube_version}" --vm-driver="${DRIVER:-kvm2}" --disk-size="${DISKSIZE:-30g}" --extra-config=apiserver.enable-admission-plugins="LimitRanger,NamespaceExists,NamespaceLifecycle,ResourceQuota,ServiceAccount,DefaultStorageClass,MutatingAdmissionWebhook"
    header_text "Waiting for core k8s services to initialize"
    sleep 5; while echo && kubectl get pods -n kube-system | grep -v -E "(Running|Completed|STATUS)"; do sleep 5; done

    header_text "Strimzi install"
    kubectl create namespace kafka
    curl -L "https://github.com/strimzi/strimzi-kafka-operator/releases/download/${strimzi_version}/strimzi-cluster-operator-${strimzi_version}.yaml" \
        | sed 's/namespace: .*/namespace: kafka/' \
        | kubectl -n kafka apply -f -

    header_text "Applying Strimzi Cluster file"
    kubectl -n kafka apply -f "https://raw.githubusercontent.com/strimzi/strimzi-kafka-operator/${strimzi_version}/examples/kafka/kafka-persistent-single.yaml"
    header_text "Waiting for Strimzi to become ready"
    sleep 5; while echo && kubectl get pods -n kafka | grep -v -E "(Running|Completed|STATUS)"; do sleep 5; done

    setup_istio

    install_upstream_serving

}

#header_text "Setting up Knative Eventing"
#kubectl apply --filename https://github.com/knative/eventing/releases/download/${eventing_version}/release.yaml
#kubectl apply --filename https://storage.googleapis.com/knative-nightly/eventing/latest/release.yaml

#header_text "Waiting for Knative Eventing to become ready"
#sleep 5; while echo && kubectl get pods -n knative-eventing | grep -v -E "(Running|Completed|STATUS)"; do sleep 5; done

