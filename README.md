# eneo-openshift

OpenShift manifests for deploying [Eneo](https://github.com/eneo-ai/eneo) — the open-source AI platform for the public sector.

Traefik is replaced by OpenShift Routes.

---

## Prerequisites

- OpenShift 4.x cluster - Instructions assume Red Hat developer Sandbox - https://sandbox.redhat.com/
- A ReadWriteMany-capable StorageClass for the shared volumes (e.g. ODF/CephFS, NFS, EFS)
- Thie instructions assume Red Hat Developer Sandbox environment which includes 3 small models
- An OIDC identity provider, or use the built-in username/password login

---

## Security context summary

All components run under the default **restricted SCC** — no anyuid or elevated privileges required.

| Component | ServiceAccount | SCC | Image |
|-----------|---------------|-----|-------|
| backend | eneo-app | restricted (default) | ghcr.io/eneo-ai/eneo-backend — UID 1000 / GID 0 |
| worker | eneo-app | restricted (default) | ghcr.io/eneo-ai/eneo-backend — UID 1000 / GID 0 |
| frontend | eneo-app | restricted (default) | ghcr.io/eneo-ai/eneo-frontend — read-only runtime |
| postgres | eneo-app | restricted (default) | quay.io/rh-aiservices-bu/postgresql-15-pgvector-c9s — SCLORG / UID 26 / GID 0 |
| redis | eneo-app | restricted (default) | quay.io/sclorg/redis-7-c9s — SCLORG / UID 1001 / GID 0 |

> **PostgreSQL version note**: The SCLORG-based image provides PostgreSQL 15 with pgvector 0.5.1.
> Eneo's upstream docker-compose targets PostgreSQL 16. Test compatibility before going to production.
> If you need PG16 or a newer pgvector version, build a custom image by adapting the
> [Containerfile](https://github.com/rh-aiservices-bu/llm-on-openshift/blob/main/vector-databases/pgvector/Containerfile)
> to use `quay.io/sclorg/postgresql-16-c9s` as the base.

---

## Deployment steps

### 0. Clone this repo
**git clone ...:**
```bash
git clone https://github.com/johwes/eneo-openshift.git
```

### 1. Create or join a project

**New project:**
```bash
oc new-project eneo
```

**Existing namespace** (e.g. Red Hat Developer Sandbox, where you cannot create new projects):
```bash
NAMESPACE=<your-namespace>   # e.g. rhn-sa-johndoe-dev
find manifests/ -name '*.yaml' -exec sed -i "s/namespace: eneo/namespace: ${NAMESPACE}/g" {} \;
```
Skip `manifests/00-namespace.yaml` when applying — it creates a Namespace object that already exists.

### 2. Configure secrets

Generate strong values and apply the secrets in one step — secrets never need to be written to disk:

```bash
export POSTGRES_PASSWORD=$(openssl rand -hex 32)
export JWT_SECRET=$(openssl rand -hex 32)
export URL_SIGNING_KEY=$(openssl rand -hex 32)
export ENCRYPTION_KEY=$(python3 -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())')
export ENEO_SUPER_API_KEY=$(openssl rand -hex 32)

envsubst '${POSTGRES_PASSWORD} ${JWT_SECRET} ${URL_SIGNING_KEY} ${ENCRYPTION_KEY} ${ENEO_SUPER_API_KEY}' \
  < manifests/02-secrets.yaml | oc apply -f -
```

`ENCRYPTION_KEY` is **required** — without it, the admin model-provider UI cannot save API keys.

> If you prefer Sealed Secrets, HashiCorp Vault, or OpenShift Secrets Manager, substitute the generated values there instead of piping to `oc apply`.

### 3. Set the initial admin password

In `manifests/03-configmap.yaml`, set `DEFAULT_USER_PASSWORD` to a strong password you will use on first login. This value is stored in a ConfigMap (not a Secret) — change it in the UI immediately after first login.

### 4. Configure the domain

Find your cluster's app domain:
```bash
oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}'
```

Set `ENEO_HOST` to your intended hostname and replace the placeholders in all manifests:
```bash
ENEO_HOST=eneo.apps.<cluster-name>.<base-domain>
find manifests/ -name '*.yaml' -exec sed -i \
  -e "s/eneo\.apps\.REPLACE_WITH_YOUR_CLUSTER_DOMAIN/${ENEO_HOST}/g" \
  -e "s|https://REPLACE_WITH_YOUR_DOMAIN|https://${ENEO_HOST}|g" {} \;
```

### 5. Configure StorageClass (if needed)

`eneo-backend-data-pvc` and `eneo-temp-files-pvc` require ReadWriteMany. Edit `manifests/04-pvc.yaml` and set `storageClassName` for those two PVCs.

```bash
oc get storageclass
```

On **Red Hat Developer Sandbox** (AWS-backed): use `efs-sc`.

### 6. Apply infrastructure tier

Apply RBAC, secrets, config, PVCs, postgres, and redis — then **wait for PostgreSQL before continuing**:

```bash
oc apply -f manifests/01-serviceaccount.yaml
oc apply -f manifests/03-configmap.yaml
oc apply -f manifests/04-pvc.yaml
oc apply -f manifests/05-postgres.yaml
oc apply -f manifests/06-redis.yaml

oc rollout status statefulset/eneo-postgres --timeout=180s
```

### 7. Enable the pgvector extension (required)

The SCLORG PostgreSQL image does not auto-enable the `vector` extension, and the `eneo` database user is not a superuser. Run this once immediately after PostgreSQL is ready — before the backend starts:

```bash
oc exec eneo-postgres-0 -- psql -d eneo -c "CREATE EXTENSION IF NOT EXISTS vector;"
```

> **Why is this step needed?** The Eneo backend's `db-init` migration (`init_db.py`) creates pgvector indexes. If the extension does not exist when the migration runs, the backend will fail to start. The community `pgvector/pgvector` Docker image enables the extension automatically; the SCLORG image requires this one-time manual step.

### 8. Apply application tier

```bash
oc apply -f manifests/07-backend.yaml
oc apply -f manifests/08-worker.yaml
oc apply -f manifests/09-frontend.yaml
oc apply -f manifests/10-routes.yaml

oc rollout status deployment/eneo-backend deployment/eneo-worker deployment/eneo-frontend --timeout=300s
```

### 9. First login

Visit `https://<ENEO_HOST>`.

Default credentials (set in `manifests/03-configmap.yaml`):
- Email: `admin@example.com` (or the value you set for `DEFAULT_USER_EMAIL`)
- Password: the value you set for `DEFAULT_USER_PASSWORD`

**Change the password immediately after first login.**

---

## Adding AI models

Models are configured through the Eneo admin panel at `https://<your-domain>/admin/models` or via the API.

Eneo supports OpenAI, Anthropic, Azure OpenAI, Mistral, and self-hosted vLLM endpoints (e.g. KServe InferenceService). `ENCRYPTION_KEY` must be set in `eneo-backend-secret` before adding providers — it encrypts stored API keys in the database.

### Self-hosted vLLM / KServe models

#### SSL bypass for self-signed certificates

If your vLLM endpoints present a self-signed TLS certificate (common with KServe InferenceService in OpenShift), LiteLLM's SSL verification must be disabled. The `eneo-python-site` ConfigMap in `03-configmap.yaml` handles this by injecting a `sitecustomize.py` that sets `litellm.ssl_verify = False` at process startup. This is included in the manifests by default.

If your endpoints use a publicly trusted certificate, remove:
- The `eneo-python-site` ConfigMap from `03-configmap.yaml`
- The `PYTHONPATH` entry from `eneo-backend-config` in `03-configmap.yaml`
- The `python-site` volume and volumeMount from `07-backend.yaml` and `08-worker.yaml`

#### ServiceAccount token for KServe authentication

KServe InferenceService endpoints in OpenShift require a Kubernetes Bearer token. Create a long-lived ServiceAccount token Secret (Kubernetes auto-rotates the contents):

```bash
oc apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: eneo-app-sa-token
  namespace: eneo
  annotations:
    kubernetes.io/service-account.name: eneo-app
type: kubernetes.io/service-account-token
EOF

sleep 5
SA_TOKEN=$(oc get secret eneo-app-sa-token -o jsonpath='{.data.token}' | base64 -d)
echo "Token length: ${#SA_TOKEN} (should be > 0)"
```

Use this token as the API key when registering a vLLM provider in the Eneo admin UI, or in the API calls below.

**Endpoint format**: KServe predictors expose HTTPS on port 8443 with the path prefix `/v1`:
```
https://<isvc-name>-predictor.<namespace>.svc.cluster.local:8443/v1
```

#### Registering a provider via API

```bash
ENEO_URL=https://<your-eneo-hostname>

# Login
TOKEN=$(curl -s -X POST "${ENEO_URL}/api/v1/users/login/token/" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=admin@example.com&password=<your-password>" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])")

# Create provider — captures provider ID
PROVIDER_ID=$(curl -s -X POST "${ENEO_URL}/api/v1/admin/model-providers/" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"My vLLM Model\",
    \"provider_type\": \"hosted_vllm\",
    \"credentials\": {\"api_key\": \"${SA_TOKEN}\"},
    \"config\": {
      \"endpoint\": \"https://<isvc-name>-predictor.<namespace>.svc.cluster.local:8443/v1\",
      \"model_name\": \"<model-id>\"
    }
  }" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")

# Add as a tenant model
curl -s -X POST "${ENEO_URL}/api/v1/admin/tenant-models/completion/" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"provider_id\": \"${PROVIDER_ID}\",
    \"name\": \"<model-id>\",
    \"display_name\": \"My Model\",
    \"max_input_tokens\": 128000,
    \"max_output_tokens\": 4096,
    \"is_active\": true,
    \"is_default\": true
  }" | python3 -m json.tool
```

### Red Hat Developer Sandbox — hosted models

The sandbox cluster (`sandbox-shared-models` namespace) provides three shared vLLM models. After deploying Eneo, run the provided script to configure them automatically:

```bash
./scripts/configure-sandbox-models.sh \
  --namespace rhn-sa-<your-id>-dev \
  --url https://<your-eneo-hostname> \
  --password <your-admin-password>
```

The script creates the SA token Secret, waits for the token to be issued, logs in to Eneo, and registers all three models (Granite 3.1 8B FP8, Nemotron Nano 9B v2 FP8, Qwen3 8B FP8).

---

## Startup order

The init containers enforce the same dependency chain as the upstream docker-compose:

```
postgres + redis  →  pgvector extension  →  db-init (migrations)  →  backend  →  worker + frontend
```

---

## Upgrading

Pin to a specific image version for production (edit the `image:` fields in manifests 07–09):

```yaml
image: ghcr.io/eneo-ai/eneo-backend:v1.9.1
image: ghcr.io/eneo-ai/eneo-frontend:v1.9.1
```

To upgrade:
1. Update the image tags
2. `oc apply -f manifests/07-backend.yaml manifests/08-worker.yaml manifests/09-frontend.yaml`
3. The backend's db-init init container will run Alembic migrations automatically on pod start

---

## File structure

```
manifests/
├── 00-namespace.yaml      Project namespace (skip if deploying to an existing namespace)
├── 01-serviceaccount.yaml           ServiceAccount
├── 02-secrets.yaml        Secret templates — fill in before applying
├── 03-configmap.yaml      Non-sensitive configuration + eneo-python-site (LiteLLM SSL bypass)
├── 04-pvc.yaml            PersistentVolumeClaims
├── 05-postgres.yaml       PostgreSQL StatefulSet + Service
├── 06-redis.yaml          Redis StatefulSet + Service
├── 07-backend.yaml        Backend Deployment + Service
├── 08-worker.yaml         Worker Deployment
├── 09-frontend.yaml       Frontend Deployment + Service
└── 10-routes.yaml         OpenShift Routes (replaces Traefik)

scripts/
└── configure-sandbox-models.sh   Configure the three Red Hat Developer Sandbox hosted models
```
