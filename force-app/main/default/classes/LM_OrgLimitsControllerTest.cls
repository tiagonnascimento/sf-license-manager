@IsTest
private class LM_OrgLimitsControllerTest {
  @IsTest
  static void getLimits_returnsRowsWithMaxAndUsed() {
    Test.startTest();
    List<LM_OrgLimitsController.LimitRow> rows = LM_OrgLimitsController.getLimits();
    Test.stopTest();
    System.assertNotEquals(
      0,
      rows.size(),
      'OrgLimits.getMap() always returns limits'
    );
    Boolean sawApi = false;
    for (LM_OrgLimitsController.LimitRow r : rows) {
      System.assertNotEquals(null, r.name, 'each row has a name');
      System.assert(r.max >= 0, 'max is non-negative');
      System.assert(r.used >= 0, 'used is non-negative');
      if (r.name == 'DailyApiRequests')
        sawApi = true;
    }
    System.assert(sawApi, 'DailyApiRequests is a standard org limit');
  }

  @IsTest
  static void getEntitlements_runsWithoutError() {
    Test.startTest();
    List<LM_OrgLimitsController.EntitlementRow> rows = LM_OrgLimitsController.getEntitlements();
    Test.stopTest();
    System.assertNotEquals(
      null,
      rows,
      'returns a (possibly empty) list, never null'
    );
  }
}
