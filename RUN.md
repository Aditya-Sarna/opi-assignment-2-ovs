# How to get REAL `ping_results.txt` and `verification_flows.json`

Multipass on Mac often creates a **3.9 GB** VM that cannot run KinD + KubeVirt.
Use one of these instead.

---

## Option 1 — Docker Desktop on your Mac (recommended)

Skip Multipass entirely. Run everything **directly on your Mac** inside Docker Desktop's Linux VM (you can give it 64 GB disk).

### 1. Install Docker Desktop

Download and install: https://docs.docker.com/desktop/setup/install/mac-install/

Open Docker Desktop and wait until it says **Running**.

### 2. Increase Docker disk (critical)

Docker Desktop → **Settings** → **Resources**:

| Setting | Value |
|---------|--------|
| **Memory** | 8 GB |
| **Disk image size** | **64 GB** (or more) |

Click **Apply & restart**.

### 3. Run the setup on your Mac

Open **Terminal.app**:

```bash
cd "/Users/adityasarna/lfx task 2"
docker info | head -3
./cluster_setup.sh
```

Wait 30–90 minutes (no KVM on Mac → software emulation). When done:

```bash
ls -la ping_results.txt verification_flows.json
grep "packet loss" ping_results.txt
```

---

## Option 2 — GitHub Actions (free, no local disk issues)

Runs on GitHub's **ubuntu-latest** server (~20 GB disk, amd64, Docker included).

### 1. Create a GitHub repo and push

```bash
cd "/Users/adityasarna/lfx task 2"
git init
git add cluster_setup.sh manifests.yaml dpu_offload_concept.md .github/workflows/capture.yml
git commit -m "OPI assignment 2"
git branch -M main
git remote add origin https://github.com/YOUR_USERNAME/opi-assignment-2.git
git push -u origin main
```

### 2. Run the workflow

1. Open your repo on GitHub  
2. **Actions** tab → **Capture OVS Evidence** → **Run workflow**  
3. Wait ~30–90 min for green checkmark  
4. Open the run → **Artifacts** → download **ovs-evidence**  
5. Unzip and copy `ping_results.txt` + `verification_flows.json` into your project folder  

---

## Option 3 — Oracle Cloud Free VM (100 GB disk, always free)

Best if Docker Desktop is too heavy for your Mac.

### 1. Create account

https://www.oracle.com/cloud/free/

### 2. Create VM

- **Shape:** VM.Standard.A1.Flex (Ampere ARM)  
- **OCPUs:** 4 | **Memory:** 24 GB  
- **Boot volume:** 100 GB  
- **Image:** Ubuntu 24.04  

### 3. SSH in and run

```bash
ssh ubuntu@YOUR_VM_PUBLIC_IP

sudo apt-get update
sudo apt-get install -y docker.io curl python3 git
sudo usermod -aG docker ubuntu
newgrp docker

git clone https://github.com/YOUR_USERNAME/opi-assignment-2.git
cd opi-assignment-2
chmod +x cluster_setup.sh
./cluster_setup.sh
```

### 4. Copy results to Mac

```bash
scp ubuntu@YOUR_VM_PUBLIC_IP:~/opi-assignment-2/ping_results.txt \
    ubuntu@YOUR_VM_PUBLIC_IP:~/opi-assignment-2/verification_flows.json \
    "/Users/adityasarna/lfx task 2/"
```

---

## Stop using Multipass

The 3.9 GB default Multipass VM **cannot** run this lab. Delete it:

```bash
/Applications/Multipass.app/Contents/MacOS/multipass delete gratified-raccoon --purge
/Applications/Multipass.app/Contents/MacOS/multipass delete opi-lab --purge
```

---

## Which option to pick?

| Option | Effort | Reliability |
|--------|--------|-------------|
| **Docker Desktop** | Install app, run one script | Good on Mac with 64 GB Docker disk |
| **GitHub Actions** | Push repo, click Run | Best — no local resources |
| **Oracle Cloud** | Free signup, SSH once | Best if Mac is too slow |
