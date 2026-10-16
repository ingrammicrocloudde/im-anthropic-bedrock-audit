# Amazon Bedrock Audit Script (Anthropic / Claude)

A diagnostic script that audits an AWS account for Anthropic (Claude) model
access and quota problems on **Amazon Bedrock**. It inventories the Anthropic
foundation models visible to the account and reports on model access, quotas,
inference profiles and the stored use-case form. A missing-access or "quota is
0" situation can be understood quickly and documented for a support request.

The script is **read-only by default**. On request, it can also fix the most
common blockers: submit the Anthropic use case, create model agreements and
request quota increases.

It is provided by Ingram Micro for partners and customers who consume Anthropic
models through Amazon Bedrock. Version 0.22 is extended by inQdo.

## Why this exists

Getting the newest Claude models running on Bedrock can fail for several
different reasons that look similar from the outside:

- no use-case form submitted;
- missing model agreement;
- model not authorized or entitled in the region;
- access granted, but the tokens-per-minute quota is still `0`.

This script makes those states explicit and distinguishable in a single
report. It ends with a per-model summary and an exit code, so you can see at a
glance whether every model is usable.

## What it checks

- Dynamic Anthropic foundation-model inventory (no hard-coded model versions)
- System inference profiles (EU / Global)
- Stored Anthropic use case (FTU)
- Agreement, authorization, entitlement and region availability per model,
  listing **every** failing check (e.g. `AGREEMENT+AUTH`)
- Applied runtime quotas vs. AWS default quotas (TPM / RPM), with scope
- Service Quotas request history
- Optional runtime test (`--invoke`) when access is `READY` and a matching TPM
  quota is `> 0`
- One or more regions in a single run

## What it can request (opt-in)

| Option | What it does |
| --- | --- |
| `--submit-use-case` | Submits the Anthropic use case if none exists |
| `--request-agreement` | Creates model agreements for models without one; a private (reseller) offer is preferred |
| `--request-quota` | Requests a quota increase for runtime quotas at `0`, for models that have an agreement |

Each of these changes the account and runs only when you pass the option.
Without `--yes` you select per item what is requested.

## Safety

- **Read-only by default.** Without change options, nothing is written to the
  account and no model is invoked.
- **Changes only on request.** Use case, agreements and quota requests run only
  with their option. You select the items, or confirm the list of changes once
  at the start when using `--yes` in a terminal. The use case always asks for a
  separate confirmation, unless it comes from a file together with `--yes`.
- **Minimal cost.** A tiny runtime invocation (max. 8 tokens) runs **only** with
  `--invoke`.
- **Exactly one output file:** the full terminal transcript, saved as
  `IM_Bedrock_Audit_<Partner>_<Customer>_<account>_<timestamp>.txt`. All
  intermediate data is kept in a temporary directory and removed on exit.

> Review any script before running it in your account — including this one.
> Agreements on a **public** offer may not be billed through Ingram Micro; check
> the offer type in the report before requesting.

## Requirements

- Bash 3.2 or later (the script re-execs under Bash if started with `sh`).
  Written for Bash 3.2 (macOS default); tested with Bash 5.2.
- AWS CLI v2, authenticated (a named profile or ambient CloudShell/session
  credentials)
- `python3` (recommended — used to decode and show the use case)
- `awk`, `sed`, `grep`, `mkfifo` (standard on Linux, macOS and CloudShell)

IAM permissions:

| Action | Permissions |
| --- | --- |
| Audit (always) | `bedrock:List*`, `bedrock:Get*`, `servicequotas:List*` / `Get*`, `cloudtrail:LookupEvents`, `sts:GetCallerIdentity` |
| `--invoke` | `bedrock:InvokeModel` (Converse) |
| `--submit-use-case` | `bedrock:PutUseCaseForModelAccess` |
| `--request-agreement` | `bedrock:ListFoundationModelAgreementOffers`, `bedrock:CreateFoundationModelAgreement`, `aws-marketplace:Subscribe`, `aws-marketplace:ViewSubscriptions` |
| `--request-quota` | `servicequotas:RequestServiceQuotaIncrease` |

## Usage

```bash
chmod +x im-anthropic-bedrock-audit.sh
./im-anthropic-bedrock-audit.sh [--profile NAME] [--region R1[,R2,...]] [--invoke] [--global]
    [--submit-use-case [--use-case-file FILE]]
    [--request-agreement [--private-only] [--include-legacy]]
    [--request-quota [--quota-value N] [--quota-scope eu|global|all]]
    [--yes] [--parallel N]
```

Typical workflow:

```bash
# 1. Read-only: what is missing?
./im-anthropic-bedrock-audit.sh

# 2. Request use case, agreements and quotas, selecting per item
./im-anthropic-bedrock-audit.sh --submit-use-case --request-agreement --request-quota

# 3. Everything at once: one confirmation at the start, no further questions
./im-anthropic-bedrock-audit.sh --submit-use-case --request-agreement --request-quota --yes

# 4. After approval: check that the models really answer
./im-anthropic-bedrock-audit.sh --invoke

# Several regions in one run
./im-anthropic-bedrock-audit.sh --region eu-central-1,eu-west-1
```

Re-run the read-only audit after each request until the summary shows no
`ISSUE` (exit code `0`). Agreements and quota requests can take minutes to days.

### Options

| Option | Description | Changes the account? |
| --- | --- | --- |
| `--profile NAME` | AWS CLI profile. If omitted, the current session / CloudShell credentials are offered first, then any named profiles | No |
| `--region R1,R2` | One or more regions, comma-separated. Default `eu-central-1` | No |
| `--invoke` | Minimal runtime test per usable model (max. 8 tokens). Can create minimal Bedrock usage/cost | No |
| `--global` | With `--invoke`, also test Global inference profiles; widens the default quota scope to `all` | No |
| `--parallel N` | Parallel AWS calls for availability and offer lookups. Default 6; `1` = sequential | No |
| `--submit-use-case` | Submit the Anthropic use case if none exists; fields are asked interactively | Yes |
| `--use-case-file FILE` | Read the use case from a JSON file (implies `--submit-use-case`) | Yes |
| `--request-agreement` | Create agreements for models whose agreement is `NOT_AVAILABLE` or `ERROR` | Yes |
| `--private-only` | Only accept private offers (e.g. Ingram Micro reselling) | Yes |
| `--include-legacy` | Also include `LEGACY` models in agreement and quota requests | Yes |
| `--request-quota` | Request quota increases for quotas at `0`, for models with an agreement | Yes |
| `--quota-value N` | Request N instead of the AWS default; never below the default | Yes |
| `--quota-scope S` | `eu` (EU / regional, default), `global` or `all` | Yes |
| `--yes` | No interactive selection: request everything that qualifies, for the change options you passed | Yes |
| `-h`, `--help` | Show help | No |

### Run in AWS CloudShell (no local setup)

1. Sign in to the AWS Console for the account you want to audit.
2. Set the Region (top-right) to the region you use (e.g. Europe (Frankfurt),
   `eu-central-1`).
3. Open **CloudShell**, upload `im-anthropic-bedrock-audit.sh`
   (**Actions → Upload file**), then:

   ```bash
   chmod +x im-anthropic-bedrock-audit.sh
   ./im-anthropic-bedrock-audit.sh
   ```

4. Download the generated `IM_Bedrock_Audit_...txt` (**Actions → Download file**).

## Audit steps

Steps 0 and 1 run once; steps 2–10 run per region. The requests (steps 8 and
9) run **before** the runtime test (step 10), so the test sees the state after
the requests.

| Step | Name | What to look for |
| --- | --- | --- |
| 0 | Pre-flight | AWS CLI and Bash version; credential selection |
| 1 | Account | Account ID, caller, regions and `Mode` (read-only or which changes are enabled) |
| 2 | Foundation model inventory | All Anthropic models, `ACTIVE` or `LEGACY`. If this call fails, the region is skipped |
| 3 | System inference profiles | EU and Global profiles (`eu.` / `global.`) per model |
| 4 | Anthropic FTU / use case | Account-wide; checked in the first region only |
| 5 | Model access / availability | `RESULT`: `READY`, or every failing check (e.g. `AGREEMENT+AUTH`) |
| 6 | Relevant runtime quotas | `Actual` vs. `Default`, with scope (EU / GLOBAL). `Actual: 0` means the model is not usable |
| 7 | Quota request history | Earlier requests with date, status and case ID |
| 8 | Model agreement requests | Models without an agreement, their offer type and the result of the request |
| 9 | Runtime quota increase requests | Quotas at `0`, the requested value and the result |
| 10 | Runtime test and model status | Per model `OK`, `ISSUE`, `CHECK` or `LEGACY`; with `--invoke` also the test result |

The report ends with a summary: what was requested per region, every model
that is not `OK`, the counts and the verdict with exit code.

## Submitting the use case

Anthropic models only work once a use case (first-time use) has been submitted
for the account. Step 4 checks this. If it is missing, `--submit-use-case`
submits it with `aws bedrock put-use-case-for-model-access`. Do this before
requesting agreements.

```bash
# Interactive: the script asks for the fields and a confirmation
./im-anthropic-bedrock-audit.sh --submit-use-case

# From a file, without questions
./im-anthropic-bedrock-audit.sh --use-case-file usecase.json --yes
```

Example `usecase.json`:

```json
{
  "companyName": "Customer B.V.",
  "companyWebsite": "https://www.customer.example",
  "intendedUsers": "0",
  "industryOption": "Technology",
  "otherIndustryOption": "",
  "useCases": "Internal assistant for employees: document summaries and code generation."
}
```

| Field | Content |
| --- | --- |
| `companyName` | Name of the customer (owner of the AWS account) |
| `companyWebsite` | Customer website, including `https://` |
| `intendedUsers` | `0` = internal, `1` = external, `2` = internal and external |
| `industryOption` | Industry, e.g. Technology, Retail or Finance |
| `otherIndustryOption` | Optional clarification of the industry |
| `useCases` | What the models are used for; at least 10 characters |

- The script only submits a use case when none exists. If step 4 returns
  AccessDenied, nothing is submitted, because a use case may already exist.
- After submitting, the script reads the use case back to verify it.
- Anthropic sees these details. Fill them in on behalf of the customer,
  honestly and specifically.

## Requesting agreements

`--request-agreement` creates a Marketplace agreement for each model you
select. Only models with agreement `NOT_AVAILABLE` or `ERROR` that are offered
in the region are candidates. `PENDING` models are not requested again, and
`LEGACY` models are skipped unless `--include-legacy` is passed.

1. Per model, the script retrieves an offer with
   `aws bedrock list-foundation-model-agreement-offers --model-id <id>` and
   with `--offer-type ALL`, for all models in parallel.
2. A private offer (Ingram Micro reselling) always wins. Otherwise the offer
   from the first call is used.
3. You select: `all`, `none` or numbers such as `1,3,5`. Empty means nothing is
   requested. With `--yes` everything is selected.
4. All selected agreements are created with
   `aws bedrock create-foundation-model-agreement --model-id <id> --offer-token <token>`.
5. The script waits up to about 60 seconds in total for activation and shows
   `PENDING`, `AVAILABLE` or `ERROR` per model.
6. Availability of those models is checked again, so steps 9 and 10 use the
   new state.

| Offer type | Meaning |
| --- | --- |
| `PRIVATE` | Private offer, e.g. the Ingram Micro reselling offer. Always used when present |
| `PUBLIC` | Public AWS offer. May not be billed through Ingram Micro |
| `UNKNOWN` | An offer was returned, but its type could not be determined |
| `PUB-ONLY` | Only a public offer; skipped because `--private-only` is set |
| `NONE` / `API-ERROR` | AWS returned no offer token; cannot be requested |

If every model shows `PUBLIC` with `PRIV 0`, there is no private Ingram Micro
offer for this account (yet). Check with Ingram Micro before accepting a public
offer, or run with `--private-only`.

## Requesting quota increases

`--request-quota` requests an increase for Anthropic runtime quotas that are
`0` while the AWS default is higher. By default it requests the AWS default of
each quota (e.g. 10,000,000 tokens per minute). AWS rejects values below the
default; if AWS demands a value above the default, the script retries once with
default + 1. With `--quota-value N` you request a higher value; a value below
the default is raised to the default.

- **Scope:** EU / regional quotas by default. With `--global` both EU and
  Global; with `--quota-scope eu|global|all` you choose.
- **Agreement first:** quotas of models without an agreement are shown as
  `NO-AGREEMENT` and skipped.
- **Skipped:** quotas with an open request (`OPEN-REQ`) and quotas of `LEGACY`
  models (unless `--include-legacy`).
- **Result:** status and case or request ID per request. A request that is
  approved immediately is used by the runtime test in the same run.

AWS reviews each request; this can take hours to days. A quota of `0` with a
high default is often an account-level restriction. If a request is denied or
stalls, open an AWS Support case (Service limit increase → Amazon Bedrock) and
attach the report.

## Output / result codes

| Code | Where | Meaning | What to do |
| --- | --- | --- | --- |
| `READY` | Step 5 | Agreement, authorization, entitlement and region are fine | Check the quota in step 6 |
| `AGREEMENT` | Step 5 | No active agreement for this model | `--request-agreement` |
| `AUTH` | Step 5 | The account is not authorized for this model | Check the use case (step 4) and IAM / SCP permissions |
| `ENTITLEMENT` | Step 5 | No entitlement, often because the Marketplace subscription is still processing | Wait and re-run; if it persists, contact Ingram Micro |
| `REGION` | Step 5 | The model is not available in this region | Other region or an inference profile |
| `API-ERROR` | Step 5 / 8 | The AWS call failed | Check the caller's permissions; the run ends with exit code 3 |
| `NO-AGREEMENT` | Step 9 | Quota belongs to a model without an agreement; not requested | `--request-agreement` first |
| `OPEN-REQ` | Step 9 | A request for this quota is already open | Wait for AWS; status in step 7 |
| `IllegalArgumentException` ("greater than the default") | Step 9 | AWS rejects a value below (or equal to) the default | The script requests the default and retries with default + 1; otherwise use a higher `--quota-value` |
| `OK` | Step 10 | Access fine and quota above 0; with `--invoke` also a successful test | No action needed |
| `ISSUE (QUOTA0)` | Step 10 | Access fine, but the quota is 0 | `--request-quota` |
| `ISSUE (EU-QUOTA0 ...)` | Step 10 | Only the Global quota is above 0 | Run with `--global`, or request EU quota |
| `ISSUE (TEST)` | Step 10 | The runtime test failed; the error is shown below the table | See the test codes below |
| `CHECK (NO-QUOTA)` | Step 10 | No dedicated quota found for this model (often `LEGACY`) | Verify with `--invoke` |
| `LEGACY` | Step 10 | `LEGACY` model that is not usable; not counted in the verdict | Usually no action needed |
| `RETENTION-REQ` | Test | The model requires an account-wide data-retention opt-in | Enable it separately and re-run (the audit changes no such setting) |
| `ACCESS-FAIL` | Test | The call was denied | Check agreement and IAM permissions |
| `THROTTLED` | Test | Quota or rate limit reached | Check step 6; request more quota if needed |
| `AccessDenied` | Step 8 / 9 | The caller lacks permissions for the request | See the IAM table under Requirements |

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | All `ACTIVE` models are usable |
| `2` | Issues found (`ISSUE`) |
| `3` | Audit incomplete: one or more AWS calls failed (see the `[FAIL]` lines) |
| `1` | Fatal error, e.g. no credentials or an invalid option |

## Testing

A test suite runs the script against a mocked AWS CLI: no AWS account, no
network, no cost.

```bash
bash tests/test-im-anthropic-bedrock-audit.sh
```

- Exit code `0` when all tests pass, `1` on a failure. With `KEEP=1` the output
  of each scenario is kept for inspection.
- The suite sets `IM_AUDIT_POLL_SECONDS=0` so the script does not wait between
  status checks; for normal use the default stays 5 seconds.
- `TEST-RESULTS.md` compares the current version with the original v0.21.
- The tests use mocked AWS responses. Verify a new version with a read-only run
  against a real account as well.

## Version history

| Version | Main change |
| --- | --- |
| 0.21 | Original by Ingram Micro: read-only audit |
| 0.22 | Extended by inQdo: submit the use case, request agreements and quota increases, multiple regions, parallel and fewer AWS calls, per-model summary, exit codes, requests before the runtime test, test suite |

## License & disclaimer

Released under the [MIT License](LICENSE). The software is provided **"as is",
without warranty of any kind** and without any liability — see the LICENSE file
for the full disclaimer. Running the script is at your own responsibility.
With `--invoke` it may create minimal Amazon Bedrock usage/cost. With the
change options it creates agreements, use-case submissions and quota requests
in the account.

## Contact

- Original script: Tobias Tomandl — <tobias.tomandl@ingrammicro.com>
- Extensions (v0.22): Corne van der Steen, inQdo — <corne.vandersteen@inqdo.com>

---

Copyright (c) 2026 Ingram Micro
