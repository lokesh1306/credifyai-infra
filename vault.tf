resource "helm_release" "vault" {
  name       = "vault"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "vault"
  namespace  = kubernetes_namespace.vault.metadata[0].name
  values     = [file("./vault-config.yaml")]
  depends_on = [kubernetes_namespace.vault]
}

data "kubernetes_service" "vault" {
  metadata {
    name      = "vault-server"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }
  depends_on = [null_resource.vault_unseal]
}

data "kubernetes_secret" "vault_token" {
  metadata {
    name      = "vault-root-token"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }
  depends_on = [null_resource.vault_unseal]
}
resource "null_resource" "vault_init" {
  provisioner "local-exec" {
    command = <<EOT
        kubectl exec -n vault vault-server-0 -- vault operator init -key-shares=5 -key-threshold=3 -format=json > /tmp/vault-init.json
        kubectl create secret generic vault-root-token --from-literal=root_token=$(jq -r ".root_token" /tmp/vault-init.json) -n vault
        jq -r ".unseal_keys_b64[]" /tmp/vault-init.json > /tmp/vault-unseal-keys
        for i in {0..4}; do
          kubectl create secret generic vault-unseal-key-$i --from-literal=unseal_key=$(jq -r ".unseal_keys_b64[$i]" /tmp/vault-init.json) -n vault
        done
    EOT
  }
  depends_on = [helm_release.vault]
}

resource "null_resource" "vault_unseal" {
  count = 3

  provisioner "local-exec" {
    command = <<EOT
      UNSEAL_KEY=$(kubectl get secret vault-unseal-key-${count.index} -n vault -o jsonpath="{.data.unseal_key}" | base64 --decode)
      kubectl exec -n vault vault-server-0 -- vault operator unseal $UNSEAL_KEY
    EOT
  }

  depends_on = [null_resource.vault_init]
}

resource "vault_auth_backend" "kubernetes" {
  type       = "kubernetes"
  depends_on = [null_resource.vault_unseal]
}

resource "vault_kubernetes_auth_backend_config" "kubernetes" {
  backend = vault_auth_backend.kubernetes.path
  # kubernetes_host = "http://vault-server.vault.svc:8200"
  kubernetes_host = azurerm_kubernetes_cluster.kubernetes.kube_config.0.host
  # kubernetes_ca_cert = base64decode(azurerm_kubernetes_cluster.kubernetes.kube_config.0.cluster_ca_certificate)
  # token_reviewer_jwt = data.kubernetes_secret.vault_token.data["root_token"]
  issuer                 = azurerm_kubernetes_cluster.kubernetes.kube_config.0.host
  disable_iss_validation = "true"
  depends_on             = [vault_auth_backend.kubernetes]
}

resource "vault_mount" "crdb" {
  path       = "crdb"
  type       = "database"
  depends_on = [vault_kubernetes_auth_backend_config.kubernetes]
}

resource "vault_policy" "crdb_policy" {
  name = "crdb-policy"

  policy     = <<EOT
path "*" {
  capabilities = ["read", "create", "update", "patch", "delete", "list"]
}
EOT
  depends_on = [vault_database_secret_backend_role.crdb_role]
}

locals {
  trimmed_host = replace(azurerm_kubernetes_cluster.kubernetes.kube_config.0.host, ":443", "")
  depends_on   = [vault_policy.crdb_policy]
}

resource "vault_kubernetes_auth_backend_role" "crdb_role" {
  backend   = vault_auth_backend.kubernetes.path
  role_name = "crdb-role"

  bound_service_account_names      = ["credifyai-crdb"]
  bound_service_account_namespaces = ["crdb"]
  audience                         = local.trimmed_host
  token_ttl                        = 3600
  token_policies                   = ["crdb-policy"]
  depends_on                       = [local.trimmed_host]
}

resource "vault_database_secret_backend_connection" "crdb" {
  backend       = vault_mount.crdb.path
  name          = "crdb"
  allowed_roles = ["crdb-role"]

  postgresql {
    connection_url = "postgresql://{{username}}:{{password}}@cockroachdb-public.crdb.svc:26257/credifyai?sslmode=require"
    username       = "credifyai"
    password       = "admin"
  }
  depends_on = [vault_mount.crdb]
}

resource "vault_database_secret_backend_role" "crdb_role" {
  backend = vault_mount.crdb.path
  name    = "crdb-role"
  db_name = vault_database_secret_backend_connection.crdb.name
  creation_statements = [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';",
    "GRANT ALL PRIVILEGES ON DATABASE credifyai TO \"{{name}}\";"
  ]
  default_ttl = 3600
  max_ttl     = 14400
  depends_on  = [vault_database_secret_backend_connection.crdb]
}