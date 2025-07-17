#!/bin/bash
set -e

# This script is used to set up the environment for TDMC on Kind.
# It includes the installation of necessary tools and configuration of the environment.

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Check if kubectl is installed
if ! command -v kubectl &> /dev/null; then
    echo -e "${YELLOW}kubectl is not installed. Installing kubectl...${NC}"
    # Download and install kubectl
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/kubectl
else
    echo -e "${GREEN}kubectl is already installed.${NC}"
fi

# Check if Kind is installed
if ! command -v kind &> /dev/null; then
    echo -e "${YELLOW}Kind is not installed. Installing Kind...${NC}"
    # Download and install Kind
    curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.29.0/kind-linux-amd64 && sudo install -m 755 ./kind /usr/local/bin/kind
    rm ./kind
else
    echo -e "${GREEN}Kind is already installed.${NC}"
fi

# Check if k9s is installed
if ! command -v k9s &> /dev/null; then
    echo -e "${YELLOW}k9s is not installed. Installing k9s...${NC}"
    # Download and install k9s
    wget -O k9s_linux_amd64.deb https://github.com/derailed/k9s/releases/latest/download/k9s_linux_amd64.deb && sudo dpkg -i k9s_linux_amd64.deb
    rm k9s_linux_amd64.deb
else
    echo -e "${GREEN}k9s is already installed.${NC}"
fi

# Check if krew is installed
if ! command -v kubectl-krew &> /dev/null; then
    echo -e "${YELLOW}krew is not installed. Installing krew...${NC}"
    # Download and install krew
    (
      set -x; cd "$(mktemp -d)" &&
      OS="$(uname | tr '[:upper:]' '[:lower:]')" &&
      ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/\(arm\)\(64\)\?.*/\1\2/' -e 's/aarch64$/arm64/')" &&
      KREW="krew-${OS}_${ARCH}" &&
      curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/${KREW}.tar.gz" &&
      tar zxvf "${KREW}.tar.gz" &&
      ./"${KREW}" install krew
    )
    echo export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH" >> $HOME/.bashrc
    echo '. $HOME/.bashrc' >> $HOME/.bash_profile
    kubectl completion bash | sudo tee /etc/bash_completion.d/kubectl > /dev/null
    echo 'complete -o default -F __start_kubectl k' >> $HOME/.bashrc
    echo -e "${GREEN}krew installed successfully.${NC}"
else
    echo -e "${GREEN}krew is already installed.${NC}"
fi

# Check if kubectx is installed
if ! command -v kubectl-ctx &> /dev/null; then
    echo -e "${YELLOW}kubectx is not installed. Installing kubectx...${NC}"
    # Download and install kubectx
    kubectl krew install ctx
    kubectl krew install ns
else
    echo -e "${GREEN}kubectx is already installed.${NC}"
fi

# Check if yq is installed
if ! command -v yq &> /dev/null; then
    echo -e "${YELLOW}yq is not installed. Installing yq...${NC}"
    # Download and install yq
    wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq &&\
    chmod +x /usr/local/bin/yq
else
    echo -e "${GREEN}yq is already installed.${NC}"
fi

# Check for tdmc-cp cluster
if ! kind get clusters | grep -q "tdmc-cp"; then
    echo -e "${YELLOW}tdmc-cp cluster not found. Creating tdmc-cp cluster...${NC}"
    # Create tdmc-cp cluster
    kind create cluster --name tdmc-cp --config kind/kind-config-tdmc-cp.yaml
else
    echo -e "${GREEN}tdmc-cp cluster already exists.${NC}"
fi

# Check for tdmc-dp-1 cluster
if ! kind get clusters | grep -q "tdmc-dp-1"; then
    echo -e "${YELLOW}tdmc-dp-1 cluster not found. Creating tdmc-dp-1 cluster...${NC}"
    # Create tdmc-dp-1 cluster
    kind create cluster --name tdmc-dp-1 --config kind/kind-config-tdmc-dp-1.yaml
else
    echo -e "${GREEN}tdmc-dp-1 cluster already exists.${NC}"
fi

# Check for tdmc-dp-2 cluster
if ! kind get clusters | grep -q "tdmc-dp-2"; then
    echo -e "${YELLOW}tdmc-dp-2 cluster not found. Creating tdmc-dp-2 cluster...${NC}"
    # Create tdmc-dp-2 cluster
    kind create cluster --name tdmc-dp-2 --config kind/kind-config-tdmc-dp-2.yaml
else
    echo -e "${GREEN}tdmc-dp-2 cluster already exists.${NC}"
fi

# Check if the kind-cloud-provider is running
if ! docker ps | grep -q "cloud-provider-kind"; then
    echo -e "${YELLOW}cloud-provider-kind is not running. Starting cloud-provider-kind...${NC}"
    # Start kind-cloud-provider
    docker run -d --network host -v /var/run/docker.sock:/var/run/docker.sock --name cloud-provider-kind registry.k8s.io/cloud-provider-kind/cloud-controller-manager:v0.7.0
else
    echo -e "${GREEN}cloud-provider-kind is already running.${NC}"
fi

# Check if minio container is running
if ! docker ps | grep -q "minio"; then
    echo -e "${YELLOW}Minio container is not running. Starting Minio...${NC}"
    # Prepare Minio data and certs directories
    mkdir -p ${HOME}/minio/data ${HOME}/minio/certs
    # Create self-signed certificate for Minio
    cat <<EOF > ${HOME}/minio/certs/san.cnf
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
[req_distinguished_name]
countryName = US
stateOrProvinceName = Georgia
localityName = Canton
organizationName = Self-Signed Certificate Org
commonName = self-signed
[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = minio.kind
EOF
    openssl req -x509 -nodes -days 730 -newkey rsa:2048 -keyout ${HOME}/minio/certs/private.key -out ${HOME}/minio/certs/public.crt -config ${HOME}/minio/certs/san.cnf
    docker run -d -p 9000:9000 -p 9001:9001 --user $(id -u):$(id -g) --name minio -e "MINIO_ROOT_USER=ROOTUSER" -e "MINIO_ROOT_PASSWORD=CHANGEME123" -v ${HOME}/minio/data:/data -v ${HOME}/minio/certs:/opt/certs --network kind quay.io/minio/minio server /data --console-address ":9001" --certs-dir /opt/certs
    echo -e "${GREEN}Minio started successfully.${NC}"
else
    echo -e "${GREEN}Minio is already running.${NC}"
fi

# Check if tdmc-installer is present
if [ ! -f tdmc/tdmc-installer ]; then
    echo -e "${YELLOW}tdmc-installer not found. Downloading tdmc-installer...${NC}"
    # Create temporary directory for tdmc-installer
    mkdir -p downloads
    # Download tdmc-installer
    wget --no-check-certificate -O downloads/tdmc-installer.tar https://10.84.76.19/tdmc/tdmc-installer-1.1.1-3ff888.tar
    # Extract tdmc-installer
    tar -xf downloads/tdmc-installer.tar -C downloads
    # Move tdmc-installer to the current directory
    mv downloads/bin/tdmc-installer-linux-amd64 tdmc/tdmc-installer
    chmod +x tdmc/tdmc-installer
    # Move the credential-generator to the tdmc directory
    mv downloads/bin/credential-generator-linux-amd64 tdmc/credential-generator
    chmod +x tdmc/credential-generator
    # Clean up temporary directory
    rm -rf downloads
    echo -e "${GREEN}tdmc-installer downloaded and extracted successfully.${NC}"
else
    echo -e "${GREEN}tdmc-installer is already present.${NC}"
fi

# Check if tdmc CLI is installed
if ! command -v tdmc &> /dev/null; then
    echo -e "${YELLOW}tdmc CLI is not installed. Installing tdmc CLI...${NC}"
    # Create temporary directory for tdmc-installer
    mkdir -p downloads
    # Download and install tdmc CLI
    wget --no-check-certificate -O downloads/tdmc-cli.tar https://10.84.76.19/tdmc/tdmc-cli-1.1.1-3ff888.tar
    # Extract tdmc CLI
    tar -xf downloads/tdmc-cli.tar -C downloads
    # Move tdmc CLI to the current directory
    mv downloads/bin/tdmc-linux-amd64 tdmc/tdmc-cli
    chmod +x tdmc/tdmc-cli
    # Clean up temporary directory
    rm -rf downloads
    echo -e "${GREEN}tdmc CLI installed successfully.${NC}"
else
    echo -e "${GREEN}tdmc CLI is already installed.${NC}"
fi

# Check if inotify.max_user_instances and inotify.max_user_watches are set
if [ ! -f /etc/sysctl.d/increase-inotify.conf ]; then
    echo -e "${YELLOW}Setting inotify.max_user_instances and inotify.max_user_watches...${NC}"
    # Create sysctl configuration file for inotify
    echo "fs.inotify.max_user_instances=512" | sudo tee /etc/sysctl.d/increase-inotify.conf
    echo "fs.inotify.max_user_watches=524288" | sudo tee -a /etc/sysctl.d/increase-inotify.conf
    # Apply the changes
    sudo sysctl --system
    echo -e "${GREEN}inotify settings applied successfully.${NC}"
else
    echo -e "${GREEN}inotify settings are already set.${NC}"
fi

# Add in systemd resolved.conf.d file for TDMC Domain
if [ ! -f /etc/systemd/resolved.conf.d/tdmc.conf ]; then
    echo -e "${YELLOW}Creating systemd resolved.conf.d file for TDMC Domain...${NC}"
    # Create the directory if it doesn't exist
    sudo mkdir -p /etc/systemd/resolved.conf.d
    # Create the configuration file for TDMC Domain
    echo "[Resolve]" | sudo tee /etc/systemd/resolved.conf.d/tdmc.conf
    echo "Domains=~example.domain.com" | sudo tee -a /etc/systemd/resolved.conf.d/tdmc.conf
    echo "DNS=172.17.0.51" | sudo tee -a /etc/systemd/resolved.conf.d/tdmc.conf
    # Restart systemd-resolved service
    sudo systemctl restart systemd-resolved
    echo -e "${GREEN}systemd resolved.conf.d file for TDMC Domain created successfully.${NC}"
else
    echo -e "${GREEN}systemd resolved.conf.d file for TDMC Domain already exists.${NC}"
fi

# Check if the TDMC Control Plane namespace exists
if ! kubectl --context kind-tdmc-cp get namespace mds-cp &> /dev/null; then
    echo -e "${YELLOW}The mds-cp namespace doesn't exist, installing TDMC Control Plane...${NC}"
    # Prompt for Broadcom Registry credentials
    read -p "Enter Broadcom Registry Hostname: " REGISTRY_HOSTNAME
    read -p "Enter Broadcom Registry Username: " REGISTRY_USERNAME
    read -s -p "Enter Broadcom Registry Password: " REGISTRY_PASSWORD
    export REGISTRY_HOSTNAME REGISTRY_USERNAME REGISTRY_PASSWORD
    echo
    # Install TDMC
    tdmc/tdmc-installer install -f <(
      CPKUBECONFIG=$(kind get kubeconfig -n tdmc-cp) yq -e '.Kubeconfig.Kubeconfig = strenv(CPKUBECONFIG)' tdmc/epc-tdmc-install.yaml |
      CPREG=$(tdmc/credential-generator -url $REGISTRY_HOSTNAME -username $REGISTRY_USERNAME -password $REGISTRY_PASSWORD | head -n -2 | tail -n +4 | jq) yq -e '.ImageRegistryDetails.registryCreds = strenv(CPREG)' |
      yq -e '.ImageRegistryDetails.registryUrl = strenv(REGISTRY_HOSTNAME)'
    )
else
    echo -e "${GREEN}TDMC Control Plane namespace already exists.  Assuming the Control plane is installed.${NC}"
fi

# Wait for the TDMC Control Plane to be ready by checking the https endpoint
echo -n -e "${YELLOW}Waiting for TDMC Control Plane to be ready: ${NC}"
while ! curl -s --head --request GET "https://tdmc-cp-epc.example.domain.com" -k | grep "200 OK" > /dev/null; do
    echo -n -e "${YELLOW}.${NC}"
    sleep 5
done
echo -e "${GREEN}Connected${NC}"

