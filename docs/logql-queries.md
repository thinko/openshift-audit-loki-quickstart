# Audit LogQL cheat sheet

Queries assume OpenShift Logging **ViaQ** on LokiStack tenant `audit`. In the
console choose **Observe → Logs → Audit**. Field names come from the
kube-apiserver audit JSON, usually nested inside the ViaQ `message` field;
`| json` unpacks it.

Adjust the time range before running wide queries. Prefer a label matcher
(`{log_type="audit"}`) plus a line filter before `| json`.

## Who deleted a resource

```logql
{log_type="audit"} | json | verb="delete"
```

Narrow by object:

```logql
{log_type="audit"}
  |= `"verb":"delete"`
  | json
  | objectRef_resource="secrets"
```

ConfigMap probe from `scripts/test-attribution.sh`:

```logql
{log_type="audit"} |= `audit-loki-probe-` | json
```

Confirm `user.username` matches `oc whoami`.

## RBAC changes and ClusterRoleBinding modifications

ClusterRole / Role writes:

```logql
{log_type="audit"}
  | json
  | verb=~"create|update|patch|delete"
  | objectRef_resource=~"clusterroles|roles|clusterrolebindings|rolebindings"
```

A specific binding name:

```logql
{log_type="audit"}
  |= `"resource":"clusterrolebindings"`
  | json
  | objectRef_name="cluster-admin"
```

## Failed authentication and 401 / 403 responses

Edge filters keep 401 and 403 (they are not in the default omit list).

```logql
{log_type="audit"} | json | responseStatus_code=~"401|403"
```

Forbidden writes:

```logql
{log_type="audit"}
  | json
  | verb=~"create|update|patch|delete"
  | responseStatus_code="403"
```

## Privilege escalation (`impersonate`)

```logql
{log_type="audit"} | json | verb="impersonate"
```

Impersonated user (when present):

```logql
{log_type="audit"}
  |= `"verb":"impersonate"`
  | json
  | line_format "{{.user_username}} impersonated {{.impersonatedUser_username}}"
```

## High-value mutating verbs only

The pipeline already drops `get`/`list`/`watch`. This query is a second check
in the UI:

```logql
{log_type="audit"} | json | verb=~"create|update|patch|delete"
```

## Actor is a human user (not a service account)

```logql
{log_type="audit"}
  | json
  | verb=~"create|update|patch|delete"
  | user_username !~ `^system:serviceaccount:`
```

## Secret and ConfigMap writes

```logql
{log_type="audit"}
  | json
  | verb=~"create|update|patch|delete"
  | objectRef_resource=~"secrets|configmaps"
```

Metadata-level events include `objectRef` but **not** Secret values.

## Field name variants

Depending on `| json` flattening you may see dotted or underscored keys:

| Meaning | Common names |
| --- | --- |
| Actor | `user_username`, `user.username` |
| Verb | `verb` |
| Resource | `objectRef_resource`, `objectRef.resource` |
| Object name | `objectRef_name` |
| HTTP status | `responseStatus_code` |
| Impersonatee | `impersonatedUser_username` |

If a query returns no fields, inspect one raw line first:

```logql
{log_type="audit"} |= `"verb":"delete"`
```

then add `| json` and pick the names that actually unpacked.
