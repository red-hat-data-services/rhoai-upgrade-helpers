# Migration Script RBAC Permissions

This document lists the Kubernetes RBAC permissions required to run the migration scripts.

## Summary by Command

| Command | Permissions Level |
|---------|-------------------|
| `list` | Read-only |
| `pre-upgrade` | Read-only (backup only writes to local files) |
| `post-upgrade` | Read + Write |
| `post-upgrade --from-backup` | Read + Write |

## Detailed Permissions

### Core Resources (API Group: `""`)

| Resource | Verbs | Used By | Purpose |
|----------|-------|---------|---------|
| `namespaces` | `list` | All commands | List all namespaces when `--all-namespaces` is used |
| `pods` | `list` | All commands | Check pod status, wait for cluster readiness |
| `serviceaccounts` | `list`, `delete` | `post-upgrade` | Clean up old CodeFlare OAuth proxy ServiceAccounts |

### RayClusters (API Group: `ray.io`)

| Resource | Verbs | Used By | Purpose |
|----------|-------|---------|---------|
| `rayclusters` | `get` | All commands | Fetch individual RayCluster details |
| `rayclusters` | `list` | All commands | List RayClusters in namespace(s) |
| `rayclusters` | `patch` | `post-upgrade` | Update RayCluster spec (suspend/unsuspend) |
| `rayclusters` | `update` | `post-upgrade` | Replace RayCluster with cleaned spec |
| `rayclusters` | `create` | `post-upgrade --from-backup` | Create RayCluster from backup |
| `rayclusters` | `delete` | `post-upgrade --from-backup` | Delete existing RayCluster before restore |

### Gateway API Resources (API Group: `gateway.networking.k8s.io`)

| Resource | Verbs | Used By | Purpose |
|----------|-------|---------|---------|
| `httproutes` | `list` | `post-upgrade` | Find HTTPRoute for dashboard URL |
| `gateways` | `get` | `post-upgrade` | Get Gateway hostname for dashboard URL |

### OpenShift Routes (API Group: `route.openshift.io`)

| Resource | Verbs | Used By | Purpose |
|----------|-------|---------|---------|
| `routes` | `get` | `post-upgrade` | Fallback to get Gateway external hostname |

### DataScienceCluster (API Group: `datasciencecluster.opendatahub.io`)

| Resource | Verbs | Used By | Purpose |
|----------|-------|---------|---------|
| `datascienceclusters` | `list` | `pre-upgrade` | Verify CodeFlare operator is disabled |

### Authorization (API Group: `authorization.k8s.io`)

| Resource | Verbs | Used By | Purpose |
|----------|-------|---------|---------|
| `selfsubjectaccessreviews` | `create` | All commands | Check user permissions |

---

## RBAC YAML Examples

### Minimal Read-Only Role (for `list` and `pre-upgrade`)

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: raycluster-migration-readonly
rules:
  # Core resources
  - apiGroups: [""]
    resources: ["namespaces"]
    verbs: ["list"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["list"]
  
  # RayClusters
  - apiGroups: ["ray.io"]
    resources: ["rayclusters"]
    verbs: ["get", "list"]
  
  # DataScienceCluster (for pre-upgrade check)
  - apiGroups: ["datasciencecluster.opendatahub.io"]
    resources: ["datascienceclusters"]
    verbs: ["list"]
  
  # Permission checking
  - apiGroups: ["authorization.k8s.io"]
    resources: ["selfsubjectaccessreviews"]
    verbs: ["create"]
```

### Full Migration Role (for `post-upgrade` and `post-upgrade --from-backup`)

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: raycluster-migration-full
rules:
  # Core resources
  - apiGroups: [""]
    resources: ["namespaces"]
    verbs: ["list"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["list"]
  - apiGroups: [""]
    resources: ["serviceaccounts"]
    verbs: ["list", "delete"]
  
  # RayClusters - full access for migration
  - apiGroups: ["ray.io"]
    resources: ["rayclusters"]
    verbs: ["get", "list", "create", "update", "patch", "delete"]
  
  # Gateway API - for dashboard URL discovery
  - apiGroups: ["gateway.networking.k8s.io"]
    resources: ["httproutes"]
    verbs: ["list"]
  - apiGroups: ["gateway.networking.k8s.io"]
    resources: ["gateways"]
    verbs: ["get"]
  
  # OpenShift Routes - fallback for Gateway hostname
  - apiGroups: ["route.openshift.io"]
    resources: ["routes"]
    verbs: ["get"]
  
  # DataScienceCluster (for pre-upgrade check)
  - apiGroups: ["datasciencecluster.opendatahub.io"]
    resources: ["datascienceclusters"]
    verbs: ["list"]
  
  # Permission checking
  - apiGroups: ["authorization.k8s.io"]
    resources: ["selfsubjectaccessreviews"]
    verbs: ["create"]
```

### Namespace-Scoped Role (if not using `--all-namespaces`)

If you only need to migrate clusters in specific namespaces, you can use a `Role` instead of `ClusterRole`:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: raycluster-migration
  namespace: my-namespace  # Change to your namespace
rules:
  # Core resources
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["list"]
  - apiGroups: [""]
    resources: ["serviceaccounts"]
    verbs: ["list", "delete"]
  
  # RayClusters
  - apiGroups: ["ray.io"]
    resources: ["rayclusters"]
    verbs: ["get", "list", "create", "update", "patch", "delete"]
  
  # Gateway API
  - apiGroups: ["gateway.networking.k8s.io"]
    resources: ["httproutes"]
    verbs: ["list"]
  - apiGroups: ["gateway.networking.k8s.io"]
    resources: ["gateways"]
    verbs: ["get"]
  
  # OpenShift Routes
  - apiGroups: ["route.openshift.io"]
    resources: ["routes"]
    verbs: ["get"]
```

**Note:** When using namespace-scoped roles, you'll also need a `ClusterRole` for:
- `namespaces` (list) - only if using `--all-namespaces`
- `datascienceclusters` (list) - cluster-scoped resource
- `selfsubjectaccessreviews` (create) - cluster-scoped resource

### RoleBinding Example

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: raycluster-migration-binding
subjects:
  - kind: User
    name: migration-user
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: raycluster-migration-full
  apiGroup: rbac.authorization.k8s.io
```

---

## Permission Check

The script includes a built-in permission check. Run with `--check-permissions` to verify:

```bash
python ray_cluster_migration.py pre-upgrade --namespace my-ns --check-permissions
```

This will test if you have the required permissions before attempting any operations.

---

## Notes

1. **ServiceAccount Deletion**: The `post-upgrade` command deletes old CodeFlare OAuth proxy ServiceAccounts (pattern: `{cluster}-oauth-proxy-*`). This requires `delete` permission on `serviceaccounts`.

2. **Gateway API**: HTTPRoute and Gateway permissions are only needed if you want the script to output the dashboard URL after migration. The migration itself will succeed without these permissions.

3. **OpenShift Routes**: Route read permission is a fallback for getting the external hostname when the Gateway doesn't have a hostname in its spec.

4. **DataScienceCluster**: This permission is only needed for the `pre-upgrade` safety check that verifies CodeFlare operator is disabled. You can skip this check with `--skip-dsc-check` if you don't have permission.
