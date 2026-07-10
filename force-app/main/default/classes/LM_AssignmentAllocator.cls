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
