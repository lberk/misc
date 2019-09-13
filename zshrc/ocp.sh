#!/usr/bin/env sh

ocp_ensure_env()
{
    command -v oc >/dev/null 2>&1 || return 1
    CONFIG_DIR=${CONFIG_DIR:-"$(whoami)-dev"}
    INSTALLER_DIR=${INSTALLER_DIR:-"${GOPATH}/src/github.com/openshift/installer/"}
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
