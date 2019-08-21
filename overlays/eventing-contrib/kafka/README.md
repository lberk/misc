# Usage

NOTE: This assumes a tree structure similar to that found in
[eventing-contrib](https://github.com/knative/eventing-contrib/tree/b6013ae3ccf2de202ca1b2fb576ae53e7e810bf8).

Using `channel` as an example. Place `channel/kustomization.yaml` in your local
[eventing-contrib/kafka/channel](https://github.com/knative/eventing-contrib/tree/b6013ae3ccf2de202ca1b2fb576ae53e7e810bf8/kafka/channel)
directory.

```shell
cp channel/kustomization.yaml $GOPATH/src/knative.dev/eventing-contrib/kafka/channel/
```

Likewise with the overlays:

```shell
cp -r channel/overlays $GOPATH/src/knative.dev/eventing-contrib/kafka/channel/
```

To apply the modified `yaml`:

```shell
cd $GOPATH/src/knative.dev/eventing-contrib/kafka/channel
kustomize build | ko apply -f -
```
