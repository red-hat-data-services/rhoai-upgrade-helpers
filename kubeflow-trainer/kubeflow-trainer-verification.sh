#!/usr/bin/env bash
set -euo pipefail

trap 'echo "❌ Verification failed. See the output above for details."' ERR

oc create ns test-kfto-upgrade
oc apply -f - <<'EOF'
apiVersion: kubeflow.org/v1
kind: PyTorchJob
metadata:
  name: pytorch-hello-world
  namespace: test-kfto-upgrade
spec:
  pytorchReplicaSpecs:
    Master:
      replicas: 1
      restartPolicy: OnFailure
      template:
        spec:
          containers:
            - name: pytorch
              image: registry.redhat.io/rhoai/odh-training-cuda128-torch28-py312-rhel9:v3.3
              command:
                - python
                - -c
                - "print('Hello World')"
EOF

oc wait --for=condition=PodScheduled pod/pytorch-hello-world-master-0 -n test-kfto-upgrade --timeout=300s
oc delete pytorchjob/pytorch-hello-world -n test-kfto-upgrade
oc delete ns test-kfto-upgrade

echo "✅ Kubeflow Training Operator verification completed successfully."