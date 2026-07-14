# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

An unlocked Salesforce package (`LicenseManager`, see `sfdx-project.json`) that adds an **analytical layer** for determining which Salesforce Product Licenses are actually in use. The core insight (see `docs/00-problema-gestao-licencas.md` and `README.md`): native license assignment alone is ambiguous — different products can provision the _same_ Setting Licenses — so this app determines product usage by combining assignments with other user attributes via a per-license SOQL query.

The solution now includes **Apex classes** for assignment automation (`LM_AssignmentGenerationBatch`, `LM_AssignmentAllocator`) alongside the declarative components. There are currently **no triggers and no LWC/Aura components** — the `triggers/` and `aura/` directories remain empty. The functionality lives in custom objects, Apex batch jobs, reports, permission sets, and a CRM Analytics app.

## Data model

Five custom objects (all prefixed `LM_`, under `force-app/main/default/objects/`):

- **`LM_ProductLicense__c`** — catalog of what is purchased (Base or Add-On). Has `Quantity`/`AssignedQuantity` rollups, `AvailableQuantity` formula, `Weight`, `Type`, `AssignmentType`, `UserType`, `Org`.
- **`LM_ProductLicensePersona__c`** — the analytical layer: holds `Query__c` (SOQL) defining who uses the license. Master-detail to `ProductLicense`.
- **`LM_PersonaPurchaseAllocation__c`** — junction linking Persona to PurchaseCondition with a `Weight__c` quota. Master-detail to `ProductLicensePersona__c`, lookup to `ProductLicensePurchaseCondition__c`. Enables per-purchase financial allocation.
- **`LM_ProductLicensePurchaseCondition__c`** — commercial terms (price, quantity, dates, org hierarchy fields). Maintained by account managers.
- **`LM_ProductLicenseUserAssignment__c`** — detail rows of users assigned to a license (`Username`, `IsActive`, `LastLoginDate`, `UniqueConstraint__c`, `PurchaseCondition__c`, `Persona__c`). Populated by `LM_AssignmentGenerationBatch` (truncate-and-reload materialization; Base licenses deduplicated via the `UniqueConstraint__c` unique index; weighted partition via `LM_AssignmentAllocator`). Represents actual utilization and per-purchase assignment.

## CRM Analytics

`force-app/main/default/wave/` contains the analytics layer that surfaces the dashboards: a dataflow (`.wdf`) / recipe (`.wdpr`) pair (`License_Manager_Datasets_Preparation`) prepares datasets, feeding `License_Management_Dashboard`. The recipe produces a `ProductLicensePurchaseUtilization` dataset (raw joined per-purchase facts); the financial dashboard page computes derived metrics (UnitPrice = Price/Quantity, UsedCost = Used×UnitPrice, WasteCost = (Contracted−Used)×UnitPrice, WasteQty = Contracted−Used) in the SAQL layer. After install the CRM Analytics recipe must be run (and can be scheduled) — assign the `License Manager` permission set to the Analytics Integration User first. When changing the data model, keep the dataflow and recipe equivalent (recent commit history shows they are maintained in parallel).

## Permission sets

- `LM_LicenseManager` — full access to the app and data model.
- `LM_LicenseManagerDownloadCRMAnalytics` — only CRM Analytics download (used to list users who haven't logged in within 180 days).

## Commands

```bash
npm run lint              # ESLint over aura/lwc JS (no JS today, but wired up)
npm run test:unit         # sfdx-lwc-jest
npm run test:unit -- <path>   # run a single Jest test file
npm run prettier          # format cls/cmp/component/css/html/js/json/md/page/trigger/xml/yaml
npm run prettier:verify   # check formatting without writing
```

A husky `pre-commit` hook runs `lint-staged` (prettier on most files, eslint on aura/lwc JS). Prettier uses `prettier-plugin-apex` and `@prettier/plugin-xml`.

Deploy metadata with the Salesforce CLI, e.g. `sf project deploy start`. Source API version is `67.0`. Note `.forceignore` excludes `profiles/**`, `package.xml`, and LWC config/test files from source tracking.

## Sample data

`scripts/data/sfdmu/` holds CSV sample data loaded via the [SFDMU](https://help.sfdmu.com/) plugin. `export.json` defines the load order/queries (ProductLicense → Persona → PersonaPurchaseAllocation → PurchaseCondition → UserAssignment, all upserts). Includes add-on licenses (CRM Analytics, HVS) based on real SKU analysis. From an authenticated org:

```bash
cd scripts/data/sfdmu
sf sfdmu run --sourceusername csvfile --targetusername <TARGET USERNAME>
```

`scripts/js/generateProductLicenseUserAssignment.js` uses `@faker-js/faker` to generate bulk fake user-assignment CSV rows (note: it hardcodes a `ProductLicense__c` record Id, adjust before use).

## Conventions

- All custom metadata (objects, fields, tabs, permission sets, reports, apps) uses the `LM_` prefix.
- Portuguese (pt_BR) object translations exist under `objectTranslations/` — keep them in sync when adding fields.
- The package installation key is `Vai Corinthians`.
