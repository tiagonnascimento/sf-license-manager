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

  @isTest
  static void nullAllocations_allNull() {
    List<Id> result = LM_AssignmentAllocator.allocate(users(3), null);
    System.assertEquals(3, result.size());
    for (Id r : result)
      System.assertEquals(null, r);
  }

  @isTest
  static void samePurchaseDates_allocatesCorrectly() {
    // Both allocations have same purchaseDate; order in input should be preserved
    List<LM_AssignmentAllocator.Allocation> allocs = new List<LM_AssignmentAllocator.Allocation>{
      new LM_AssignmentAllocator.Allocation(
        PC_A,
        60,
        Date.newInstance(2025, 1, 1)
      ),
      new LM_AssignmentAllocator.Allocation(
        PC_B,
        40,
        Date.newInstance(2025, 1, 1)
      )
    };
    List<Id> result = LM_AssignmentAllocator.allocate(users(10), allocs);
    Integer countA = 0, countB = 0;
    for (Id r : result) {
      if (r == PC_A)
        countA++;
      else if (r == PC_B)
        countB++;
    }
    System.assertEquals(6, countA, 'A should get 60%');
    System.assertEquals(4, countB, 'B should get 40%');
  }

  @isTest
  static void zeroWeights_allNull() {
    // All weights are 0; no allocation should happen
    List<LM_AssignmentAllocator.Allocation> allocs = new List<LM_AssignmentAllocator.Allocation>{
      new LM_AssignmentAllocator.Allocation(
        PC_A,
        0,
        Date.newInstance(2025, 1, 1)
      ),
      new LM_AssignmentAllocator.Allocation(
        PC_B,
        0,
        Date.newInstance(2025, 6, 1)
      )
    };
    List<Id> result = LM_AssignmentAllocator.allocate(users(5), allocs);
    // With zero weights, first allocation (and subsequent) gets 0, last gets remainder
    System.assertEquals(5, result.size());
    for (Integer i = 0; i < 5; i++) {
      System.assertEquals(
        PC_B,
        result[i],
        'All users go to most recent (last allocation after sort)'
      );
    }
  }

  @isTest
  static void nullPurchaseDate_movedToEnd() {
    // Allocation with null purchaseDate should be sorted to end
    List<LM_AssignmentAllocator.Allocation> allocs = new List<LM_AssignmentAllocator.Allocation>{
      new LM_AssignmentAllocator.Allocation(PC_B, 50, null),
      new LM_AssignmentAllocator.Allocation(
        PC_A,
        50,
        Date.newInstance(2025, 1, 1)
      )
    };
    List<Id> result = LM_AssignmentAllocator.allocate(users(10), allocs);
    Integer countA = 0, countB = 0;
    for (Id r : result) {
      if (r == PC_A)
        countA++;
      else if (r == PC_B)
        countB++;
    }
    // A gets 50% (earlier date), B (null purchaseDate, sorted last) gets remainder
    System.assertEquals(5, countA, 'A should get 50%');
    System.assertEquals(5, countB, 'B gets remainder');
  }

  @isTest
  static void capExceeded_adjustsCount() {
    // Test the cap scenario: when assigned + c > total, c is adjusted
    // This is hard to trigger directly, but happens when rounding causes overflow
    List<LM_AssignmentAllocator.Allocation> allocs = new List<LM_AssignmentAllocator.Allocation>{
      new LM_AssignmentAllocator.Allocation(
        PC_A,
        50,
        Date.newInstance(2025, 1, 1)
      ),
      new LM_AssignmentAllocator.Allocation(
        PC_B,
        50,
        Date.newInstance(2025, 6, 1)
      )
    };
    List<Id> result = LM_AssignmentAllocator.allocate(users(3), allocs);
    // 3 users, 50/50 → 1.5 / 1.5 → A rounds to 2, cap check: 0 + 2 = 2 <= 3, ok
    // B gets remainder: 3 - 2 = 1
    Integer countA = 0, countB = 0;
    for (Id r : result) {
      if (r == PC_A)
        countA++;
      else if (r == PC_B)
        countB++;
    }
    System.assertEquals(2, countA, 'A should get 2');
    System.assertEquals(1, countB, 'B gets 1');
    System.assertEquals(3, countA + countB, 'Total should be 3');
  }

  @isTest
  static void bothNullPurchaseDates() {
    // Both allocations have null purchaseDate; first in sorted order is "earlier"
    List<LM_AssignmentAllocator.Allocation> allocs = new List<LM_AssignmentAllocator.Allocation>{
      new LM_AssignmentAllocator.Allocation(PC_A, 60, null),
      new LM_AssignmentAllocator.Allocation(PC_B, 40, null)
    };
    List<Id> result = LM_AssignmentAllocator.allocate(users(10), allocs);
    Integer countA = 0, countB = 0;
    for (Id r : result) {
      if (r == PC_A)
        countA++;
      else if (r == PC_B)
        countB++;
    }
    // When both are null, comparator returns 0 (equal), so order preserved; A gets 60%, B gets remainder
    System.assertEquals(6, countA, 'A should get 60%');
    System.assertEquals(4, countB, 'B gets remainder');
  }
}
