# eneo-openshift

OpenShift manifests for deploying [Eneo](https://github.com/eneo-ai/eneo) — the open-source AI platform for the public sector.

Traefik is replaced by OpenShift Routes. 

---

## Prerequisites

- OpenShift 4.x cluster
- A ReadWriteMany-capable StorageClass for the shared volumes (e.g. ODF/CephFS, NFS)
- At least one LLM provider API key (OpenAI, Anthropic, Azure, or a self-hosted model)
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

### 1. Create the project

```bash
oc new-project eneo
```

### 2. Apply RBAC

```bash
oc apply -f manifests/01-rbac.yaml
```

### 3. Configure secrets

Edit `manifests/02-secrets.yaml` and replace all `REPLACE_WITH_*` placeholders:

```bash
# Generate values
POSTGRES_PASSWORD=$(openssl rand -base64 32)
JWT_SECRET=$(openssl rand -hex 32)
URL_SIGNING_KEY=$(openssl rand -hex 32)
ENEO_SUPER_API_KEY=$(openssl rand -hex 32)
```

> **Never commit the filled-in secrets file to version control.**
> Use Sealed Secrets, HashiCorp Vault, or OpenShift Secrets Manager instead.

### 4. Configure the domain

Replace `REPLACE_WITH_YOUR_CLUSTER_DOMAIN` in the following files:
- `manifests/03-configmap.yaml` — `PUBLIC_ORIGIN`, `ENEO_BACKEND_URL`, `PUBLIC_ENEO_BACKEND_URL`, `ORIGIN`
- `manifests/10-routes.yaml` — `host` field in all five Route objects

The hostname format is typically: `eneo.apps.<cluster-name>.<base-domain>`

Find your cluster domain with:
```bash
oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}'
```

### 5. Configure your StorageClass (if needed)

The `eneo-backend-data-pvc` and `eneo-temp-files-pvc` PVCs require ReadWriteMany.
Edit `manifests/04-pvc.yaml` and uncomment/set the `storageClassName` field.

Check available StorageClasses:
```bash
oc get storageclass
```

### 6. Apply all manifests

```bash
oc apply -f manifests/00-namespace.yaml
oc apply -f manifests/01-rbac.yaml
oc apply -f manifests/02-secrets.yaml
oc apply -f manifests/03-configmap.yaml
oc apply -f manifests/04-pvc.yaml
oc apply -f manifests/05-postgres.yaml
oc apply -f manifests/06-redis.yaml
oc apply -f manifests/07-backend.yaml
oc apply -f manifests/08-worker.yaml
oc apply -f manifests/09-frontend.yaml
oc apply -f manifests/10-routes.yaml
```

Or apply everything at once:
```bash
oc apply -f manifests/
```

### 7. First login

Once all pods are Running, visit `https://eneo.apps.<your-cluster-domain>`.

Default credentials (set in `03-configmap.yaml` → `DEFAULT_USER_*`):
- Email: `admin@example.com`
- Password: `REPLACE_WITH_INITIAL_PASSWORD` *(the literal placeholder value, if you have not changed it before deploying)*

**Change the password immediately after first login.**

---

## Startup order

The init containers enforce the same dependency chain as the upstream docker-compose:

```
postgres + redis  →  db-init (migrations)  →  backend  →  worker + frontend
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
├── 00-namespace.yaml      Project namespace
├── 01-rbac.yaml           ServiceAccount
├── 02-secrets.yaml        Secret templates — fill in before applying
├── 03-configmap.yaml      Non-sensitive configuration
├── 04-pvc.yaml            PersistentVolumeClaims
├── 05-postgres.yaml       PostgreSQL StatefulSet + Service
├── 06-redis.yaml          Redis StatefulSet + Service
├── 07-backend.yaml        Backend Deployment + Service
├── 08-worker.yaml         Worker Deployment
├── 09-frontend.yaml       Frontend Deployment + Service
└── 10-routes.yaml         OpenShift Routes (replaces Traefik)
```
