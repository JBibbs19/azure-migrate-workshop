# Migrate scripts – subscription check and prompts (2026-09-23)

Baseline: the scripts in `../azure-migrate-workshop-update/scripts` as last edited by the
OneDrive File Access chat (2026-09-23 18:01). Full line-by-line changes: `changes-vs-previous.diff`.

## All migrate steps (1–6, 3a, 3b)
- No default parameter values. Every required value not passed on the command line is
  prompted for (examples are shown as hints only), so each step can run on its own.
- Uses the current Azure sign-in (`Get-AzContext`). If no one is signed in, the script
  stops and says to run `Connect-AzAccount` / `Set-AzContext`. The subscription is NOT prompted
  for (deploy-lab.ps1 is unchanged and still takes it as hidden input).
- Before changing anything, checks that the step's resources exist in the signed-in subscription
  (source/target resource groups, HyperVHost VM, Azure Migrate project, as applicable). Each
  missing item is reported as “not found in subscription 1a2b3***…” with a hint to switch
  subscription or account.
- Only the first five characters of the subscription ID (and tenant ID) appear in any console
  output, including Azure error messages and resource IDs. Subscription names are not shown.
- Self-contained: no dependency on common.ps1 or migrate-common.ps1.
- Steps 3–5 keep the `-Workload` filter (All / Agentless / AgentBased); it is now prompted.

## Step 2 (Module 1 alignment)
- Locates the ApplianceStore volume (normally E:\Appliance) created by deploy-lab.ps1.
- Unless the appliance VM already exists, downloads the VHD as a background task on the host
  (resumable, SHA256-verified), extracts to `<store>:\Appliance\Extracted`, and imports per
  Module 1 section 3.4 (16 GB static, 8 vCPU, intSwitch, static MAC / .20 reservation,
  80 GB disk, VM files in `<store>:\Appliance\VMs`). Waits as long as needed with a
  keep-waiting prompt; project key is never displayed in full.
- Discovery waits for the four workload names; assessment covers exactly those four.

Not tested in a live environment; do a rehearsal run before delivery.
