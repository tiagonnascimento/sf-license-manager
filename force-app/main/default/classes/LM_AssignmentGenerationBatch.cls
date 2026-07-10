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
        ORDER BY ProductLicense__r.Weight__c DESC NULLS LAST
      ]
    );
  }

  public void execute(Database.BatchableContext ctx, List<SObject> scope) {
    List<LM_ProductLicenseUserAssignment__c> toInsert = new List<LM_ProductLicenseUserAssignment__c>();

    for (SObject s : scope) {
      LM_ProductLicensePersona__c persona = (LM_ProductLicensePersona__c) s;
      if (String.isBlank(persona.Query__c)) {
        continue; // skip personas with no query
      }
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
