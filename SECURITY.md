# Security policy

## Reporting a vulnerability

If you have found a possible vulnerability, please email
`security at flare dot network`.

## Bug bounties

We sincerely appreciate and encourage reports of suspected security
vulnerabilities. We currently run a bug bounty program through Immunefi, where
eligible researchers can earn rewards for responsibly disclosing valid security
issues. Please refer to our
[Immunefi](https://immunefi.com/bug-bounty/flarenetwork/information/) page for
scope, rules, and submission guidelines.

## Vulnerability disclosures

Critical vulnerabilities will be disclosed via GitHub's
[security advisory](https://github.com/flare-foundation/flare-smart-accounts/security)
system.

## Review scope and audits

### In scope

- `contracts/composer/**/*`
- `contracts/smartAccounts/**/*`
- `contracts/userInterfaces/**/*`
- `contracts/utils/**/*`

### Out of scope

- `contracts/diamond/**/*`
- `contracts/mock/**/*`

### Previous audits

All audit reports are available in the [`audit/`](./audit/) folder.

| Report | Auditor | Date |
| ------ | ------- | ---- |
| [Smart Accounts Audit Report](./audit/2025-11-26-Zellic-Smart_Accounts_Audit_Report.pdf) | Zellic | November 2025 |
| [Smart Accounts Diff Audit v1](./audit/2026-02-12-Zellic-Smart_Accounts_diff_v1.pdf) | Zellic | February 2026 |
| [FAsset Redeem Composer Audit Report](./audit/2026-04-15-Zellic-FAsset_Redeem_Composer_Audit_Report.pdf) | Zellic | April 2026 |
| [Smart Accounts Diff Audit v2](./audit/2026-04-23-Zellic-Smart_Accounts_diff_v2.pdf) | Zellic | April 2026 |
