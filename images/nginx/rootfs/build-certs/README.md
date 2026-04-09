# Optional CA certificates for the image build

If **`build.sh`** fails inside **`podman build`** with **`curl: (60) SSL certificate`** when downloading from **GitHub** or other HTTPS sites, your network likely uses TLS inspection. The build container only trusts default public CAs until you add your **corporate root (or issuing) CA** here.

1. Obtain a **`.pem`** file (see **How to get the PEM** below). A **chain** file (several **`BEGIN CERTIFICATE`** blocks in one file) is fine.
2. Copy it into this directory, for example:

   ```bash
   cp ~/Downloads/github-com-chain.pem images/nginx/rootfs/build-certs/
   ```

3. Confirm the file is on disk (**`*.pem`** is gitignored, so **`git status`** will not show it):

   ```bash
   ls -la images/nginx/rootfs/build-certs/*.pem
   ```

4. Re-run **`podman build`** for **`images/nginx/rootfs`**.

If the build log shows **`No /build-certs/*.pem in this image build context`**, the PEM was not in this directory when **`podman build`** ran (wrong path, or copy skipped).

Files in this directory are **not** required for upstream-style builds on open networks. **`*.pem`** is gitignored so keys are not committed.

## How to get the PEM

You need the certificate that **signs TLS for HTTPS through your corporate proxy** (the inspection CA), **not** the leaf certificate for a single website.

**Easiest if you already fixed Podman:** Use the **same** **`.pem`** you installed on the Podman machine (**`/etc/pki/ca-trust/source/anchors/`** + **`update-ca-trust extract`**). For example, if **`~/Downloads/github-com-chain.pem`** is your exported chain from **`https://github.com`**, that file is valid both **on the Podman machine** (registry and image pulls) and **here** in **`build-certs/`** for **`build.sh`** **`curl`** inside the Alpine builder. Copy that file from your Mac into **`build-certs/`**.

**Important:** A chain saved from **docker.com** (for example **`docker-com-chain.pem`**) might **not** include the issuer your proxy uses for **github.com**. If **`curl`** still fails on GitHub URLs during **`build.sh`**, export the chain while viewing **`https://github.com`**, or ask IT for the **corporate root / inspection CA** that signs **all** intercepted HTTPS.

**If you do not have that file anymore:**

1. **IT / security** - Ask for the **root** or **issuing CA** used for **SSL inspection** / **HTTPS decryption**, in **PEM** (Base64) form.

2. **Firefox (often clearest chain on macOS)** - Open **`https://github.com`** (or any HTTPS site that fails the same way in the build). Lock icon -> **Connection secure** -> **More information** -> **View Certificate**. Open the **chain** tab. Select the **corporate** certificate (often the **top** root, or the **middle** issuer above the site cert). Export or download as **PEM** if the UI offers it. If you only get **`.crt`** (DER), convert: **`openssl x509 -inform DER -in file.crt -out corp-ca.pem`**.

3. **macOS Keychain Access** - Search for your **company** name or the **issuer** shown in the browser. Export the **CA** certificate as **`.pem`** or **`.cer`**, then **`openssl x509 -inform PEM`** or **`-inform DER`** to normalize to PEM text starting with **`-----BEGIN CERTIFICATE-----`**.

4. **OpenSSL (with proxy if required)** - With **`HTTPS_PROXY`** set if your network needs it:

   ```bash
   openssl s_client -proxy "$HTTPS_PROXY" -connect github.com:443 -showcerts </dev/null 2>/dev/null \
     | sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' > /tmp/chain.pem
   ```

   That file may contain **several** PEM blocks. The **last** block is often the **root**; if GitHub still fails after using only the root, try the **second-to-last** block (corporate **issuing** CA) instead. Save one block as **`corp-ca.pem`**.

**Check:** **`openssl x509 -in corp-ca.pem -noout -subject -issuer`**
