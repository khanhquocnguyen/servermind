# Cloudflare Origin Certificate

Traefik serves two files per domain from this folder, written by `../add-cert.sh`:

```
certs/<domain>.pem   # the certificate, e.g. example.com.pem   (644)
certs/<domain>.key   # the private key                          (600)
```

Do not create them by hand and do not edit `dynamic/tls.yml` by hand: the script regenerates that file
from whatever is in this folder and your edits would be lost.

## Get the certificate (once per domain, valid up to 15 years)

1. Cloudflare dashboard → pick the domain → **SSL/TLS → Origin Server → Create Certificate**
2. Key type: RSA (2048). Hostnames: `example.com` and `*.example.com`. Validity: 15 years.
3. Keep that page open and run on the server:

   ```bash
   cd ~/traefik && bash add-cert.sh
   ```

   Paste the **Origin Certificate** block when asked, then the **Private Key** block. The script
   validates both, writes the files, regenerates `dynamic/tls.yml` and verifies Traefik serves the
   new cert. No restart needed.
4. **SSL/TLS → Overview**: set the encryption mode to **Full (strict)**.
5. Every hostname you route must be **Proxied** (orange cloud) in Cloudflare DNS, as an **A** record.
   The origin cert is only trusted by Cloudflare, and Traefik only accepts connections from Cloudflare.

## A second domain

Run `add-cert.sh` again with the other domain. One cert per domain covers all its subdomains.

## Never commit these files

`../.gitignore` excludes `certs/*.pem` and `certs/*.key`.
