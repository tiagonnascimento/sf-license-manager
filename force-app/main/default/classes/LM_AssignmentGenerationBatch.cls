/**
 * Reload half of the truncate-and-reload materialization of LM_ProductLicenseUserAssignment__c.
 * Reads each Persona, runs its Query__c against the org, partitions the returned users across
 * the persona's purchase allocations (LM_AssignmentAllocator), and inserts one assignment per user
 * stamped with a single PurchaseCondition.
 *
 * Base exclusivity is enforced by the UniqueConstraint__c unique index: personas are processed
 * highest-Weight-first and inserts use allOrNone=false, so a lower-weight Base persona's duplicate
 * users are silently rejected by the index.
 *
 * Query__c contract: SELECT Id, Username, CreatedDate FROM User WHERE <persona disambiguation>.
 *
 * TRUNCATION: This batch assumes LM_ProductLicenseUserAssignment__c is ALREADY EMPTY. It no longer
 * deletes existing rows — a single delete over a large table breaches the 50k query-row limit. The
 * purge is owned by LM_AssignmentPurgeQueueable, which truncates in chunks and then chains this
 * batch. Kick off a full reload via LM_AssignmentPurgeQueueable, never by calling this batch on a
 * non-empty table.
 *
 * INVARIANT: This batch MUST be run at scope=1 (one persona per execute()). The Schedulable entry
 * point enforces this. Each persona's Query__c result set must fit within a single transaction's
 * heap and query-row limits (up to ~50k users). Personas exceeding this boundary are out of scope
 * and should be split into multiple personas.
 */
public with sharing class LM_AssignmentGenerationBatch implements Database.Batchable<SObject>, Database.Stateful, Schedulable {
  public Database.QueryLocator start(Database.BatchableContext ctx) {
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

    // Bulkify allocation loading: query all allocations for personas in scope
    Set<Id> personaIds = new Set<Id>();
    for (SObject s : scope) {
      personaIds.add(s.Id);
    }
    Map<Id, List<LM_AssignmentAllocator.Allocation>> allocationsByPersona = loadAllocationsBulk(
      personaIds
    );

    for (SObject s : scope) {
      LM_ProductLicensePersona__c persona = (LM_ProductLicensePersona__c) s;
      if (String.isBlank(persona.Query__c)) {
        continue; // skip personas with no query
      }
      List<User> matched;
      try {
        matched = (List<User>) Database.query(persona.Query__c);
      } catch (Exception e) {
        System.debug(
          LoggingLevel.ERROR,
          'LM_AssignmentGenerationBatch: persona ' +
            persona.Id +
            ' (' +
            persona.Name +
            ') query failed: ' +
            e.getMessage()
        );
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

      List<LM_AssignmentAllocator.Allocation> allocs = allocationsByPersona.get(
        persona.Id
      );
      if (allocs == null) {
        allocs = new List<LM_AssignmentAllocator.Allocation>();
      }
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
      insertInChunks(toInsert);
    }
  }

  public void finish(Database.BatchableContext ctx) {
  }

  // Schedulable entry point — start a full purge+reload. The purge queueable truncates the table in
  // chunks and chains this batch when empty, so the scheduled job scales past the 50k query-row cap.
  public void execute(SchedulableContext sc) {
    System.enqueueJob(new LM_AssignmentPurgeQueueable());
  }

  private Map<Id, List<LM_AssignmentAllocator.Allocation>> loadAllocationsBulk(
    Set<Id> personaIds
  ) {
    Map<Id, List<LM_AssignmentAllocator.Allocation>> result = new Map<Id, List<LM_AssignmentAllocator.Allocation>>();
    for (LM_PersonaPurchaseAllocation__c a : [
      SELECT
        Persona__c,
        PurchaseCondition__c,
        Weight__c,
        PurchaseCondition__r.PurchaseDate__c
      FROM LM_PersonaPurchaseAllocation__c
      WHERE Persona__c IN :personaIds
    ]) {
      if (!result.containsKey(a.Persona__c)) {
        result.put(a.Persona__c, new List<LM_AssignmentAllocator.Allocation>());
      }
      result.get(a.Persona__c)
        .add(
          new LM_AssignmentAllocator.Allocation(
            a.PurchaseCondition__c,
            a.Weight__c,
            a.PurchaseCondition__r.PurchaseDate__c
          )
        );
    }
    return result;
  }

  private void insertInChunks(
    List<LM_ProductLicenseUserAssignment__c> records
  ) {
    Integer chunkSize = 10000;
    for (Integer i = 0; i < records.size(); i += chunkSize) {
      Integer endIdx = Math.min(i + chunkSize, records.size());
      List<LM_ProductLicenseUserAssignment__c> slice = new List<LM_ProductLicenseUserAssignment__c>();
      for (Integer j = i; j < endIdx; j++) {
        slice.add(records[j]);
      }
      Database.insert(slice, false); // index rejects lower-weight Base duplicates
    }
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
