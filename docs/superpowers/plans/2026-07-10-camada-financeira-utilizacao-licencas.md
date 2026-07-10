# Camada Financeira de Utilização de Licenças — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Attribute each generated license user-assignment to a specific purchase (deterministically), so the CRM Analytics layer can extract per-purchase financial metrics — waste cost, chargeback, and renewal forecast.

**Architecture:** Three layers. (1) A declarative junction object `LM_PersonaPurchaseAllocation__c` (with an explicit `Weight__c`) declares which population belongs to which purchase and in what proportion. (2) An Apex Batch/Schedulable runs each Persona's `Query__c`, resolves Base-license conflicts, partitions users across purchases by weight, and materializes `LM_ProductLicenseUserAssignment__c` records — each stamped with exactly one `PurchaseCondition__c` (truncate-and-reload). (3) The CRM Analytics recipe aggregates those real records into financial measures grouped by Board/VP/project/date.

**Tech Stack:** Salesforce metadata (CustomObject, CustomField, PermissionSet, CustomObjectTranslation, custom index), Apex (`Database.Batchable`, `Database.Stateful`, `Schedulable`), CRM Analytics recipe (`.wdpr`) + dataflow (`.wdf`), SFDMU sample data. Source API version `62.0`.

## Global Constraints

- All custom metadata uses the `LM_` prefix. (verbatim from CLAUDE.md)
- Source API version is `62.0`. (from `sfdx-project.json`)
- Portuguese (pt_BR) object translations exist under `objectTranslations/` — keep them in sync when adding fields. (verbatim from CLAUDE.md)
- Keep the dataflow (`.wdf`) and recipe (`.wdpr`) equivalent — they are maintained in parallel. (from CLAUDE.md)
- Unlocked package requires ≥75% Apex code coverage to package/deploy to production.
- `UniqueConstraint__c` key is composed in Apex, never a formula on the field. Base key = `Username|Base`; add-on key = `Username|<ProductLicense.Name>`. NO purchase-condition dimension in the key. (from spec §4.3)
- `PurchaseCondition.Price` stays the purchase TOTAL; unit price is derived in Analytics, never persisted. (from spec §4.4)
- Apex never truncates users to fit purchased `Quantity` — overflow surfaces as over-utilization in Analytics. (from spec §5.2)
- New lookups use `lookup` relationships (NOT master-detail) except where noted; `LM_PersonaPurchaseAllocation__c.Persona__c` is master-detail. (from spec §4)

---

## File Structure

**Metadata — create:**

- `force-app/main/default/objects/LM_PersonaPurchaseAllocation__c/LM_PersonaPurchaseAllocation__c.object-meta.xml`
- `force-app/main/default/objects/LM_PersonaPurchaseAllocation__c/fields/Persona__c.field-meta.xml`
- `force-app/main/default/objects/LM_PersonaPurchaseAllocation__c/fields/PurchaseCondition__c.field-meta.xml`
- `force-app/main/default/objects/LM_PersonaPurchaseAllocation__c/fields/Weight__c.field-meta.xml`
- `force-app/main/default/objects/LM_ProductLicenseUserAssignment__c/fields/PurchaseCondition__c.field-meta.xml`
- `force-app/main/default/objects/LM_ProductLicenseUserAssignment__c/fields/Persona__c.field-meta.xml`
- `force-app/main/default/classes/LM_AssignmentAllocator.cls` (+ `.cls-meta.xml`)
- `force-app/main/default/classes/LM_AssignmentAllocatorTest.cls` (+ `.cls-meta.xml`)
- `force-app/main/default/classes/LM_AssignmentGenerationBatch.cls` (+ `.cls-meta.xml`)
- `force-app/main/default/classes/LM_AssignmentGenerationBatchTest.cls` (+ `.cls-meta.xml`)
- pt_BR translations for the new object + fields (paths in Task 3)

**Metadata — modify:**

- `force-app/main/default/permissionsets/LM_LicenseManager.permissionset-meta.xml` (object + field perms + Apex class access)
- `force-app/main/default/wave/License_Manager_Datasets_Preparation.wdpr` (new join + financial nodes)
- `force-app/main/default/wave/License_Manager_Datasets_Preparation.wdf` (mirror of the recipe)
- `scripts/data/sfdmu/export.json` (add junction object + new UserAssignment fields)
- `scripts/data/sfdmu/LM_PersonaPurchaseAllocation__c.csv` (new sample data)

**Responsibility split (Apex):**

- `LM_AssignmentAllocator` — **pure logic**: given users (already sorted) and weighted allocations, return the PurchaseCondition Id for each user. No SOQL, no DML. This is the unit-test sweet spot.
- `LM_AssignmentGenerationBatch` — **orchestration**: truncate, query Personas (ordered by Weight DESC), run each `Query__c`, build assignment records via the allocator, insert with `allOrNone=false` (unique index rejects lower-weight Base duplicates). Also `Schedulable`.

---

## Task 1: Junction object `LM_PersonaPurchaseAllocation__c` + fields

**Files:**

- Create: `force-app/main/default/objects/LM_PersonaPurchaseAllocation__c/LM_PersonaPurchaseAllocation__c.object-meta.xml`
- Create: `force-app/main/default/objects/LM_PersonaPurchaseAllocation__c/fields/Persona__c.field-meta.xml`
- Create: `force-app/main/default/objects/LM_PersonaPurchaseAllocation__c/fields/PurchaseCondition__c.field-meta.xml`
- Create: `force-app/main/default/objects/LM_PersonaPurchaseAllocation__c/fields/Weight__c.field-meta.xml`

**Interfaces:**

- Produces: object `LM_PersonaPurchaseAllocation__c` with master-detail `Persona__c` → `LM_ProductLicensePersona__c` (relationshipName `PersonaPurchaseAllocations`), lookup `PurchaseCondition__c` → `LM_ProductLicensePurchaseCondition__c` (relationshipName `PersonaPurchaseAllocations`), and `Weight__c` (Percent, precision 5 scale 2). Consumed by Task 5 (batch) and Task 6 (recipe).

- [ ] **Step 1: Create the object metadata**

`LM_PersonaPurchaseAllocation__c.object-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">
    <deploymentStatus>Deployed</deploymentStatus>
    <description
  >Junction between a Persona and a Purchase Condition. Declares which population (Persona) belongs to which purchase, and in what proportion (Weight). Consumed by the assignment-generation batch to stamp each generated user assignment with a single purchase condition.</description>
    <enableActivities>false</enableActivities>
    <enableBulkApi>true</enableBulkApi>
    <enableFeeds>false</enableFeeds>
    <enableHistory>false</enableHistory>
    <enableReports>true</enableReports>
    <enableSearch>false</enableSearch>
    <enableSharing>true</enableSharing>
    <enableStreamingApi>true</enableStreamingApi>
    <label>Persona Purchase Allocation</label>
    <nameField>
        <displayFormat>PPA-{00000}</displayFormat>
        <label>Persona Purchase Allocation Name</label>
        <type>AutoNumber</type>
    </nameField>
    <pluralLabel>Persona Purchase Allocations</pluralLabel>
    <sharingModel>ControlledByParent</sharingModel>
    <visibility>Public</visibility>
</CustomObject>
```

- [ ] **Step 2: Create the `Persona__c` master-detail field**

`fields/Persona__c.field-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Persona__c</fullName>
    <description
  >Persona whose query population this allocation splits across purchase conditions.</description>
    <inlineHelpText>The persona this allocation belongs to.</inlineHelpText>
    <label>Persona</label>
    <referenceTo>LM_ProductLicensePersona__c</referenceTo>
    <relationshipLabel>Persona Purchase Allocations</relationshipLabel>
    <relationshipName>PersonaPurchaseAllocations</relationshipName>
    <relationshipOrder>0</relationshipOrder>
    <reparentableMasterDetail>false</reparentableMasterDetail>
    <trackTrending>false</trackTrending>
    <type>MasterDetail</type>
    <writeRequiresMasterRead>false</writeRequiresMasterRead>
</CustomField>
```

- [ ] **Step 3: Create the `PurchaseCondition__c` lookup field**

`fields/PurchaseCondition__c.field-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>PurchaseCondition__c</fullName>
    <description
  >Purchase condition that this slice of the persona population is attributed to.</description>
    <inlineHelpText
  >The purchase condition this allocation attributes users to.</inlineHelpText>
    <label>Purchase Condition</label>
    <referenceTo>LM_ProductLicensePurchaseCondition__c</referenceTo>
    <relationshipLabel>Persona Purchase Allocations</relationshipLabel>
    <relationshipName>PersonaPurchaseAllocations</relationshipName>
    <required>true</required>
    <trackTrending>false</trackTrending>
    <type>Lookup</type>
</CustomField>
```

- [ ] **Step 4: Create the `Weight__c` field**

`fields/Weight__c.field-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Weight__c</fullName>
    <description
  >Partition quota. When the same persona links to more than one purchase of the same product license, its query population is split across those purchases proportionally to this weight. A single allocation means 100% implicitly.</description>
    <inlineHelpText
  >Proportion (percent) of this persona's users attributed to this purchase, when the persona spans multiple purchases.</inlineHelpText>
    <label>Weight</label>
    <precision>5</precision>
    <scale>2</scale>
    <required>true</required>
    <trackTrending>false</trackTrending>
    <type>Percent</type>
</CustomField>
```

- [ ] **Step 5: Validate the object deploys against a scratch org**

Run: `sf project deploy start --source-dir force-app/main/default/objects/LM_PersonaPurchaseAllocation__c --dry-run`
Expected: `Status: Succeeded` (or a real deploy to a scratch org succeeds). If no target org is configured, create one first with the `dx-org-manage` skill.

- [ ] **Step 6: Commit**

```bash
git add force-app/main/default/objects/LM_PersonaPurchaseAllocation__c
git commit -m "feat: add LM_PersonaPurchaseAllocation__c junction (Persona↔PurchaseCondition with weight)"
```

---

## Task 2: New lookups on `LM_ProductLicenseUserAssignment__c`

**Files:**

- Create: `force-app/main/default/objects/LM_ProductLicenseUserAssignment__c/fields/PurchaseCondition__c.field-meta.xml`
- Create: `force-app/main/default/objects/LM_ProductLicenseUserAssignment__c/fields/Persona__c.field-meta.xml`

**Interfaces:**

- Consumes: `LM_ProductLicensePurchaseCondition__c`, `LM_ProductLicensePersona__c` (both already exist).
- Produces: `LM_ProductLicenseUserAssignment__c.PurchaseCondition__c` (lookup, the deterministic stamp) and `LM_ProductLicenseUserAssignment__c.Persona__c` (lookup, provenance). Consumed by Task 5 (batch writes them) and Task 6 (recipe joins/aggregates on `PurchaseCondition__c`).

- [ ] **Step 1: Create the `PurchaseCondition__c` lookup**

`fields/PurchaseCondition__c.field-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>PurchaseCondition__c</fullName>
    <description
  >The single purchase condition this assignment is attributed to. Set deterministically by the assignment-generation batch. Enables per-purchase financial metrics in CRM Analytics.</description>
    <inlineHelpText
  >Which purchase this user's license usage is attributed to.</inlineHelpText>
    <label>Purchase Condition</label>
    <referenceTo>LM_ProductLicensePurchaseCondition__c</referenceTo>
    <relationshipLabel>Product License User Assignments</relationshipLabel>
    <relationshipName>ProductLicenseUserAssignments</relationshipName>
    <trackTrending>false</trackTrending>
    <type>Lookup</type>
</CustomField>
```

- [ ] **Step 2: Create the `Persona__c` lookup**

`fields/Persona__c.field-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Persona__c</fullName>
    <description
  >The persona whose query generated this assignment. Provenance / auditability for the truncate-and-reload run.</description>
    <inlineHelpText
  >Which persona query generated this assignment.</inlineHelpText>
    <label>Persona</label>
    <referenceTo>LM_ProductLicensePersona__c</referenceTo>
    <relationshipLabel>Product License User Assignments</relationshipLabel>
    <relationshipName>ProductLicenseUserAssignments</relationshipName>
    <trackTrending>false</trackTrending>
    <type>Lookup</type>
</CustomField>
```

- [ ] **Step 3: Validate deploy**

Run: `sf project deploy start --source-dir force-app/main/default/objects/LM_ProductLicenseUserAssignment__c/fields/PurchaseCondition__c.field-meta.xml --source-dir force-app/main/default/objects/LM_ProductLicenseUserAssignment__c/fields/Persona__c.field-meta.xml --dry-run`
Expected: `Status: Succeeded`.

- [ ] **Step 4: Commit**

```bash
git add force-app/main/default/objects/LM_ProductLicenseUserAssignment__c/fields/PurchaseCondition__c.field-meta.xml force-app/main/default/objects/LM_ProductLicenseUserAssignment__c/fields/Persona__c.field-meta.xml
git commit -m "feat: add PurchaseCondition__c + Persona__c lookups to UserAssignment"
```

---

## Task 3: pt_BR translations + permission set access

**Files:**

- Create: `force-app/main/default/objectTranslations/LM_PersonaPurchaseAllocation__c-pt_BR/LM_PersonaPurchaseAllocation__c-pt_BR.objectTranslation-meta.xml`
- Create: `force-app/main/default/objectTranslations/LM_PersonaPurchaseAllocation__c-pt_BR/Persona__c.fieldTranslation-meta.xml`
- Create: `force-app/main/default/objectTranslations/LM_PersonaPurchaseAllocation__c-pt_BR/PurchaseCondition__c.fieldTranslation-meta.xml`
- Create: `force-app/main/default/objectTranslations/LM_PersonaPurchaseAllocation__c-pt_BR/Weight__c.fieldTranslation-meta.xml`
- Create: `force-app/main/default/objectTranslations/LM_ProductLicenseUserAssignment__c-pt_BR/PurchaseCondition__c.fieldTranslation-meta.xml`
- Create: `force-app/main/default/objectTranslations/LM_ProductLicenseUserAssignment__c-pt_BR/Persona__c.fieldTranslation-meta.xml`
- Modify: `force-app/main/default/permissionsets/LM_LicenseManager.permissionset-meta.xml`

**Interfaces:**

- Consumes: Task 1 & 2 metadata.
- Produces: full CRUD/FLS on the new object + fields in `LM_LicenseManager`, so the batch's running user (and admins) can read/write them.

- [ ] **Step 1: Create the object translation**

`LM_PersonaPurchaseAllocation__c-pt_BR/LM_PersonaPurchaseAllocation__c-pt_BR.objectTranslation-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<CustomObjectTranslation xmlns="http://soap.sforce.com/2006/04/metadata">
    <caseValues>
        <plural>false</plural>
        <value>Alocação de Compra da Persona</value>
    </caseValues>
    <caseValues>
        <plural>true</plural>
        <value>Alocações de Compra da Persona</value>
    </caseValues>
    <gender>Feminine</gender>
</CustomObjectTranslation>
```

- [ ] **Step 2: Create the three field translations for the junction**

`Persona__c.fieldTranslation-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<CustomFieldTranslation xmlns="http://soap.sforce.com/2006/04/metadata">
    <help
  ><!-- Persona whose query population this allocation splits across purchase conditions. --></help>
    <label>Persona</label>
    <name>Persona__c</name>
    <relationshipLabel>Alocações de Compra da Persona</relationshipLabel>
</CustomFieldTranslation>
```

`PurchaseCondition__c.fieldTranslation-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<CustomFieldTranslation xmlns="http://soap.sforce.com/2006/04/metadata">
    <help
  ><!-- Purchase condition that this slice of the persona population is attributed to. --></help>
    <label>Condição de Compra</label>
    <name>PurchaseCondition__c</name>
    <relationshipLabel>Alocações de Compra da Persona</relationshipLabel>
</CustomFieldTranslation>
```

`Weight__c.fieldTranslation-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<CustomFieldTranslation xmlns="http://soap.sforce.com/2006/04/metadata">
    <help
  ><!-- Partition quota: proportion of this persona's users attributed to this purchase when the persona spans multiple purchases. --></help>
    <label>Peso</label>
    <name>Weight__c</name>
</CustomFieldTranslation>
```

- [ ] **Step 3: Create the two field translations for UserAssignment**

`LM_ProductLicenseUserAssignment__c-pt_BR/PurchaseCondition__c.fieldTranslation-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<CustomFieldTranslation xmlns="http://soap.sforce.com/2006/04/metadata">
    <help
  ><!-- The single purchase condition this assignment is attributed to. --></help>
    <label>Condição de Compra</label>
    <name>PurchaseCondition__c</name>
    <relationshipLabel>Atribuições de Usuário</relationshipLabel>
</CustomFieldTranslation>
```

`LM_ProductLicenseUserAssignment__c-pt_BR/Persona__c.fieldTranslation-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<CustomFieldTranslation xmlns="http://soap.sforce.com/2006/04/metadata">
    <help><!-- The persona whose query generated this assignment. --></help>
    <label>Persona</label>
    <name>Persona__c</name>
    <relationshipLabel>Atribuições de Usuário</relationshipLabel>
</CustomFieldTranslation>
```

- [ ] **Step 4: Add object + field permissions to `LM_LicenseManager`**

Insert an `<objectPermissions>` block for the junction and `<fieldPermissions>` blocks for the 5 new fields. Add near the other `LM_` object/field permissions (order does not matter to the platform, but keep it grouped). Object block:

```xml
<objectPermissions>
        <allowCreate>true</allowCreate>
        <allowDelete>true</allowDelete>
        <allowEdit>true</allowEdit>
        <allowRead>true</allowRead>
        <modifyAllRecords>true</modifyAllRecords>
        <object>LM_PersonaPurchaseAllocation__c</object>
        <viewAllRecords>true</viewAllRecords>
    </objectPermissions>
```

Field blocks (Weight/PurchaseCondition/Persona on the junction are editable; the two on UserAssignment are editable — the batch writes them):

```xml
    <fieldPermissions>
        <editable>true</editable>
        <field>LM_PersonaPurchaseAllocation__c.Weight__c</field>
        <readable>true</readable>
    </fieldPermissions>
    <fieldPermissions>
        <editable>true</editable>
        <field>LM_PersonaPurchaseAllocation__c.PurchaseCondition__c</field>
        <readable>true</readable>
    </fieldPermissions>
    <fieldPermissions>
        <editable>true</editable>
        <field>LM_ProductLicenseUserAssignment__c.PurchaseCondition__c</field>
        <readable>true</readable>
    </fieldPermissions>
    <fieldPermissions>
        <editable>true</editable>
        <field>LM_ProductLicenseUserAssignment__c.Persona__c</field>
        <readable>true</readable>
    </fieldPermissions>
```

> Note: `Persona__c` on the junction is the master-detail field — master-detail fields are always required/controlled and are NOT listed under `<fieldPermissions>` (the platform rejects FLS on master-detail fields). Only add FLS for the four lookup/percent fields above.

- [ ] **Step 5: Validate deploy of translations + permission set**

Run: `sf project deploy start --source-dir force-app/main/default/objectTranslations --source-dir force-app/main/default/permissionsets/LM_LicenseManager.permissionset-meta.xml --dry-run`
Expected: `Status: Succeeded`.

- [ ] **Step 6: Commit**

```bash
git add force-app/main/default/objectTranslations force-app/main/default/permissionsets/LM_LicenseManager.permissionset-meta.xml
git commit -m "feat: pt_BR translations + LM_LicenseManager access for allocation model"
```

---

## Task 4: `LM_AssignmentAllocator` — pure partition logic (TDD)

**Files:**

- Create: `force-app/main/default/classes/LM_AssignmentAllocator.cls` + `.cls-meta.xml`
- Test: `force-app/main/default/classes/LM_AssignmentAllocatorTest.cls` + `.cls-meta.xml`

**Interfaces:**

- Produces:

  - `LM_AssignmentAllocator.Allocation` — inner class with `public Id purchaseConditionId; public Decimal weight; public Date purchaseDate;` and constructor `Allocation(Id purchaseConditionId, Decimal weight, Date purchaseDate)`.
  - `public static List<Id> LM_AssignmentAllocator.allocate(List<Id> sortedUserIds, List<Allocation> allocations)` — returns a list parallel to `sortedUserIds` giving the `PurchaseCondition` Id each user is stamped with. Preconditions: `sortedUserIds` is already ordered by `(CreatedDate ASC, Id ASC)`. The method sorts `allocations` by `purchaseDate ASC` internally. Rounds each slice HALF_UP; the rounding remainder goes to the allocation with the most-recent `purchaseDate` (last after sort). Empty/`null` allocations → all entries `null`. Consumed by Task 5.

- [ ] **Step 1: Write the failing tests**

`LM_AssignmentAllocatorTest.cls`:

```apex
@isTest
private class LM_AssignmentAllocatorTest {
  // Distinct fake Ids for two purchase conditions (15/18-char safe via Id.valueOf on real prefix not needed;
  // use fabricated Ids valid for equality/parallel-list purposes).
  private static Id PC_A = LM_AssignmentAllocatorTest.fakeId(1);
  private static Id PC_B = LM_AssignmentAllocatorTest.fakeId(2);

  private static Id fakeId(Integer n) {
    String s = String.valueOf(n).leftPad(12, '0');
    return Id.valueOf('a01' + s); // 3-char prefix + 12 = 15 chars
  }

  private static List<Id> users(Integer count) {
    List<Id> ids = new List<Id>();
    for (Integer i = 0; i < count; i++) {
      ids.add(Id.valueOf('005' + String.valueOf(i).leftPad(12, '0')));
    }
    return ids;
  }

  @isTest
  static void noAllocations_allNull() {
    List<Id> result = LM_AssignmentAllocator.allocate(
      users(3),
      new List<LM_AssignmentAllocator.Allocation>()
    );
    System.assertEquals(3, result.size());
    for (Id r : result)
      System.assertEquals(null, r);
  }

  @isTest
  static void singleAllocation_allSame() {
    List<LM_AssignmentAllocator.Allocation> allocs = new List<LM_AssignmentAllocator.Allocation>{
      new LM_AssignmentAllocator.Allocation(
        PC_A,
        100,
        Date.newInstance(2025, 1, 1)
      )
    };
    List<Id> result = LM_AssignmentAllocator.allocate(users(5), allocs);
    System.assertEquals(5, result.size());
    for (Id r : result)
      System.assertEquals(PC_A, r);
  }

  @isTest
  static void weighted_60_40_exact() {
    // A: PurchaseDate earlier (gets earliest-created users), 60%; B: later, 40%.
    List<LM_AssignmentAllocator.Allocation> allocs = new List<LM_AssignmentAllocator.Allocation>{
      new LM_AssignmentAllocator.Allocation(
        PC_B,
        40,
        Date.newInstance(2025, 6, 1)
      ),
      new LM_AssignmentAllocator.Allocation(
        PC_A,
        60,
        Date.newInstance(2025, 1, 1)
      )
    };
    List<Id> result = LM_AssignmentAllocator.allocate(users(90), allocs);
    Integer countA = 0, countB = 0;
    for (Id r : result) {
      if (r == PC_A)
        countA++;
      else if (r == PC_B)
        countB++;
    }
    System.assertEquals(54, countA, 'A should get 60% of 90');
    System.assertEquals(36, countB, 'B should get 40% of 90');
    // earliest 54 users → A (earliest purchaseDate)
    for (Integer i = 0; i < 54; i++)
      System.assertEquals(PC_A, result[i]);
    for (Integer i = 54; i < 90; i++)
      System.assertEquals(PC_B, result[i]);
  }

  @isTest
  static void weighted_remainder_goes_to_most_recent_purchase() {
    // 91 users, 60/40 → 54.6 / 36.4 → A rounds to 55, remainder to B (most recent) = 36.
    List<LM_AssignmentAllocator.Allocation> allocs = new List<LM_AssignmentAllocator.Allocation>{
      new LM_AssignmentAllocator.Allocation(
        PC_A,
        60,
        Date.newInstance(2025, 1, 1)
      ),
      new LM_AssignmentAllocator.Allocation(
        PC_B,
        40,
        Date.newInstance(2025, 6, 1)
      )
    };
    List<Id> result = LM_AssignmentAllocator.allocate(users(91), allocs);
    Integer countA = 0, countB = 0;
    for (Id r : result) {
      if (r == PC_A)
        countA++;
      else if (r == PC_B)
        countB++;
    }
    System.assertEquals(55, countA, 'A rounds 54.6 → 55');
    System.assertEquals(
      36,
      countB,
      'B gets the remainder (most recent purchaseDate)'
    );
    System.assertEquals(
      91,
      countA + countB,
      'sum equals total, never truncated'
    );
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `sf apex run test --tests LM_AssignmentAllocatorTest --result-format human --wait 10`
Expected: FAIL — `LM_AssignmentAllocator` class does not exist / compile error.

- [ ] **Step 3: Write the implementation**

`LM_AssignmentAllocator.cls`:

```apex
/**
 * Pure partition logic: given users already sorted by (CreatedDate ASC, Id ASC) and a set of
 * weighted allocations, decide which single PurchaseCondition each user is stamped with.
 * No SOQL, no DML — unit-testable in isolation.
 */
public with sharing class LM_AssignmentAllocator {
  public class Allocation {
    public Id purchaseConditionId;
    public Decimal weight;
    public Date purchaseDate;
    public Allocation(
      Id purchaseConditionId,
      Decimal weight,
      Date purchaseDate
    ) {
      this.purchaseConditionId = purchaseConditionId;
      this.weight = weight;
      this.purchaseDate = purchaseDate;
    }
  }

  private class ByPurchaseDate implements Comparator<Allocation> {
    public Integer compare(Allocation a, Allocation b) {
      if (a.purchaseDate == b.purchaseDate) {
        return 0;
      }
      if (a.purchaseDate == null) {
        return 1;
      } // nulls last
      if (b.purchaseDate == null) {
        return -1;
      }
      return a.purchaseDate < b.purchaseDate ? -1 : 1;
    }
  }

  public static List<Id> allocate(
    List<Id> sortedUserIds,
    List<Allocation> allocations
  ) {
    List<Id> result = new List<Id>();
    Integer total = sortedUserIds == null ? 0 : sortedUserIds.size();

    if (allocations == null || allocations.isEmpty()) {
      for (Integer i = 0; i < total; i++) {
        result.add(null);
      }
      return result;
    }

    allocations.sort(new ByPurchaseDate()); // ASC; last element = most recent purchaseDate

    Decimal sumWeight = 0;
    for (Allocation a : allocations) {
      sumWeight += (a.weight == null ? 0 : a.weight);
    }

    // Slice counts: all but the last are rounded HALF_UP; the last takes the remainder.
    List<Integer> counts = new List<Integer>();
    Integer assigned = 0;
    for (Integer i = 0; i < allocations.size(); i++) {
      if (i == allocations.size() - 1) {
        counts.add(total - assigned); // remainder → most recent purchaseDate
      } else {
        Decimal w = allocations[i].weight == null ? 0 : allocations[i].weight;
        Integer c = (sumWeight == 0)
          ? 0
          : Integer.valueOf(
              ((w / sumWeight) * total).setScale(0, System.RoundingMode.HALF_UP)
            );
        if (assigned + c > total) {
          c = total - assigned;
        }
        counts.add(c);
        assigned += c;
      }
    }

    for (Integer i = 0; i < allocations.size(); i++) {
      for (Integer k = 0; k < counts[i]; k++) {
        result.add(allocations[i].purchaseConditionId);
      }
    }
    return result;
  }
}
```

`LM_AssignmentAllocator.cls-meta.xml` (and identical for every class in this plan, adjusting nothing but the file it pairs with):

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<ApexClass xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>62.0</apiVersion>
    <status>Active</status>
</ApexClass>
```

`LM_AssignmentAllocatorTest.cls-meta.xml`: same content as above.

- [ ] **Step 4: Run tests to verify they pass**

Run: `sf apex run test --tests LM_AssignmentAllocatorTest --result-format human --code-coverage --wait 10`
Expected: PASS, 4/4 tests, `LM_AssignmentAllocator` coverage 100%.

- [ ] **Step 5: Commit**

```bash
git add force-app/main/default/classes/LM_AssignmentAllocator.cls force-app/main/default/classes/LM_AssignmentAllocator.cls-meta.xml force-app/main/default/classes/LM_AssignmentAllocatorTest.cls force-app/main/default/classes/LM_AssignmentAllocatorTest.cls-meta.xml
git commit -m "feat: LM_AssignmentAllocator pure weighted-partition logic + tests"
```

---

## Task 5: `LM_AssignmentGenerationBatch` — orchestration (Batch + Schedulable)

**Files:**

- Create: `force-app/main/default/classes/LM_AssignmentGenerationBatch.cls` + `.cls-meta.xml`
- Test: `force-app/main/default/classes/LM_AssignmentGenerationBatchTest.cls` + `.cls-meta.xml`

**Interfaces:**

- Consumes: `LM_AssignmentAllocator.allocate(...)` and `LM_AssignmentAllocator.Allocation`.
- Produces: `LM_AssignmentGenerationBatch implements Database.Batchable<SObject>, Database.Stateful, Schedulable`. Public contract for a Persona's `Query__c`: it MUST `SELECT Id, Username, CreatedDate FROM User` with whatever `WHERE` disambiguates the persona. The batch reads `Username` and `CreatedDate` from each returned row.

**Design notes (read before implementing):**

- `start()` truncates ALL `LM_ProductLicenseUserAssignment__c`, then returns a `QueryLocator` over Personas ordered `ProductLicense__r.Weight__c DESC NULLS LAST`. Higher-weight Base personas are therefore processed first.
- Base exclusivity is enforced by the existing unique index on `UniqueConstraint__c`. The batch inserts with `Database.insert(records, false)` (allOrNone=false); when a lower-weight Base persona would assign a user already taken by a higher-weight one, the `Username|Base` key collides and that row is silently rejected. This needs NO large in-memory Set — heap-safe at Vivo scale.
- Add-on rows key on `Username|<ProductLicense.Name>`, so distinct add-ons for the same user all insert; the same add-on twice is rejected.
- Per persona: run `Query__c`, sort users by `(CreatedDate ASC, Id ASC)`, load the persona's `PersonaPurchaseAllocations`, call the allocator, build assignment records.
- Scope size 1 (one persona per `execute`) keeps `Query__c` row volume bounded to a single persona's population per transaction and preserves locator ordering for the Base-first guarantee.

- [ ] **Step 1: Write the failing test**

`LM_AssignmentGenerationBatchTest.cls`:

```apex
@isTest
private class LM_AssignmentGenerationBatchTest {
  private static final String LMARK = 'LMBATCHTEST';

  // Users are setup objects — visible in tests. Create N with a distinctive LastName so the
  // persona query can select exactly our test users.
  private static void makeUsers(Integer count) {
    Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
    List<User> us = new List<User>();
    for (Integer i = 0; i < count; i++) {
      String uniq = LMARK + i + System.currentTimeMillis();
      us.add(
        new User(
          FirstName = 'LM',
          LastName = LMARK,
          Email = uniq + '@example.com',
          Username = uniq + '@lmbatchtest.example.com',
          Alias = ('a' + i).left(8),
          TimeZoneSidKey = 'America/Sao_Paulo',
          LocaleSidKey = 'pt_BR',
          EmailEncodingKey = 'UTF-8',
          LanguageLocaleKey = 'en_US',
          ProfileId = p.Id
        )
      );
    }
    insert us;
  }

  @isTest
  static void generatesAssignmentsStampedWithPurchase() {
    makeUsers(10);
    // One Base product license, one persona whose query returns the test users,
    // two purchases 60/40.
    LM_ProductLicense__c pl = new LM_ProductLicense__c(
      Name = 'Comms Advanced',
      Type__c = 'Base',
      Weight__c = 10
    );
    insert pl;
    LM_ProductLicensePersona__c persona = new LM_ProductLicensePersona__c(
      Name = 'Advanced Users',
      ProductLicense__c = pl.Id,
      Query__c = 'SELECT Id, Username, CreatedDate FROM User WHERE LastName = \'' +
        LMARK +
        '\''
    );
    insert persona;
    LM_ProductLicensePurchaseCondition__c pcA = new LM_ProductLicensePurchaseCondition__c(
      ProductLicense__c = pl.Id,
      Price__c = 1000,
      Quantity__c = 6,
      PurchaseDate__c = Date.newInstance(2025, 1, 1),
      IsActive__c = true
    );
    LM_ProductLicensePurchaseCondition__c pcB = new LM_ProductLicensePurchaseCondition__c(
      ProductLicense__c = pl.Id,
      Price__c = 1000,
      Quantity__c = 4,
      PurchaseDate__c = Date.newInstance(2025, 6, 1),
      IsActive__c = true
    );
    insert new List<LM_ProductLicensePurchaseCondition__c>{ pcA, pcB };
    insert new List<LM_PersonaPurchaseAllocation__c>{
      new LM_PersonaPurchaseAllocation__c(
        Persona__c = persona.Id,
        PurchaseCondition__c = pcA.Id,
        Weight__c = 60
      ),
      new LM_PersonaPurchaseAllocation__c(
        Persona__c = persona.Id,
        PurchaseCondition__c = pcB.Id,
        Weight__c = 40
      )
    };

    Test.startTest();
    Database.executeBatch(new LM_AssignmentGenerationBatch(), 1);
    Test.stopTest();

    List<LM_ProductLicenseUserAssignment__c> uas = [
      SELECT Id, PurchaseCondition__c, Persona__c, UniqueConstraint__c
      FROM LM_ProductLicenseUserAssignment__c
    ];
    System.assertEquals(10, uas.size(), 'all 10 test users materialized');
    Integer a = 0, b = 0;
    for (LM_ProductLicenseUserAssignment__c ua : uas) {
      System.assertEquals(persona.Id, ua.Persona__c, 'provenance stamped');
      if (ua.PurchaseCondition__c == pcA.Id)
        a++;
      else if (ua.PurchaseCondition__c == pcB.Id)
        b++;
    }
    System.assertEquals(6, a, '60% of 10');
    System.assertEquals(4, b, '40% of 10');
  }

  @isTest
  static void truncateReloadRemovesStaleRows() {
    // Pre-seed a stale assignment; the batch must delete it in start().
    LM_ProductLicense__c pl = new LM_ProductLicense__c(
      Name = 'X',
      Type__c = 'Base',
      Weight__c = 1
    );
    insert pl;
    insert new LM_ProductLicenseUserAssignment__c(
      ProductLicense__c = pl.Id,
      Username__c = 'stale@x.com',
      UniqueConstraint__c = 'stale@x.com|Base',
      IsActive__c = true
    );

    Test.startTest();
    Database.executeBatch(new LM_AssignmentGenerationBatch(), 1);
    Test.stopTest();

    System.assertEquals(
      0,
      [SELECT COUNT() FROM LM_ProductLicenseUserAssignment__c],
      'stale rows deleted; no persona → no new rows'
    );
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sf apex run test --tests LM_AssignmentGenerationBatchTest --result-format human --wait 10`
Expected: FAIL — `LM_AssignmentGenerationBatch` does not exist.

- [ ] **Step 3: Write the implementation**

`LM_AssignmentGenerationBatch.cls`:

```apex
/**
 * Truncate-and-reload materialization of LM_ProductLicenseUserAssignment__c.
 * Reads each Persona, runs its Query__c against the org, partitions the returned users across
 * the persona's purchase allocations (LM_AssignmentAllocator), and inserts one assignment per user
 * stamped with a single PurchaseCondition.
 *
 * Base exclusivity is enforced by the UniqueConstraint__c unique index: personas are processed
 * highest-Weight-first and inserts use allOrNone=false, so a lower-weight Base persona's duplicate
 * users are silently rejected by the index.
 *
 * Query__c contract: SELECT Id, Username, CreatedDate FROM User WHERE <persona disambiguation>.
 */
public with sharing class LM_AssignmentGenerationBatch implements Database.Batchable<SObject>, Database.Stateful, Schedulable {
  public Database.QueryLocator start(Database.BatchableContext ctx) {
    delete [SELECT Id FROM LM_ProductLicenseUserAssignment__c];
    return Database.getQueryLocator(
      [
        SELECT
          Id,
          Name,
          Query__c,
          ProductLicense__c,
          ProductLicense__r.Name,
          ProductLicense__r.Type__c,
          ProductLicense__r.Weight__c
        FROM LM_ProductLicensePersona__c
        WHERE Query__c != NULL
        ORDER BY ProductLicense__r.Weight__c DESC NULLS LAST
      ]
    );
  }

  public void execute(Database.BatchableContext ctx, List<SObject> scope) {
    List<LM_ProductLicenseUserAssignment__c> toInsert = new List<LM_ProductLicenseUserAssignment__c>();

    for (SObject s : scope) {
      LM_ProductLicensePersona__c persona = (LM_ProductLicensePersona__c) s;
      List<User> matched;
      try {
        matched = (List<User>) Database.query(persona.Query__c);
      } catch (Exception e) {
        continue; // a malformed persona query must not abort the whole batch
      }
      if (matched.isEmpty()) {
        continue;
      }

      // Sort users deterministically: CreatedDate ASC, then Id ASC.
      matched.sort(new UserByCreatedThenId());
      List<Id> sortedUserIds = new List<Id>();
      Map<Id, User> byId = new Map<Id, User>();
      for (User u : matched) {
        sortedUserIds.add(u.Id);
        byId.put(u.Id, u);
      }

      List<LM_AssignmentAllocator.Allocation> allocs = loadAllocations(
        persona.Id
      );
      List<Id> purchasePerUser = LM_AssignmentAllocator.allocate(
        sortedUserIds,
        allocs
      );

      Boolean isBase = persona.ProductLicense__r.Type__c == 'Base';
      String keySuffix = isBase ? 'Base' : persona.ProductLicense__r.Name;

      for (Integer i = 0; i < sortedUserIds.size(); i++) {
        User u = byId.get(sortedUserIds[i]);
        toInsert.add(
          new LM_ProductLicenseUserAssignment__c(
            ProductLicense__c = persona.ProductLicense__c,
            Persona__c = persona.Id,
            PurchaseCondition__c = purchasePerUser[i],
            Username__c = u.Username,
            IsActive__c = true,
            UniqueConstraint__c = u.Username + '|' + keySuffix
          )
        );
      }
    }

    if (!toInsert.isEmpty()) {
      Database.insert(toInsert, false); // index rejects lower-weight Base duplicates
    }
  }

  public void finish(Database.BatchableContext ctx) {
  }

  // Schedulable entry point — chain the batch from a scheduled job.
  public void execute(SchedulableContext sc) {
    Database.executeBatch(new LM_AssignmentGenerationBatch(), 1);
  }

  private List<LM_AssignmentAllocator.Allocation> loadAllocations(
    Id personaId
  ) {
    List<LM_AssignmentAllocator.Allocation> allocs = new List<LM_AssignmentAllocator.Allocation>();
    for (LM_PersonaPurchaseAllocation__c a : [
      SELECT
        PurchaseCondition__c,
        Weight__c,
        PurchaseCondition__r.PurchaseDate__c
      FROM LM_PersonaPurchaseAllocation__c
      WHERE Persona__c = :personaId
    ]) {
      allocs.add(
        new LM_AssignmentAllocator.Allocation(
          a.PurchaseCondition__c,
          a.Weight__c,
          a.PurchaseCondition__r.PurchaseDate__c
        )
      );
    }
    return allocs;
  }

  private class UserByCreatedThenId implements Comparator<User> {
    public Integer compare(User a, User b) {
      if (a.CreatedDate != b.CreatedDate) {
        return a.CreatedDate < b.CreatedDate ? -1 : 1;
      }
      if (a.Id == b.Id) {
        return 0;
      }
      return a.Id < b.Id ? -1 : 1;
    }
  }
}
```

`LM_AssignmentGenerationBatch.cls-meta.xml` and `LM_AssignmentGenerationBatchTest.cls-meta.xml`: same `<ApexClass>` content as Task 4 Step 3.

- [ ] **Step 4: Run tests to verify they pass**

Run: `sf apex run test --tests LM_AssignmentGenerationBatchTest --result-format human --code-coverage --wait 10`
Expected: PASS, 2/2 tests. If the org has no `Standard User` profile, adjust the profile name to one present (e.g. `Minimum Access - Salesforce`).

- [ ] **Step 5: Run the full Apex suite + coverage gate**

Run: `sf apex run test --tests LM_AssignmentAllocatorTest --tests LM_AssignmentGenerationBatchTest --code-coverage --result-format human --wait 10`
Expected: all pass; combined org-wide coverage for the two new classes ≥75%.

- [ ] **Step 6: Static analysis**

Run: `sf code-analyzer run --workspace force-app/main/default/classes --view detail`
Expected: no High/Critical violations on the two new classes. Fix any that appear (common: add `WITH SECURITY_ENFORCED`/`with sharing` — `with sharing` is already declared).

- [ ] **Step 7: Commit**

```bash
git add force-app/main/default/classes/LM_AssignmentGenerationBatch.cls force-app/main/default/classes/LM_AssignmentGenerationBatch.cls-meta.xml force-app/main/default/classes/LM_AssignmentGenerationBatchTest.cls force-app/main/default/classes/LM_AssignmentGenerationBatchTest.cls-meta.xml
git commit -m "feat: LM_AssignmentGenerationBatch — truncate-and-reload assignment materialization"
```

---

## Task 6: CRM Analytics — per-purchase financial layer

**Files:**

- Modify: `force-app/main/default/wave/License_Manager_Datasets_Preparation.wdpr`
- Modify: `force-app/main/default/wave/License_Manager_Datasets_Preparation.wdf`

**Interfaces:**

- Consumes: `LM_ProductLicenseUserAssignment__c.PurchaseCondition__c` (Task 2), `LM_ProductLicensePurchaseCondition__c` fields (existing: `Price__c`, `Quantity__c`, `BoardOfDirectors__c`, `VicePresidency__c`, `Project__c`, `Domain__c`, `ContractStartDate__c`, `ContractEndDate__c`).
- Produces: a new dataset `ProductLicensePurchaseUtilization` with per-purchase measures `AssignedByPurchase`, `UnitPrice`, `WasteQty`, `WasteCost`, `UsedCost`, `ContractedCost`. (`WasteQty` negative = over-utilization.)

**Design notes:**

- The existing `LOAD_DATASET5` already loads UserAssignment. Add `PurchaseCondition__c` to its `fields` list.
- Add an aggregate node grouping UserAssignment by `PurchaseCondition__c` where `IsActive__c = true` → `AssignedByPurchase` (count).
- Join that aggregate (LOOKUP on `PurchaseCondition__c` = PurchaseCondition `Id`) back onto the PurchaseCondition load (`LOAD_DATASET3`), then a `computeExpression` node derives the measures.
- Mirror every change into the `.wdf` (single-line JSON array) so the two stay equivalent.

- [ ] **Step 1: Add `PurchaseCondition__c` to the UserAssignment load in the recipe**

In `.wdpr`, edit `LOAD_DATASET5.parameters.fields` to include `"PurchaseCondition__c"`:

```json
        "fields" : [ "Id", "ProductLicense__c", "PurchaseCondition__c", "IsActive__c", "LastLoginDate__c", "UniqueConstraint__c", "Username__c" ],
```

- [ ] **Step 2: Add the aggregate + join + computeExpression + output nodes**

Insert these four nodes into the `.wdpr` `nodes` object (alongside the existing nodes). Filter to active assignments, count per purchase, join to purchase, compute measures:

```json
    "FILTER_ACTIVE_UA" : {
      "action" : "filter",
      "sources" : [ "LOAD_DATASET5" ],
      "parameters" : { "filterExpressions" : [ { "field" : "IsActive__c", "operator" : "==", "value" : [ "true" ] } ] }
    },
    "AGG_BY_PURCHASE" : {
      "action" : "aggregate",
      "sources" : [ "FILTER_ACTIVE_UA" ],
      "parameters" : {
        "groupings" : [ "PurchaseCondition__c" ],
        "aggregations" : [ { "action" : "count", "name" : "AssignedByPurchase" } ]
      }
    },
    "JOIN_PURCHASE_UTIL" : {
      "action" : "join",
      "sources" : [ "LOAD_DATASET3", "AGG_BY_PURCHASE" ],
      "schema" : { "fields" : [ ], "slice" : { "mode" : "DROP", "ignoreMissingFields" : true, "fields" : [ "Assignment.PurchaseCondition__c" ] } },
      "parameters" : { "joinType" : "LOOKUP", "leftKeys" : [ "Id" ], "rightQualifier" : "Assignment", "rightKeys" : [ "PurchaseCondition__c" ] }
    },
    "COMPUTE_FINANCIALS" : {
      "action" : "computeExpression",
      "sources" : [ "JOIN_PURCHASE_UTIL" ],
      "parameters" : {
        "mergeWithSource" : true,
        "computedFields" : [
          { "name" : "AssignedByPurchase", "type" : "Numeric", "precision" : 18, "scale" : 0, "defaultValue" : "0", "saqlExpression" : "coalesce('Assignment.AssignedByPurchase', 0)" },
          { "name" : "UnitPrice", "type" : "Numeric", "precision" : 18, "scale" : 2, "defaultValue" : "0", "saqlExpression" : "case when Quantity__c > 0 then Price__c / Quantity__c else 0 end" },
          { "name" : "WasteQty", "type" : "Numeric", "precision" : 18, "scale" : 0, "defaultValue" : "0", "saqlExpression" : "Quantity__c - coalesce('Assignment.AssignedByPurchase', 0)" },
          { "name" : "WasteCost", "type" : "Numeric", "precision" : 18, "scale" : 2, "defaultValue" : "0", "saqlExpression" : "(Quantity__c - coalesce('Assignment.AssignedByPurchase', 0)) * (case when Quantity__c > 0 then Price__c / Quantity__c else 0 end)" },
          { "name" : "UsedCost", "type" : "Numeric", "precision" : 18, "scale" : 2, "defaultValue" : "0", "saqlExpression" : "coalesce('Assignment.AssignedByPurchase', 0) * (case when Quantity__c > 0 then Price__c / Quantity__c else 0 end)" },
          { "name" : "ContractedCost", "type" : "Numeric", "precision" : 18, "scale" : 2, "defaultValue" : "0", "saqlExpression" : "Price__c" }
        ]
      }
    },
    "OUTPUT_PURCHASE_UTIL" : {
      "action" : "save",
      "sources" : [ "COMPUTE_FINANCIALS" ],
      "parameters" : {
        "fields" : [ ],
        "dataset" : { "type" : "analyticsDataset", "label" : "Product License Purchase Utilization", "name" : "ProductLicensePurchaseUtilization", "folderName" : "License_Manager_Analytics_App" },
        "measuresToCurrencies" : [ ]
      }
    }
```

- [ ] **Step 3: Add matching `ui.nodes` + `ui.connectors` entries**

In the `.wdpr` `ui.nodes`, add label/position entries for the five new nodes (positions are cosmetic — space them below the existing graph, e.g. `top` 812/952/1092/1232/1372, `left` 112–392). In `ui.connectors`, add:

```json
    , { "source" : "LOAD_DATASET5", "target" : "FILTER_ACTIVE_UA" }
    , { "source" : "FILTER_ACTIVE_UA", "target" : "AGG_BY_PURCHASE" }
    , { "source" : "LOAD_DATASET3", "target" : "JOIN_PURCHASE_UTIL" }
    , { "source" : "AGG_BY_PURCHASE", "target" : "JOIN_PURCHASE_UTIL" }
    , { "source" : "JOIN_PURCHASE_UTIL", "target" : "COMPUTE_FINANCIALS" }
    , { "source" : "COMPUTE_FINANCIALS", "target" : "OUTPUT_PURCHASE_UTIL" }
```

- [ ] **Step 4: Mirror the changes into the `.wdf`**

The `.wdf` is a single-line JSON array whose second element is the stringified graph. Apply the exact same node/connector additions and the `LOAD_DATASET5` field addition there, keeping it valid escaped JSON on one line. (The `.wdf` and `.wdpr` must describe the same graph — CLAUDE.md convention.)

- [ ] **Step 5: Validate deploy of the wave assets**

Run: `sf project deploy start --source-dir force-app/main/default/wave --dry-run`
Expected: `Status: Succeeded`. If the recipe schema rejects a node, open the recipe in Analytics Studio Data Prep to confirm node names/params, then re-export.

- [ ] **Step 6: Commit**

```bash
git add force-app/main/default/wave/License_Manager_Datasets_Preparation.wdpr force-app/main/default/wave/License_Manager_Datasets_Preparation.wdf
git commit -m "feat: per-purchase financial dataset (waste/used/contracted cost) in CRM Analytics recipe"
```

---

## Task 7: Sample data (SFDMU) — allocations + add-ons

**Files:**

- Modify: `scripts/data/sfdmu/export.json`
- Create: `scripts/data/sfdmu/LM_PersonaPurchaseAllocation__c.csv`
- Modify: `scripts/data/sfdmu/LM_ProductLicenseUserAssignment__c.csv` (only if regenerating; otherwise leave — the batch now populates assignments)

**Interfaces:**

- Consumes: all metadata from Tasks 1–2.
- Produces: a loadable sample set that exercises the junction (weighted allocation) and at least one add-on persona.

- [ ] **Step 1: Add the junction to `export.json` load order (after PurchaseCondition, before UserAssignment)**

Insert this object entry into the `objects` array, positioned after the `LM_ProductLicensePurchaseCondition__c` entry and before `LM_ProductLicenseUserAssignment__c`:

```json
    {
      "operation": "Upsert",
      "query": "SELECT Id, Persona__c, PurchaseCondition__c, Weight__c FROM LM_PersonaPurchaseAllocation__c"
    },
```

- [ ] **Step 2: Add the new fields to the UserAssignment query in `export.json`**

Change the UserAssignment entry's query to include the two new lookups:

```json
      "query": "SELECT Id, ProductLicense__c, PurchaseCondition__c, Persona__c, IsActive__c, LastLoginDate__c, Username__c, UniqueConstraint__c FROM LM_ProductLicenseUserAssignment__c"
```

- [ ] **Step 3: Create the allocation sample CSV**

`scripts/data/sfdmu/LM_PersonaPurchaseAllocation__c.csv` — SFDMU matches lookups by the parent CSV's own external ids; use the `Persona__c` and `PurchaseCondition__c` record ids present in the sibling CSVs (open `LM_ProductLicensePersona__c.csv` and `LM_ProductLicensePurchaseCondition__c.csv` to copy real ids). Header + example rows (replace the id values with real ones from those files):

```csv
Persona__c,PurchaseCondition__c,Weight__c
<persona-id-1>,<purchasecondition-id-A>,60
<persona-id-1>,<purchasecondition-id-B>,40
<persona-id-2>,<purchasecondition-id-C>,100
```

- [ ] **Step 4: Load into an authenticated org and run the batch**

Run:

```bash
cd scripts/data/sfdmu
sf sfdmu run --sourceusername csvfile --targetusername <TARGET USERNAME>
cd -
echo "Database.executeBatch(new LM_AssignmentGenerationBatch(), 1);" | sf apex run --target-org <TARGET USERNAME>
```

Expected: SFDMU upserts the four/five objects with no `MissingParentRecordsReport` rows for the junction; the batch job completes and creates UserAssignments with `PurchaseCondition__c` populated.

- [ ] **Step 5: Verify per-purchase attribution**

Run: `sf data query --query "SELECT PurchaseCondition__c, COUNT(Id) c FROM LM_ProductLicenseUserAssignment__c GROUP BY PurchaseCondition__c" --target-org <TARGET USERNAME>`
Expected: counts split across purchase conditions per the weights (no single NULL bucket unless a persona has no allocation).

- [ ] **Step 6: Commit**

```bash
git add scripts/data/sfdmu/export.json scripts/data/sfdmu/LM_PersonaPurchaseAllocation__c.csv
git commit -m "chore: SFDMU sample data for persona-purchase allocations"
```

---

## Task 8: Documentation refresh

**Files:**

- Modify: `CLAUDE.md`
- Modify: `README.md` (roadmap section, if it lists the automation as pending)

**Interfaces:** none (docs only).

- [ ] **Step 1: Update `CLAUDE.md`**

In the "What this is" / data-model sections, note: (a) `LM_PersonaPurchaseAllocation__c` junction now links Persona↔PurchaseCondition with a `Weight__c` quota; (b) `LM_ProductLicenseUserAssignment__c` is now populated by `LM_AssignmentGenerationBatch` (truncate-and-reload, Base dedup via the `UniqueConstraint__c` index, deterministic per-purchase stamp); (c) the repo now HAS Apex — the "no Apex" statement is no longer true.

- [ ] **Step 2: Update `README.md` roadmap**

Move "automate UserAssignment generation" and "link personas to purchase conditions" from roadmap/pending to delivered; mention the new per-purchase financial dataset.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "docs: reflect assignment automation + per-purchase financial layer"
```

---

## Self-Review

**Spec coverage:**

- §2 goal 1 (unit price) → Task 6 `UnitPrice`. ✓
- §2 goal 2 (waste cost) → Task 6 `WasteQty`/`WasteCost`. ✓
- §2 goal 3 (chargeback) → Task 6 `UsedCost` grouped by Board/VP/Project (fields carried through the PurchaseCondition load). ✓
- §2 goal 4 (renewal forecast = contracted cost) → Task 6 `ContractedCost` + `ContractStartDate__c`/`ContractEndDate__c` on the load. ✓
- §4.1 junction (master-detail Persona, lookup PurchaseCondition, Weight) → Task 1. ✓
- §4.2 new lookups on UserAssignment → Task 2. ✓
- §4.3 UniqueConstraint unchanged (`Username|Type`, no purchase dimension) → Task 5 key composition (`Username|Base` / `Username|<name>`); field untouched. ✓
- §4.4 Price stays total, unit derived in Analytics → Task 6. ✓
- §5.1 truncate-and-reload, Base dedup by Weight, two passes, weighted partition, CreatedDate/PurchaseDate ordering, remainder to most recent → Tasks 4 & 5. ✓
- §5.2 overflow never truncated → allocator sums to total (Task 4 test `weighted_remainder_goes_to_most_recent_purchase`); WasteQty negative surfaces it (Task 6). ✓
- §5.3 scale (heap-safe via unique-index dedup, scope 1) → Task 5 design notes. ✓
- §5.4 batch→recipe window → covered by ordering of Task 5 then Task 6 run. ✓
- §6 recipe/dataflow updated in parallel → Task 6. ✓
- §7 tests (Apex ≥75%, Analytics validation, sample data + add-ons) → Tasks 4/5 (tests + coverage), 6 (validate), 7 (sample data). ✓

**Two-pass Base/Add-on note:** the plan collapses the spec's "two passes" into a single ordered locator (Weight DESC) + `allOrNone=false` insert. This is equivalent for Base exclusivity (higher weight inserts first; index rejects the rest) and add-ons are unaffected because they key on the license name, not `Base`. Documented in Task 5 design notes so the implementer understands the substitution.

**Placeholder scan:** the only literal placeholders are `<TARGET USERNAME>` and the CSV `<...-id-...>` tokens in Task 7 — these are genuine per-org runtime values, not deferred design. No "TBD"/"handle later"/"add validation" remain.

**Type consistency:** `LM_AssignmentAllocator.Allocation(Id, Decimal, Date)` and `allocate(List<Id>, List<Allocation>) → List<Id>` are used identically in Task 4 (defined + tested) and Task 5 (consumed). Field API names (`PurchaseCondition__c`, `Persona__c`, `Weight__c`, `UniqueConstraint__c`, `Query__c`, `Type__c`, `Weight__c`, `PurchaseDate__c`, `Price__c`, `Quantity__c`) match the metadata created in Tasks 1–2 and the existing objects verified in the repo. ✓
