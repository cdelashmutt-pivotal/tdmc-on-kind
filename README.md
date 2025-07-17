# TDMC on EPC
* Delete all Harbor containers on Jumpbox
* Install kind:
  * ```curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.29.0/kind-linux-amd64 && sudo install -m 755 ./kind /usr/local/bin/kind```
* Install k9s
  * ```wget -O k9s_linux_amd64.deb https://github.com/derailed/k9s/releases/latest/download/k9s_linux_amd64.deb && sudo dpkg -i k9s_linux_amd64.deb```
* Install krew:
  * ```
    (
      set -x; cd "$(mktemp -d)" &&
      OS="$(uname | tr '[:upper:]' '[:lower:]')" &&
      ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/\(arm\)\(64\)\?.*/\1\2/' -e 's/aarch64$/arm64/')" &&
      KREW="krew-${OS}_${ARCH}" &&
      curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/${KREW}.tar.gz" &&
      tar zxvf "${KREW}.tar.gz" &&
      ./"${KREW}" install krew
    )
    ```
  * `echo export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH" >> $HOME/.bashrc`
  * `echo '. $HOME/.bashrc' >> $HOME/.bash_profile`
  * `kubectl completion bash | sudo tee /etc/bash_completion.d/kubectl > /dev/null`
  * `echo 'complete -o default -F __start_kubectl k' >> $HOME/.bashrc`
* kubectl krew install ctx
* kubectxl krew install ns
* Create kind cluster tdmc-cp with kind-config-tdmc-cp.yaml config.
* Create two kind clusters (tdmc-dp1, tdmc-dp2) with kind-config-tdmc-dp.yaml
* Run the kind cloud provider
  * `docker run -d --network host -v /var/run/docker.sock:/var/run/docker.sock --name cloud-provider-kind registry.k8s.io/cloud-provider-kind/cloud-controller-manager:v0.7.0`
* Run a Minio Container
  * mkdir -p ${HOME}/minio/data ${HOME}/minio/certs
  * Create a file in ${HOME}/minio/certs called san.cnf:
    * ```
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
      IP.1 = 172.17.0.19
      DNS.1 = minio.kind
      ```
    * `openssl req -x509 -nodes -days 730 -newkey rsa:2048 -keyout private.key -out public.crt -config san.cnf`
  * docker run -d -p 9000:9000 -p 9001:9001 --user $(id -u):$(id -g) --name minio -e "MINIO_ROOT_USER=ROOTUSER" -e "MINIO_ROOT_PASSWORD=CHANGEME123" -v ${HOME}/minio/data:/data -v ${HOME}/minio/certs:/opt/certs --network kind quay.io/minio/minio server /data --console-address ":9001" --certs-dir /opt/certs
* Put tdmc-installer on jumpbox
  * Prereleases at https://usw1.packages.broadcom.com/ui/repos/tree/General/tdh-generic-dev-local/tdh-internal/tdmc-installer
* TDMC_KUBECONFIG=$(kind get kubeconfig -n tdmc-cp) yq e -i '.Kubeconfig.Kubeconfig = strenv(TDMC_KUBECONFIG)' tdmc-installer.yaml
* Add more inotify instances
  * sudo sh -c 'echo "fs.inotify.max_user_instances=512\nfs.inotify.max_user_watches=524288" > /etc/sysctl.d/increase-inotify.conf'
  * Then call `sudo sysctl --system`
* Install TDMC
  * `./tdmc-installer-linux-amd64 install -f tdmc-installer.yaml`
* Onramp TKGM Cloud Accounts
  * `kind get kubeconfig --name=tdmc-dp1 | DP_IP="https://$(docker inspect tdmc-dp1-control-plane | jq -r '.[0].NetworkSettings.Networks.kind.IPAddress'):6443" yq e '.clusters[0].cluster.server = strenv(DP_IP)' | base64 -w0`
  * `kind get kubeconfig --name=tdmc-dp2 | DP_IP="https://$(docker inspect tdmc-dp2-control-plane | jq -r '.[0].NetworkSettings.Networks.kind.IPAddress'):6443" yq e '.clusters[0].cluster.server = strenv(DP_IP)' | base64 -w0`
* Onramp Data Plane Clusters
* Add minio as external object storage with credentials used above.
* Create Org called "Test Org", and make admin@tdmc.example.com the admin
* Create self-DR config
* Switch to Org, go to "Identities & Access Management" -> "Policies" and create an "allow-all" network policy.
  * CIDR: 0.0.0.0/0
  * Check all ports


Restarts
* You will need to heal the ips in the mds-infra/tds-dns-server-bind-config and kube-system/tdh-dns as the kind cloud provider might change the IPs of services.
  * Grab the UDP dns server service IP, and the traefik service IP to replace into the configmap, and then restart the mds-infra/tdh-dns-server statefulset.
  * Delete the old kindccm-* pods
  * Relaunch the cloud-provider-kind pod