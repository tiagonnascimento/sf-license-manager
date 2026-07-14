@isTest
private class LM_AssignmentGenerationBatchTest {
  private static final String LMARK = 'LMBATCHTEST';

  // A running user that holds LM_LicenseManager. The package objects' FLS-restricted fields
  // (e.g. LM_ProductLicense__c.Weight__c, Persona__c.Query__c, *.IsActive__c) are granted ONLY by
  // this permission set — profiles are .forceignore'd, so a bare admin (as in the packaging test
  // run) can't set them. All FLS-touching setup + batch execution runs as this user.
  private static User permsetHolder() {
    // Reuse the running user's profile (UserInfo.getProfileId always resolves) rather than querying
    // a profile by an English name — the packaging test org may have a localized/renamed profile.
    User u = new User(
      Alias = 'lmadm',
      Email = 'lm-batchtest-admin@example.com.invalid',
      EmailEncodingKey = 'UTF-8',
      LastName = 'LMAdmin',
      LanguageLocaleKey = 'en_US',
      LocaleSidKey = 'en_US',
      ProfileId = UserInfo.getProfileId(),
      TimeZoneSidKey = 'America/Sao_Paulo',
      Username = 'lm-batchtest-admin@example.com.invalid'
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

  // Users are setup objects — visible in tests. Create N with a distinctive LastName so the
  // persona query can select exactly our test users.
  private static void makeUsers(Integer count) {
    Profile p = [
      SELECT Id
      FROM Profile
      WHERE Name = 'Minimum Access - Salesforce'
      LIMIT 1
    ];
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
    User runner = permsetHolder();

    System.runAs(runner) {
      // One Base product license, one persona whose query returns the test users,
      // two purchases 60/40.
      LM_ProductLicense__c pl = new LM_ProductLicense__c(
        Name = 'Comms Advanced',
        Type__c = 'Base',
        Weight__c = 10,
        Org__c = 'Test Org'
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
        ContractStartDate__c = Date.newInstance(2025, 1, 1),
        ContractEndDate__c = Date.newInstance(2026, 1, 1),
        Project__c = 'Test Project A',
        IsActive__c = true
      );
      LM_ProductLicensePurchaseCondition__c pcB = new LM_ProductLicensePurchaseCondition__c(
        ProductLicense__c = pl.Id,
        Price__c = 1000,
        Quantity__c = 4,
        PurchaseDate__c = Date.newInstance(2025, 6, 1),
        ContractStartDate__c = Date.newInstance(2025, 6, 1),
        ContractEndDate__c = Date.newInstance(2026, 6, 1),
        Project__c = 'Test Project B',
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
  }

  @isTest
  static void batchDoesNotTruncatePreExistingRows() {
    User runner = permsetHolder();

    System.runAs(runner) {
      // The batch no longer truncates — truncation is owned by LM_AssignmentPurgeQueueable. A stale
      // row must survive a batch run with no personas (nothing to insert, nothing to delete).
      LM_ProductLicense__c pl = new LM_ProductLicense__c(
        Name = 'X',
        Type__c = 'Base',
        Weight__c = 1,
        Org__c = 'Test Org'
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
        1,
        [SELECT COUNT() FROM LM_ProductLicenseUserAssignment__c],
        'batch does not delete; purge queueable owns truncation'
      );
    }
  }
}
