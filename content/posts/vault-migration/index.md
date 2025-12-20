---
title: "Migrating HashiCorp Vault Between AKS Clusters"
date: 2026-01-01
author: "Max Leske (Xovis, @theseion) and Mathis Kretz (bespinian)"
tags: ["Kubernetes", "Vault", "Azure", "Cloud Engineering"]
categories: ["Engineering", "Cloud Native"]
---

# Migrating HashiCorp Vault Between AKS Clusters

## Introduction

At [Xovis](https://xovis.com) and bespinian, we recently faced the challenge of
migrating HashiCorp Vault cluster from one Azure Kubernetes
Service (AKS) cluster to another. The goal was to consolidate infrastructure and
reduce the number of AKS clusters that required maintenance. The outcome of a
somewhat arduous journey is a Bash script that has enabled us to test the
migration repeatedly and then perform the migration with an outage of less than 2
minutes.

This blog post walks through our approach and presents the migration steps in 14
structured chapters. Each chapter includes excerpts from the automation script,
highlighting the checks, operations, and configuration changes we performed
along the way.

## Why We Migrated

Operating multiple AKS clusters can introduce unnecessary complexity and
overhead. To optimize our infrastructure and simplify maintenance, we decided to
migrate Vault from one AKS cluster to another, reducing the number of clusters
we needed to manage. Our primary goals were:

- Minimal downtime to avoid disruptions to dependent services.
- Data integrity with a verifiable transition from the old to the new instance.
- Seamless switchover to ensure applications continued to function without
  configuration changes.
- A rollback strategy in case of unforeseen issues.

## Migration Strategy

We implemented the entire process of migrating the original Vault instance to the
new AKS cluster with a Bash script that automated all steps including snapshot
creation, auto-unseal key migration, and data restoration to the new Vault instance.\
We wrote an additional Bash script to handle restoration of the original Vault
instance, in case of unexpected issues.

Before starting the actual migration, we tested the migration several times between
two non-production clusters.

### Pre-Migration Setup

Before the migration script can be used, the target cluster must be prepared with
an empty Vault instance with the same configuration as the original Vault instance.
Setting up this empty Vault instance isn't covered in this post, however, as part
of this work we also automated setting up new Vault instances, so that we could
iterate on testing as fast as possible, with minimal manual intervention. In general,
before the start of a migration run, the following work needs to be completed:

1. **Provision the new Vault cluster**: Set up a fresh Vault instance on the
   target AKS cluster with the same configuration as the existing one.
2. **Configure networking and authentication**: Ensure that the new instance has
   the necessary access permissions and that external clients will be able to
   connect post-migration.

## Migration Process

In the following sections, we describe each individual step in the script.

Uppercase variables like `OLD_K8S_NAME` refer to data that was configured
as part of the script invocation, e.g., with `--old-k8s-name`, or data that
was created in one step and needs to be available in another step. Lowercase
variables like `required_tools` are local variables and are only read in the
current step.

The script snippets use some functions that are not explained further. Refer
to the actual script to see what they do exactly.

Note that the script snippets shown have been adapted to fit the blog post
and can differ slightly from the actual script.

### 1. Prepare the Migration

Before performing the actual migration, it's crucial to validate the
environment and ensure all prerequisites are met. This step includes setting up
local backups, verifying Kubernetes contexts, ensuring proper access
permissions, and preparing the user for the maintenance window.

1. Create a local backup directory:

    ```bash
    mkdir -p vault-backups
    ```

2. Check that the required tools are available and that `kubectl wait` is
   supported:

    ```bash
    required_tools=(az kubectl jq ed dig)

    for tool in "${required_tools[@]}"; do
        if ! command -v "${tool}" >/dev/null 2>&1; then
        print_message "Required tool '${tool}' is not installed or not on PATH."
        missing=1
        fi
    done

    if ! kubectl wait --help | grep -q 'Wait for a specific condition'; then
        print_message "'kubectl wait' is not supported."
        missing=1
    fi

    if [ -n "${missing}" ]; then
        print_message "Please install the missing tools."
        exit 1
    fi
    ```

3. Check that the `kubectl` contexts for both clusters are available. You may have
   to run `az aks get-credentials` to set up the required contexts for `kubectl`.

    ```bash
    if ! (kubectl config get-contexts "${OLD_K8S_NAME}" > /dev/null 2>&1 && \
        kubectl config get-contexts "${NEW_K8S_NAME}" > /dev/null 2>&1); then
        print_message "No contexts for ${OLD_K8S_NAME} and ${NEW_K8S_NAME}."
        print_message "Make sure you have credentials for both clusters"
        exit 1
    fi
    ```

4. Check that both `kubectl` contexts are accessible:

    ```bash
    switch_context "${OLD_K8S_NAME}" "${OLD_VAULT_NAME}"
    if ! kubectl get cm > /dev/null 2>&1; then
        print_message "Can't access resources on ${OLD_K8S_NAME}. Aborting"
        exit 1
    fi

    switch_context "${NEW_K8S_NAME}" "${NEW_VAULT_NAME}"
    if ! kubectl get cm > /dev/null 2>&1; then
        print_message "Can't access resources on ${NEW_K8S_NAME}. Aborting"
        exit 1
    fi
    ```

5. Check that the new Vault cluster has the number of desired replicas,
   as specified when the script was called:

    ```bash
    availableReplicas=$(kubectl get statefulsets.apps "${NEW_VAULT_NAME}" \
        -o template \
        --template="{{.status.availableReplicas}}")
    if [ "${availableReplicas}" -ge "${EXPECTED_REPLICAS} ]; then
        print_message "Expected number of replicas found on ${NEW_K8S_NAME}"
    else
        print_message "Unexpected replica count on ${NEW_K8S_NAME}: ${availableReplicas}, expected ${EXPECTED_REPLICAS}. Exiting."
        exit 1
    fi
    ```

6. Our auto-unseal setup using Azure Key Vault is based on the AKS cluster's
   Managed Service Identity. We thus need to check that the Managed Service
   Identity of the new Vault cluster has access to the recovery keys of both Vault
   instances, since both sets of keys will be rquired during the migration.

    ```bash
    az account set -s "${NEW_VAULT_SUBSCRIPTION_NAME}"

    msi_principal_id=$(az identity list \
        -g "${NEW_VAULT_RESOURCE_GROUP}" \
        --query "[?clientId == '${NEW_VAULT_MSI_CLIENT_ID}'].principalId" \
        | jq -r '.[]')

    key_vault_id=$(az keyvault show \
        --name "${NEW_KEY_VAULT_NAME}" \
        --query "id" | jq -r '.')
    if
        ! az role assignment list \
        --scope "${key_vault_id}" \
        --role "Key Vault Crypto Service Encryption User" \
        --query "[?principalId == '${msi_principal_id}']" > /dev/null 2>&1; then
        print_message "Role assigment missing for new vault MSI"
        print_message "Assign role 'Key Vault Crypto Service Encryption User'"
        exit 1
    fi

    az account set -s "${OLD_VAULT_SUBSCRIPTION_NAME}"

    key_vault_id=$(az keyvault show --name "${OLD_KEY_VAULT_NAME}" \
        --query "id" | jq -r '.')
    if
        ! az role assignment list \
        --scope "${key_vault_id}" \
        --role "Key Vault Crypto Service Encryption User" \
        --query "[?principalId == '${msi_principal_id}']" > /dev/null 2>&1; then
        print_message "Role assigment missing for new vault MSI"
        print_message "Assign role 'Key Vault Crypto Service Encryption User'"
        exit 1
    fi
    ```

7. Remind the user to now announce the start of the maintenance window:

    ```bash
    print_message "Please announce the start of the maintenance window."
    wait_for_any_key
    ```

### 2. Create temporary migration tokens

To perform the snapshot and restore operations securely, we create short-lived
Vault tokens with limited permissions. These tokens allow access to specific
endpoints like snapshot creation, restoration, sealing, and leadership
operations, which aren't granted to the existing policies.

1. The following policies are required by the migration tokens and are stored in
   a dedicated file:

    ```hcl
    # Policy allowing to step down Vault leader
    path "sys/step-down" {
    capabilities = ["update", "sudo"]
    }
    # Policy allowing to save snapshots
    path "sys/storage/raft/snapshot" {
    capabilities = [ "create", "read", "update", "list" ]
    }
    # Policy allowing to restore vault's snapshots
    path "sys/storage/raft/snapshot-force" {
    capabilities = [ "create", "read", "update", "list" ]
    }
    ```

2. Create tokens for each vault instance, using the policies shown above:

    ```bash
    NEW_VAULT_MIGRATION_TOKEN="$(create_migration_token "${NEW_K8S_NAME}" "${NEW_VAULT_NAME}" "${NEW_VAULT_ADMIN_TOKEN}")"
    OLD_VAULT_MIGRATION_TOKEN="$(create_migration_token "${OLD_K8S_NAME}" "${OLD_VAULT_NAME}" "${OLD_VAULT_ADMIN_TOKEN}")"
    ```

### 3. Block access to the old Vault instance

We are now ready to actually perform the migration. Before creating the snapshot
of the data in the old Vault instance, it’s important to prevent any further
writes to the old Vault instance. This step ensures no data is changed after the
snapshot has been created.

Backup and delete the ingress resource for the old Vault instance:

```bash
kubectl delete ing vault --wait=true
```

### 4. Create snapshot of the old Vault instance

We now take a snapshot of the Vault data using the Raft backend's built-in
snapshot mechanism. After the snapshot is saved and downloaded, we immediately
disable the old Vault to avoid unintended behavior. We do this to prevent issues
with lease revocation, which would continue to run in the old Vault instance and
lead to a difference in state to the snapshot.

1. Log in to the leader pod with the migration token:

    ```bash
    kubectl exec -it "${OLD_VAULT_NAME}-${leader_index}" -- \
        vault login "${OLD_VAULT_ADMIN_TOKEN}"
    ```

2. Create the snapshot in the leader pod:

    ```bash
    kubectl exec -it "${OLD_VAULT_NAME}-${leader_index}" -- \
        vault operator raft snapshot save "${snapshot_filepath}"
    ```

3. Download the snapshot:

    ```bash
    kubectl cp "${OLD_VAULT_NAME}-${leader_index}":"${snapshot_filepath}" \
        "${BACKUPS_DIR}/${OLD_VAULT_SNAPSHOT_FILENAME}"
    ```


4. Disable the old Vault instance by changing the command of the Vault StatefulSet to
   `sleep infinity`. This will ensure that they reach a "ready" state without actually
   running Vault.

    ```bash
    kubectl get statefulset vault -o yaml > \
    "${BACKUPS_DIR}/${OLD_VAULT_STATEFULSET_FILENAME}"
    cp "${BACKUPS_DIR}/${OLD_VAULT_STATEFULSET_FILENAME}" .

    ed "${OLD_VAULT_STATEFULSET_FILENAME}" <<EOF
    /args:/
    +1,/-config=/c
            - sleep infinity
    .
    w
    q
    EOF

    kubectl apply -f "${OLD_VAULT_STATEFULSET_FILENAME}"
    ```

    The `args` field of the container in the StatefulSet resource will be changed from:

    ```yaml
    - args:
        - "cp /vault/config/extraconfig-from-values.hcl /tmp/storageconfig.hcl;\n[
            -n \"${HOST_IP}\" ] && sed -Ei \"s|HOST_IP|${HOST_IP?}|g\" /tmp/storageconfig.hcl;\n[
            -n \"${POD_IP}\" ] && sed -Ei \"s|POD_IP|${POD_IP?}|g\" /tmp/storageconfig.hcl;\n[
            -n \"${HOSTNAME}\" ] && sed -Ei \"s|HOSTNAME|${HOSTNAME?}|g\" /tmp/storageconfig.hcl;\n[
            -n \"${API_ADDR}\" ] && sed -Ei \"s|API_ADDR|${API_ADDR?}|g\" /tmp/storageconfig.hcl;\n[
            -n \"${TRANSIT_ADDR}\" ] && sed -Ei \"s|TRANSIT_ADDR|${TRANSIT_ADDR?}|g\"
            /tmp/storageconfig.hcl;\n[ -n \"${RAFT_ADDR}\" ] && sed -Ei \"s|RAFT_ADDR|${RAFT_ADDR?}|g\"
            /tmp/storageconfig.hcl;\n/usr/local/bin/docker-entrypoint.sh vault server
            -config=/tmp/storageconfig.hcl \n"
    ```
    to:

    ```yaml
    - args:
        - sleep infinity
    ```


    - Restart all pods to pick up the patched configuration (the pod disruption budget 
    prevents the StatefulSet from redeploying the pods automatically):
    ```bash
    kubectl delete pod --selector=app.kubernetes.io/name=vault
    ```

### 5. Restore the snapshot in the new Vault instance

With the snapshot from the old instance in hand, we restore it to the new Vault
instance. Once the snapshot has been restored, both Vault instances will have the
identical state.

1. Upload the snapshot the to leader pod:

    ```bash
    kubectl cp "${BACKUPS_DIR}/${OLD_VAULT_SNAPSHOT_FILENAME}" \
        "vault-${leader_index}":"${snapshot_tmp}"
    ```

2. Log in with the migration token:

    ```bash
    kubectl exec -it "vault-${leader_index}" -- \
        vault login "${NEW_VAULT_MIGRATION_TOKEN}"
    ```

3. Run the restore command in the leader pod.

    ```bash
    kubectl exec -it "vault-${leader_index}" -- \
        sh -c "vault operator raft snapshot restore -force \"${snapshot_tmp}\""
    ```

### 6. Configure the new Vault cluster to use the old auto-unseal key

The restored state must be unsealed with the auto-unseal key stored in the KeyVault
associated with the _old_ Vault instance. We now need to unseal the state but
store a new auto-unseal key in the KeyVault associated with the _new_ Vault instance.
This step modifies the config map by replacing the coordinates to the _new_
instance auto-unseal key with those of the _old_ instance auto-unseal key and restarts the
pods to apply the change. After the restart, the pods will unseal the state
automatically since they have access to the old auto-unseal key.

1. Patch the configuration of the new Vault cluster with the credentials of the
   old Azure Key Vault:

    ```bash
    kubectl get cm vault-config -o yaml > "${vault_config_filename}"

    ed '+/seal "/' "${vault_config_filename}" <<EOF
    .,/}/d
    -
    a
        seal "azurekeyvault" {
            tenant_id      = "${TENANT_ID}"
            client_id      = "${NEW_VAULT_MSI_CLIENT_ID}"
            vault_name     = "${OLD_KEY_VAULT_NAME}"
            key_name       = "${OLD_VAULT_UNSEAL_KEY_SECRET_NAME}"
        }
    .
    w
    q
    EOF

    kubectl apply -f "${vault_config_filename}"
    ```

    This will apply the following ConfigMap to the new Vault cluster:

    ```yaml
    apiVersion: v1
    kind: ConfigMap
    metadata:
        name: new-vault-config
        namespace: new-vault-destination
    data:
        extraconfig-from-values.hcl: |-
        disable_mlock = true
        plugin_directory = "/vault/data/plugins"
        ui = false
        listener "tcp" {
            tls_disable = 1
            address = "[::]:8200"
            cluster_address = "[::]:8201"
        }
        storage "raft" {
            path = "/vault/data"
        }
        seal "azurekeyvault" {
            tenant_id      = "$TENANT_ID"
            client_id      = "$NEW_VAULT_MSI_CLIENT_ID"
            vault_name     = "$OLD_KEY_VAULT_NAME"
            key_name       = "$OLD_VAULT_UNSEAL_KEY_SECRET_NAME"
        }
        service_registration "kubernetes" {}
    ```

2. Restart all pods to pick up the patched configuration:

    ```bash
    kubectl delete pod --selector=app.kubernetes.io/name=vault
    ```

### 7. Prepare the auto-unseal key migration on the new Vault instance

The new Vault instance has now been unsealed. We now need to migrate the auto-unseal
configuration, so that the new Vault will read the auto-unseal key from the new
KeyVault and no longer the old KeyVault.

To enable auto-unseal key migration, the new Vault cluster needs to know about both
auto-unseal key configurations when the configuration is loaded the next time (after
unsealing the state) — keeping the old seal block active but _disabled_, and
adding a new one that points to the new Azure Key Vault.

Update the Vault configuration:

```bash
kubectl get cm vault-config -o yaml > vault-config.yaml

ed '+/seal "/' vault-config.yaml <<EOF
a
    disabled       = true
.
/}/
a
    seal "azurekeyvault" {
    tenant_id      = "${TENANT_ID}"
    client_id      = "${NEW_VAULT_MSI_CLIENT_ID}"
    vault_name     = "${NEW_KEY_VAULT_NAME}"
    key_name       = "${NEW_VAULT_UNSEAL_KEY_SECRET_NAME}"
    }
.
w
q
EOF

kubectl apply -f vault-config.yaml
```

This will apply the following config map to the new Vault cluster

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
name: new-vault-config
namespace: new-vault-destination
data:
extraconfig-from-values.hcl: |2-
    disable_mlock = true
    plugin_directory = "/vault/data/plugins"
    ui = false
    listener "tcp" {
        tls_disable = 1
        address = "[::]:8200"
        cluster_address = "[::]:8201"
    }
    storage "raft" {
        path = "/vault/data"
    }
    seal "azurekeyvault" {
        # the old seal config
        disabled       = true
        tenant_id      = "$TENANT_ID"
        client_id      = "$NEW_VAULT_MSI_CLIENT_ID"
        vault_name     = "$OLD_KEY_VAULT_NAME"
        key_name       = "$OLD_VAULT_UNSEAL_KEY_SECRET_NAME"
    }
    seal "azurekeyvault" {
        # the new seal config
        tenant_id      = "$TENANT_ID"
        client_id      = "$NEW_VAULT_MSI_CLIENT_ID"
        vault_name     = "$NEW_KEY_VAULT_NAME"
        key_name       = "$NEW_VAULT_UNSEAL_KEY_SECRET_NAME"
    }
    service_registration "kubernetes" {}
```

### 8. Perform the auto-unseal key migration on the follower pods

Vault only allows auto-unseal key migration on follower nodes, so we restart each
follower pod and run the migration steps.

Iterate through each follower pod and migrate it using the recovery keys provided
during script invocation:

```bash
for i in $(get_vault_follower_indexes); do
print_message "Restarting pod vault-${i} to start auto-unseal key migration"
kubectl delete pod "vault-${i}"
kubectl wait \
    --for=jsonpath='{.status.containerStatuses[0].state.running}' \
    --selector=apps.kubernetes.io/pod-index="${i}" \
    --timeout=90s \
    pod

print_message "Migrating vault-${i}"
for key in "${OLD_VAULT_RECOVERY_KEYS}"; do
    kubectl exec -it "vault-${i}" -- \
    sh -c "vault operator unseal -migrate \"${key}\""
done
done
```

### 9. Step down leader pod

Once all follower pods have been migrated, the leader must step down so it can
restart and apply the new auto-unseal configuration.\
Note that we use the migration token of the _old_ Vault instance here, since
that is the token stored in the restored snapshot.

Step down the leader pod:

```bash
kubectl exec -it "vault-${leader-index}" -- vault login "${OLD_VAULT_MIGRATION_TOKEN}"
kubectl exec -it "vault-${leader-index}" -- vault operator step-down
```

### 10. Remove old seal block from the ConfigMap

Now that all pods use the new seal configuration, we can safely remove the old
seal block.

Edit the ConfigMap to remove the old seal block and apply it:

```bash
kubectl get cm vault-config -o yaml > vault-config.yaml

ed '+/disabled \+= true/' vault-config.yaml <<EOF
-
.;/}/d
w
q
EOF

kubectl apply -f vault-config.yaml
```

### 11. Restart all replicas

Restart all Vault pods to ensure they all use the final configuration:

```bash
kubectl delete pod --selector=app.kubernetes.io/name=vault
```

### 12. Create a proxy service from the old Vault to the new Vault

To allow clients using the old Vault domain to reach the new Vault instance, we
create a proxy Service and EndpointSlice in the old cluster that forwards
traffic to the new Vault instance's ingress. Note: We use an IP address for the
forwarding target instead of a DNS name because the ExternalName feature in
ingress-nginx relies on commercial NGINX functionality and is not supported in
the open source version.

```bash
new_vault_ip="$(dig +short "${NEW_VAULT_DOMAIN}" | tail -1)"

kubectl apply -f - <<EOF
---
apiVersion: v1
kind: Service
metadata:
  name: vault-migration-proxy
  namespace: vault
spec:
  ports:
    - port: 443
      protocol: TCP
      targetPort: 443
      name: https
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: vault-migration-proxy
  namespace: vault
  labels:
    kubernetes.io/service-name: vault-migration-proxy
addressType: IPv4
ports:
  - name: "https"
    port: 443
endpoints:
  - addresses:
      - "${new_vault_ip}"
EOF
```

### 13. Modify the ingress of the old Vault instance to forward connections via proxy

With the proxy service in place, we recreate the ingress for the old Vault
instance but configure it to forward all requests to the proxy. This enables
existing clients to continue using the old Vault domain without any modifications,
as long as the configuration on the old cluster forwards requests.

Edit the old ingress and apply it:

```bash
cp "${BACKUPS_DIR}/${OLD_VAULT_INGRESS_FILENAME}" "${new_ingress_filename}"
ed '+/annotations:/' "${new_ingress_filename}" <<EOF
a
    nginx.ingress.kubernetes.io/backend-protocol: HTTPS
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/upstream-vhost: "${NEW_VAULT_DOMAIN}"
.
/name: vault-active/
s/name:.*/name: vault-migration-proxy
/number: 8200/
s/number:.*/number: 443
w
q
EOF

kubectl apply -f "${new_ingress_filename}"
```

The following shows the relevant fields of the Ingress resource before the
modification:

```yaml
metadata:
  annotations:
spec:
  rules:
  - http:
      paths:
      - backend:
          service:
            name: vault-active
            port:
              number: 8200
```

The following shows the modified fields of the Ingress resource:

  ```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: HTTPS
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/upstream-vhost: "<new vault domain>"
spec:
  rules:
    - http:
      paths:
      - backend:
          service:
            name: vault-migration-proxy
            port:
              number: 443
```

### 14. Test the reachability of the old and new Vault domains

Finally, we test that both the old and new Vault domains point to the same
instance (the old instance will not respond since it is not running) and that
authentication works as expected.\
Note again the use of the _old_ Vault token for both tests.

```bash
  export VAULT_ADDR="${OLD_VAULT_URL}"
  if ! (vault login "${OLD_TOKEN}" && vault secrets list | head -n 5); then
    print_message "Failed to reach Vault at '${OLD_VAULT_DOMAIN}'. Aborting"
    exit 1
  fi

  export VAULT_ADDR="${NEW_VAULT_URL}"
  if ! (vault login "${OLD_TOKEN}" && vault secrets list | head -n 5); then
    print_message "Failed to reach Vault at '${NEW_VAULT_DOMAIN}'. Aborting"
    exit 1
  fi
```

## Restoration in case of failure

The migration script creates backups of all modified resources in the working directory.
When something goes wrong, the restoration script can simply restore the backed up
resources and restart the nodes of the old Vault instance.

Despite careful planning and multiple test runs on non-production clusters, we did use the
restoration script twice during migration attempts on the production clusters. In both
instances, the reasons were related to network access, which varied slightly between
the production and non-production clusters.

## Conclusion

Migrating Vault between AKS clusters may seem daunting, especially when
considering the critical nature of secrets management. However, by automating
the process end-to-end, we were able to significantly reduce the risks and
complexity involved.

The scripted approach ensured a reliable, repeatable migration path, minimized
human error, and provided built-in checkpoints and validation at every stage.
Thanks to careful planning, extensive testing, and robust scripting, we were
able to execute the migration with minimal downtime and no impact on dependent
systems.

We provide all the scripts and files described in this blog post for your use at
<insert git repo link>. We provide no guarantees or support, use them at your own
risk.

We hope this walkthrough — and the accompanying script excerpts — can serve as a
blueprint for others facing similar migrations. If you have questions, feedback,
or suggestions for improvements, feel free to reach out!