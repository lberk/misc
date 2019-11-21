#!/usr/bin/env sh

ocp_ensure_env()
{
    command -v oc >/dev/null 2>&1 || return 1
    CONFIG_DIR=${CONFIG_DIR:-"$(whoami)-dev"}
    INSTALLER_DIR=${INSTALLER_DIR:-"${GOPATH}/src/github.com/openshift/installer/"}
    OLM_NAMESPACE=${OLM_NAMESPACE:-"openshift-marketplace"}
    OS_BIN=${OS_BIN:-"bin/openshift-install"}

}
ocp_start() 
{
    ocp_ensure_env
    cd "$INSTALLER_DIR" || return 1

    # What if we override the default? Needs to be full path?
    if [ ! -f "${OS_BIN}" ]; then
        hack/build.sh || return 1
    fi

    ${OS_BIN} --dir="${CONFIG_DIR}" destroy cluster --log-level=debug && rm -rf "${CONFIG_DIR:?}/*"
    cp -f initial/install-config.yaml "${CONFIG_DIR}" && \
        ${OS_BIN} --dir="${CONFIG_DIR}" create cluster --log-level=debug

    export KUBECONFIG="${INSTALLER_DIR}/${CONFIG_DIR}/auth/kubeconfig"
    cd - || return 1

    ocp_scale_up
}

ocp_scale_up()
{
    ocp_scale 2
}

ocp_scale_down()
{
    ocp_scale 1
}

ocp_scale()
{
    # Scale workers so knative-serving actually works
    command -v oc >/dev/null 2>&1 || return 1
    WORKER_HASH=$(oc get machinesets -n openshift-machine-api -o jsonpath='{.items[].metadata.name}' | cut -f3 -d-)
    REPLICAS=${1:-"2"}

    for i in a b c; do
        oc scale --replicas="$REPLICAS" machineset "$(whoami)-dev-${WORKER_HASH}-worker-us-east-1${i}" -n openshift-machine-api
    done
    oc get machinesets -n openshift-machine-api
}

ocp_stop() {

    ocp_ensure_env
    cd "$INSTALLER_DIR" || return 1
    if [ ! -f "${OS_BIN}" ]; then
        hack/build.sh || return 1
    fi
    ${OS_BIN} --dir="${CONFIG_DIR}" destroy cluster --log-level=debug
    cd - || return 1
    return 0
}
strimzi_setup() {

    ocp_ensure_env
    export KUBECONFIG=${KUBECONFIG:-"${INSTALLER_DIR}/${CONFIG_DIR}/auth/kubeconfig"} || return 1
    # Add kafka ns check here
    kubectl create ns kafka
    strimzi_version=`curl -L https://github.com/strimzi/strimzi-kafka-operator/releases/latest |  awk -F 'tag/' '{print $2}' | awk -F '"' '{print $1}' 2>/dev/null | tr -d '[:space:]' | cut -f1 -d'&'`
    kubectl -n kafka apply -f "https://raw.githubusercontent.com/strimzi/strimzi-kafka-operator/${strimzi_version}/examples/kafka/kafka-persistent-single.yaml"

}

maistra_setup(){
    ocp_ensure_env
    export KUBECONFIG=${KUBECONFIG:-"${INSTALLER_DIR}/${CONFIG_DIR}/auth/kubeconfig"} || return 1
    cat <<-EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: istio-system
---
apiVersion: maistra.io/v1
kind: ServiceMeshControlPlane
metadata:
  name: basic-install
  namespace: istio-system
spec:
  istio:
    global:
      multitenant: true
      proxy:
        autoInject: disabled
      omitSidecarInjectorConfigMap: true
      disablePolicyChecks: false
      defaultPodDisruptionBudget:
        enabled: false
    istio_cni:
      enabled: true
    gateways:
      istio-ingressgateway:
        autoscaleEnabled: false
        type: LoadBalancer
      istio-egressgateway:
        enabled: false
      cluster-local-gateway:
        autoscaleEnabled: false
        enabled: true
        labels:
          app: cluster-local-gateway
          istio: cluster-local-gateway
        ports:
          - name: status-port
            port: 15020
          - name: http2
            port: 80
            targetPort: 8080
          - name: https
            port: 443
    mixer:
      enabled: false
      policy:
        enabled: false
      telemetry:
        enabled: false
    pilot:
      autoscaleEnabled: false
      sidecar: false
    kiali:
      enabled: false
    tracing:
      enabled: false
    prometheus:
      enabled: false
    grafana:
      enabled: false
    sidecarInjectorWebhook:
      enabled: false


---
apiVersion: maistra.io/v1
kind: ServiceMeshMemberRoll
metadata:
  name: default
  namespace: istio-system
spec:
  members:
  - knative-serving
  - knative-eventing
  - knative-sources
  - default
  - kafka
EOF
}

knative_serving_setup() {
    ocp_ensure_env
    export KUBECONFIG=${KUBECONFIG:-"${INSTALLER_DIR}/${CONFIG_DIR}/auth/kubeconfig"} || return 1
    cat <<-EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
 name: knative-serving
---
apiVersion: serving.knative.dev/v1alpha1
kind: KnativeServing
metadata:
 name: knative-serving
 namespace: knative-serving
EOF
}

deploy_serverless_operator(){
    ocp_ensure_env
    export KUBECONFIG=${KUBECONFIG:-"${INSTALLER_DIR}/${CONFIG_DIR}/auth/kubeconfig"} || return 1
    SERVERLESS_NAME=${SERVERLESS_NAME:-"serverless-operator"}

  cat <<-EOF | kubectl apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${NAME}-subscription
  namespace: openshift-operators
spec:
  source: ${NAME}
  sourceNamespace: $OLM_NAMESPACE
  name: ${NAME}
  channel: techpreview
EOF
}

deploy_strimzi_operator(){
    ocp_ensure_env
    export KUBECONFIG=${KUBECONFIG:-"${INSTALLER_DIR}/${CONFIG_DIR}/auth/kubeconfig"} || return 1
    SERVERLESS_NAME=${SERVERLESS_NAME:-"strimzi-kafka-operator"}
  cat <<-EOF | kubectl apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${NAME}-subscription
  namespace: openshift-operators
spec:
  source: ${NAME}
  sourceNamespace: $OLM_NAMESPACE
  name: ${NAME}
  channel: stable
EOF
}

deploy_maistra_operator(){
    ocp_ensure_env
    export KUBECONFIG=${KUBECONFIG:-"${INSTALLER_DIR}/${CONFIG_DIR}/auth/kubeconfig"} || return 1
    SERVERLESS_NAME=${SERVERLESS_NAME:-"maistraoperator.v1.0.0"}
  cat <<-EOF | kubectl apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${NAME}-subscription
  namespace: openshift-operators
spec:
  source: ${NAME}
  sourceNamespace: $OLM_NAMESPACE
  name: ${NAME}
  channel: 1.0
EOF
}


deploy_operators(){
    ocp_ensure_env
    export KUBECONFIG=${KUBECONFIG:-"${INSTALLER_DIR}/${CONFIG_DIR}/auth/kubeconfig"} || return 1
    deploy_strimzi_operator
    deploy_serverless_operator
    deploy_maistra_operator
}

knative_setup(){
    ocp_ensure_env
    ocp_start
    export KUBECONFIG=${KUBECONFIG:-"${INSTALLER_DIR}/${CONFIG_DIR}/auth/kubeconfig"} || return 1
    deploy_operators
    maistra_setup
    knative_serving_setup
}
