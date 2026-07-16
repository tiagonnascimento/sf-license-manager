# Salesforce Lightning Application for License Management

### Overview

This Salesforce Lightning Application is designed to manage product licenses, user assignments, and purchase conditions. The application leverages custom objects and relationships to track and manage licenses efficiently.

### Motivation

In a Salesforce Org, to accurately determine that a Product License is in use, it is necessary to do more than just observe the assignment of User Licenses, Permission Set Licenses, and Feature Licenses to users.

An analytical layer is essential, utilizing not only these assignments but also other user characteristics such as profile and permissions. This layer does not exist natively in Salesforce Orgs. For a detailed write-up of this license-management problem and why native assignment alone is ambiguous, see [`docs/00-problema-gestao-licencas.md`](docs/00-problema-gestao-licencas.md).

This application is built to provide an infrastructure in terms of data model and data extraction to achieve that end.

### Screenshots

_CRM Analytics dashboard — Base license utilization:_
![Dashboard - base license utilization](https://github.com/tiagonnascimento/sf-license-manager/blob/main/docs/images/home.png?raw=true)

_Dashboard — add-ons and login utilization:_
![Dashboard - add-ons and login utilization](https://github.com/tiagonnascimento/sf-license-manager/blob/main/docs/images/home-addons.png?raw=true)

_Dashboard — users without recent login:_
![Dashboard - users without login](https://github.com/tiagonnascimento/sf-license-manager/blob/main/docs/images/home-users.png?raw=true)

_Dashboard — financial utilization by named license:_
![Dashboard - financial utilization by named license](https://github.com/tiagonnascimento/sf-license-manager/blob/main/docs/images/home-named.png?raw=true)

_Dashboard — org-wide entitlements (capacity limits and usage-based entitlements):_
![Dashboard - org-wide entitlements](https://github.com/tiagonnascimento/sf-license-manager/blob/main/docs/images/home-entitlements.png?raw=true)

_Product License list:_
![Product license list](https://github.com/tiagonnascimento/sf-license-manager/blob/main/docs/images/productLicenseList.png?raw=true)

_Product License detail:_
![Product license detail](https://github.com/tiagonnascimento/sf-license-manager/blob/main/docs/images/productLicenseDetail.png?raw=true)

_Persona detail (the analytical layer — SOQL query defining who uses the license):_
![Persona detail](https://github.com/tiagonnascimento/sf-license-manager/blob/main/docs/images/personaDetail.png?raw=true)

_Purchase Condition detail (commercial terms):_
![Purchase condition detail](https://github.com/tiagonnascimento/sf-license-manager/blob/main/docs/images/purchaseCondition.png?raw=true)

_Purchase detail:_
![Purchase detail](https://github.com/tiagonnascimento/sf-license-manager/blob/main/docs/images/purchaseDetail.png?raw=true)

### Entities and Relationships

The application is built around the following custom objects and their relationships:

1. _ProductLicense\_\_c_ - Contains details about the product license to be managed. Product license is what customer buys from Salesforce. It could be a base license or an add-on.
1. _ProductLicensePersona\_\_c_ - Persona that uses this product license - represented by a SOQL query.
1. _PersonaPurchaseAllocation\_\_c_ - Junction linking Persona to PurchaseCondition with a Weight field for per-purchase allocation.
1. _ProductLicensePurchaseCondition\_\_c_ - As a Product License can have different purchase conditions depending on commercial negotiations, this object will keep a track of these conditions so final prices can be correctly calculated.
1. _ProductLicenseUserAssignment\_\_c_ - Object to represent product license assignment to users. This object is populated automatically by `LM_AssignmentGenerationBatch` based on the Product License persona queries. It represents the analytical aspect required to determine product license utilization in a Salesforce Org, and includes per-purchase assignment stamps for financial tracking.

Several reports were built in the app based in this data model. A CRM Analytics dashboard provides financial utilization analysis (unit price, used cost, idle cost) drilled down to the license level, broken down by Vice-Presidency and Board of Directors, with values in BRL (R$).

### Permissioning

The package contains two permission sets:

1. _License Manager_ - permission set with all required permissions to access the Lightning Application and Data Model. This permission set needs to be assigned to the Analytics Integration User as there is a Analytics Recipe to synchronize the new SObjects with CRM Analytics, so the dashboards can be displayed.
1. _License Manager - Download CRM Analytics_ - permission set with only the permission to Download CRM Analytics data - useful to get the list of users assigned to permissions without login in the past 180 days

Beside these two permission sets, as the application uses CRM Analytics, users need to have the CRM Analytics permission set license and the permission set in order to access the out-of-the-box dashboard.

### Roadmap

~~Based on the Product License Personas, it's possible to implement automations to automatically create and maintain the Assignments.~~ **DELIVERED**: `LM_AssignmentGenerationBatch` now automates UserAssignment generation from persona queries, with Base license deduplication and per-purchase allocation via `PersonaPurchaseAllocation__c`.

~~Link personas to purchase conditions for per-purchase financial tracking.~~ **DELIVERED**: The `PersonaPurchaseAllocation__c` junction and CRM Analytics financial dashboard now provide unit price, waste cost, chargeback allocation, and renewal forecasts per purchase condition.

**v0.3.0** delivered four further improvements:

- **Org-wide entitlements** (issue #3): the `LM_OrgLimitsController` Apex class and `lmOrgLimits` LWC surface org-level capacity limits and usage-based entitlements (from `OrgLimits` and `TenantUsageEntitlement`) directly on the dashboard — metrics that are not attributable per purchase.
- **Multi-org readiness** (issue #4): a recipe-stamped `SourceOrg` dimension (replacing the old `Org__c` text tag) lets the dashboard group dynamically by org. A single install renders as one section; consolidating two or more real orgs is a documented manual extension in [`docs/05-runbook-multi-org.md`](docs/05-runbook-multi-org.md) (Data Sync connections are environment-specific and not packageable).
- **Allocation junction UI** (issue #5): the `PersonaPurchaseAllocation__c` junction now has a page layout, record page, and related lists on both parents, so admins can maintain allocations from the Lightning app.
- **Faceted financial table** (issue #6): the financial utilization table is aggregated to license grain (matching the charts) and reacts to chart selections as a facet filter.

### Distribution and Installation

This application is distributed in form of an unlocked package. You can build your own app based on the code or simply get the package ID on the `sfdx-project.json` and install it directly in your org. Installation key is `Vai Corinthians`.

After installation, please assign the required permission sets to the user. Also, as this app contains CRM analytics recipe, assign the permission set _License Manager_ to the Analytics Integration User and execute the recipe. You can also schedule the recipe to execute in a determined agenda.

### Data sample loading

On `scripts/data/sfdmu` folder there are some data sample that can be used to load sample data after package installation. For that you can use [Salesforce Data Move Utility](https://help.sfdmu.com/) plugin and authenticated in the target org execute:

```
cd scripts/data/sfdmu
sf sfdmu run --sourceusername csvfile --targetusername <TARGET USERNAME>
```

### Contributing to the Repository

If you find any issues or opportunities for improving this repository, fix them! Feel free to contribute to this project by [forking](http://help.github.com/fork-a-repo/) this repository and making changes to the content. Once you've made your changes, share them back with the community by sending a pull request. See [How to send pull requests](http://help.github.com/send-pull-requests/) for more information about contributing to GitHub projects.

### Reporting Issues

If you find any issues with this demo that you can't fix, feel free to report them in the [issues](https://github.com/forcedotcom/sfdx-bitbucket-org/issues) section of this repository.
