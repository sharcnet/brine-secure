# What brine must do

Both deployments in this repo depend on brine:

- the single-user sandbox, in the top-level folder
- the multi-reviewer grant review, in [`grant-review/`](grant-review/)

Neither can make brine safe from the client side. This is the one list the brine admins
need to answer, in writing, before either deployment handles sensitive data.

Status as of 2026-11-10. "Owner said" means the brine owner gave a verbal answer, recorded in
commit 26b7c46. It still needs confirming in writing, and checking with the tests at the end.

| # | Requirement | Why | Status |
|---|---|---|---|
| 1 | **brine answers only as itself.** Give it its own IP, or make the proxy on its IP drop any request whose Host or SNI isn't `brine.sharcnet.ca`. Set Plausible to invite-only either way | Security groups filter by IP and port only. That IP also serves Plausible Analytics with open sign-up, which an injected agent can use to post data to the internet (SECURITY-REVIEW finding 1, issue #3) | **Open. Blocks the sandbox.** The grant review is protected by its own design (containers have no network, and nginx always sends brine's name), so for it this is a second layer of defence |
| 2 | **Every model runs on SHARCNET hardware.** No fallbacks, aliases or routes to an outside provider | Prompts are the sensitive data | Owner said yes: no forwarding routes configured |
| 3 | **Keys are scoped per deployment:** one LiteLLM team each; each key lists only on-prem models, with a budget, rpm/tpm limits and a duration | Limits what a leaked or misused key can do, and attributes use | Open (sandbox: issue #2). Grant review mints keys this way. **Who mints them:** a credential that can create keys for one team only needs LiteLLM's `team_admin` role, which LiteLLM documents as an Enterprise (paid) feature. Without Enterprise, a brine admin mints and revokes the keys by hand (about 50 per competition); `review add` takes a key file for that case |
| 4 | **Pass-through and side routes are off for these keys:** `/openai_passthrough`, `/anthropic`, `/gemini`, `/vertex_ai`, `/bedrock`, `/azure`, `/langfuse`, `/mcp`, `/a2a`, `/v1/files`, `/v1/batches`, vector stores and assistants (e.g. team or key `allowed_routes`) **[VERIFY]** | Each of these either sends data off-site or stores it where others can read it | Open. The grant review's nginx already allows only two paths; for the sandbox this is the only control |
| 5 | **Client-supplied overrides are refused:** `api_base`/`base_url`, provider credentials, and per-request logging or callback parameters (`langfuse_*`, `callbacks`, `success_callback`). E.g. `allow_client_side_credentials` off **[VERIFY]** | Otherwise a request body could point brine at an outside host | Open |
| 6 | **No content in LiteLLM:** `turn_off_message_logging` on, prompts not stored in spend logs, no callbacks that capture messages (global ones included), log level not DEBUG | Prompts and files must not be stored | Owner said brine logs only token counts and response times |
| 7 | **Model servers keep no content:** no per-request logging, request dumps or prompt tracing in vLLM | Same | Owner's answer above covers "brine"; confirm it covers vLLM workers |
| 8 | **The ingress proxy logs no bodies,** and LiteLLM's admin UI and admin routes can't be reached from user networks | Same; admin routes can mint keys | Open |
| 9 | **Keys work only from where they're used.** Grant review: the VM's floating IP | A key copied off the VM is useless elsewhere | Open. **LiteLLM has no per-key IP allowlist**, and its proxy-wide `allowed_ips` is an Enterprise feature that would lock out every other brine user anyway. Options: a small LiteLLM `custom_auth` hook (open source) that refuses review-team keys from any other address; or accept the risk, since keys stay root-only on the host and never enter a container |
| 10 | **Spend-log retention** matches the deployment's retention rule | Spend logs hold key aliases and timing | Open |
| 11 | **Change control:** changes to LiteLLM config, callbacks, routes or model-server flags are announced to both deployments' admins, and the canary test is rerun | A later change can undo any of the above | Open |
| 12 | **brine's terms of use allow it.** They currently say not to send sensitive data | Policy, not engineering | **Open. Blocks both deployments** |
| 13 | Recommended: a per-key (or per-reviewer) prompt-cache salt where vLLM supports one; traffic from LiteLLM to vLLM encrypted; a named list of who has root on the gateway and model hosts | Cross-user cache timing; transport between brine's parts; who could read memory | Open |

## How to check

Run these against a test key from each deployment. They're also tests 25–27, 49–50 and 55 in
`grant-review/PRIMER.md`.

- **Item 1:** from a host allowed to reach brine's IP,
  `curl -sk -m5 -H 'Host: anything' https://<brine IP>/` returns nothing but brine. So does
  every other name served on that IP.
- **Items 2–4:**
  - `/v1/models` lists only on-prem models.
  - A brine admin's lookup of the key shows its team, models, limits and expiry.
  - Calls to the routes in item 4 with that key are refused.
- **Item 5:** a chat request whose body adds `api_base`, `base_url`, `langfuse_host` and
  `metadata.callbacks` is refused or ignored. brine's admin confirms brine made no outbound
  connection.
- **Items 6–8 (canary):**
  1. Send a prompt containing `PROMPT-CANARY-<random>`, and a file containing
     `FILE-CANARY-<random>`.
  2. brine's admin greps the LiteLLM logs, a dump of the LiteLLM database (including
     SpendLogs), the ingress logs and the vLLM logs for both strings.
  3. There should be no matches.
