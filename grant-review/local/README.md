# Local test environment (macOS, Apple Silicon)

A Lima VM that stands in for the OpenStack VM, so you can run the whole deployment and the
acceptance tests on a laptop.

```bash
brew install lima            # once
grant-review/local/up        # VM, data disk, configure, image, test reviewers (~10-15 min first time)
cd grant-review && REVIEW_ENV=local/review.env ./acceptance.sh --with-resource
grant-review/local/down      # delete the VM and its data disk
```

`up` builds the same thing the real setup does:

- **Same steps:** it runs `review data-volume` and `review deploy` with the same `vm/configure`.
  The image is built from the same Containerfile and installed with `install-image`.
- **Test reviewers:** it adds `testa`, `testb` and `testa2`, loads `sample.pdf` and `sample.txt`
  for each, and activates them. It also adds `testp`, who stays unactivated, for test 51.
- **Re-running:** it's safe to run `up` again.
- **After `limactl start`:** the VM gets a new SSH host key on every boot. Run `up` again, or
  re-pin through Lima's own channel:
  `printf 'review-vm %s\n' "$(limactl shell grant-review cat /etc/ssh/ssh_host_ed25519_key.pub | cut -d' ' -f1-2)" > local/.ssh/known_hosts`

How it differs from OpenStack:

| | OpenStack | Local |
|---|---|---|
| Architecture | x86_64 | arm64. The image is built inside the VM (`LOCAL_TEST=1` lets `image/build` run there) |
| Network lock | Security group, egress to brine only | None. The VM has normal internet access through the Mac. The container and nftables controls are the same |
| Data volume | Cinder volume (not encrypted) | A raw Lima disk (not encrypted) |
| Host key | Pinned from the console log | Pinned through Lima's own SSH channel |
| brine keys | One minted per reviewer, team-scoped | **Your own key** from `~/.pi/agent/models.json`, for all test reviewers. `LOCAL_TEST=1` stops `review` from ever revoking it |
| Admin SSH | Allowlisted admin addresses | Lima's user and key, from the vzNAT subnet |

**Expected results locally:**

- **SKIP:** tests 43, 44 and 56. They check OpenStack-only things.
- **Web:** open `https://192.168.64.2/` (the address `up` prints), accept the self-signed
  certificate, and sign in as `testa`, `testb` or `testa2`. The passwords are in
  `local/web-passwords.txt` (gitignored).
- **Checked by hand:** test 45 reports volume encryption for information only, and test 46
  notes that snapshots must be checked by hand.
- **FAIL:** test 55 fails until brine stops serving another site on its IP
  (BRINE-REQUIREMENTS item 1).
- **Everything else** should pass.

Don't put real applications in this VM. Its disk isn't encrypted, and it has internet access.
