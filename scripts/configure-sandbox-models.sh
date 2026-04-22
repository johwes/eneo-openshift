#!/usr/bin/env bash
# configure-sandbox-models.sh
#
# Registers the three Red Hat Developer Sandbox hosted vLLM models in Eneo.
# Run this after a fresh Eneo deployment on the sandbox cluster.
#
# Usage:
#   ./scripts/configure-sandbox-models.sh \
#     --namespace rhn-sa-<your-id>-dev \
#     --url https://eneo-rhn-sa-<your-id>-dev.apps.rm3.7wse.p1.openshiftapps.com \
#     --password <your-admin-password>
#
# Prerequisites:
#   - oc CLI, logged in to the sandbox cluster
#   - Eneo backend running and reachable
#   - ENCRYPTION_KEY set in eneo-backend-secret (required for model provider API)

set -euo pipefail

NAMESPACE=""
ENEO_URL=""
ADMIN_EMAIL="admin@example.com"
ADMIN_PASSWORD=""

usage() {
  echo "Usage: $0 --namespace <ns> --url <eneo-url> --password <admin-password> [--email <admin-email>]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --url)       ENEO_URL="$2"; shift 2 ;;
    --password)  ADMIN_PASSWORD="$2"; shift 2 ;;
    --email)     ADMIN_EMAIL="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; usage ;;
  esac
done

[[ -z "$NAMESPACE" || -z "$ENEO_URL" || -z "$ADMIN_PASSWORD" ]] && usage

echo "==> Creating ServiceAccount token secret in namespace ${NAMESPACE}"
oc apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: eneo-app-sa-token
  namespace: ${NAMESPACE}
  annotations:
    kubernetes.io/service-account.name: eneo-app
type: kubernetes.io/service-account-token
EOF

echo "==> Waiting for token to be issued..."
for i in $(seq 1 12); do
  SA_TOKEN=$(oc get secret eneo-app-sa-token -n "${NAMESPACE}" \
    -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || true)
  if [[ ${#SA_TOKEN} -gt 100 ]]; then
    echo "    Token ready (${#SA_TOKEN} chars)"
    break
  fi
  sleep 5
done
if [[ ${#SA_TOKEN} -le 100 ]]; then
  echo "ERROR: Token not populated after 60s. Check that eneo-app ServiceAccount exists in ${NAMESPACE}."
  exit 1
fi

echo "==> Logging in to Eneo at ${ENEO_URL}"
AUTH_RESPONSE=$(curl -sf -X POST "${ENEO_URL}/api/v1/users/login/token/" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=${ADMIN_EMAIL}&password=${ADMIN_PASSWORD}")
JWT=$(echo "$AUTH_RESPONSE" | python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])")
echo "    Login successful"

# Helper: create provider + tenant model, return provider ID
create_model() {
  local display_name="$1"
  local model_id="$2"
  local endpoint="$3"
  local max_input="$4"
  local is_default="${5:-false}"

  echo ""
  echo "==> Registering provider: ${display_name}"

  EXISTING=$(curl -sf "${ENEO_URL}/api/v1/admin/model-providers/" \
    -H "Authorization: Bearer ${JWT}" \
    | python3 -c "
import json,sys
providers = json.load(sys.stdin)
for p in providers:
    if p.get('config',{}).get('model_name') == '${model_id}':
        print(p['id'])
        break
" 2>/dev/null || true)

  if [[ -n "$EXISTING" ]]; then
    echo "    Provider already exists (${EXISTING}), skipping creation"
    PROVIDER_ID="$EXISTING"
  else
    PROVIDER_RESPONSE=$(curl -sf -X POST "${ENEO_URL}/api/v1/admin/model-providers/" \
      -H "Authorization: Bearer ${JWT}" \
      -H "Content-Type: application/json" \
      -d "{
        \"name\": \"${display_name}\",
        \"provider_type\": \"hosted_vllm\",
        \"credentials\": {\"api_key\": \"${SA_TOKEN}\"},
        \"config\": {
          \"endpoint\": \"${endpoint}\",
          \"model_name\": \"${model_id}\"
        }
      }")
    PROVIDER_ID=$(echo "$PROVIDER_RESPONSE" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
    echo "    Provider created: ${PROVIDER_ID}"
  fi

  # Test connectivity
  TEST=$(curl -sf -X POST "${ENEO_URL}/api/v1/admin/model-providers/${PROVIDER_ID}/test/" \
    -H "Authorization: Bearer ${JWT}" \
    -H "Content-Type: application/json" \
    -d '{}')
  SUCCESS=$(echo "$TEST" | python3 -c "import json,sys; print(json.load(sys.stdin).get('success', False))")
  MESSAGE=$(echo "$TEST" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('message') or d.get('error',''))")
  if [[ "$SUCCESS" == "True" ]]; then
    echo "    Connection test: OK — ${MESSAGE}"
  else
    echo "    WARNING: Connection test failed — ${MESSAGE}"
  fi

  # Check if tenant model already exists
  EXISTING_MODEL=$(curl -sf "${ENEO_URL}/api/v1/completion-models/" \
    -H "Authorization: Bearer ${JWT}" \
    | python3 -c "
import json,sys
data = json.load(sys.stdin)
items = data.get('items', data) if isinstance(data, dict) else data
for m in items:
    if m.get('name') == '${model_id}':
        print(m['id'])
        break
" 2>/dev/null || true)

  if [[ -n "$EXISTING_MODEL" ]]; then
    echo "    Tenant model already exists (${EXISTING_MODEL}), skipping"
  else
    MODEL_RESPONSE=$(curl -sf -X POST "${ENEO_URL}/api/v1/admin/tenant-models/completion/" \
      -H "Authorization: Bearer ${JWT}" \
      -H "Content-Type: application/json" \
      -d "{
        \"provider_id\": \"${PROVIDER_ID}\",
        \"name\": \"${model_id}\",
        \"display_name\": \"${display_name}\",
        \"max_input_tokens\": ${max_input},
        \"max_output_tokens\": 4096,
        \"hosting\": \"eu\",
        \"is_active\": true,
        \"is_default\": ${is_default}
      }")
    MODEL_ID=$(echo "$MODEL_RESPONSE" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
    echo "    Tenant model created: ${MODEL_ID}"
  fi
}

BASE="sandbox-shared-models.svc.cluster.local:8443/v1"

create_model \
  "Granite 3.1 8B (FP8)" \
  "isvc-granite-31-8b-fp8" \
  "https://isvc-granite-31-8b-fp8-predictor.${BASE}" \
  65536 \
  "true"

create_model \
  "Nemotron Nano 9B v2 (FP8)" \
  "isvc-nemotron-nano-9b-v2-fp8" \
  "https://isvc-nemotron-nano-9b-v2-fp8-predictor.${BASE}" \
  128000 \
  "false"

create_model \
  "Qwen3 8B (FP8)" \
  "isvc-qwen3-8b-fp8" \
  "https://isvc-qwen3-8b-fp8-predictor.${BASE}" \
  32768 \
  "false"

echo ""
echo "==> Done. Visit ${ENEO_URL} to start using Eneo with the sandbox models."
