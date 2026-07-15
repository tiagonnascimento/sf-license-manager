# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

An unlocked Salesforce package (`LicenseManager`, see `sfdx-project.json`) that adds an **analytical layer** for determining which Salesforce Product Licenses are actually in use. The core insight (see `docs/00-problema-gestao-licencas.md` and `README.md`): native license assignment alone is ambiguous — different products can provision the _same_ Setting Licenses — so this app determines product usage by combining assignments with other user attributes via a per-license SOQL query.

The solution includes **Apex classes** for assignment automation (`LM_AssignmentGenerationBatch`, `LM_AssignmentAllocator`) plus a read-only controller (`LM_OrgLimitsController`) that surfaces org-wide entitlements, and one **LWC** (`lmOrgLimits`) that renders those org limits / usage-based entitlements inside the CRM Analytics dashboard. There are still **no triggers** and no Aura components — the `triggers/` and `aura/` directories remain empty. The rest of the functionality lives in custom objects, Apex batch jobs, reports, permission sets, and a CRM Analytics app.

## Data model

Five custom objects (all prefixed `LM_`, under `force-app/main/default/objects/`):

- **`LM_ProductLicense__c`** — catalog of what is purchased (Base or Add-On). Has `Quantity`/`AssignedQuantity` rollups, `AvailableQuantity` formula, `Weight`, `Type`, `AssignmentType`, `UserType`. (The former `Org__c` text tag was dropped in v0.3.0 — org attribution is now the recipe-stamped `SourceOrg` dimension; see CRM Analytics below.)
- **`LM_ProductLicensePersona__c`** — the analytical layer: holds `Query__c` (SOQL) defining who uses the license. Master-detail to `ProductLicense`.
- **`LM_PersonaPurchaseAllocation__c`** — junction linking Persona to PurchaseCondition with a `Weight__c` quota. Master-detail to `ProductLicensePersona__c`, lookup to `ProductLicensePurchaseCondition__c`. Enables per-purchase financial allocation.
- **`LM_ProductLicensePurchaseCondition__c`** — commercial terms (price, quantity, dates, org hierarchy fields). Maintained by account managers.
- **`LM_ProductLicenseUserAssignment__c`** — detail rows of users assigned to a license (`Username`, `IsActive`, `LastLoginDate`, `UniqueConstraint__c`, `PurchaseCondition__c`, `Persona__c`). Populated by `LM_AssignmentGenerationBatch` (truncate-and-reload materialization; Base licenses deduplicated via the `UniqueConstraint__c` unique index; weighted partition via `LM_AssignmentAllocator`). Represents actual utilization and per-purchase assignment.

## CRM Analytics

`force-app/main/default/wave/` contains the analytics layer that surfaces the dashboards: a dataflow (`.wdf`) / recipe (`.wdpr`) pair (`License_Manager_Datasets_Preparation`) prepares datasets, feeding `License_Management_Dashboard`. The recipe produces a `ProductLicensePurchaseUtilization` dataset (raw joined per-purchase facts); the financial dashboard page computes derived metrics (UnitPrice = Price/Quantity, UsedCost = Used×UnitPrice, WasteCost = (Contracted−Used)×UnitPrice, WasteQty = Contracted−Used) in the SAQL layer. After install the CRM Analytics recipe must be run (and can be scheduled) — assign the `License Manager` permission set to the Analytics Integration User first. When changing the data model, keep the dataflow and recipe equivalent (recent commit history shows they are maintained in parallel).

**`SourceOrg` dimension (multi-org, issue #4).** Each dashboard-feeding dataset is stamped with a `SourceOrg` dimension via a recipe `formula` node (constant `"Primary"` for the single, same-org install), and the dashboard groups dynamically by `SourceOrg` — so a single org renders as one section, with no hardcoded org split. **Recipe formula-node schema is API-version-sensitive**: use `expressionType: "SQL"` + a `fields` array entry with `type: "TEXT"`, `formulaExpression: "'Primary'"` (single-quoted literal), NOT `computeExpression` / `saqlExpression` / `computedFields` — the wrong shape deploys clean but fails at recipe run-time (`Specify fields for the <NODE> node`). Consolidating **two or more real orgs** into one dashboard is not packageable (Data Sync connections are environment-specific) — that is a documented manual extension: see `docs/05-runbook-multi-org.md` (add a per-org input branch, stamp its own `SourceOrg`, append/union before each save) and the illustrative `docs/samples/` reference recipe.

**Org-wide entitlements (issue #3).** `LM_OrgLimitsController` reads `OrgLimits.getMap()` (capacity limits) and `TenantUsageEntitlement` (usage-based entitlements) under `WITH USER_MODE` (`WITH SECURITY_ENFORCED` is removed in API 67.0). The `lmOrgLimits` LWC (target `analytics__Dashboard`) calls both methods imperatively and renders them as tiles; it is embedded as a component widget on a dashboard page. These metrics are org-level and NOT attributable per purchase, so they live outside the named-license financial math.

## Permission sets

- `LM_LicenseManager` — full access to the app and data model.
- `LM_LicenseManagerDownloadCRMAnalytics` — only CRM Analytics download (used to list users who haven't logged in within 180 days).

## Commands

```bash
npm run lint              # ESLint over aura/lwc JS (the lmOrgLimits LWC)
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
