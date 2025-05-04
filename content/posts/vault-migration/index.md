---
title: "Migrating HashiCorp Vault Between AKS Clusters"
date: 2025-03-18
author: "Max Leske (Xovis) and Mathis Kretz (bespinian)"
tags: ["Kubernetes", "Vault", "Azure", "Cloud Engineering"]
categories: ["Engineering", "Cloud Native"]
---

# Migrating HashiCorp Vault Between AKS Clusters

## Introduction

At [Xovis](https://xovis.com) and bespinian, we recently faced the challenge of
migrating a Kubernetes-based HashiCorp Vault instance from one Azure Kubernetes
Service (AKS) cluster to another. The goal was to consolidate infrastructure and
reduce the number of AKS clusters that required maintenance. The outcome of a
somewhat arduous journey is a Bash script that has enabled us to test the
migration repeatedly and then perform the migration with a outage of less than 2
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

Our Vault instances are running in a high-availability configuration using the
integrated Raft storage backend and auto-unseal with Azure Key Vault. This setup
is needed in order to ensure resilience and security across client environments.
To migrate Vault between AKS clusters, we implemented the process with a Bash
script that automated all steps including snapshot creation, data restoration,
and unseal key migration.

### Pre-Migration Setup

Before initiating the migration:

1. **Provision the new Vault cluster**: Set up a fresh Vault instance on the
   target AKS cluster with the same configuration as the existing one.
2. **Configure networking and authentication**: Ensure that the new instance has
   the necessary access permissions and that external clients will be able to
   connect post-migration.
3. **Test the migration in a staging environment**: Migrate a test Vault
   instance within between two non-production clusters to verify the process.

## Migration Process

The migration script consists of the steps outlined below.

### 1. Prepare the Migration

Before performing the actual migration, it's crucial to validate your
environment and ensure all prerequisites are met. This step includes setting up
local backups, verifying Kubernetes contexts, ensuring proper access
permissions, and preparing the user for the maintenance window.

- Create a local backup directory:

  ```bash
  mkdir -p vault-backups
  ```

- Check that the required tools are available and that `kubectl wait` is
  supported

  ```bash
  REQUIRED_TOOLS=(az kubectl jq ed dig)

  for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      print_message "Required tool '$tool' is not installed or not in PATH."
      MISSING=1
    fi
  done

  if ! kubectl wait --help | grep -q 'Wait for a specific condition'; then
    print_message "'kubectl wait' is not supported."
    MISSING=1
  fi

  if [ -n "$MISSING" ]; then
    print_message "Please install the missing tools."
    exit 1
  fi
  ```

- Check that the `kubectl` contexts for both clusters are available

  ```bash
  if ! (kubectl config get-contexts "${OLD_K8S_NAME}" > /dev/null 2>&1 && \
      kubectl config get-contexts "${NEW_K8S_NAME}" > /dev/null 2>&1); then
    print_message "No contexts for ${OLD_K8S_NAME} and ${NEW_K8S_NAME}."
    print_message "Make sure you have credentials for both clusters"
    exit 1
  fi
  ```

- Check that both `kubectl` contexts are accessible

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

- Check that the new Vault cluster has three replicas

  ```bash
  availableReplicas=$(kubectl get statefulsets.apps "${NEW_VAULT_NAME}" \
    -o template --template="{{.status.availableReplicas}}")
  if [ "${availableReplicas}" -ge 3 ]; then
    print_message "Expected number of replicas found on ${NEW_K8S_NAME}"
  else
    print_message "Unexpected replica count on ${NEW_K8S_NAME}. Exiting."
    exit 1
  fi
  ```

- Our auto-unseal setup using Azure Key Vault is based on the AKS cluster's
  Managed Service Identity. We thus need to check that the Managed Service
  Identity of the new Vault cluster has access to the unseal keys of both Vault
  instances, since both sets of keys will be rquired during the migration.

  ```bash
  az account set -s "${NEW_VAULT_SUBSCRIPTION_NAME}"

  msi_principal_id=$(az identity list \
    -g "${NEW_VAULT_RESOURCE_GROUP}" \
    --query "[?clientId == '${NEW_VAULT_MSI_CLIENT_ID}'].principalId" \
    | jq -r '.[]')

  key_vault_id=$(az keyvault show --name "${NEW_KEY_VAULT_NAME}" \
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

- Remind the user to now announce the start of the maintenance window

  ```bash
  print_message "Please announce the start of the maintenance window."
  wait_for_any_key
  ```

### 2. Create temporary migration tokens

To perform the snapshot and restore operations securely, we create short-lived
Vault tokens with limited permissions. These tokens allow access to specific
endpoints like snapshot creation, restoration, sealing, and leadership
operations, which aren't granted to the existing policies.

- Write policies for authorizing the migration operations

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

- Detect the index of the leader pod in each Vault instance

  ```bash
  kubectl get pod -l "vault-active=true" -o jsonpath \
    --template "{.items[0].metadata.labels.apps\.kubernetes\.io/pod-index}"
  ```

- Create tokens for each vault instances

  ```bash
  switch_context "${cluster_name}" "${vault_name}" > /dev/null
  leader_index="$(detect_vault_leader_index)" > /dev/null

  kubectl cp migration-policy.hcl "${vault_name}-${leader_index}":/tmp > /dev/null

  kubectl exec -it "${vault_name}-${leader_index}" -- \
    vault login "${admin_token}" > /dev/null

  kubectl exec -it "${vault_name}-${leader_index}" -- \
    sh -c "cat /tmp/migration-policy.hcl | vault policy write migration -" \
    > /dev/null

  kubectl exec -it "${vault_name}-${leader_index}" -- \
    vault token create -policy=migration -period=30m -format json \
    | jq -r '.auth.client_token'

  kubectl exec -it "${vault_name}-${leader_index}" -- \
    rm /tmp/migration-policy.hcl > /dev/null
  ```

### 3. Block access to the old Vault instance

Before creating the snapshot, it’s important to prevent any writes to the old
Vault instance. This step ensures no data is changed after the snapshot and
avoids issues with lease revocation.

- Backup and delete the ingress for the old Vault instance

  ```bash
  kubectl get ing vault -o yaml > "${BACKUPS_DIR}/${OLD_VAULT_INGRESS_FILENAME}"

  kubectl delete ing vault --wait=true
  ```

### 4. Create snapshot of the old Vault instance

We now take a snapshot of the Vault data using the Raft backend's built-in
snapshot mechanism. After the snapshot is saved and downloaded, we immediately
disable the old Vault to avoid unintended behavior.

- Log in with the migration token

  ```bash
  kubectl exec -it "${OLD_VAULT_NAME}-${leader_index}" -- \
    vault login "${OLD_VAULT_ADMIN_TOKEN}"
  ```

- Create the snapshot in the leader pod

  ```bash
  kubectl exec -it "${OLD_VAULT_NAME}-${leader_index}" -- \
    vault operator raft snapshot save "${snapshot_filepath}"
  ```

- Dowload the snapshot

  ```bash
  kubectl cp "${OLD_VAULT_NAME}-${leader_index}":"${snapshot_filepath}" \
    "${BACKUPS_DIR}/${OLD_VAULT_SNAPSHOT_FILENAME}"

  kubectl exec -it "${OLD_VAULT_NAME}-${leader_index}" -- \
    rm "${snapshot_temp_filepath}"
  ```

- Disable the old Vault instance by changing the command of the Vault
  StatefulSet to `sleep`

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

- Restart all pods to pick up the patched configuration
  ```bash
  kubectl delete pod --selector=app.kubernetes.io/name=vault
  ```

### 5. Restore the snapshot in the new Vault instance

With the snapshot from the old instance in hand, we restore it to the new Vault
instance. This effectively brings the new Vault cluster to the same data state
as the old one.

- Upload the snapshot the to leader pod

  ```bash
  kubectl cp "${BACKUPS_DIR}/${OLD_VAULT_SNAPSHOT_FILENAME}" \
    "vault-${leader_index}":"${snapshot_tmp}"
  ```

- Log in with the migration token

  ```bash
  kubectl exec -it "vault-${leader_index}" -- \
    vault login "${NEW_VAULT_MIGRATION_TOKEN}"
  ```

- Run the restore command
  ```bash
  kubectl exec -it "vault-${leader_index}" -- \
    sh -c "vault operator raft snapshot restore -force \"${snapshot_tmp}\""
  ```

### 6. Configure the new Vault cluster to use the old unseal key

The restored state must be unsealed with the unseal key stored in the KeyVault
associated with the _old_ Vault instance. We now need to unseal the state but
store a new unseal key in the KeyVault associated with the _new_ Vault instance.
This step modifies the config map by replacing the coordinates to the _new_
instance unseal key with those of the _old_ instance unseal key and restarts the
pods to apply the change. After the restart, the pods should unseal the state
automatically since they have access to the original unseal key.

- Patch the configuration of the new Vault cluster with the credentials of the
  old Azure Key Vault

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

  This will apply the following config map to the new Vault cluster

  ```yaml
  apiVersion: v1
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
        tenant_id      = "$TENANT_ID"
        client_id      = "$NEW_VAULT_MSI_CLIENT_ID"
        vault_name     = "$OLD_KEY_VAULT_NAME"
        key_name       = "$OLD_VAULT_UNSEAL_KEY_SECRET_NAME"
      }
      service_registration "kubernetes" {}
  kind: ConfigMap
  metadata:
    name: new-vault-config
    namespace: new-vault-destination
  ```

- Restart all pods to pick up the patched configuration
  ```bash
  kubectl delete pod --selector=app.kubernetes.io/name=vault
  ```

### 7. Prepare the unseal key migration on the new Vault instance

To enable unseal key migration, the new Vault cluster needs to know about both
unseal key coordinates when the configuration is loaded the next time (after
unsealing the state) — keeping the old seal block active but disabled, and
adding a new one that points to the new Azure Key Vault.

- Update the Vault configuration:

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
kind: ConfigMap
metadata:
  name: new-vault-config
  namespace: new-vault-destination
```

### 8. Perform the unseal key migration on the follower pods

Vault only allows unseal key migration on follower nodes, so we restart each
follower pod and run the migration steps.

- Iterate through each follower pod and migrate it using the required number of
  unseal keys (in this case, 3, based on the configured unseal threshold). Note:
  This refers to unseal keys generated during the initial Vault initialization
  process (using Shamir’s Secret Sharing), not recovery keys which are used in
  auto-unseal or disaster recovery modes.

  ```bash
  for i in {0..2}; do
    if [ "${i}" -eq "${leader_index}" ]; then
      continue
    fi

    print_message "Restarting pod vault-${i} to start unseal key migration"
    kubectl delete pod "vault-${i}"
    kubectl wait \
      --for=jsonpath='{.status.containerStatuses[0].state.running}' \
      --selector=apps.kubernetes.io/pod-index="${i}" \
      --timeout=90s \
      pod

    print_message "Migrating vault-${i}"
    kubectl exec -it "vault-${i}" -- \
      sh -c "vault operator unseal -migrate \"${OLD_VAULT_UNSEAL_KEY_1}\""
    kubectl exec -it "vault-${i}" -- \
      sh -c "vault operator unseal -migrate \"${OLD_VAULT_UNSEAL_KEY_2}\""
    kubectl exec -it "vault-${i}" -- \
      sh -c "vault operator unseal -migrate \"${OLD_VAULT_UNSEAL_KEY_3}\""
  done
  ```

### 9. Step down leader pod

Once all follower pods have been migrated, the leader must step down so it can
restart and apply the new seal configuration.\
Note that we use the migration token of the _old_ Vault instance here, since
that is the token stored in the restored snapshot.

- Step down the leader pod

  ```bash
  kubectl exec -it "vault-${leader-index}" -- vault login "${OLD_VAULT_MIGRATION_TOKEN}"
  kubectl exec -it "vault-${leader-index}" -- vault operator step-down
  ```

### 10. Remove old seal block from the config

Now that all pods use the new seal configuration, we can safely remove the old
seal block.

- Edit the config map

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

- Restart all Vault pods to ensure they all use the final configuration.
  ```bash
  kubectl delete pod --selector=app.kubernetes.io/name=vault
  ```

### 12. Create a proxy service from the old Vault to the new Vault

To allow clients using the old Vault domain to reach the new Vault instance, we
create a proxy Service and EndpointSlice in the old cluster that forwards
traffic to the new Vault’s ingress. Note: We use an IP address for the
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

### 13. Modify the ingress of the old Vault to forward connections via proxy

With the proxy service in place, we recreate the ingress for the old Vault
instance but configured to forward all requests to the proxy.

- Edit the old ingress and update

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

  This allows existing clients to continue using the old Vault domain without
  any modifications, as long as the configuration on the old cluster forwards
  requests.

### 14. Test the reachability of the old Vault domain

Finally, we test that both the old and new Vault domains point to the same
instance and that authentication works as expected.\
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

We hope this walkthrough — and the accompanying script excerpts — can serve as a
blueprint for others facing similar migrations. If you have questions, feedback,
or suggestions for improvements, feel free to reach out!
