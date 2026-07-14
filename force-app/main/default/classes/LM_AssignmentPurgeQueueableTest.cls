@isTest
private class LM_AssignmentPurgeQueueableTest {
  // A running user that holds LM_LicenseManager. The package objects' FLS-restricted fields
  // (LM_ProductLicense__c.Weight__c, LM_ProductLicenseUserAssignment__c.IsActive__c) are granted
  // ONLY by this permission set — profiles are .forceignore'd, so a bare admin (as in the packaging
  // test run) can't set them. Setup + queueable execution runs as this user.
  private static User permsetHolder() {
    // Reuse the running user's profile (UserInfo.getProfileId always resolves) rather than querying
    // a profile by an English name — the packaging test org may have a localized/renamed profile.
    User u = new User(
      Alias = 'lmadm',
      Email = 'lm-purgetest-admin@example.com.invalid',
      EmailEncodingKey = 'UTF-8',
      LastName = 'LMAdmin',
      LanguageLocaleKey = 'en_US',
      LocaleSidKey = 'en_US',
      ProfileId = UserInfo.getProfileId(),
      TimeZoneSidKey = 'America/Sao_Paulo',
      Username = 'lm-purgetest-admin@example.com.invalid'
    );
    insert u;
    PermissionSet ps = [
      SELECT Id
      FROM PermissionSet
      WHERE Name = 'LM_LicenseManager'
      LIMIT 1
    ];
    insert new PermissionSetAssignment(
      AssigneeId = u.Id,
      PermissionSetId = ps.Id
    );
    return u;
  }

  private static LM_ProductLicense__c makeLicense() {
    LM_ProductLicense__c pl = new LM_ProductLicense__c(
      Name = 'X',
      Type__c = 'Base',
      Weight__c = 1,
      Org__c = 'Test Org'
    );
    insert pl;
    return pl;
  }

  private static void seedAssignments(Id plId, Integer count) {
    List<LM_ProductLicenseUserAssignment__c> rows = new List<LM_ProductLicenseUserAssignment__c>();
    for (Integer i = 0; i < count; i++) {
      rows.add(
        new LM_ProductLicenseUserAssignment__c(
          ProductLicense__c = plId,
          Username__c = 'u' + i + '@x.com',
          UniqueConstraint__c = 'u' + i + '@x.com|Base',
          IsActive__c = true
        )
      );
    }
    insert rows;
  }

  @isTest
  static void deletesChunkAndSignalsReloadWhenEmptied() {
    User runner = permsetHolder();

    System.runAs(runner) {
      // Chunk size larger than the seeded rows: one pass empties the table, so the queueable should
      // signal that it would chain the reload batch (chaining itself is suppressed in test context).
      LM_ProductLicense__c pl = makeLicense();
      seedAssignments(pl.Id, 5);
      LM_AssignmentPurgeQueueable.purgeRechained = false;
      LM_AssignmentPurgeQueueable.reloadEnqueued = false;

      Test.startTest();
      System.enqueueJob(new LM_AssignmentPurgeQueueable(100));
      Test.stopTest();

      System.assertEquals(
        0,
        [SELECT COUNT() FROM LM_ProductLicenseUserAssignment__c],
        'all rows purged in a single chunk'
      );
      System.assert(
        LM_AssignmentPurgeQueueable.reloadEnqueued,
        'reload batch enqueued once table is empty'
      );
      System.assert(
        !LM_AssignmentPurgeQueueable.purgeRechained,
        'no re-chain when the table was emptied in one pass'
      );
    }
  }

  @isTest
  static void rechainsWhenRowsRemainAfterChunk() {
    User runner = permsetHolder();

    System.runAs(runner) {
      // Chunk size smaller than the seeded rows: one pass leaves rows behind, so the queueable
      // should signal a re-chain (it would enqueue another purge, not the reload batch).
      LM_ProductLicense__c pl = makeLicense();
      seedAssignments(pl.Id, 5);
      LM_AssignmentPurgeQueueable.purgeRechained = false;
      LM_AssignmentPurgeQueueable.reloadEnqueued = false;

      Test.startTest();
      System.enqueueJob(new LM_AssignmentPurgeQueueable(2));
      Test.stopTest();

      System.assertEquals(
        3,
        [SELECT COUNT() FROM LM_ProductLicenseUserAssignment__c],
        'one chunk of 2 deleted, 3 remain'
      );
      System.assert(
        LM_AssignmentPurgeQueueable.purgeRechained,
        're-chained because rows remain'
      );
      System.assert(
        !LM_AssignmentPurgeQueueable.reloadEnqueued,
        'reload not enqueued while rows remain'
      );
    }
  }

  @isTest
  static void schedulableEntryPointEnqueuesPurge() {
    // The batch's Schedulable entry point must enqueue the purge queueable (not the batch directly).
    Test.startTest();
    new LM_AssignmentGenerationBatch().execute((SchedulableContext) null);
    Integer queued = Limits.getQueueableJobs();
    Test.stopTest();

    System.assertEquals(
      1,
      queued,
      'schedulable entry point enqueued the purge queueable'
    );
  }
}
