#!/bin/bash -ex

cd $(git rev-parse --show-toplevel)

DEST_DIR=${1:-.}

kubectl --namespace openstack \
    create secret generic mariadb \
    --dry-run=client \
    -o yaml \
    --type Opaque \
    --from-literal=root-password="$(./scripts/pwgen.sh)" \
    --from-literal=password="$(./scripts/pwgen.sh)" \
    > "${DEST_DIR}/secret-mariadb.yaml"

kubectl --namespace nautobot \
    create secret generic nautobot-env \
    --dry-run=client \
    -o yaml \
    --type Opaque \
    --from-literal=NAUTOBOT_SECRET_KEY="$(./scripts/pwgen.sh)" \
    --from-literal=NAUTOBOT_SUPERUSER_API_TOKEN="$(./scripts/pwgen.sh)" \
    --from-literal=NAUTOBOT_SUPERUSER_PASSWORD="$(./scripts/pwgen.sh)" \
    > "${DEST_DIR}/secret-nautobot-env.yaml"

kubectl --namespace nautobot \
    create secret generic nautobot-redis \
    --dry-run=client \
    -o yaml \
    --type Opaque \
    --from-literal=redis-password="$(./scripts/pwgen.sh)" \
    > "${DEST_DIR}/secret-nautobot-redis.yaml"

NAUTOBOT_SSO_SECRET=$(./scripts/pwgen.sh)
for ns in nautobot dex; do
  kubectl --namespace $ns \
    create secret generic nautobot-sso \
    --dry-run=client \
    -o yaml \
    --type Opaque \
    --from-literal=client-secret="$NAUTOBOT_SSO_SECRET" \
    > "${DEST_DIR}/secret-nautobot-sso-$ns.yaml"
done
unset NAUTOBOT_SSO_SECRET

ARGO_SSO_SECRET=$(./scripts/pwgen.sh)
for ns in argo argo-events argocd dex; do
  kubectl --namespace $ns \
    create secret generic argo-sso \
    --dry-run=client \
    -o yaml \
    --type Opaque \
    --from-literal=client-secret="$ARGO_SSO_SECRET" \
    --from-literal=client-id=argo \
    > "${DEST_DIR}/secret-argo-sso-$ns.yaml"
done
unset ARGO_SSO_SECRET

# create constant OpenStack memcache key to avoid cache invalidation on deploy
export MEMCACHE_SECRET_KEY="$(./scripts/pwgen.sh 64)"
# keystone admin user password
export KEYSTONE_ADMIN_PASSWORD="$(./scripts/pwgen.sh)"
# keystone user password in mariadb for keystone db
export KEYSTONE_DB_PASSWORD="$(./scripts/pwgen.sh)"
# rabbitmq user password for the keystone queues
export KEYSTONE_RABBITMQ_PASSWORD="$(./scripts/pwgen.sh)"
# ironic keystone service account
export IRONIC_KEYSTONE_PASSWORD="$(./scripts/pwgen.sh)"
# ironic user password in mariadb for ironic db
export IRONIC_DB_PASSWORD="$(./scripts/pwgen.sh)"
# rabbitmq user password for the ironic queues
export IRONIC_RABBITMQ_PASSWORD="$(./scripts/pwgen.sh)"

kubectl --namespace openstack \
    create secret generic keystone-rabbitmq-password \
    --type Opaque \
    --from-literal=username="keystone" \
    --from-literal=password="${KEYSTONE_RABBITMQ_PASSWORD}" \
    --dry-run=client -o yaml \
    > "${DEST_DIR}/secret-keystone-rabbitmq-password.yaml"
kubectl --namespace openstack \
    create secret generic keystone-db-password \
    --type Opaque \
    --from-literal=password="${KEYSTONE_DB_PASSWORD}" \
    --dry-run=client -o yaml \
    > "${DEST_DIR}/secret-keystone-db-password.yaml"
kubectl --namespace openstack \
    create secret generic keystone-admin \
    --type Opaque \
    --from-literal=password="${KEYSTONE_ADMIN_PASSWORD}" \
    --dry-run=client -o yaml \
    > "${DEST_DIR}/secret-keystone-admin.yaml"

# ironic credentials
kubectl --namespace openstack \
    create secret generic ironic-rabbitmq-password \
    --type Opaque \
    --from-literal=username="ironic" \
    --from-literal=password="${IRONIC_RABBITMQ_PASSWORD}" \
    --dry-run=client -o yaml > "${DEST_DIR}/secret-ironic-rabbitmq-password.yaml"
kubectl --namespace openstack \
    create secret generic ironic-db-password \
    --type Opaque \
    --from-literal=password="${IRONIC_DB_PASSWORD}" \
    --dry-run=client -o yaml > "${DEST_DIR}/secret-ironic-db-password.yaml"
kubectl --namespace openstack \
    create secret generic ironic-keystone-password \
    --type Opaque \
    --from-literal=username="ironic" \
    --from-literal=password="${IRONIC_KEYSTONE_PASSWORD}" \
    --dry-run=client -o yaml > "${DEST_DIR}/secret-ironic-keystone-password.yaml"

if [ "x${DO_TMPL_VALUES}" = "xy" ]; then
    yq '(.. | select(tag == "!!str")) |= envsubst' \
        "./components/openstack-secrets.tpl.yaml" \
        > "${DEST_DIR}/secret-openstack.yaml"
fi

if [ "x${SKIP_KUBESEAL}" = "xy" ]; then
    echo "Skipping kubeseal"
    exit 0
fi

kubeseal \
    --scope cluster-wide \
    --allow-empty-data \
    -o yaml \
    -f "${DEST_DIR}/secret-mariadb.yaml" \
    -w components/01-secrets/encrypted-mariadb.yaml

kubeseal \
    --scope cluster-wide \
    --allow-empty-data \
    -o yaml \
    -f "${DEST_DIR}/secret-nautobot-env.yaml" \
    -w components/01-secrets/encrypted-nautobot-env.yaml

kubeseal \
    --scope cluster-wide \
    --allow-empty-data \
    -o yaml \
    -f "${DEST_DIR}/secret-nautobot-redis.yaml" \
    -w components/01-secrets/encrypted-nautobot-redis.yaml

for skrt in $(find "${DEST_DIR}" -maxdepth 1 -name "secret-keystone*.yaml" -o -name "secret-ironic*.yaml"); do
    encskrt=$(echo "${skrt}" | sed -e 's/secret-/components\/01-secrets\/encrypted-/')
    kubeseal \
        --scope cluster-wide \
        --allow-empty-data \
        -o yaml \
        -f "${skrt}" \
        -w "${encskrt}"
done

for ns in nautobot dex; do
  kubeseal \
    --scope cluster-wide \
    --allow-empty-data \
    -o yaml \
    -f "${DEST_DIR}/secret-nautobot-sso-$ns.yaml" \
    -w components/01-secrets/encrypted-nautobot-sso-$ns.yaml
done

for ns in argo argo-events argocd dex; do
  kubeseal \
    --scope cluster-wide \
    --allow-empty-data \
    -o yaml \
    -f secret-argo-sso-$ns.yaml \
    -w components/01-secrets/encrypted-argo-sso-$ns.yaml
done

cd components/01-secrets/
rm -f kustomization.yaml
kustomize create --autodetect
cd ../..
