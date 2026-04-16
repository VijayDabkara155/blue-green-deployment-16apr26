#!/bin/bash
set -euo pipefail

echo "🚀 Starting DevOps Setup (Robust Version)"

export DEBIAN_FRONTEND=noninteractive

# -------------------------------
# 0. Wait for APT Locks
# -------------------------------
wait_for_apt() {
  echo "⏳ Checking for apt locks..."

  while fuser /var/lib/dpkg/lock >/dev/null 2>&1 \
     || fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
     || fuser /var/lib/apt/lists/lock >/dev/null 2>&1 \
     || fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
    echo "🔒 Another apt process is running... waiting"
    sleep 5
  done
}

# -------------------------------
# Retry function
# -------------------------------
retry() {
  local n=0
  local max=5
  local delay=5

  until "$@"; do
    n=$((n+1))
    if [ $n -ge $max ]; then
      echo "❌ Failed after $n attempts: $*"
      exit 1
    fi
    echo "🔁 Retry $n/$max..."
    sleep $delay
  done
}

wait_for_apt

# -------------------------------
# 1. System Update
# -------------------------------
retry apt-get update -y
wait_for_apt

retry apt-get upgrade -y
wait_for_apt

# -------------------------------
# 2. Dependencies
# -------------------------------
retry apt-get install -y ca-certificates curl gnupg lsb-release
wait_for_apt

# -------------------------------
# 3. Docker Install
# -------------------------------
if ! command -v docker >/dev/null 2>&1; then
  echo "🐳 Installing Docker..."

  apt-get remove -y docker docker-engine docker.io containerd runc || true

  install -m 0755 -d /etc/apt/keyrings

  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg

  chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
  "deb [arch=$(dpkg --print-architecture) \
  signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list

  retry apt-get update -y
  wait_for_apt

  retry apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  wait_for_apt

  systemctl enable docker
  systemctl start docker
else
  echo "✅ Docker already installed"
fi

# -------------------------------
# 4. Install k3d
# -------------------------------
if ! command -v k3d >/dev/null 2>&1; then
  echo "⚙️ Installing k3d..."
  curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
else
  echo "✅ k3d already installed"
fi

# -------------------------------
# 5. Install kubectl
# -------------------------------
if ! command -v kubectl >/dev/null 2>&1; then
  echo "📦 Installing kubectl..."
  curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
  rm -f kubectl
else
  echo "✅ kubectl already installed"
fi

# -------------------------------
# 6. Create k3d cluster
# -------------------------------
if ! k3d cluster list | grep -q prod; then
  echo "☸️ Creating k3d cluster..."
  k3d cluster create prod \
    -s 1 -a 1 \
    --k3s-arg "--disable=traefik@server:0" \
    -p "80:80@loadbalancer" \
    -p "443:443@loadbalancer"
else
  echo "✅ k3d cluster already exists"
fi

echo "⏳ Waiting for Kubernetes nodes..."
kubectl wait --for=condition=Ready nodes --all --timeout=180s

# Namespace
kubectl create ns prod --dry-run=client -o yaml | kubectl apply -f -
kubectl config set-context --current --namespace=prod

# -------------------------------
# 7. Install NGINX Ingress
# -------------------------------
if ! kubectl get ns ingress-nginx >/dev/null 2>&1; then
  echo "🌐 Installing NGINX Ingress..."
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml
else
  echo "✅ Ingress already exists"
fi

kubectl wait --namespace ingress-nginx \
  --for=condition=available deployment ingress-nginx-controller \
  --timeout=300s || true

# -------------------------------
# 8. Install Cert-Manager
# -------------------------------
if ! kubectl get ns cert-manager >/dev/null 2>&1; then
  echo "🔐 Installing Cert-Manager..."
  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
else
  echo "✅ Cert-Manager already exists"
fi

kubectl wait --namespace cert-manager \
  --for=condition=available deployment --all \
  --timeout=300s || true

# -------------------------------
# 9. Verification
# -------------------------------
echo "✅ Verifying setup..."

kubectl get nodes
kubectl get pods -A
kubectl get svc -A

echo "🎉 DONE: Fully Ready DevOps Environment!"
